import Foundation

struct StatisticsTrendBucket: Identifiable {
    let start: Date
    let count: Int
    let maximumMagnitude: Double

    var id: Date { start }
}

/// Sunucudan gelen ham istatistiklerden yalnızca bir kez üretilen görünüm modeli.
/// Sıralama, reduce ve standart sapma hesapları SwiftUI `body` geçişlerinde tekrarlanmaz.
struct StatisticsPresentation {
    let trendBuckets: [StatisticsTrendBucket]
    let strongestQuakes: [GlobalStats.TopQuake]
    let topRegions: [GlobalStats.Region]
    let activityChangePercent: Double
    let dailyAverage: Double
    let averageIntervalMinutes: Double?
    let shallowSharePercent: Int?
    let peakBucket: StatisticsTrendBucket?
    let activeBucketSharePercent: Int?
    let activityVolatilityPercent: Int?
    let significantEventSharePercent: Int?
    let sourceCoverageCount: Int
    let dominantMagnitudeBand: String

    init(stats: GlobalStats) {
        let bucketCount = min(
            stats.bucketStarts.count,
            min(stats.dailyCounts.count, stats.dailyMaxMag.count)
        )
        trendBuckets = (0..<bucketCount).map { index in
            StatisticsTrendBucket(
                start: stats.bucketStarts[index],
                count: stats.dailyCounts[index],
                maximumMagnitude: stats.dailyMaxMag[index]
            )
        }
        strongestQuakes = Array(stats.topQuakes.sorted { lhs, rhs in
            if lhs.magnitude != rhs.magnitude { return lhs.magnitude > rhs.magnitude }
            return (lhs.time ?? .distantPast) > (rhs.time ?? .distantPast)
        }.prefix(6))
        topRegions = Array(stats.topCountries.prefix(6))

        let counts = stats.dailyCounts
        let middle = counts.count / 2
        let earlier = counts.prefix(middle)
        let recent = counts.suffix(counts.count - middle)
        let earlierRate = Double(earlier.reduce(0, +)) / Double(max(1, earlier.count))
        let recentRate = Double(recent.reduce(0, +)) / Double(max(1, recent.count))
        activityChangePercent = earlierRate > 0
            ? (recentRate - earlierRate) / earlierRate * 100
            : (recentRate > 0 ? 100 : 0)

        dailyAverage = Double(stats.total7d) / max(Double(stats.rangeHours) / 24, 1.0 / 24)
        averageIntervalMinutes = stats.total7d > 0
            ? Double(stats.rangeHours * 60) / Double(stats.total7d)
            : nil

        let depthTotal = stats.depthDist.shallow + stats.depthDist.intermediate + stats.depthDist.deep
        shallowSharePercent = depthTotal > 0
            ? Int((Double(stats.depthDist.shallow) / Double(depthTotal) * 100).rounded())
            : nil

        peakBucket = trendBuckets.max { lhs, rhs in
            lhs.count == rhs.count
                ? lhs.maximumMagnitude < rhs.maximumMagnitude
                : lhs.count < rhs.count
        }

        if counts.isEmpty {
            activeBucketSharePercent = nil
            activityVolatilityPercent = nil
        } else {
            activeBucketSharePercent = Int(
                (Double(counts.filter { $0 > 0 }.count) / Double(counts.count) * 100).rounded()
            )
            let mean = Double(counts.reduce(0, +)) / Double(counts.count)
            if mean > 0 {
                let variance = counts.reduce(0.0) { partial, count in
                    partial + pow(Double(count) - mean, 2)
                } / Double(counts.count)
                activityVolatilityPercent = Int((sqrt(variance) / mean * 100).rounded())
            } else {
                activityVolatilityPercent = 0
            }
        }

        significantEventSharePercent = stats.total7d > 0
            ? Int((Double(stats.m45plus) / Double(stats.total7d) * 100).rounded())
            : nil
        sourceCoverageCount = [
            stats.sourceCounts.afad,
            stats.sourceCounts.emsc,
            stats.sourceCounts.usgs,
            stats.sourceCounts.noa ?? 0
        ].filter { $0 > 0 }.count

        let magnitudeBands = [
            ("M < 3", stats.magDist.micro),
            ("M 3–4.4", stats.magDist.light),
            ("M 4.5–5.9", stats.magDist.moderate),
            ("M 6+", stats.magDist.strong + stats.magDist.major)
        ]
        dominantMagnitudeBand = magnitudeBands.max { $0.1 < $1.1 }?.0 ?? "—"
    }
}

@MainActor
@Observable
final class StatisticsViewModel {
    private(set) var viewState: ViewState<GlobalStats> = .idle
    private(set) var isRefreshing = false
    private(set) var presentation: StatisticsPresentation?

    var stats: GlobalStats? { viewState.value }
    var errorMessage: String? { viewState.failure?.localizedDescription }

    private var activeKey = ""
    private var requestGeneration = 0

    func load(
        range: EarthquakeListViewModel.TimeRange,
        region: String?,
        alternateRegion: String?,
        forceRefresh: Bool = false
    ) async {
        let key = "\(range.hours)-\(region ?? "GL")"
        requestGeneration += 1
        let generation = requestGeneration

        // `isRefreshing` eskiden yalnızca mutlu yolda sıfırlanıyordu: görev
        // iptal edilirse (sekme değişimi, `.refreshable` kapsamının sonlanması)
        // son `guard` erken dönüyor ve kart köşesindeki çark sonsuza dek
        // dönmeye devam ediyordu. Çıkış yolu ne olursa olsun temizlenir.
        defer {
            if generation == requestGeneration { isRefreshing = false }
        }

        let keyChanged = activeKey != key
        activeKey = key

        if keyChanged || viewState.value == nil {
            let cached = await GlobalStatsService.shared.lastKnownStats(range: range, region: region)
            guard generation == requestGeneration else { return }
            if let cached {
                display(cached)
                isRefreshing = true
            } else {
                // Bu kapsam için elde hiçbir veri yok. Önceki kapsamın
                // kartlarını ekranda bırakmak yalnızca "yükleniyor" hissini
                // gizlemiyordu, YANLIŞ da okunuyordu: Türkiye rakamları
                // "Dünya" seçiliyken duruyordu. Veri hazırlanana kadar
                // iskelet gösterilir.
                viewState = .loading
                presentation = nil
                isRefreshing = false
            }
        } else {
            // Aynı kapsamın tazelenmesi (aşağı çekme dâhil): kartlar yerinde
            // kalır. İçerik yüksekliği değişmediği için yenileme denetimi
            // toparlanacağı yeri bulabilir — eskiden içerik iskeletle yer
            // değiştirdiğinde kaydırma yarı yolda asılı kalıyordu.
            isRefreshing = true
        }

        // Diğer bölgeyi sekme değiştirilmeden önceden ısıt; mevcut ekranın
        // sonucunu bekletmemesi için bu görev ana isteğin kritik yolunda değildir.
        Task(priority: .utility) {
            _ = await GlobalStatsService.shared.stats(
                range: range,
                region: alternateRegion,
                forceRefresh: false
            )
        }

        let result = await GlobalStatsService.shared.stats(
            range: range,
            region: region,
            forceRefresh: forceRefresh
        )

        guard generation == requestGeneration, !Task.isCancelled else { return }
        if let result {
            display(result)
        } else if viewState.value == nil {
            viewState = .error(ViewStateError(L("error.dataUnavailable")))
        }
    }

    private func display(_ stats: GlobalStats) {
        guard viewState.value != stats else { return }
        presentation = StatisticsPresentation(stats: stats)
        viewState = .loaded(stats)
    }
}
