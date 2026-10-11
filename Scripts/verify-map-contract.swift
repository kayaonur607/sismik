import Foundation

// `/map` sözleşmesini uygulamanın GERÇEK `Earthquake` decoder'ıyla doğrular.
// Kopya model kullanılmaz: sapma olursa test değil, uygulama kodu yanılır.
//
// Girdi, `Scripts/verify-map-contract.sh` tarafından üretilen ve sunucunun
// gerçek `/map` yanıtını içeren bir JSON dosyasıdır.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("kullanım: verify-map-contract <served.json>\n".utf8))
    exit(2)
}

let data: Data
do {
    data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
} catch {
    FileHandle.standardError.write(Data("girdi okunamadı: \(error)\n".utf8))
    exit(2)
}

let quakes: [Earthquake]
do {
    quakes = try JSONDecoder().decode([Earthquake].self, from: data)
} catch {
    FileHandle.standardError.write(Data("iOS decoder /map yanıtını çözemedi: \(error)\n".utf8))
    exit(1)
}

print("çözülen kayıt: \(quakes.count)")

// `EarthquakeTechnicalCard`'ın okuduğu alanlar. Harita havuzundaki nesne
// kullanıcı "Detay"a gittiğinde doğrudan `EarthquakeDetailView`e geçtiği ve
// detay ekranı kaydı sunucudan tazelemediği için, bu alanların `/map`
// yanıtında hayatta kalması zorunludur.
var present: [String: Int] = [:]
func count(_ key: String, _ isPresent: Bool) {
    if isPresent { present[key, default: 0] += 1 }
}

for quake in quakes {
    count("sourceURL", quake.sourceURL != nil)
    count("updatedAt", quake.updatedAt != nil)
    count("status", quake.status != nil)
    count("network", quake.network != nil)
    count("eventCode", quake.eventCode != nil)
    count("eventType", quake.eventType != nil)
    count("catalog", quake.catalog != nil)
    count("author", quake.author != nil)
    count("significance", quake.significance != nil)
    count("stationCount", quake.stationCount != nil)
    count("minimumDistance", quake.minimumDistance != nil)
    count("rms", quake.rms != nil)
    count("gap", quake.gap != nil)
    count("detailURL", quake.detailURL != nil)
}

for key in present.keys.sorted() { print("  \(key): \(present[key]!)") }

var failures: [String] = []

if quakes.isEmpty { failures.append("yanıt boş") }

// Haritanın çizim için zorunlu saydığı alanlar.
let invalidCoordinate = quakes.filter {
    !$0.coordinate.latitude.isFinite || !$0.coordinate.longitude.isFinite
        || $0.coordinate.latitude < -90 || $0.coordinate.latitude > 90
        || $0.coordinate.longitude < -180 || $0.coordinate.longitude > 180
}.count
let dateFallback = quakes.filter { $0.date.timeIntervalSince1970 <= 0 }.count
let emptyID = quakes.filter { $0.id.isEmpty }.count
let emptySourceTag = quakes.filter { $0.sourceTag.isEmpty }.count

print("geçersiz koordinat: \(invalidCoordinate), tarih fallback: \(dateFallback), boş id: \(emptyID), boş sourceTag: \(emptySourceTag)")

if invalidCoordinate > 0 { failures.append("\(invalidCoordinate) kayıtta geçersiz koordinat") }
if dateFallback > 0 { failures.append("\(dateFallback) kayıtta tarih çözülemedi") }
if emptyID > 0 { failures.append("\(emptyID) kayıtta boş id") }
if emptySourceTag > 0 { failures.append("\(emptySourceTag) kayıtta boş sourceTag") }

// Teknik kartın alanları tamamen kaybolmamalı. Sağlayıcıya göre bazı alanlar
// doğal olarak eksiktir; bu yüzden "hiç yok" durumu hatadır, "bazılarında yok"
// değil.
for field in ["sourceURL", "updatedAt", "status", "network", "eventCode",
              "eventType", "catalog", "author", "significance",
              "stationCount", "minimumDistance", "rms", "gap"] {
    if (present[field] ?? 0) == 0 {
        failures.append("\(field) hiçbir kayıtta yok — detay teknik kartı boşalır")
    }
}

// Kasten düşürülen alan gerçekten düşmüş olmalı.
if (present["detailURL"] ?? 0) > 0 {
    failures.append("detailURL düşürülmeliydi ama \(present["detailURL"]!) kayıtta var")
}

if failures.isEmpty {
    print("✅ /map sözleşmesi gerçek iOS decoder'ıyla doğrulandı")
} else {
    for failure in failures {
        FileHandle.standardError.write(Data("❌ \(failure)\n".utf8))
    }
    exit(1)
}
