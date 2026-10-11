import Foundation

/// Sismik uygulamasının arka uç (backend) bağlantı yapılandırması.
enum BackendConfig {
    /// Firebase Cloud Function API adresi.
    /// Firebase'e dağıtım (deploy) yaptıktan sonra terminalde veya Firebase Console'da
    /// görünen "sismikApi" HTTP tetikleyici URL adresini buraya girmelisiniz.
    /// Örn: "https://sismikapi-t6mxmndqla-uc.a.run.app" veya "https://us-central1-[PROJE-ID].cloudfunctions.net/sismikApi"
    /// Firebase Hosting üzerinden gidilir: doğrudan Cloud Run adresinin önünde
    /// paylaşılan bir önbellek olmadığı için uçların `s-maxage` başlıkları
    /// yok sayılıyordu ve her yoklama fonksiyonu ayrı ayrı çalıştırıyordu.
    /// Hosting CDN'i arkasında kök uç 15 saniyede bir, `/map` 30 dakikada bir
    /// origin'e iner — kullanıcı sayısından bağımsız olarak.
    static let baseURL = "https://\(apiHost)/api"

    /// API'nin bulunduğu Firebase Hosting sitesi.
    ///
    /// Herkese açık tanıtım sitesinden (`linkHost`) BİLEREK ayrıdır: o adreste
    /// hiçbir API ucu yayımlanmaz, dolayısıyla tanıtım sayfasını gezen birinin
    /// erişebileceği bir uç nokta da yoktur. Ayrım `firebase.json`'daki iki
    /// hosting hedefiyle uygulanır — `main` (tanıtım, /api yok) ve `api`.
    static let apiHost = "sismik-app-ea600.web.app"

    /// Paylaşım bağlantılarının (Universal Link) ve herkese açık sayfaların
    /// adresi. Değiştirirken `Sismik.entitlements` içindeki `applinks:`
    /// girdisinin de güncellenmesi gerekir; derleyici bunu denetleyemez.
    static let linkHost = "sismik-app.web.app"

    /// Daha önce yayımlanmış paylaşım bağlantılarının sunucu adı. Yeni link
    /// üretilmez ama gelen bağlantılar çalışmaya devam eder: dağıtılmış
    /// linkler kullanıcıların mesajlarında yaşamayı sürdürüyor.
    static let legacyHost = "sismik-app-ea600.web.app"
}
