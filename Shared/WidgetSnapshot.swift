import Foundation

// MARK: - Uygulama ↔ widget ortak verisi
//
// Widget'lar uygulamanın ana listesinin AYNISINI gösterir: uygulama, listede
// o an görünen depremleri (son 24 saat, seçili kaynaklar, büyüklük eşiği)
// ve aktif filtreyi App Group kapsayıcısına küçük bir JSON olarak yazar.
// Widget yalnızca bu dosyayı okur — ağa, sunucuya ya da veritabanına hiç
// çıkmaz. Veri, uygulamanın zaten yaptığı liste isteğinden gelir (açıkken
// yenileme, kapalıyken arka plan yenilemesi).
//
// Bu dosya uygulama, widget ve bildirim uzantısı hedeflerinde derlenir
// (`Shared` klasörü).

struct WidgetSnapshot: Codable, Sendable {
    struct Quake: Codable, Sendable, Identifiable, Hashable {
        let id: String
        /// Büyük harf kaynak etiketi: AFAD, EMSC, USGS, NOA.
        let provider: String
        /// Listede gösterilen yer adı.
        let title: String
        let magnitude: Double
        let depth: Double?
        let date: Date

        /// "Sındırgı (Balıkesir)" → "Balıkesir"; parantez yoksa virgülden
        /// önceki ilk parça. Özet widget'ının "en aktif bölge"si için.
        var region: String {
            if let open = title.lastIndex(of: "("),
               let close = title.lastIndex(of: ")"), open < close {
                let inner = title[title.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { return inner }
            }
            let head = title.split(separator: ",").first.map(String.init) ?? title
            return head.trimmingCharacters(in: .whitespaces)
        }
    }

    var generatedAt: Date
    /// Listede görünen depremler, yeniden eskiye.
    var quakes: [Quake]
    /// Listenin kaynak filtresi (AFAD, EMSC, USGS, NOA etiketleri).
    var sources: [String]
    /// Listenin büyüklük eşiği; 0 = tümü.
    var minMagnitude: Double
}

enum WidgetSharedStore {
    static let appGroupID = "group.com.kayasoftware.sismik"
    /// Güvenlik sınırı: 24 saatlik liste tipik olarak ~700 kayıt (~120 KB).
    static let maximumQuakes = 1500

    private static let languageKey = "widget.languageCode"
    private static let sourcesKey = "widget.list.sources"
    private static let minMagnitudeKey = "widget.list.minMagnitude"
    private static let fileName = "widget-list-v2.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Bir kez açılır: widget her metin için dili okur, her okumada yeni bir
    /// `UserDefaults` örneği oluşturmak gereksizdi. (UserDefaults iş parçacığı
    /// güvenlidir.)
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: appGroupID)

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL else { return }
        var bounded = snapshot
        bounded.quakes = Array(snapshot.quakes.prefix(maximumQuakes))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(bounded) else { return }
        try? data.write(to: url, options: [.atomic])
        // Arka plan yenilemesi listeyi aynı filtreyle üretebilsin.
        defaults?.set(snapshot.sources, forKey: sourcesKey)
        defaults?.set(snapshot.minMagnitude, forKey: minMagnitudeKey)
    }

    static func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Listenin son bilinen filtresi (uygulama arka planda yenilerken).
    static var listFilter: (sources: [String], minMagnitude: Double)? {
        guard let sources = defaults?.stringArray(forKey: sourcesKey), !sources.isEmpty else { return nil }
        return (sources, defaults?.double(forKey: minMagnitudeKey) ?? 0)
    }

    /// Uygulamada seçili dil; widget'lar metinlerini bu dilde gösterir.
    static var languageCode: String? {
        get { defaults?.string(forKey: languageKey) }
        set { defaults?.set(newValue, forKey: languageKey) }
    }
}
