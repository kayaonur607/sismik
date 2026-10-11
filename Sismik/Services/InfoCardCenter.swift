import SwiftUI

/// Uygulama açıldığında bir kez gösterilen bilgi kartları.
///
/// İki kaynak:
/// - **Sürüm notları** (`ReleaseNotes`): güncellemeden sonraki ilk açılışta
///   App Store'daki "Bu Sürümdeki Yenilikler" metni mağazadan okunur ve bir
///   kez gösterilir. Metin App Store Connect'e yazıldığı gibi gelir; kodda
///   sürüm metni tutulmaz. Yeni kurulumda gösterilmez.
/// - **Uzak kartlar**: `Scripts/info-cards.mjs` ile yayınlanır. Sunucu kart
///   revizyonunu liste yanıtının `X-Sismik-Info-Revision` başlığında gönderir;
///   uygulama yalnızca revizyon değişince `/info-cards` çeker. Ayrı bir yoklama
///   yoktur, Firestore'a hiç gidilmez.
///
/// Her kart kimliği cihazda bir kez gösterilir. Derin bağlantı
/// (`sismik://info/<id>`) ve bildirim dokunuşu kartı yine açar.
@MainActor
@Observable
final class InfoCardCenter {
    static let shared = InfoCardCenter()

    nonisolated static let responseHeader = "X-Sismik-Info-Revision"

    /// RootView bu karta bağlı bir sayfa açar.
    var presented: InfoCard?

    private var remoteCards: [InfoCard] = []
    private var fetchTask: Task<Void, Never>?
    private var releaseNotesTask: Task<Void, Never>?
    private var isReady = false

    private enum Key {
        static let seen = "infoCards.seen"
        static let revision = "infoCards.revision"
        static let cache = "infoCards.cache"
        static let lastVersion = "infoCards.lastVersion"
    }

