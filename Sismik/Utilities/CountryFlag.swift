import Foundation

/// Deprem başlığındaki ülke/bölge adından bayrak emojisi (best-effort).
enum CountryFlag {
    /// Anahtar kelime → bayrak. Daha özel olanlar önce gelmeli.
    private static let map: [(String, String)] = [
        ("türkiye", "🇹🇷"), ("turkey", "🇹🇷"),
        ("greece", "🇬🇷"), ("aegean", "🇬🇷"), ("crete", "🇬🇷"),
        ("alaska", "🇺🇸"), ("california", "🇺🇸"), ("oregon", "🇺🇸"),
        ("hawaii", "🇺🇸"), ("nevada", "🇺🇸"), ("washington", "🇺🇸"),
        ("oklahoma", "🇺🇸"), ("texas", "🇺🇸"), ("montana", "🇺🇸"),
        ("puerto rico", "🇵🇷"), ("united states", "🇺🇸"),
        ("chile", "🇨🇱"), ("argentina", "🇦🇷"), ("peru", "🇵🇪"),
        ("bolivia", "🇧🇴"), ("colombia", "🇨🇴"), ("ecuador", "🇪🇨"),
        ("venezuela", "🇻🇪"), ("mexico", "🇲🇽"), ("guatemala", "🇬🇹"),
        ("el salvador", "🇸🇻"), ("nicaragua", "🇳🇮"), ("costa rica", "🇨🇷"),
        ("panama", "🇵🇦"), ("indonesia", "🇮🇩"), ("philippines", "🇵🇭"),
        ("japan", "🇯🇵"), ("taiwan", "🇹🇼"), ("xizang", "🇨🇳"),
        ("tibet", "🇨🇳"), ("sichuan", "🇨🇳"), ("china", "🇨🇳"),
        ("iran", "🇮🇷"), ("iraq", "🇮🇶"), ("afghanistan", "🇦🇫"),
        ("pakistan", "🇵🇰"), ("india", "🇮🇳"), ("nepal", "🇳🇵"),
        ("kamchatka", "🇷🇺"), ("kuril", "🇷🇺"), ("russia", "🇷🇺"),
        ("papua new guinea", "🇵🇬"), ("new guinea", "🇵🇬"),
        ("new zealand", "🇳🇿"), ("fiji", "🇫🇯"), ("vanuatu", "🇻🇺"),
        ("tonga", "🇹🇴"), ("solomon", "🇸🇧"), ("italy", "🇮🇹"),
        ("spain", "🇪🇸"), ("portugal", "🇵🇹"), ("iceland", "🇮🇸"),
        ("romania", "🇷🇴"), ("albania", "🇦🇱"), ("croatia", "🇭🇷"),
        ("morocco", "🇲🇦"), ("algeria", "🇩🇿"), ("ethiopia", "🇪🇹"),
        ("azerbaijan", "🇦🇿"), ("georgia", "🇬🇪"), ("armenia", "🇦🇲"),
        ("syria", "🇸🇾"), ("cyprus", "🇨🇾")
    ]

    /// Çözülen başlık → bayrak. Liste ~25 saniyede bir yenilenir ve aynı
    /// birkaç yüz başlık her seferinde yeniden çözümlenir; önbelleksiz hâlde
    /// her deprem için `lowercased()` bir dize tahsis ediyor, ardından 66
    /// anahtar üzerinde Unicode `contains` taraması yapılıyordu (yenileme
    /// başına on binlerce alt dize araması). `NSCache` hem thread-safe hem
    /// bellek baskısında kendini boşaltıyor.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2_000
        return cache
    }()

    static func emoji(forTitle title: String) -> String {
        let key = title as NSString
        if let cached = cache.object(forKey: key) { return cached as String }

        let lowercased = title.lowercased()
        var flag = "🌍"
        for (keyword, candidate) in map where lowercased.contains(keyword) {
            flag = candidate
            break
        }
        cache.setObject(flag as NSString, forKey: key)
        return flag
    }
}
