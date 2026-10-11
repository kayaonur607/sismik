import SwiftUI

/// Ana sayfadaki "Yeni Sürüm Mevcut" banner'ının durumu.
///
/// Ayrı bir sürüm kontrolü YAPMAZ: sunucu, App Store'da yayında olan sürümü
/// canlı deprem listesinin yanıt başlığında (`X-Sismik-Latest-Version`)
/// gönderir; uygulama o listeyi zaten düzenli olarak çekiyor. Sürüm sunucuda
/// yalnızca Apple onaylayıp mağazada göründükten sonra artar (App Store
/// Connect webhook'u), dolayısıyla banner güncellemesi indirilemeyen bir
/// sürümü asla göstermez. Son değer UserDefaults'ta saklanır; çevrimdışı
/// açılışta da banner kaybolmaz.
@MainActor
@Observable
final class AppUpdateNotice {
    static let shared = AppUpdateNotice()

    // Değişmez ve Sendable: `EarthquakeService` actor'ı gibi ana aktör dışındaki
    // yerlerden de okunur.
    nonisolated static let storeURL = URL(string: "https://apps.apple.com/app/id6787776158")!
    nonisolated static let responseHeader = "X-Sismik-Latest-Version"
    private static let latestVersionKey = "appUpdateNotice.latestVersion"

    private(set) var showBanner = false

    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private init() {
        evaluate(UserDefaults.standard.string(forKey: Self.latestVersionKey))
    }

    /// Liste yanıtındaki başlık değerini kaydeder. Başlık yoksa (eski sunucu,
    /// hata yanıtı) mevcut durum korunur.
    func record(latestVersion raw: String?) {
        guard let version = raw?.trimmingCharacters(in: .whitespaces),
              !version.isEmpty,
              version.allSatisfy({ $0.isNumber || $0 == "." }) else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.latestVersionKey) != version {
            defaults.set(version, forKey: Self.latestVersionKey)
        }
        evaluate(version)
    }

    private func evaluate(_ latestVersion: String?) {
        let visible = latestVersion.map { Self.version(currentVersion, isOlderThan: $0) } ?? false
        if visible != showBanner {
            withAnimation(.easeInOut(duration: 0.3)) { showBanner = visible }
        }
    }

    /// Basit semver karşılaştırması: "2.1.0" < "2.1.1", "1.0.9" < "1.0.10".
    nonisolated static func version(_ lhs: String, isOlderThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// Ana sayfa listesinin üstündeki güncelleme banner'ı. Metinler 2.0.x
/// banner'ıyla aynı çeviri anahtarlarını kullanır.
struct AppUpdateBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title3)
                .foregroundStyle(.brandOrange)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Yeni Sürüm Mevcut"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(L("Uygulamanın yeni sürümü yayında. Güncellemek için tıklayın."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                UIApplication.shared.open(AppUpdateNotice.storeURL)
            } label: {
                Text(L("Update"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.brandOrange, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.brandOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.brandOrange.opacity(0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { UIApplication.shared.open(AppUpdateNotice.storeURL) }
    }
}
