import SwiftUI
import WidgetKit

// MARK: - Liste filtresi

typealias WidgetQuake = WidgetSnapshot.Quake

/// Uygulamadaki listenin aktif filtresi; widget'ta rozet olarak görünür.
struct WidgetListFilter: Equatable {
    static let allSources = ["AFAD", "EMSC", "USGS", "NOA"]
    static let unfiltered = WidgetListFilter(sources: allSources, minMagnitude: 0)

    let sources: [String]
    let minMagnitude: Double

    var showsAllSources: Bool { Set(sources) == Set(Self.allSources) }

    /// "AFAD", "AFAD +1" ya da tüm kaynaklarda `nil` (rozet "TÜMÜ").
    var sourceBadge: String? {
        guard !showsAllSources, let first = sources.first else { return nil }
        return sources.count == 1 ? first : "\(first) +\(sources.count - 1)"
    }

    /// "M3+" / "M2.5+"; eşik yoksa `nil`.
    var magnitudeBadge: String? {
        guard minMagnitude > 0 else { return nil }
        let value = minMagnitude.rounded() == minMagnitude
            ? String(Int(minMagnitude))
            : String(format: "%.1f", minMagnitude)
        return "M\(value)+"
    }
}

// MARK: - Zaman çizelgesi

struct QuakeEntry: TimelineEntry {
    /// Göreli zamanlar ("12 dk önce") bu ana göre yazılır; zaman çizelgesi
    /// 5 dakikalık adımlarla ilerlediği için metin kendiliğinden güncellenir.
    let date: Date
    /// Uygulamanın listesinde görünen depremler, yeniden eskiye.
    let quakes: [WidgetQuake]
    let filter: WidgetListFilter
    /// Uygulama henüz hiç liste yazmadı (kurulumdan sonra açılmadı).
    var hasData = true

    var latest: WidgetQuake? { quakes.first }
}

/// Widget'ın tek veri kaynağı: uygulamanın App Group'a yazdığı liste.
/// Ağ isteği, sunucu ya da veritabanı erişimi YOK — küçük bir disk okuması,
/// her zaman çizelgesi isteğinde tekrarlanabilecek kadar ucuz.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> QuakeEntry {
        QuakeEntry(date: Date(), quakes: WidgetSamples.quakes, filter: .unfiltered)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuakeEntry) -> Void) {
        let snapshot = WidgetSharedStore.read()
        if context.isPreview, snapshot == nil {
            // Galeri önizlemesi: uygulama henüz liste yazmadıysa örnek veri.
            completion(QuakeEntry(date: Date(), quakes: WidgetSamples.quakes, filter: .unfiltered))
            return
        }
        completion(entry(at: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuakeEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSharedStore.read()
        // Aynı liste, 5 dakikalık adımlarla bir saat: yalnızca göreli zaman
        // metinleri ilerler. Liste değişince uygulama widget'ları hemen
        // yeniletir; bir saat sonra dosya yeniden okunur (yine ağsız).
        let entries = (0..<12).map { step in
            entry(at: now.addingTimeInterval(Double(step) * 5 * 60), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 60))))
    }

    private func entry(at date: Date, snapshot: WidgetSnapshot?) -> QuakeEntry {
        guard let snapshot else {
            return QuakeEntry(date: date, quakes: [], filter: .unfiltered, hasData: false)
        }
        // Liste son 24 saati gösterir; zaman ilerledikçe pencereden çıkanlar
        // widget'ta da düşer.
        let cutoff = date.addingTimeInterval(-24 * 3600)
        return QuakeEntry(
            date: date,
            quakes: snapshot.quakes.filter { $0.date >= cutoff },
            filter: WidgetListFilter(sources: snapshot.sources, minMagnitude: snapshot.minMagnitude)
        )
    }
}

// MARK: - Özet (Deprem Özeti widget'ı)

/// Listenin son 24 saati: sayı, en büyük deprem, M3+ sayısı, en aktif bölge ve
/// saatlik yoğunluk (24 dilim, her dilim en büyük depreminin rengini taşır).
struct QuakeDigest {
    let count: Int
    let largest: WidgetQuake?
    let feltCount: Int
    let busiestRegion: String?
    let hourlyCounts: [Int]
    let hourlyMaxMagnitudes: [Double]

    init(quakes: [WidgetQuake], now: Date) {
        let start = now.addingTimeInterval(-24 * 3600)
        let window = quakes.filter { $0.date > start && $0.date <= now }
        count = window.count
        largest = window.max { $0.magnitude < $1.magnitude }
        feltCount = window.filter { $0.magnitude >= 3 }.count

        var regions: [String: Int] = [:]
        for quake in window { regions[quake.region, default: 0] += 1 }
        busiestRegion = regions.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key

        var counts = Array(repeating: 0, count: 24)
        var maxima = Array(repeating: 0.0, count: 24)
        for quake in window {
            let hour = min(23, max(0, Int(quake.date.timeIntervalSince(start) / 3600)))
            counts[hour] += 1
            maxima[hour] = max(maxima[hour], quake.magnitude)
        }
        hourlyCounts = counts
        hourlyMaxMagnitudes = maxima
    }
}

// MARK: - Örnek veri (galeri ve yer tutucu)

enum WidgetSamples {
    static var quakes: [WidgetQuake] {
        let now = Date()
        let rows: [(String, String, String, Double, Double, TimeInterval)] = [
            ("1", "AFAD", "Ege Denizi", 4.2, 10, 720),
            ("2", "AFAD", "Doğanşehir (Malatya)", 3.1, 7, 1860),
            ("3", "EMSC", "Western Turkey", 2.8, 12, 2640),
            ("4", "AFAD", "Tuşba (Van)", 3.4, 9, 3480),
            ("5", "NOA", "Greece", 2.3, 6, 4200),
            ("6", "AFAD", "Sındırgı (Balıkesir)", 3.6, 11, 6100),
            ("7", "USGS", "Crete, Greece", 4.4, 8, 8300)
        ]
        return rows.map {
            WidgetQuake(id: $0.0, provider: $0.1, title: $0.2, magnitude: $0.3, depth: $0.4,
                        date: now.addingTimeInterval(-$0.5))
        }
    }
}
