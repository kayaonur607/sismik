import Foundation
import os
import SwiftUI

/// Uzak yapılandırma: önemli bir olayda ya da bir hata görüldüğünde uygulama
/// güncellemesi beklemeden davranışı değiştirmek için.
///
/// Kaynak Firestore'daki `_system/remote_config_v1` belgesinin `client`
/// bölümüdür (bkz. functions/src/remote-config.ts, Scripts/remote-config.mjs).
/// Sunucu revizyonu liste yanıtının `X-Sismik-Config-Revision` başlığında
/// gönderir; uygulama yalnızca revizyon değişince `/app-config` çeker. Ayrı bir
/// yoklama ya da Firestore okuması yoktur. Son değer diskte saklanır: çevrimdışı
/// açılışta da geçerlidir.
///
/// Her alan isteğe bağlıdır; olmayan alan için koddaki varsayılan kullanılır.
/// Sayılar sunucuda doğrulanır ve burada da aralığa kırpılır — bozuk bir
/// yapılandırma uygulamayı hiçbir zaman kullanılamaz hâle getirmez.
@MainActor
@Observable
final class RemoteConfigCenter {
    static let shared = RemoteConfigCenter()

    nonisolated static let responseHeader = "X-Sismik-Config-Revision"

    private(set) var config: RemoteClientConfig
    /// Kapatılan duyuru kimlikleri.
    private(set) var dismissedNotices: Set<String>

    private var fetchTask: Task<Void, Never>?

    private enum Key {
        static let revision = "remoteConfig.revision"
        static let cache = "remoteConfig.cache"
        static let dismissedNotices = "remoteConfig.dismissedNotices"
    }

    private init() {
        let defaults = UserDefaults.standard
        config = defaults.data(forKey: Key.cache)
            .flatMap { try? JSONDecoder().decode(RemoteClientConfig.self, from: $0) } ?? RemoteClientConfig()
        dismissedNotices = Set(defaults.stringArray(forKey: Key.dismissedNotices) ?? [])
        RemoteConfig.store(config)
    }

    // MARK: Revizyon ve çekme

    /// Liste yanıtındaki revizyon başlığı. Değişmişse yapılandırma bir kez çekilir.
    func record(revision raw: String?) {
        guard let revision = raw?.trimmingCharacters(in: .whitespaces), !revision.isEmpty,
              revision != UserDefaults.standard.string(forKey: Key.revision),
              fetchTask == nil else { return }
        fetchTask = Task {
            defer { fetchTask = nil }
            await fetch()
        }
    }

    private func fetch() async {
        guard let url = URL(string: BackendConfig.baseURL + "/app-config") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return }
            let payload = try JSONDecoder().decode(RemoteConfigPayload.self, from: data)
            apply(payload.config, revision: payload.revision)
        } catch {
            AppLog.network.error("app-config fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ next: RemoteClientConfig, revision: String) {
        let defaults = UserDefaults.standard
        defaults.set(revision, forKey: Key.revision)
        if let encoded = try? JSONEncoder().encode(next) {
            defaults.set(encoded, forKey: Key.cache)
        }
        guard next != config else { return }
        withAnimation(.snappy) { config = next }
        RemoteConfig.store(next)
        AppLog.network.info("app-config applied revision=\(revision, privacy: .public)")
        // Özellik kapatıldıysa etkisi hemen görülsün.
        if !next.isEnabled(.backgroundLocation) {
            SignificantLocationService.shared.refresh()
        }
    }

    // MARK: Duyuru ve zorunlu güncelleme

    /// Liste başındaki duyuru: sürüm/zaman penceresine uyuyor ve kapatılmamışsa.
    var activeNotice: RemoteClientConfig.Notice? {
        guard let notice = config.notice,
              notice.isEligible(version: InfoCardCenter.currentVersion, now: Date()),
              !(notice.isDismissible && dismissedNotices.contains(notice.id)) else { return nil }
        return notice
    }

    func dismissNotice(_ id: String) {
        withAnimation(.snappy) { _ = dismissedNotices.insert(id) }
        UserDefaults.standard.set(Array(dismissedNotices.suffix(50)), forKey: Key.dismissedNotices)
    }

    /// Bu sürüm artık desteklenmiyor mu? (ör. kritik bir hata sonrası)
    var requiresUpdate: Bool {
        guard let minimum = config.minVersion else { return false }
        return AppUpdateNotice.version(InfoCardCenter.currentVersion, isOlderThan: minimum)
    }
}

/// Ana aktör dışından (servis actor'ları, `nonisolated` yardımcılar) okunabilen
/// kopya. `RemoteConfigCenter` her değişiklikte günceller.
enum RemoteConfig {
    private static let lock = OSAllocatedUnfairLock(initialState: RemoteClientConfig())

    nonisolated static var current: RemoteClientConfig { lock.withLock { $0 } }

    nonisolated static func store(_ config: RemoteClientConfig) {
        lock.withLock { $0 = config }
    }

    nonisolated static func isEnabled(_ feature: RemoteClientConfig.Feature) -> Bool {
        current.isEnabled(feature)
    }

