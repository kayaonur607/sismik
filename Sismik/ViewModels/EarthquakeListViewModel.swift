import Foundation
import SwiftUI
import UIKit
import CoreLocation

@MainActor
@Observable
final class EarthquakeListViewModel {
    /// Varsayılan "Tümü": kaynak ne yayımlıyorsa o gösterilir (AFAD micro dahil).
    private static let defaultMinMagnitude = 0.0

    private(set) var earthquakes: [Earthquake] = [] {
        didSet {
            if !earthquakes.isEmpty {
                viewState = .loaded(earthquakes)
            }
            oldestEarthquakeDate = earthquakes.min(by: { $0.date < $1.date })?.date
            dataRevision += 1
            applyFilters()
            // Harita havuzu `mapQuakes` dolu olsa bile yeni canlı depremler
            // haritaya anında yansıtılmalı. `scheduleMapFiltering` imza karşılaştırması
            // yaptığı için değişiklik yoksa MapKit katmanı gereksiz tetiklenmez.
            scheduleMapFiltering()
        }
    }
    private var oldestEarthquakeDate: Date?
    private(set) var dataRevision = 0
    private(set) var sourceStatuses: [EarthquakeService.SourceStatus] = []
    private(set) var lastUpdated: Date?
    private(set) var viewState: ViewState<[Earthquake]> = .idle
    private(set) var isRefreshing = false
    private(set) var isOffline = false
    private var liveDataLoadTask: Task<Void, Never>?
    private var liveDataLoadGeneration = 0

    var isLoading: Bool { viewState.isInitialLoading || isRefreshing }
    var errorMessage: String? { viewState.failure?.localizedDescription }

    init() {
        // Diskteki son anlık görüntüyü göster; ağ arkada tazeler.
        // Okuma arka plan thread'inde yapılır — açılışta ana thread bloke olmaz.
        Task { @MainActor [weak self] in
            let cached = await QuakeCache.shared.load()
            guard let self, self.earthquakes.isEmpty, !cached.isEmpty else { return }
            self.earthquakes = cached
            // Ağ yokken açılışta da deprem anı ekranı diskteki listeden çıkar.
            StrongQuakeMonitor.shared.evaluate(cached)
        }

        // Yoğun harita arşivi canlı liste önbelleğinden ayrı tutulur. Diskteki
        // son sonuç MapKit oluşturulmadan önce filtrelenmeye başlar; ağ isteği
        // daha sonra aynı veriyi sessizce tazeler.
        Task { @MainActor [weak self] in
            let cached = await QuakeCache.shared.loadMapArchive()
            guard let self, self.mapQuakes.isEmpty, !cached.isEmpty else { return }
            self.mapQuakes = cached
            self.mapViewState = .loaded(cached)
        }
    }

    // MARK: Filtreler
    private var isBatching = false

    var searchText: String = "" { didSet { if searchText != oldValue && !isBatching { scheduleFilters() } } }
    var minMagnitude: Double = defaultMinMagnitude { didSet { if minMagnitude != oldValue && !isBatching { scheduleFilters() } } }
    var enabledSources: Set<String> = Set(EarthquakeListViewModel.defaultSources) {
        didSet {
            guard enabledSources != oldValue else { return }
            // Kaynak değişince geçmiş arşivi baştan denenebilir olmalı.
            reachedHistoryEnd = false
            if !isBatching { scheduleFilters() }
        }
    }
    /// Sıralama tek dokunuşluk bir eylem: debounce'a girmez, filtre ANINDA
    /// uygulanır — segment değişimiyle liste aynı karede akmaya başlar.
    var sortMode: SortMode = .newest { didSet { if sortMode != oldValue && !isBatching { applyFilters() } } }

