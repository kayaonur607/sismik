import Foundation
import Network
import Observation

/// Uygulama genelinde paylaşılan tek `NWPathMonitor` örneği. Cihazın ağ
/// erişimini gerçek zamanlı izler; view'lar `isOffline`'ı doğrudan
/// gözlemleyebilir (ör. deprem listesini çevrimdışıyken kilitlemek için).
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// İlk path güncellemesi gelene kadar iyimser varsayım: çevrimiçi.
    /// Aksi halde soğuk açılışta kısa bir "çevrimdışı" yanıp sönmesi olurdu.
    private(set) var isOffline = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.kayasoftware.sismik.connectivity")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                guard let self, self.isOffline != offline else { return }
                self.isOffline = offline
            }
        }
        monitor.start(queue: queue)
    }
}
