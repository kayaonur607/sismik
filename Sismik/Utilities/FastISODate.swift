import Foundation

/// Sağlayıcı yanıtlarındaki ISO-8601 zaman damgalarını tahsis yapmadan çözer.
///
/// `ISO8601DateFormatter` her çağrıda ICU üzerinden geçtiği için 30 bin kayıtlık
/// harita arşivinde tek başına ~600 ms tutuyordu (ölçüm: Apple silicon, -O).
/// Buradaki elle çözümleme aynı girdiler için ~5 ms sürer ve kesirli saniye ile
/// sayısal saat dilimi ekini tek geçişte kabul eder; bu yüzden iki ayrı
/// formatter denemesi de ortadan kalkar.
///
/// Desteklenen biçimler:
/// `2026-08-23T14:00:00Z`, `2026-08-23T14:00:00.123Z`,
/// `2026-08-23T14:00:00+03:00`, `2026-08-23 14:00:00` (saat dilimi yoksa UTC).
enum FastISODate {

    /// Çözülemeyen girdide `nil` döner; çağıran taraf Foundation formatter'ına
    /// düşerek hiçbir sağlayıcı biçimini kaybetmez.
    static func date(from string: String) -> Date? {
        // Tarih/saat bileşenleri sırayla doldurulur: yıl, ay, gün, saat, dakika, saniye.
        var components = [0, 0, 0, 0, 0, 0]
        var componentIndex = 0
        var componentDigits = 0

        var fraction = 0.0
        var fractionScale = 1.0

        var timeZoneSign = 0.0
        var timeZoneComponents = [0, 0]
        var timeZoneIndex = 0

        var seenTimeSeparator = false
        var inFraction = false
        var inTimeZone = false

        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let value = Int(byte - UInt8(ascii: "0"))
                if inFraction {
                    fraction = fraction * 10 + Double(value)
                    fractionScale *= 10
                } else if inTimeZone {
                    guard timeZoneIndex < 2 else { return nil }
                    timeZoneComponents[timeZoneIndex] = timeZoneComponents[timeZoneIndex] * 10 + value
                    if timeZoneComponents[timeZoneIndex] > 99 { return nil }
                    componentDigits += 1
                    if componentDigits == 2 {
                        timeZoneIndex += 1
                        componentDigits = 0
                    }
                } else {
                    guard componentIndex < 6 else { return nil }
                    components[componentIndex] = components[componentIndex] * 10 + value
                    componentDigits += 1
                    // Yıl 4 hane, kalan bileşenler 2 hane.
                    if componentDigits == (componentIndex == 0 ? 4 : 2) {
                        componentIndex += 1
                        componentDigits = 0
                    }
                }

            case UInt8(ascii: "T"), UInt8(ascii: " "), UInt8(ascii: "t"):
                seenTimeSeparator = true
                componentDigits = 0

            case UInt8(ascii: "."), UInt8(ascii: ","):
                guard componentIndex >= 6 else { return nil }
                inFraction = true

            case UInt8(ascii: "+"):
                guard seenTimeSeparator else { return nil }
                inFraction = false
                inTimeZone = true
                timeZoneSign = 1
                componentDigits = 0

            case UInt8(ascii: "-"):
                // Tarih içindeki ayraç ile saat dilimi eki aynı karakteri kullanır.
                if seenTimeSeparator {
                    inFraction = false
                    inTimeZone = true
                    timeZoneSign = -1
                    componentDigits = 0
                } else {
                    componentDigits = 0
                }

            case UInt8(ascii: ":"):
                componentDigits = 0

            case UInt8(ascii: "Z"), UInt8(ascii: "z"):
                inFraction = false

            default:
                return nil
            }
        }

        // Saniyeye kadar tüm bileşenler dolmuş olmalı.
        guard componentIndex >= 6 else { return nil }

        let year = components[0]
        let month = components[1]
        let day = components[2]
        let hour = components[3]
        let minute = components[4]
        let second = components[5]

        guard month >= 1, month <= 12,
              day >= 1, day <= daysInMonth(year: year, month: month),
              hour <= 23, minute <= 59, second <= 60 else { return nil }

        // Saat dilimi eki gerçek bir ofset olmalı. Aksi hâlde "+99:00" gibi
        // bozuk bir ek sessizce kabul edilip tarihi günlerce kaydırıyordu;
        // Foundation bu girdiye nil döndüğü için yedek yol da devreye girmezdi.
        if timeZoneSign != 0 {
            guard timeZoneComponents[0] <= 14, timeZoneComponents[1] <= 59 else { return nil }
        }

        let epochDays = daysFromCivil(year: year, month: month, day: day)
        var interval = Double(epochDays) * 86_400
            + Double(hour * 3_600 + minute * 60 + second)
        if fractionScale > 1 { interval += fraction / fractionScale }
        if timeZoneSign != 0 {
            interval -= timeZoneSign * Double(timeZoneComponents[0] * 3_600 + timeZoneComponents[1] * 60)
        }
        return Date(timeIntervalSince1970: interval)
    }

    /// Ayın gerçek gün sayısı (artık yıl dahil). Sabit 31 sınırı "2026-02-30"
    /// gibi geçersiz bir günü kabul edip takvimde ileri kaydırıyordu.
    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        }
    }

    /// Howard Hinnant'ın `days_from_civil` algoritması: proleptik Gregoryen
    /// takvimde 1970-01-01'den itibaren gün sayısı (artık yıl kuralları dahil).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400                      // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
