import Foundation

// FastISODate doğrulaması. Bu dosya projedeki GERÇEK
// Sismik/Utilities/FastISODate.swift ile birlikte derlenir (kopya değil):
//
//   Scripts/verify-fastisodate.sh
//
// Başarısızlıkta çıkış kodu 1'dir, böylece CI'da da kullanılabilir.

var failures: [String] = []

func iso8601Reference(_ s: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}

// 1) Foundation ile birebir uyum: geniş aralıkta rastgele damgalar.
let fmtZ = ISO8601DateFormatter()
fmtZ.formatOptions = [.withInternetDateTime]
let fmtF = ISO8601DateFormatter()
fmtF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

var mismatches = 0
var parsed = 0
let sampleCount = 200_000
for i in 0..<sampleCount {
    let t = Double.random(in: -2_000_000_000...2_000_000_000).rounded()
    let s = (i % 2 == 0)
        ? fmtZ.string(from: Date(timeIntervalSince1970: t))
        : fmtF.string(from: Date(timeIntervalSince1970: t))
    guard let fast = FastISODate.date(from: s) else { continue }
    parsed += 1
    guard let ref = iso8601Reference(s) else { continue }
    if abs(fast.timeIntervalSince1970 - ref.timeIntervalSince1970) > 0.0005 { mismatches += 1 }
}
print("rastgele örnek: \(sampleCount), FastISODate çözdü: \(parsed), sapma: \(mismatches)")
expect(mismatches == 0, "Foundation ile \(mismatches) sapma var")
expect(parsed == sampleCount, "FastISODate geçerli damgaların hepsini çözemedi (\(parsed)/\(sampleCount))")

// 2) Sağlayıcıların gerçekte gönderdiği biçimler çözülebilmeli.
let mustParse = [
    "2026-08-23T14:00:00Z",
    "2026-08-23T14:00:00.123Z",
    "2026-08-23T14:00:00+03:00",
    "2026-08-23T14:00:00-05:00",
    "2026-08-23T14:00:00.999+03:00",
    "2026-08-23 14:00:00",        // saat dilimi yok → UTC
    "1970-01-01T00:00:00Z",
    "2000-02-29T23:59:59Z",       // 400'e bölünen artık yıl
    "2024-02-29T00:00:00Z",       // normal artık yıl
    "2024-12-31T23:59:59.999Z",
    "2026-08-23T00:00:00+14:00",  // en uç geçerli ofset
]
for s in mustParse {
    guard let fast = FastISODate.date(from: s) else {
        failures.append("çözülemedi: \(s)")
        continue
    }
    if let ref = iso8601Reference(s) {
        expect(abs(fast.timeIntervalSince1970 - ref.timeIntervalSince1970) < 0.0005,
               "Foundation'dan farklı: \(s)")
    }
}

// 3) Bozuk girdi asla sessizce yanlış tarih üretmemeli; nil dönmeli ki
//    çağıran taraf Foundation yedeğine düşebilsin.
let mustReject = [
    "", "abc", "null", "2026/08/23",
    "2026-13-01T00:00:00Z",        // ay 13
    "2026-02-30T00:00:00Z",        // şubat 30
    "2026-04-31T00:00:00Z",        // 31 çeken ay değil
    "2026-02-29T00:00:00Z",        // artık yıl değil
    "1900-02-29T00:00:00Z",        // 100'e bölünen, 400'e bölünmeyen
    "2026-08-23T25:00:00Z",        // saat 25
    "2026-08-23T00:61:00Z",        // dakika 61
    "202-08-23T00:00:00Z",         // eksik yıl basamağı
    "2026-08-23T00:00:00+99:00",   // olmayan saat dilimi
    "2026-08-23T00:00:00+15:00",   // ±14:00 sınırının dışı
    "2026-08-23T00:00:00+03:60",   // ofset dakikası 60
]
for s in mustReject {
    let result = FastISODate.date(from: s)
    expect(result == nil, "geçersiz girdi kabul edildi: \"\(s)\" → \(String(describing: result))")
}

// 4) Performans: hız avantajı korunuyor mu (30k kayıtlık gerçekçi yük).
let sample = (0..<30_000).map { fmtZ.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double($0))) }
var t0 = Date()
var sink = 0.0
for s in sample { sink += FastISODate.date(from: s)?.timeIntervalSince1970 ?? 0 }
let fastMs = Date().timeIntervalSince(t0) * 1000
t0 = Date()
var sinkRef = 0.0
for s in sample { sinkRef += iso8601Reference(s)?.timeIntervalSince1970 ?? 0 }
let refMs = Date().timeIntervalSince(t0) * 1000
print(String(format: "30k kayıt — FastISODate: %.1f ms, ISO8601DateFormatter: %.1f ms (%.0fx)",
             fastMs, refMs, refMs / max(fastMs, 0.001)))
expect(abs(sink - sinkRef) < 1.0, "toplu sonuçlar Foundation ile eşleşmiyor")
expect(fastMs < refMs, "FastISODate artık Foundation'dan hızlı değil")

if failures.isEmpty {
    print("✅ FastISODate doğrulaması geçti")
    exit(0)
} else {
    print("❌ \(failures.count) başarısız kontrol:")
    for f in failures { print("   - \(f)") }
    exit(1)
}
