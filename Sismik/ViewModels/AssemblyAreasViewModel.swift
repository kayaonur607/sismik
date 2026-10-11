import Foundation
import CoreLocation
import MapKit

@MainActor
@Observable
final class AssemblyAreasViewModel {
    private(set) var areas: [AssemblyArea] = [] {
        didSet {
            if !areas.isEmpty { viewState = .loaded(areas) }
        }
    }
    private(set) var viewState: ViewState<[AssemblyArea]> = .idle
    private(set) var isRefreshing = false
    private var refreshError: (any Error)?

    var isLoading: Bool { viewState.isInitialLoading }
    var errorMessage: String? {
        (refreshError ?? viewState.failure)?.localizedDescription
    }

    /// Aramanın yapıldığı merkez (kullanıcı konumu veya fallback).
    private(set) var searchCenter: CLLocationCoordinate2D?
    private(set) var isUsingFallbackCenter = false

    /// Verinin kaynağı (arayüzde göstermek için).
    private(set) var sourceLabel: String = ""
    private(set) var isShowingOfflineData = false

    /// Bir önceki yavaş istek daha sonra bitse bile yalnızca en yeni aramanın
    /// ekrana yazılmasını sağlar.
    private var requestGeneration = 0

    private struct RegionCacheEntry {
        let date: Date
        let coordinate: CLLocationCoordinate2D
    }

    private var regionCache: [String: RegionCacheEntry] = [:]
    private let regionCacheTTL: TimeInterval = 30 * 60
    /// Anahtar kullanıcının serbest arama metni olduğundan cache sınırsız
    /// büyüyebilir; uzun oturumlarda süresi dolmuş girdiler birikmesin diye
    /// bu sınıra ulaşınca önce bayatlar, gerekirse en eski girdiler atılır.
    private let regionCacheLimit = 60

    /// Konum henüz alınamadığında ekranı boş bırakmamak için Türkiye içinde güvenli yedek merkez.
    private let fallbackCenter = CLLocationCoordinate2D(latitude: 41.0082, longitude: 28.9784)

    func load(userLocation: CLLocation?,
              categories: Set<EmergencyPlaceCategory>) async {
        let generation = beginRequest()

        let center = userLocation?.coordinate ?? fallbackCenter
        searchCenter = center
        isUsingFallbackCenter = userLocation == nil

        do {
            await hydrateFromCache(near: center, categories: categories, generation: generation)
            let result = try await search(near: center, categories: categories)
            finish(
                result,
                generation: generation,
                emptyMessage: isUsingFallbackCenter
                    ? L("assembly.error.fallbackEmpty")
                    : L("assembly.error.nearbyEmpty")
            )
        } catch {
            fail(error, generation: generation)
        }
    }
    
    func searchRegion(query: String,
                      categories: Set<EmergencyPlaceCategory>) async {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return }

        let generation = beginRequest()

        do {
            let coord = try await coordinate(for: normalizedQuery)
            guard generation == requestGeneration else { return }

            if let coord {
                self.searchCenter = coord
                self.isUsingFallbackCenter = false
                await hydrateFromCache(near: coord, categories: categories, generation: generation)
                let result = try await search(near: coord, categories: categories)
                finish(result, generation: generation, emptyMessage: L("assembly.error.regionEmpty"))
            } else {
                fail(ViewStateError(L("assembly.error.regionNotFound")), generation: generation, preserveData: false)
            }
        } catch {
            fail(
                ViewStateError(String(format: L("assembly.error.searchFailed"), error.localizedDescription)),
                generation: generation
            )
        }
    }

    func reloadCurrent(categories: Set<EmergencyPlaceCategory>) async {
        guard let center = searchCenter else { return }

        let generation = beginRequest()

        do {
            await hydrateFromCache(near: center, categories: categories, generation: generation)
            let result = try await search(near: center, categories: categories)
            finish(result, generation: generation, emptyMessage: L("assembly.error.nearbyEmpty"))
        } catch {
            fail(error, generation: generation)
        }
    }

    private func beginRequest() -> Int {
        requestGeneration += 1
        refreshError = nil
        if areas.isEmpty {
            viewState = .loading
        } else {
            // SWR: son bilinen işaretler yeni arama tamamlanana kadar haritada kalır.
            viewState = .loaded(areas)
            isRefreshing = true
        }
        return requestGeneration
    }

    private func search(
        near center: CLLocationCoordinate2D,
        categories: Set<EmergencyPlaceCategory>
    ) async throws -> AssemblyAreaSearchResult {
        try await AssemblyAreaService.shared.search(
            near: center,
            radius: 2_000,
            categories: categories
        )
    }

    private func hydrateFromCache(
        near center: CLLocationCoordinate2D,
        categories: Set<EmergencyPlaceCategory>,
        generation: Int
    ) async {
        guard let cached = await AssemblyAreaService.shared.cachedSearch(
            near: center,
            categories: categories
        ), generation == requestGeneration else { return }

        areas = cached.areas
        sourceLabel = cached.sourceLabel
        isShowingOfflineData = true
        viewState = .loaded(cached.areas)
        isRefreshing = true
    }

    private func finish(
        _ result: AssemblyAreaSearchResult,
        generation: Int,
        emptyMessage: String
    ) {
        guard generation == requestGeneration else { return }
        isRefreshing = false
        sourceLabel = result.sourceLabel
        isShowingOfflineData = result.usesOfflineCache
        guard !result.areas.isEmpty else {
            areas = []
            viewState = .error(ViewStateError(emptyMessage))
            return
        }
        areas = result.areas
        viewState = .loaded(result.areas)
    }

    private func fail(
        _ error: any Error,
        generation: Int,
        preserveData: Bool = true
    ) {
        guard generation == requestGeneration else { return }
        isRefreshing = false
        if preserveData, !areas.isEmpty {
            refreshError = error
            viewState = .loaded(areas)
        } else {
            areas = []
            sourceLabel = ""
            viewState = .error(error)
        }
    }

    private func coordinate(for query: String) async throws -> CLLocationCoordinate2D? {
        let key = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if let cached = regionCache[key],
           Date().timeIntervalSince(cached.date) < regionCacheTTL {
            return cached.coordinate
        }

        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = query
        searchRequest.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: searchRequest).start()
        guard let firstMapItem = response.mapItems.first else { return nil }

        let coordinate: CLLocationCoordinate2D
        if #available(iOS 26.0, *) {
            coordinate = firstMapItem.location.coordinate
        } else {
            coordinate = firstMapItem.placemark.coordinate
        }
        regionCache[key] = RegionCacheEntry(date: Date(), coordinate: coordinate)
        pruneRegionCacheIfNeeded()
        return coordinate
    }

    private func pruneRegionCacheIfNeeded() {
        guard regionCache.count > regionCacheLimit else { return }
        let now = Date()
        regionCache = regionCache.filter { now.timeIntervalSince($0.value.date) < regionCacheTTL }
        guard regionCache.count > regionCacheLimit else { return }
        // Hepsi hâlâ tazeyse en eskiden başlayarak sınıra kadar küçült.
        let survivors = regionCache
            .sorted { $0.value.date > $1.value.date }
            .prefix(regionCacheLimit)
        regionCache = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }
}