    /// `section.key` sayısı, verilen aralığa kırpılmış; yoksa varsayılan.
    nonisolated static func number(
        _ section: KeyPath<RemoteClientConfig, [String: Double]?>,
        _ key: String,
        default fallback: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        guard let value = current[keyPath: section]?[key], value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// `/app-config` yanıtındaki `config`. Sunucudaki `ClientRemoteConfig` ile
/// aynı (snake_case) alanlar; bilinmeyen alanlar yok sayılır, hatalı tipteki
/// bir alan tüm yapılandırmayı düşürmez.
struct RemoteClientConfig: Codable, Equatable, Sendable {
    enum Feature: String, CaseIterable, Sendable {
        case feltCard = "felt_card"
        case liveActivity = "live_activity"
        case aiAnalysis = "ai_analysis"
        case strongQuakeScreen = "strong_quake_screen"
        case feltReports = "felt_reports"
        case infoCards = "info_cards"
        case backgroundLocation = "background_location"
        case majorEventCard = "major_event_card"
    }

    struct Notice: Codable, Equatable, Sendable {
        let id: String
        var tint: String?
        var icon: String?
        var title: [String: String]
        var body: [String: String]?
        var url: String?
        var minVersion: String?
        var maxVersion: String?
        var startAt: String?
        var endAt: String?
        var dismissible: Bool?

        enum CodingKeys: String, CodingKey {
            case id, tint, icon, title, body, url, dismissible
            case minVersion = "min_version"
            case maxVersion = "max_version"
            case startAt = "start_at"
            case endAt = "end_at"
        }

        var isDismissible: Bool { dismissible ?? true }
        var localizedTitle: String { Self.localized(title) ?? "" }
        var localizedBody: String? { body.flatMap(Self.localized) }

        var color: Color {
            switch tint {
            case "green": .green
            case "blue": .blue
            case "red": .red
            case "purple": .purple
            case "teal": .teal
            case "yellow": .yellow
            default: .brandOrange
            }
        }

        func isEligible(version: String, now: Date) -> Bool {
            if let minVersion, AppUpdateNotice.version(version, isOlderThan: minVersion) { return false }
            if let maxVersion, AppUpdateNotice.version(maxVersion, isOlderThan: version) { return false }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let parse = { (text: String) in iso.date(from: text) ?? ISO8601DateFormatter().date(from: text) }
            if let start = startAt.flatMap(parse), now < start { return false }
            if let end = endAt.flatMap(parse), now >= end { return false }
            return !localizedTitle.isEmpty
        }

        /// Uygulama dili → İngilizce → Türkçe → herhangi biri.
        private static func localized(_ texts: [String: String]) -> String? {
            let code = AppLanguage.currentLanguageCode
            return texts[code] ?? texts[code.components(separatedBy: "-").first ?? code]
                ?? texts["en"] ?? texts["tr"] ?? texts.values.sorted().first
        }
    }

    var minVersion: String?
    var notice: Notice?
    var features: [String: Bool]?
    var hiddenSources: [String]?
    var feltCard: [String: Double]?
    var strongQuake: [String: Double]?
    var refresh: [String: Double]?
    var dedupe: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case notice, features, refresh, dedupe
        case minVersion = "min_version"
        case hiddenSources = "hidden_sources"
        case feltCard = "felt_card"
        case strongQuake = "strong_quake"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minVersion = try? c.decodeIfPresent(String.self, forKey: .minVersion)
        notice = try? c.decodeIfPresent(Notice.self, forKey: .notice)
        features = try? c.decodeIfPresent([String: Bool].self, forKey: .features)
        hiddenSources = try? c.decodeIfPresent([String].self, forKey: .hiddenSources)
        feltCard = try? c.decodeIfPresent([String: Double].self, forKey: .feltCard)
        strongQuake = try? c.decodeIfPresent([String: Double].self, forKey: .strongQuake)
        refresh = try? c.decodeIfPresent([String: Double].self, forKey: .refresh)
        dedupe = try? c.decodeIfPresent([String: Double].self, forKey: .dedupe)
    }

    /// Varsayılan: açık. Yalnızca açıkça `false` verilen özellik kapanır.
    func isEnabled(_ feature: Feature) -> Bool {
        features?[feature.rawValue] ?? true
    }

    func isSourceHidden(_ tag: String) -> Bool {
        hiddenSources?.contains(QuakeSourceKey.remoteKey(forTag: tag)) ?? false
    }
}

/// Uygulamadaki kaynak etiketi ("KANDİLLİ") ↔ sunucu anahtarı ("KANDILLI").
enum QuakeSourceKey {
    nonisolated static func remoteKey(forTag tag: String) -> String {
        tag.uppercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "İ", with: "I")
    }
}

private struct RemoteConfigPayload: Decodable {
    let revision: String
    let config: RemoteClientConfig
}

// MARK: - Görünümler

/// Liste başındaki uzak duyuru (ör. "AFAD verisi gecikiyor", "bildirimlerde
/// gecikme var, düzeltildi"). Kapatılabilir; kapatılan kimlik bir daha görünmez.
struct RemoteNoticeBanner: View {
    let notice: RemoteClientConfig.Notice

    @Environment(\.openURL) private var openURL

    var body: some View {
        let tint = notice.color
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notice.icon ?? "info.circle.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.localizedTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = notice.localizedBody {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let link {
                    Button {
                        openURL(link)
                    } label: {
                        Label(L("remote.notice.more"), systemImage: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 4)

            if notice.isDismissible {
                Button {
                    RemoteConfigCenter.shared.dismissNotice(notice.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("feltcard.dismiss"))
            }
        }
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var link: URL? {
        notice.url.flatMap(URL.init(string:))
    }
}

/// Desteklenmeyen sürüm (`min_version`): güncelleme ekranı. Bir deprem
/// uygulaması kullanıcıyı hiçbir zaman dışarıda bırakmamalı; "Şimdilik devam
/// et" bu oturum için ekranı kapatır, bir sonraki açılışta yeniden gösterilir.
struct RemoteUpdateRequiredView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("LogoOrange")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text(L("remote.update.title"))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(L("remote.update.body"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                UIApplication.shared.open(AppUpdateNotice.storeURL)
            } label: {
                Label(L("Update"), systemImage: "arrow.down.app.fill")
            }
            .buttonStyle(.sismikPrimary(height: 52))
            Button(L("remote.update.continue"), action: onContinue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