    /// Kullanıcı kaynaklı hızlı filtre değişimlerini (arama yazımı, slider) tek bir
    /// hesaplamada birleştirir — her tuşta detached görev açmaz.
    private var filterDebounce: Task<Void, Never>?
    private var filteringTask: Task<Void, Never>?
    private func scheduleFilters() {
        filterDebounce?.cancel()
        filterDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.applyFilters()
        }
    }

    private(set) var filteredAll: [Earthquake] = []
    private(set) var filtered: [Earthquake] = []
    private(set) var featuredQuake: Earthquake?

    /// Son uygulanan sıralama — applyFilters, sıralama değişimini (yer
    /// değiştirme animasyonu) diğer güncellemelerden ayırt etmek için kullanır.
    private var lastAppliedSortMode: SortMode = .newest
    /// Son uygulanan veri revizyonu — veri tazelemesini (animasyonsuz)
    /// kullanıcı filtre eylemlerinden (animasyonlu) ayırt eder.
    private var lastAppliedDataRevision = -1

    /// Son yenilemede akışa YENİ katılan deprem kimlikleri — listede vurgulu
    /// (animasyonlu) gösterilir, birkaç saniye sonra kendiliğinden söner.
    private(set) var freshQuakeIDs: Set<String> = []
    private var freshClearTask: Task<Void, Never>?

    /// Liste penceresi: gezinme, sıralama ve arama dahil TÜM kullanıcılar için
    /// (Premium fark etmeksizin) yalnızca son 24 saatteki depremler gösterilir.
    nonisolated static var listWindowCutoff: Date {
        Date().addingTimeInterval(-86_400)
    }

    // MARK: Genişletilmiş 34 günlük havuz (liste araması + harita)

    /// Sunucunun `/map` ucundan gelen yoğun veri seti: en fazla son 34 gün, tüm kaynaklar.
    /// AFAD mikro depremleri dahil tam arşiv olabildiğinden on binlerce kayıt
    /// içerebilir. Açılışta yüklenir; liste aramasını
    /// genişletir (EMSC/USGS/NOA için de AFAD gibi tam arşiv aranabilir olsun diye)
    /// — ama haritanın GÖSTERDİĞİ küme aşağıdaki bağımsız harita filtreleriyle
    /// belirlenir, liste filtrelerinden (kaynak/büyüklük/arama/sıra) etkilenmez.
    private(set) var mapQuakes: [Earthquake] = [] {
        didSet {
            oldestMapDate = mapQuakes.min(by: { $0.date < $1.date })?.date
            applyFilters()
            scheduleMapFiltering()
        }
    }
    private var oldestMapDate: Date?
    private var mapDataFetchedAt: Date?
    private var mapDataLoadTask: Task<[Earthquake], Never>?
    private(set) var mapViewState: ViewState<[Earthquake]> = .idle
    private(set) var isMapRefreshing = false

    // MARK: Harita filtreleri (listeden tamamen bağımsız)

    /// Haritanın kendi kaynak/büyüklük/zaman seçimi — liste filtresinden ayrı;
    /// biri değiştiğinde diğerini etkilemez.
    var mapSource: String = "all" { didSet { if mapSource != oldValue { scheduleMapFiltering() } } }
    var mapMinMagnitude: Double = 0 { didSet { if mapMinMagnitude != oldValue { scheduleMapFiltering() } } }
    var mapTimeRange: TimeRange = .day { didSet { if mapTimeRange != oldValue { scheduleMapFiltering() } } }

    /// Haritada gösterilen küme: canlı akış (taze) + 34 günlük havuz (derinlik)
    /// birleştirilir, yalnızca `mapSource`/`mapMinMagnitude`/`mapTimeRange`
    /// uygulanır — liste filtrelerinden hiç etkilenmez.
    private(set) var mapFiltered: [Earthquake] = []
    /// `EarthquakeMapView`'in yeniden çizim gerekip gerekmediğini anlaması için
    /// ayrı sayaç — liste `dataRevision`'ından bağımsız değişir.
    private(set) var mapDataRevision = 0

    private var mapFilterTask: Task<Void, Never>?
    private var mapFilterGeneration = 0
    private var mapFilteredSignature = ""

    /// Filtrelenmiş kümenin ucuz imzası. Kimlikler karıştırılırken sıra da
    /// hesaba katılır, dolayısıyla aynı kayıtların farklı sıralanması da
    /// değişiklik sayılır — nokta katmanı sıralı kayıtlarla kuruluyor.
    private static func mapSignature(of quakes: [Earthquake]) -> String {
        var hasher = Hasher()
        hasher.combine(quakes.count)
        for quake in quakes { hasher.combine(quake.id) }
        return "\(quakes.count):\(hasher.finalize())"
    }

    /// Aynı render turundaki veri/kaynak/zaman değişikliklerini tek hesaplamada
    /// birleştirir. Yoğun 34 günlük filtreleme arka planda yapılır; aynı sonuç
    /// yeniden oluşursa MapKit revision'ı artırılmaz.
    private func scheduleMapFiltering() {
        mapFilterTask?.cancel()
        mapFilterGeneration += 1
        let generation = mapFilterGeneration
        let source = mapSource
        let minMagnitude = mapMinMagnitude
        let cutoff = mapTimeRange.cutoff
        let livePool = earthquakes
        let archivePool = mapQuakes

        mapFilterTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                let pool: [Earthquake]
                if archivePool.isEmpty {
                    pool = livePool
                } else if livePool.isEmpty {
                    pool = archivePool
                } else {
                    var combined = livePool
                    let liveIDs = Set(livePool.map(\.id))
                    for q in archivePool where !liveIDs.contains(q.id) {
                        combined.append(q)
                    }
                    pool = combined
                }

                // Tüm kaynaklarda aynı deprem tek nokta (resmî ajans kaydı):
                // ajansların farklı konumlarıyla üç ayrı nokta çiziliyordu
                // (24 Eyl Şanlıurfa). Tekilleştirme büyüklük filtresinden ÖNCE:
                // yoksa M5+ filtresinde AFAD 4.9 elenip aynı depremin EMSC 5.1
                // kaydı kalırdı.
                let windowed = cutoff.map { cutoff in pool.filter { $0.date >= cutoff } } ?? pool
                let sourced = source == "all"
                    ? AftershockSequence.deduplicatedAgencyCopies(windowed)
                    : windowed.filter { $0.sourceTag == source }
                return minMagnitude <= 0 ? sourced : sourced.filter { $0.magnitude >= minMagnitude }
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.mapFilterGeneration == generation else { return }

            // Aynı küme yeniden hesaplandıysa MapKit'e gereksiz revision
            // göndermeyerek nokta katmanının baştan kurulmasını önle.
            //
            // Karşılaştırma ucuz bir imza üzerinden yapılır: eskiden on binlerce
            // kaydın kimliği VE koordinatları tek tek karşılaştırılıyordu, üstelik
            // sonuç değişmediğinde de. Sayı + ilk/son kimlik + kimlik karması,
            // filtrelenmiş kümenin değişip değişmediğini aynı kesinlikte söyler.
            let signature = Self.mapSignature(of: result)
            guard signature != self.mapFilteredSignature else { return }

            self.mapFilteredSignature = signature
            self.mapFiltered = result
            self.mapDataRevision += 1
        }
    }

    /// Harita filtre rozetinde gösterilecek aktif filtre sayısı. Kaynak
    /// seçici artık UI'da yok (harita her zaman tüm kaynakları tekilleştirerek
    /// gösterir), bu yüzden yalnızca büyüklük ve zaman aralığı sayılır.
    var mapActiveFilterCount: Int {
        var n = 0
        if mapMinMagnitude != 0 { n += 1 }
        if mapTimeRange != .day { n += 1 }
        return n
    }

    /// Büyüklük sıralamasında son 24 saatlik verinin hâlâ derlendiğini gösteren
    /// durum. Sıralama her zaman 24 saatle sınırlı olduğundan pencere dolunca söner.
    var isSortingAndLoadingArchive: Bool {
        guard sortMode == .magnitude, olderDataAvailable else { return false }
        guard let oldest = oldestLoadedDate else { return false }
        return oldest > Date().addingTimeInterval(-86_400)
    }

    /// Açılışta ve periyodik yenilemede çağrılır; 5 dakikalık tazelik penceresi vardır.
    func loadMapData(force: Bool = false) async {
        if !force, let fetchedAt = mapDataFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 300, !mapQuakes.isEmpty {
            mapViewState = .loaded(mapQuakes)
            return
        }
        // Harita ve İstatistik sekmeleri aynı anda göründüğünde aynı yoğun
        // arşiv isteğini paylaş. Görevi oluşturan çağrı sonucu tek kez uygular.
        if let mapDataLoadTask {
            _ = await mapDataLoadTask.value
            if !force { return }
        }
        let fallbackData = mapQuakes.isEmpty ? earthquakes : mapQuakes
        if fallbackData.isEmpty {
            mapViewState = .loading
        } else {
            mapViewState = .loaded(fallbackData)
            isMapRefreshing = true
        }
        defer { isMapRefreshing = false }
        // Harita en fazla 30 gün gösterdiği için 34 günlük saklama sınırının
        // gereksizdi — daha küçük yanıt, daha hızlı harita açılışı.
        let task = Task {
            await EarthquakeService.shared.fetchMapData(
                days: 30,
                minMagnitude: 0,
                forceRefresh: force
            )
        }
        mapDataLoadTask = task
        let data = await task.value
        mapDataLoadTask = nil
        guard !data.isEmpty else {
            if fallbackData.isEmpty {
                mapViewState = .error(ViewStateError(L("error.dataUnavailable")))
            }
            return
        }
        mapDataFetchedAt = Date()
        let changed = mapQuakes != data
        if changed {
            mapQuakes = data
        }
        mapViewState = .loaded(data)
        // Arşiv değişmediyse (sunucu 304) ~10 MB'lık dosya yeniden yazılmaz.
        if changed {
            await QuakeCache.shared.saveMapArchive(data)
        }
    }

    /// Elimizdeki en eski kayıt (canlı akış + genişletilmiş havuz birlikte).
    /// Minimumlar veri değiştiğinde bir kez hesaplanır; `canLoadMore` gibi sık
    /// okunan özellikler on binlerce harita kaydını her body turunda taramaz.
    private var oldestLoadedDate: Date? {
        [oldestEarthquakeDate, oldestMapDate]
            .compactMap { $0 }
            .min()
    }

    enum TimeRange: String, CaseIterable, Identifiable {
        case hour = "Son 1 saat"
        case day = "Son 24 saat"
        case week = "Son 7 gün"
        case month = "Son 30 gün"
        var id: String { rawValue }
        /// 7 günden uzun aralıklar Premium gerektirir (hour/day/week ücretsiz).
        var isPremium: Bool {
            switch self {
            case .hour, .day, .week: return false
            case .month: return true
            }
        }
        var title: String {
            switch self {
            case .hour: return L("time.hour")
            case .day:  return L("time.day")
            case .week: return L("time.week")
            case .month: return L("time.month")
            }
        }
        var shortTitle: String {
            switch self {
            case .hour: return L("1 sa")
            case .day: return L("24 sa")
            case .week: return L("7 gün")
            case .month: return L("30 gün")
            }
        }
        var hours: Int {
            switch self {
            case .hour: return 1
            case .day: return 24
            case .week: return 24 * 7
            case .month: return 24 * 30
            }
        }
        var cutoff: Date? { Date().addingTimeInterval(-Double(hours) * 3_600) }
    }

    /// Haritada sunulan zaman aralıkları: en fazla 30 gün. Daha uzun
    /// dönem görünümü İstatistik sekmesinde kaldı; haritada binlerce ek
    /// işaretin performans maliyeti dışında bir katkısı yoktu.
    static let mapTimeRanges: [TimeRange] = [.hour, .day, .week, .month]

    enum SortMode: String, CaseIterable, Identifiable {
        case newest
        case magnitude

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newest: return L("list.sort.newest")
            case .magnitude: return L("list.sort.largest")
            }
        }

        var icon: String {
            switch self {
            case .newest: return "clock"
            case .magnitude: return "bolt.fill"
            }
        }
    }

    /// Kaynak filtresinin anahtarları (`QuakeProviderStyle.tag`). 2.1.4 ile
    /// Kandilli (KOERI), JMA (Japonya), CENC (Çin), BMKG (Endonezya) ve GeoNet
    /// (Yeni Zelanda) eklendi.
    nonisolated static let allSources = ["AFAD", "KANDİLLİ", "EMSC", "USGS", "NOA", "JMA", "CENC", "BMKG", "GEONET"]

    /// İlk açılış kaynağı cihazın bölgesine göre belirlenir. Uygulama içi dil
    /// seçimi ülke sayılmaz: Türkiye bölgesinde AFAD, diğer yerlerde EMSC.
    nonisolated static var defaultSource: String {
        defaultSource(for: Locale.current.region?.identifier)
    }

    /// Liste kaynak filtresinin ilk açılış değeri: her yerde TÜM kaynaklar.
    ///
    /// Eskiden Türkiye'deki kullanıcılar yalnızca AFAD görüyordu. Ölçüldü
    /// (9 Eylül 2026, Muğla M2.9): EMSC olayı 09:12:05'te yayımladı, AFAD aynı
    /// olayı ~09:19'da — yani liste, veri altı dakikadır elimizdeyken boş
    /// kaldı. AFAD'ın yayım gecikmesi listenin de bildirimin de tek darboğazıydı.
    ///
    /// "Tümü" seçiliyken `deduplicatedByPhysicalEvent` devreye girdiği için
    /// aynı deprem iki sağlayıcıdan iki satır olarak görünmez; bölgenin resmî
    /// ajansının kaydı kalır. Kullanıcı isterse filtreden tek kaynağa dönebilir.
    nonisolated static var defaultSources: [String] { allSources }

    /// Saf yardımcı, ülke kuralını görünümden ve konum izninden bağımsız tutar.
    nonisolated static func defaultSource(for regionCode: String?) -> String {
        regionCode?.uppercased() == "TR" ? "AFAD" : "EMSC"
    }


    /// Premium bittiğinde/olmadığında harita aralığını ücretsiz sınıra (7 gün) çeker.
    func clampRangesForPremium(_ isPremium: Bool) {
        guard !isPremium else { return }
        if mapTimeRange.isPremium { mapTimeRange = .week }
    }

    func applyFilters() {
        filteringTask?.cancel()

        let earthquakes = self.earthquakes
        let mapQuakes = self.mapQuakes
        let searchText = self.searchText
        let minMagnitude = self.minMagnitude
        let allowedTags = self.enabledSources
        let sortMode = self.sortMode
        let visibleCount = self.visibleCount

        let dataRevision = self.dataRevision

        filteringTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
            let hasSearch = !query.isEmpty

            // Pencere kuralı: gezinme, sıralama ve arama — hepsi tüm
            // kullanıcılar için son 24 saatle sınırlıdır.
            let cutoff = Self.listWindowCutoff

            /// Arama ve sayfalama hariç ortak süzgeç.
            // "Tümü"de büyüklük eşiği tekilleştirmeden SONRA uygulanır: önce
            // uygulansaydı M4+ filtresinde AFAD 3.9 elenip aynı depremin EMSC
            // 4.1 kaydı görünürdü.
            let dedupesSources = allowedTags == Set(EarthquakeListViewModel.allSources)
            func passesBaseFilters(_ eq: Earthquake) -> Bool {
                // Büyüklük eşiği TÜM kaynaklara aynı uygulanır (AFAD dahil).
                // Varsayılan "Tümü" (0.0) olduğundan AFAD micro depremleri yine
                // görünür; kullanıcı M 3.0+ seçtiğinde AFAD da filtrelenir.
                guard dedupesSources || minMagnitude <= 0 || eq.magnitude >= minMagnitude else { return false }

                // Katı kaynak filtresi: yalnızca seçili kaynağın kayıtları gösterilir.
                guard allowedTags.contains(eq.sourceTag) else { return false }
                if eq.date < cutoff { return false }
                return true
            }

            func matchesSearch(_ eq: Earthquake) -> Bool {
                guard hasSearch else { return true }
                if eq.displayTitle.range(of: query, options: .caseInsensitive) != nil { return true }
                if let epi = eq.locationProperties.epiCenter?.name,
                   epi.range(of: query, options: .caseInsensitive) != nil { return true }
                if let city = eq.locationProperties.closestCity?.name,
                   city.range(of: query, options: .caseInsensitive) != nil { return true }
                return false
            }

            // Liste yalnızca son 24 saati ve seçili kaynağı gösterir. 34 günlük
            // harita havuzunun tamamını sıralamak yerine önce temel filtreyi
            // uygula; böylece geniş AFAD arşivinde liste filtreleri de akıcı kalır.
            var seenIDs = Set<String>()
            seenIDs.reserveCapacity(earthquakes.count + min(mapQuakes.count, 1000))
            var pool: [Earthquake] = []
            pool.reserveCapacity(earthquakes.count + min(mapQuakes.count, 1000))
            for eq in earthquakes where passesBaseFilters(eq) {
                pool.append(eq)
                seenIDs.insert(eq.id)
            }
            for eq in mapQuakes where passesBaseFilters(eq) && !seenIDs.contains(eq.id) {
                pool.append(eq)
                seenIDs.insert(eq.id)
            }

            // Yalnızca "Tümü" kaynak seçiliyken çapraz kaynak tekilleştirmesi
            // uygulanır: tek bir kaynağa filtrelenmişken (ör. yalnızca AFAD)
            // bu, o kaynağın gerçek kayıtlarını başka bir sağlayıcının aynı
            // olayı farklı büyüklükle yayımlamasıyla gizleyebilir — aynı kural
            // sunucudaki `deduplicateQuakes`'te de geçerli.
            if dedupesSources {
                pool = Self.deduplicatedByPhysicalEvent(pool)
                if minMagnitude > 0 { pool.removeAll { $0.magnitude < minMagnitude } }
            }

            // Büyüklük modu aşağıda kendi sırasını kurar; aynı havuzu önce
            // tarihe göre sıralamak gereksiz ikinci bir O(n log n) geçiştir.
            if sortMode == .newest {
                pool.sort { $0.date > $1.date }
            }

            if Task.isCancelled { return }

            var all: [Earthquake] = []
            all.reserveCapacity(pool.count)
            var featuredCandidate: Earthquake?

            for eq in pool {
                if Task.isCancelled { return }
                // Pencere sınırı passesBaseFilters'ta uygulandı (son 24 saat);
                // arama yalnızca metin eşleşmesini kontrol eder.
                if matchesSearch(eq) {
                    all.append(eq)
                    if !hasSearch,
                       featuredCandidate.map({ eq.magnitude > $0.magnitude }) ?? true {
                        featuredCandidate = eq
                    }
                }
            }

            if Task.isCancelled { return }

            let finalAll: [Earthquake]
            switch sortMode {
            case .newest:
                finalAll = all
            case .magnitude:
                finalAll = all.sorted {
                    if $0.magnitude == $1.magnitude {
                        return $0.date > $1.date
                    }
                    return $0.magnitude > $1.magnitude
                }
            }
            let filteredPrefix = Array(finalAll.prefix(visibleCount))
            // `pool` zaten son 24 saat penceresine indirgenmiş durumda.
            // Adayı yukarıdaki tek geçişte seçerek ek filter + max taramasını
            // ve geçici dizi tahsisini ortadan kaldır.
            let featured = hasSearch ? nil : featuredCandidate

            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                // Yarış durumunu önlemek için: veriler değiştiyse uygulamıyoruz
                guard searchText == self.searchText
                        && dataRevision == self.dataRevision
                        && sortMode == self.sortMode
                        && minMagnitude == self.minMagnitude
                        && allowedTags == self.enabledSources
                        && visibleCount == self.visibleCount else { return }

                let apply = {
                    self.filteredAll = finalAll
                    self.filtered = filteredPrefix
                    self.featuredQuake = featured
                }
                let isSortChange = self.lastAppliedSortMode != sortMode
                self.lastAppliedSortMode = sortMode
                // Veri kaynaklı güncelleme mi (yenileme/sayfalama/ilk yükleme),
                // kullanıcı eylemi mi (sıralama/filtre/arama)?
                let isDataRefresh = self.lastAppliedDataRevision != dataRevision
                self.lastAppliedDataRevision = dataRevision
                let shouldAnimate = !UIAccessibility.isReduceMotionEnabled && filteredPrefix.count < 250

                // Canlı akış: en yeni sıralamada yalnızca listenin BAŞINA yeni
                // deprem eklendiyse (geri kalan sıra aynı) satır yukarıdan
                // kayarak girer. Diğer veri tazelemeleri animasyonsuz kalır.
                let isLiveInsertion = shouldAnimate && isDataRefresh && !isSortChange
                    && sortMode == .newest
                    && Self.isTopInsertion(old: self.filtered, new: filteredPrefix)

                if isLiveInsertion {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86), apply)
                } else if shouldAnimate && isSortChange {
                    // Sıralama değişimi (en yeni ↔ büyüklük): satırlar yer
                    // değiştirirken kritik sönümlü, sekmesiz yay tek akışkan
                    // hareket verir — 120 Hz'de kare düşürmeden akıcıdır.
                    withAnimation(.smooth(duration: 0.55, extraBounce: 0), apply)
                } else if shouldAnimate && !isDataRefresh {
                    // Kullanıcı filtre/arama değişikliği: yumuşak snappy geçiş.
                    withAnimation(.snappy(duration: 0.35, extraBounce: 0.04), apply)
                } else {
                    // Veri tazeleme (çekerek yenileme, 90 sn otomatik yenileme,
                    // sonsuz kaydırma sayfası): ANİMASYONSUZ tek relayout.
                    // Animasyonlu uygulanınca satır kaymaları yenileme
                    // spinner'ıyla üst üste biniyor ve listede anlamsız
                    // aşağı-yukarı sallanma oluşuyordu.
                    apply()
                }
                self.triggerAutoLoadOlderIfNeeded()
                self.scheduleWidgetPublish()
            }
        }
    }

    // MARK: Widget'lar — listenin aynısı

    private var widgetPublishTask: Task<Void, Never>?
    private var lastWidgetFilterKey = ""
    private var lastWidgetSignature = ""
    private var lastWidgetPublishAt = Date.distantPast
    /// Veri kaynaklı widget güncellemeleri en fazla bu sıklıkta (disk + yenileme).
    private static let widgetPublishInterval: TimeInterval = 60

    /// Listede görünen depremleri widget'lara aktarır. Filtre değişimi hemen
    /// (kısa bekleme ile), veri yenilemesi en fazla dakikada bir yansır; son
    /// durum her zaman yazılır. Arama sürerken yazılmaz: arama sonucu
    /// widget'ta "son depremler" gibi görünmesin.
    private func scheduleWidgetPublish() {
        // Veri henüz yüklenmediyse (açılış) boş liste yazılıp widget'taki son
        // geçerli liste silinmesin.
        guard !earthquakes.isEmpty,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let (filterKey, signature) = widgetKeys()
        guard signature != lastWidgetSignature else { return }
        let wait = filterKey != lastWidgetFilterKey
            ? 0.4
            : max(0, Self.widgetPublishInterval - Date().timeIntervalSince(lastWidgetPublishAt))
        widgetPublishTask?.cancel()
        widgetPublishTask = Task { @MainActor [weak self] in
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
            }
            guard let self, !self.earthquakes.isEmpty,
                  self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let (filterKey, signature) = self.widgetKeys()
            self.lastWidgetFilterKey = filterKey
            self.lastWidgetSignature = signature
            self.lastWidgetPublishAt = Date()
            WidgetBridge.publish(self.filteredAll, sources: self.enabledSources, minMagnitude: self.minMagnitude)
        }
    }

    private func widgetKeys() -> (filter: String, signature: String) {
        let filter = "\(enabledSources.sorted())|\(minMagnitude)"
        let magnitudeSum = filteredAll.reduce(0) { $0 + $1.magnitude }
        return (filter, "\(filter)|\(filteredAll.count)|\(filteredAll.first?.id ?? "")|\(magnitudeSum)")
    }

    /// Arka plan yenilemesinde widget listesini, uygulamanın listesiyle AYNI
    /// kurallarla üretir (son 24 saat, kaynak ve büyüklük filtresi, tüm
    /// kaynaklar seçiliyse fiziksel olay tekilleştirmesi).
    nonisolated static func widgetList(from quakes: [Earthquake], sources: Set<String>, minMagnitude: Double) -> [Earthquake] {
        let cutoff = listWindowCutoff
        let pool = quakes.filter {
            $0.date >= cutoff && sources.contains($0.sourceTag) && (minMagnitude <= 0 || $0.magnitude >= minMagnitude)
        }
        let unique = sources == Set(allSources) ? deduplicatedByPhysicalEvent(pool) : pool
        return unique.sorted { $0.date > $1.date }
    }

    /// Aynı fiziksel depremin ajans kopyaları tek satır: bölgenin resmî ajansı
    /// (Türkiye'de AFAD, sonra Kandilli; Yunanistan'da NOA; Japonya'da JMA…),
    /// sonra büyüklük. Kural `AftershockSequence.isAgencyCopy` (farklı ajans ve
    /// 75 sn & 20 km ya da 20 sn & 45 km); harita ve artçılarla aynı. Eski
    /// 90 sn / 90 km kuralı yakın ama ayrı depremleri de tek satıra indiriyordu.
    private nonisolated static func deduplicatedByPhysicalEvent(_ quakes: [Earthquake]) -> [Earthquake] {
        AftershockSequence.deduplicatedAgencyCopies(quakes)
    }

    /// 0: bölgenin resmî ajansı, 1: bölgenin ikinci resmî kaynağı (Kandilli),
    /// 2: küresel ajanslar (USGS, EMSC), 3: kendi bölgesi dışındaki bölgesel ajans.
    nonisolated static func authorityRank(_ quake: Earthquake) -> Int {
        let lat = quake.coordinate.latitude
        let lon = quake.coordinate.longitude
        func inBox(_ minLat: Double, _ maxLat: Double, _ minLon: Double, _ maxLon: Double) -> Bool {
            lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }
        switch quake.sourceTag {
        case "AFAD": return inBox(35.5, 42.5, 25.5, 45.0) ? 0 : 3
        case "KANDİLLİ": return inBox(35.5, 42.5, 25.5, 45.0) ? 1 : 3
        case "NOA": return inBox(34.5, 42.0, 19.0, 30.0) ? 0 : 3
        case "JMA": return inBox(24.0, 46.0, 122.0, 146.0) ? 0 : 3
        case "CENC": return inBox(18.0, 54.0, 73.0, 135.0) ? 0 : 3
        case "BMKG": return inBox(-11.0, 6.0, 95.0, 141.0) ? 0 : 3
        case "GEONET": return (lat >= -48 && lat <= -33 && (lon >= 165 || lon <= -175)) ? 0 : 3
        case "USGS", "EMSC": return 2
        default: return 3
        }
    }

    private var autoLoadTask: Task<Void, Never>?

    private func triggerAutoLoadOlderIfNeeded() {
        autoLoadTask?.cancel()
        autoLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Tetik başına en fazla 2 sayfa: sınırsız döngü hem cihazı ısıtıyordu
            // (her sayfada tam havuz sıralaması) hem de sunucuya gereksiz
            // /history isteği üretiyordu. Kullanıcı kaydırdıkça devamı yine gelir.
            var pagesLoaded = 0
            while self.olderDataAvailable && !Task.isCancelled && pagesLoaded < 2 {
                // Arama yapılıyorsa ve eşleşen sonuç sayısı azsa (örn: < 15)
                // VEYA büyüklük sıralaması seçilmişse otomatik yükle.
                // 24 saatlik pencere zaten tamamen yüklüyse daha eskiye inmek
                // anlamsızdır — istek atma.
                let dayWindowCovered: Bool = {
                    guard let oldest = self.oldestLoadedDate else { return false }
                    return oldest <= Self.listWindowCutoff
                }()
                let needsSearchData = !self.searchText.isEmpty
                    && self.filteredAll.count < 15
                    && !dayWindowCovered

                let needsMagnitudeSortData = self.sortMode == .magnitude
                    && !dayWindowCovered
                    && self.earthquakes.count < 600

                // "En yeni" gezinmede de liste son 24 saatin TAMAMINI göstersin:
                // sunucu anlık görüntüsü pencereyi kapatmıyorsa kalan kısım
                // kaydırma beklenmeden arka planda tamamlanır.
                let needsBrowseData = !dayWindowCovered

                guard needsSearchData || needsMagnitudeSortData || needsBrowseData else { break }

                await self.loadOlder()
                pagesLoaded += 1
                if (try? await Task.sleep(for: .milliseconds(500))) == nil {
                    break
                }
            }
        }
    }

    // MARK: Kademeli gösterim + sonsuz kaydırma

    private static let pageStep = 60
    /// Bellek koruması: en fazla bu kadar kayıt tutulur.
    private static let maxStoredQuakes = 3000

    private(set) var visibleCount = 60
    private(set) var isLoadingOlder = false
    /// Sunucuda daha eski kayıt kalmadığında true olur.
    private var reachedHistoryEnd = false

    private var olderDataAvailable: Bool {
        // Görünür pencerenin (son 24 saat, tüm kullanıcılar) ötesine asla
        // inme: pencere dışı veri listede zaten gösterilmez, her sayfa boşa
        // istek olur.
        if let oldest = oldestLoadedDate, oldest <= Self.listWindowCutoff {
            return false
        }
        return !reachedHistoryEnd && earthquakes.count < Self.maxStoredQuakes
    }


    var canLoadMore: Bool {
        visibleCount < filteredAll.count || olderDataAvailable
    }

    /// Erken ön yükleme eşiği: listenin sonuna ~8 satır kala tetiklenir —
    /// kullanıcı dibe varmadan yeni sayfa çoktan hazır olur.
    var prefetchTriggerID: String? {
        guard filtered.count > 8 else { return filtered.last?.id }
        return filtered[filtered.count - 8].id
    }

    /// Kullanıcı listenin sonuna yaklaşınca: önce eldeki veriden bir sayfa daha
    /// göster; eldeki veri bittiyse sunucudan daha eski depremleri çek.
    ///
    /// Not: Yerel sayfalama `isLoading`e (90 sn'lik otomatik yenileme) takılmaz —
    /// eski sürümde yenileme anına denk gelen kaydırma sessizce yutuluyor ve
    /// onAppear tekrar tetiklenmediği için liste "takılı" kalıyordu.
    /// Yeni liste, eskisinin başına 1–10 yeni deprem eklenmiş hâli mi? Eski
    /// kayıtların sırası korunmalı (sondan taşanlar ve revizyonlar önemsiz).
    nonisolated static func isTopInsertion(old: [Earthquake], new: [Earthquake]) -> Bool {
        guard let firstOld = old.first, !new.isEmpty else { return false }
        guard let index = new.firstIndex(where: { $0.id == firstOld.id }), (1...10).contains(index) else {
            return false
        }
        let oldIDs = Set(old.map(\.id))
        guard new[..<index].allSatisfy({ !oldIDs.contains($0.id) }) else { return false }
        let tail = new[index...].prefix(20).map(\.id)
        return tail == old.prefix(tail.count).map(\.id)
    }

    func loadMore() async {
        guard canLoadMore else { return }

        // Eldeki veriden sayfa açmak anlıktır: bekleme yok, ağ yok.
        if visibleCount < filteredAll.count {
            visibleCount = min(visibleCount + Self.pageStep, filteredAll.count)
            filtered = Array(filteredAll.prefix(visibleCount))
            return
        }

        guard !isLoadingOlder && !isLoading else { return }
        await loadOlder()
    }

    /// Elimizdeki en eski kayıttan geriye doğru bir sayfa çeker ve akışa ekler.
    private func loadOlder() async {
        guard !isLoading && !isLoadingOlder else { return }
        guard olderDataAvailable else { return }
        guard let oldestDate = oldestLoadedDate else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let fetchLimit = sortMode == .magnitude ? 200 : 100
        let historySource = enabledSources == Set(Self.allSources) ? nil : enabledSources.first
        let older = await EarthquakeService.shared.fetchHistory(
            before: oldestDate,
            limit: fetchLimit,
            source: historySource
        )
        let existingIDs = Set(earthquakes.map(\.id))
        let fresh = older
            .filter { !existingIDs.contains($0.id) }
            .sorted { $0.date > $1.date }

        guard !fresh.isEmpty else {
            reachedHistoryEnd = true
            return
        }

        // Yeni sayfa görünür kalsın; didSet applyFilters'ı tetikler.
        visibleCount += Self.pageStep
        earthquakes = Array((earthquakes + fresh).prefix(Self.maxStoredQuakes))
    }

    func load(forceRefresh: Bool = false) async {
        // Otomatik yenileme, retry ve pull-to-refresh aynı ağ görevini paylaşır.
        // Kullanıcının zorunlu yenilemesi bekleyen normal görevden sonra ayrıca çalışır.
        if let liveDataLoadTask {
            await liveDataLoadTask.value
            guard forceRefresh, !Task.isCancelled else { return }
        }

        liveDataLoadGeneration += 1
        let generation = liveDataLoadGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLiveDataLoad(forceRefresh: forceRefresh)
        }
        liveDataLoadTask = task
        await task.value
        if generation == liveDataLoadGeneration {
            liveDataLoadTask = nil
        }
    }

    private func performLiveDataLoad(forceRefresh: Bool) async {
        if earthquakes.isEmpty {
            viewState = .loading
        } else {
            // SWR: önbellek/listedeki son başarılı veri ekranda kalırken ağ yenilenir.
            viewState = .loaded(earthquakes)
            isRefreshing = true
        }
        defer { isRefreshing = false }

        let previousQuakes = earthquakes
        let previousIDs = earthquakes.map(\.id)
        let snapshot = await EarthquakeService.shared.liveSnapshot(minMagnitude: minMagnitude, forceRefresh: forceRefresh)

        let offline = snapshot.statuses.contains(where: { $0.source == "Sismik Server" && $0.state == .unavailable })
        isOffline = offline

        guard !snapshot.quakes.isEmpty else {
            // Geçici hata: son başarılı veriyi koru.
            if earthquakes.isEmpty {
                viewState = .error(ViewStateError(L("error.dataUnavailable")))
            } else {
                viewState = .loaded(earthquakes)
            }
            return
        }
        sourceStatuses = snapshot.statuses
        lastUpdated = Date()

        // Sonsuz kaydırma ile yüklenmiş eski kayıtları her yenilemede koru.
        // `forceRefresh` yalnızca servis önbelleğini atlar; görünür arşivi
        // daraltması liste yüksekliğini ve kullanıcının konumunu bozuyordu.
        let baseList = earthquakes

        let incoming = snapshot.quakes
        let incomingIDs = Set(incoming.map(\.id))
        let oldestIncoming = incoming.last?.date ?? .distantPast
        let preservedOlder = baseList.filter { !incomingIDs.contains($0.id) && $0.date < oldestIncoming }
        let merged = Array((incoming + preservedOlder).prefix(Self.maxStoredQuakes))

        // İçerik duyarlı karşılaştırma (Earthquake == artık büyüklük/derinlik
        // içeriyor): AFAD revizyonları kimlik aynı kalsa da listeye yansır.
        guard merged != previousQuakes else {
            viewState = .loaded(earthquakes)
            return
        }

        // Bu yenilemede ilk kez görülen depremler: listede animasyonlu/rozetli
        // gösterilir ve bildirim değerlendirmesine ANINDA gönderilir.
        let previousIDSet = Set(previousIDs)
        let newlyArrived = merged.filter { !previousIDSet.contains($0.id) }

        earthquakes = merged

        // "Yeni" yalnızca ekrandaki en yeni kayıttan SONRA olan depremler.
        // Eskiden önbellekten açılıp ağ gelince önbellekte olmayan her kayıt
        // (eski ajans kopyaları, geriye dönük AFAD yayımları dahil) yeni
        // sayılıyor, açılışta listenin tamamı vurgulanıyordu.
        let newestShown = previousQuakes.map(\.date).max() ?? .distantFuture
        let reallyNew = newlyArrived.filter { $0.date > newestShown }
        if !previousIDSet.isEmpty && !reallyNew.isEmpty && reallyNew.count <= 10 {
            freshQuakeIDs = Set(reallyNew.map(\.id))
            freshClearTask?.cancel()
            freshClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled else { return }
                self.freshQuakeIDs = []
            }
        }

        // Aktif artçı Canlı Etkinliği varsa yeni verilerle tazele (Premium).
        AftershockTracker.shared.update(with: merged)
        // Yakında güçlü deprem: deprem anı ekranı (cihazda karar, ağsız).
        StrongQuakeMonitor.shared.evaluate(merged)

        // Filtrelere uyan YENİ depremleri anında bildir. İlk yüklemede tüm
        // anlık görüntü, sonraki yenilemelerde yalnızca gerçekten yeni
        // depremler değerlendirilir — bildirim veri geldiği AN tetiklenir.
        let quakesToEvaluate = previousIDSet.isEmpty ? snapshot.quakes : newlyArrived
        guard !quakesToEvaluate.isEmpty else { return }
        Task { await NotificationManager.shared.evaluate(quakesToEvaluate, isBackground: false) }
    }

    func refreshFromPull() async {
        // Geçmiş arşivi yeniden denenebilir yap, fakat görünür pencereyi ve
        // mevcut satırları koru. Bunları 60'a düşürmek ekranı aniden çökertiyordu.
        reachedHistoryEnd = false

        let started = Date()
        await load(forceRefresh: true)

        // KRİTİK: filtre hesaplaması ayrık görevde çalışır; `load` döndüğünde
        // liste henüz güncellenmemiş olabilir. Spinner kapanırken içerik
        // değişirse kapanma animasyonu bozulur ve liste aşağı-yukarı zıplar.
        // Bu yüzden closure, filtrelenmiş sonuç EKRANA uygulanana dek döner
        // durur — spinner ancak son yerleşimden sonra kapanır.
        let targetRevision = dataRevision
        let applyDeadline = Date().addingTimeInterval(1.2)
        while lastAppliedDataRevision < targetRevision && Date() < applyDeadline {
            try? await Task.sleep(for: .milliseconds(40))
        }

        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 0.65 {
            try? await Task.sleep(nanoseconds: UInt64((0.65 - elapsed) * 1_000_000_000))
        }
    }

}