    nonisolated static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Key.cache),
           let cards = try? JSONDecoder().decode([InfoCard].self, from: data) {
            remoteCards = cards
        }
    }

    // MARK: Açılış

    /// Uygulama başlarken bir kez: yeni kurulumda "yenilikler" kartı
    /// gösterilmesin diye sürüm hemen kaydedilir. Güncellemede anahtar ya
    /// eski sürümü taşır ya da (2.1.2 öncesinden gelen) hiç yoktur.
    nonisolated static func bootstrap(isFreshInstall: Bool) {
        let defaults = UserDefaults.standard
        if isFreshInstall, defaults.string(forKey: Key.lastVersion) == nil {
            defaults.set(currentVersion, forKey: Key.lastVersion)
        }
    }

    /// Ana ekran göründükten sonra çağrılır; sıradaki kartı gösterir.
    func appDidBecomeReady() {
        isReady = true
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Key.lastVersion) != Self.currentVersion {
            defaults.set(Self.currentVersion, forKey: Key.lastVersion)
            ReleaseNotes.markPending(version: Self.currentVersion)
        }
        showReleaseNotesOrNextCard()
    }

    /// Ön plana dönüşte: mağaza notları henüz yoksa yeniden dene; başlangıç
    /// zamanı yeni gelen uzak kart da gösterilsin.
    func sceneDidBecomeActive() {
        guard isReady else { return }
        showReleaseNotesOrNextCard()
    }

    private func showReleaseNotesOrNextCard() {
        guard ReleaseNotes.isPending(version: Self.currentVersion) else {
            presentNextRemoteCard(delay: .milliseconds(900))
            return
        }
        guard releaseNotesTask == nil else { return }
        releaseNotesTask = Task {
            defer { releaseNotesTask = nil }
            if let card = await ReleaseNotes.fetchCard(version: Self.currentVersion) {
                present(card, delay: .milliseconds(900))
            } else {
                presentNextRemoteCard(delay: .milliseconds(900))
            }
        }
    }

    // MARK: Uzak kartlar

    /// Liste yanıtındaki revizyon başlığı. Değişmişse kartlar bir kez çekilir.
    func record(revision raw: String?) {
        guard let raw, let revision = Int(raw.trimmingCharacters(in: .whitespaces)) else { return }
        guard revision != UserDefaults.standard.integer(forKey: Key.revision), fetchTask == nil else { return }
        fetchTask = Task {
            defer { fetchTask = nil }
            guard await fetchRemoteCards() else { return }
            presentNextRemoteCard(delay: .milliseconds(600))
        }
    }

    @discardableResult
    private func fetchRemoteCards() async -> Bool {
        guard let url = URL(string: BackendConfig.baseURL + "/info-cards") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return false }
            let payload = try JSONDecoder().decode(InfoCardPayload.self, from: data)
            remoteCards = payload.cards.compactMap(\.card)
            let defaults = UserDefaults.standard
            defaults.set(payload.revision, forKey: Key.revision)
            if let encoded = try? JSONEncoder().encode(remoteCards) {
                defaults.set(encoded, forKey: Key.cache)
            }
            return true
        } catch {
            AppLog.network.error("info-cards fetch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func presentNextRemoteCard(delay: Duration) {
        guard RemoteConfig.isEnabled(.infoCards) else { return }
        let isPremium = PremiumStore.shared.isPremium
        let now = Date()
        guard let card = remoteCards.first(where: {
            !hasSeen($0.id) && $0.isEligible(version: Self.currentVersion, isPremium: isPremium, now: now)
        }) else { return }
        present(card, delay: delay)
    }

    // MARK: Gösterim

    /// `sismik://info/<id>`: bildirimden ya da bağlantıdan. Görülmüş olsa da
    /// açılır; yerelde yoksa kartlar bir kez tazelenir.
    func open(id: String) {
        if let card = card(id: id) {
            present(card, delay: .milliseconds(300), force: true)
            return
        }
        Task {
            await fetchRemoteCards()
            if let card = card(id: id) { present(card, delay: .zero, force: true) }
        }
    }

    func markSeen(_ card: InfoCard) {
        var seen = UserDefaults.standard.stringArray(forKey: Key.seen) ?? []
        guard !seen.contains(card.id) else { return }
        seen.append(card.id)
        UserDefaults.standard.set(Array(seen.suffix(100)), forKey: Key.seen)
    }

    private func card(id: String) -> InfoCard? {
        if id == ReleaseNotes.cardID(version: Self.currentVersion), let card = ReleaseNotes.cachedCard {
            return card
        }
        return remoteCards.first { $0.id == id }
    }

    private func hasSeen(_ id: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: Key.seen)?.contains(id) == true
    }

    private func present(_ card: InfoCard, delay: Duration, force: Bool = false) {
        guard force || isReady else { return }
        Task {
            try? await Task.sleep(for: delay)
            // Başka bir kart açıksa üstüne binmez; sıradaki açılışta gelir.
            guard presented == nil || force else { return }
            presented = card
        }
    }
}

// MARK: - Model

/// Dil → metin. Uzak kartlarda sözlük, gömülü kartlarda çeviri anahtarı.
enum InfoCardText: Codable, Hashable, Sendable {
    case map([String: String])
    case key(String)

    var resolved: String {
        switch self {
        case .key(let key):
            return L(key)
        case .map(let map):
            let code = AppLanguage.currentLanguageCode
            for lang in [code, "en", "tr"] {
                if let text = map[lang]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
            }
            return map.values.first ?? ""
        }
    }

    var isEmpty: Bool { resolved.isEmpty }

    init(from decoder: Decoder) throws {
        self = .map(try decoder.singleValueContainer().decode([String: String].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .map(let map): try container.encode(map)
        case .key(let key): try container.encode(["key": key])
        }
    }
}

struct InfoCard: Codable, Identifiable, Hashable, Sendable {
    struct Item: Codable, Hashable, Sendable {
        var icon: String
        var title: InfoCardText
        var body: InfoCardText
    }

    struct Action: Codable, Hashable, Sendable {
        var label: InfoCardText
        var url: String
    }

