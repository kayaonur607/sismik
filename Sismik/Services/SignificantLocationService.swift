import CoreLocation
import UIKit

/// "Bulunduğum yer" bildirim kaydını, uygulama kapalıyken de cihazla birlikte
/// taşır (isteğe bağlı, Ayarlar'dan açılır).
///
/// iOS'un **önemli konum değişikliği** servisini kullanır: GPS'i sürekli açık
/// tutmaz, hücre/Wi-Fi değişimiyle ~500 m–birkaç km'de bir uygulamayı kısa
/// süreliğine uyandırır. Pil etkisi ihmal edilebilir; "Her zaman" konum izni
/// gerektirir.
///
/// Maliyet (10 bin+ kullanıcı): sunucuya yalnızca bildirim bölgesini anlamlı
/// değiştiren hareket gider — `NotificationPlacesStore.refreshCurrentLocation`
/// en az 1 km ve yarıçapın %10'unu (50 km'lik yerde 5 km) şart koşar, sunucu da
/// aynı yükü ikinci kez yazmaz. Günlük işe gidiş-dönüş çoğu kullanıcıda 0–2
/// kayıt demektir.
@MainActor
final class SignificantLocationService: NSObject, CLLocationManagerDelegate {
    static let shared = SignificantLocationService()
    static let preferenceKey = "location.backgroundUpdates"

    private let manager = CLLocationManager()
    private var monitoring = false

    private override init() {
        super.init()
        manager.delegate = self
        // Yalnızca kaba konum gerekir: bildirim yarıçapları kilometre ölçeğinde.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.pausesLocationUpdatesAutomatically = true
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.preferenceKey)
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Ayar değişince çağrılır. Açılırken "Her zaman" izni istenir; iOS önce
    /// "Kullanırken" izni verilmişse yükseltme diyaloğunu gösterir.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        if enabled, manager.authorizationStatus != .authorizedAlways {
            manager.requestAlwaysAuthorization()
        }
        refresh()
    }

    /// Uygulama açılışında (arka planda konumla uyandırıldığında dahil)
    /// çağrılır: tercih ve izin varsa izlemeyi sürdürür, yoksa durdurur.
    func refresh() {
        let shouldMonitor = isEnabled
            && RemoteConfig.isEnabled(.backgroundLocation)
            && manager.authorizationStatus == .authorizedAlways
            && CLLocationManager.significantLocationChangeMonitoringAvailable()
            && NotificationPlacesStore.shared.places.contains { $0.kind == .current && $0.enabled }
        guard shouldMonitor != monitoring else { return }
        monitoring = shouldMonitor
        if shouldMonitor {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 3_000 }) else { return }
        Task { @MainActor in
            // Arka planda uyandırıldığımızda kayıt isteği bitene kadar süreç
            // askıya alınmasın.
            let task = UIApplication.shared.beginBackgroundTask(withName: "significant-location")
            UserDefaults.standard.set(location.coordinate.latitude, forKey: "locationManager.cachedLat")
            UserDefaults.standard.set(location.coordinate.longitude, forKey: "locationManager.cachedLon")
            NotificationPlacesStore.shared.refreshCurrentLocation(location.coordinate)
            try? await Task.sleep(for: .seconds(8))
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Konum opsiyonel; bir sonraki değişiklikte yeniden denenir.
    }
}
