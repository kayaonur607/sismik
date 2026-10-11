import Foundation
import CoreLocation

/// Kullanıcı konumunu yönetir; en yakın deprem/toplanma alanı hesapları için kullanılır.
@MainActor
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var location: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Son bilinen konumun UserDefaults'taki anahtarları — `LocationManager`
    /// örneği olmayan bağlamlarda (ör. arka plan tazeleme görevi) yakınlık
    /// bildirimi filtrelemesi için okunur; bkz. `NotificationManager.evaluate`.
    private enum CacheKey {
        static let lat = "locationManager.cachedLat"
        static let lon = "locationManager.cachedLon"
    }

    /// En son güncellenen konum, `LocationManager` örneği kurulmamış
    /// bağlamlardan (arka plan görevleri gibi) da erişilebilsin diye
    /// UserDefaults'ta ayrıca önbelleklenir.
    nonisolated static var cachedCoordinate: CLLocationCoordinate2D? {
        let d = UserDefaults.standard
        guard d.object(forKey: CacheKey.lat) != nil, d.object(forKey: CacheKey.lon) != nil else { return nil }
        let lat = d.double(forKey: CacheKey.lat)
        let lon = d.double(forKey: CacheKey.lon)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 500 // 500 m'den fazla harekette güncelle (pil ve CPU için ultra optimize)
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Sistem genelinde Konum Servisleri açık mı? Kapalıyken
    /// `requestWhenInUseAuthorization()` hiçbir diyalog göstermez — arayüz bu
    /// durumda kullanıcıyı Ayarlar'a yönlendirmelidir. Apple bu çağrının ana
    /// thread'de yapılmamasını önerir (UI kilitlenmesi); arka planda okunur.
    nonisolated static func servicesEnabled() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            CLLocationManager.locationServicesEnabled()
        }.value
    }

    func requestLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            return
        }
        manager.requestLocation()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                // Yetki verildiğinde arka planda sürekli takip başlatma;
                // ihtiyaç olan ekranlar tekil konum isteyebilir.
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Geçerli ve makul güncel/hassas konumlardan en iyisini seç.
        let best = locations
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 200 }
            .filter { abs($0.timestamp.timeIntervalSinceNow) < 30 }
            .min { $0.horizontalAccuracy < $1.horizontalAccuracy }
        guard let loc = best ?? locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.location = loc
            let previous = Self.cachedCoordinate
            UserDefaults.standard.set(loc.coordinate.latitude, forKey: CacheKey.lat)
            UserDefaults.standard.set(loc.coordinate.longitude, forKey: CacheKey.lon)
            // "Bulunduğum yer" kaydı cihaz konumunu takip eder. 1 km'den az
            // hareket sunucu yazımına değmez; store zaten değişmeyen değeri
            // yazmaz, bu eşik gereksiz JSON kodlamasını da önler.
            let moved = previous.map {
                loc.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) >= 1000
            } ?? true
            if moved {
                NotificationPlacesStore.shared.refreshCurrentLocation(loc.coordinate)
            }
            // İyi bir konum alındıysa GPS'i kapat (pil ve ısınma): sürekli
            // takip gerekmiyor, uygulama öne geldiğinde startUpdating yeni
            // bir tazeleme başlatır; ekranlar requestLocation ile tekil ister.
            if best != nil { self.manager.stopUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Sessizce yok say; konum opsiyonel.
    }
}