    var id: String
    var audience: String?
    var minVersion: String?
    var maxVersion: String?
    var startAt: String?
    var endAt: String?
    var icon: String?
    var tint: String?
    var title: InfoCardText
    var subtitle: InfoCardText?
    /// Serbest metin (sürüm notları). Satır başındaki "-", "•", "*" madde olur.
    var body: InfoCardText?
    var items: [Item]?
    var action: Action?

    var tintColor: Color {
        switch tint {
        case "green": .brandGreen
        case "blue": .blue
        case "red": .red
        case "purple": .purple
        case "teal": .teal
        default: .brandOrange
        }
    }

    func isEligible(version: String, isPremium: Bool, now: Date) -> Bool {
        switch audience {
        case "free" where isPremium: return false
        case "premium" where !isPremium: return false
        default: break
        }
        if let minVersion, AppUpdateNotice.version(version, isOlderThan: minVersion) { return false }
        if let maxVersion, AppUpdateNotice.version(maxVersion, isOlderThan: version) { return false }
        let iso = ISO8601DateFormatter()
        if let start = startAt.flatMap(iso.date(from:)), now < start { return false }
        if let end = endAt.flatMap(iso.date(from:)), now >= end { return false }
        return !title.isEmpty
    }
}

/// `/info-cards` yanıtı. Tek bir hatalı kart listenin tamamını düşürmesin
/// diye kartlar tek tek çözülür.
private struct InfoCardPayload: Decodable {
    struct Lenient: Decodable {
        let card: InfoCard?
        init(from decoder: Decoder) throws { card = try? InfoCard(from: decoder) }
    }

    let revision: Int
    let cards: [Lenient]
}

// MARK: - Sürüm notları

/// App Store'daki "Bu Sürümdeki Yenilikler" metni.
///
/// Apple'ın herkese açık lookup ucu (`itunes.apple.com/lookup`) kullanılır:
/// sunucu ve veritabanı yok, cihaz başına güncelleme başına bir istek. Her
/// mağaza notu kendi dilinde döndürür; uygulama dili mağazaya eşlenir (tr → TR,
/// de → DE …). O dilde not girilmemişse App Store Connect'teki birincil dil
/// gelir.
///
/// Mağaza önbelleği yeni sürümü birkaç saat geç gösterebilir: dönen sürüm bu
/// sürüm değilse kart bekler, sonraki açılışlarda (en sık 30 dk'da bir) yeniden
/// denenir ve 7 gün sonra bırakılır.
enum ReleaseNotes {
    private enum Key {
        static let pendingVersion = "releaseNotes.pendingVersion"
        static let pendingSince = "releaseNotes.pendingSince"
        static let lastAttempt = "releaseNotes.lastAttempt"
        /// Dile göre saklanır: `releaseNotes.cache.<dil>`.
        static func cache(_ language: String) -> String { "releaseNotes.cache.\(language)" }
    }

    private static let retryInterval: TimeInterval = 30 * 60
    private static let giveUpAfter: TimeInterval = 7 * 86_400
    private static let appStoreID = "6787776158"

    static func cardID(version: String) -> String { "release-\(version)" }

    static func markPending(version: String) {
        let defaults = UserDefaults.standard
        defaults.set(version, forKey: Key.pendingVersion)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.pendingSince)
        defaults.removeObject(forKey: Key.lastAttempt)
    }

