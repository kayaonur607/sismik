import UIKit
import Observation

/// Ana ekran hızlı eylemleri (uygulama simgesine basılı tutunca açılan menü).
///
/// Her eylem uygulamanın kendi derin bağlantısına (`sismik://…`) karşılık
/// gelir; yönlendirme `RootView.handleOpenURL` ile aynı yoldan geçer, ayrı bir
/// gezinme mantığı yoktur. Soğuk açılışta eylem, arayüz kurulmadan önce
/// geldiği için `pendingURL`'de bekletilir ve kök görünüm hazır olunca işlenir.
@MainActor
@Observable
final class QuickActionRouter {
    static let shared = QuickActionRouter()

    var pendingURL: URL?

    private static let urlKey = "url"

    /// Menü dinamik kurulur: başlıklar uygulama içi dil seçimini izler
    /// (Info.plist'teki statik öğeler sistem diline bağlı kalırdı).
    static func install() {
        let items: [(type: String, title: String, icon: String, url: String)] = [
            ("recent", L("quickAction.recent"), "waveform.path.ecg", "sismik://recent"),
            ("map", L("Deprem Haritası"), "map", "sismik://map"),
            ("emergency", L("quickAction.emergency"), "cross.case", "sismik://emergency"),
            ("risk", L("risk.title"), "shield.lefthalf.filled", "sismik://risk")
        ]
        UIApplication.shared.shortcutItems = items.map { item in
            UIApplicationShortcutItem(
                type: "com.kayasoftware.sismik.\(item.type)",
                localizedTitle: item.title,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: item.icon),
                userInfo: [urlKey: item.url as NSString]
            )
        }
    }

    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let raw = item.userInfo?[Self.urlKey] as? String, let url = URL(string: raw) else { return false }
        pendingURL = url
        return true
    }
}

/// Hızlı eylemler sahne düzeyinde teslim edilir; SwiftUI yaşam döngüsünde
/// bunları almanın tek yolu bir sahne temsilcisi. Pencereyi SwiftUI kurmaya
/// devam eder, bu sınıf yalnızca eylemleri yakalar.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let item = connectionOptions.shortcutItem else { return }
        Task { @MainActor in _ = QuickActionRouter.shared.handle(item) }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in completionHandler(QuickActionRouter.shared.handle(shortcutItem)) }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Dil değişmiş olabilir; menü uygulamadan çıkarken tazelenir.
        Task { @MainActor in QuickActionRouter.install() }
    }
}