    static func isPending(version: String) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Key.pendingVersion) == version else { return false }
        if Date().timeIntervalSince1970 - defaults.double(forKey: Key.pendingSince) > giveUpAfter {
            clearPending()
            return false
        }
        return true
    }

    /// Bu sürümün, uygulamanın ŞU ANKİ dilindeki notları (daha önce indirildiyse).
    static var cachedCard: InfoCard? {
        guard let data = UserDefaults.standard.data(forKey: Key.cache(AppLanguage.currentLanguageCode)),
              let card = try? JSONDecoder().decode(InfoCard.self, from: data),
              card.id == cardID(version: InfoCardCenter.currentVersion) else { return nil }
        return card
    }

    /// Güncelleme sonrası otomatik gösterim: bekleyen sürüm için, deneme
    /// aralığına uyarak. Notlar bu sürüme aitse kartı döndürür.
    @MainActor
    static func fetchCard(version: String) async -> InfoCard? {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let lastAttempt = defaults.double(forKey: Key.lastAttempt)
        guard lastAttempt == 0 || now - lastAttempt > retryInterval else { return nil }
        defaults.set(now, forKey: Key.lastAttempt)

        switch await lookup(version: version, language: AppLanguage.currentLanguageCode) {
        case .notes(let card):
            clearPending()
            return card
        case .storeIsNewer, .noNotes:
            // Kullanıcı eski bir sürümde ya da hiçbir dilde not yok: denemeye gerek yok.
            clearPending()
            return nil
        case .notYetPublished:
            return nil
        }
    }

    private enum LookupResult {
        case notes(InfoCard)
        case notYetPublished
        case storeIsNewer
        case noNotes
    }

    /// App Store notları mağazanın ana dilinde döner; App Store Connect'te bir
    /// dile girilen notlar o dilin mağazalarında görünür. Dil için sırayla
    /// birkaç mağaza denenir, hiçbirinde not yoksa İngilizce (ABD) notlara
    /// düşülür. Uygulamanın o mağazada olmaması da (boş sonuç) bir sonrakine
    /// geçmek demektir.
    private static func lookup(version: String, language: String) async -> LookupResult {
        var sawCurrentVersion = false
        for storefront in storefronts(for: language) + ["us"] {
            guard let result = await fetch(storefront: storefront) else { continue }
            switch compare(result.version, version) {
            case .orderedDescending: return .storeIsNewer
            case .orderedAscending: return .notYetPublished
            case .orderedSame:
                sawCurrentVersion = true
                let notes = result.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !notes.isEmpty else { continue }
                let card = InfoCard(
                    id: cardID(version: version),
                    icon: "doc.text",
                    tint: "orange",
                    title: .map([language: L("releasenotes.title")]),
                    subtitle: .map([language: L("releasenotes.subtitle", version)]),
                    body: .map([language: notes])
                )
                if let encoded = try? JSONEncoder().encode(card) {
                    UserDefaults.standard.set(encoded, forKey: Key.cache(language))
                }
                return .notes(card)
            }
        }
        return sawCurrentVersion ? .noNotes : .notYetPublished
    }

    private static func fetch(storefront: String) async -> Lookup.Result? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(appStoreID)&country=\(storefront)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let lookup = try? JSONDecoder().decode(Lookup.self, from: data) else { return nil }
        return lookup.results.first
    }

    /// "2.1.10" > "2.1.9": sürümler sayısal karşılaştırılır.
    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private static func clearPending() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.pendingVersion)
        defaults.removeObject(forKey: Key.pendingSince)
        defaults.removeObject(forKey: Key.lastAttempt)
    }

    /// Uygulama dili → o dilde not gösteren mağazalar (ana dili o dil olan
    /// mağazalar, en büyükten). App Store Connect'te notun girildiği dil
    /// bu mağazalarda görünür.
    static func storefronts(for language: String) -> [String] {
        switch language {
        case "tr": ["tr"]
        case "de": ["de", "at", "ch"]
        case "es": ["es", "mx", "ar", "co", "cl"]
        case "fr": ["fr", "be", "ca"]
        case "it": ["it"]
        case "ja": ["jp"]
        case "ru": ["ru", "kz"]
        case "ar": ["sa", "ae", "eg"]
        case "el": ["gr", "cy"]
        case "pt": ["br", "pt"]
        case "id": ["id"]
        case "ko": ["kr"]
        case "zh": ["cn", "sg"]
        case "ro": ["ro", "md"]
        default: []
        }
    }

    private struct Lookup: Decodable {
        struct Result: Decodable {
            let version: String
            let releaseNotes: String?
        }
        let results: [Result]
    }
}
