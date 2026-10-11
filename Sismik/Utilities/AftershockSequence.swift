import CoreLocation
import Foundation

/// Bir ana şokun artçı dizisi: büyük olay kartı, detaydaki "Artçılar" kartı ve
/// deprem haritası AYNI kuralla sayar. Eskiden kart listeden 100 km sabit
/// çemberle ve ajans kopyalarıyla birlikte sayıyor, detay sunucudan başka bir
/// yarıçapla yüklüyordu; iki ekran farklı sayı gösteriyordu.
///
/// Alan sunucudakiyle aynıdır (functions/src/worker-utils.ts
/// `aftershockZoneRadiusKm`): Gardner–Knopoff (1974) artçı penceresi ile
/// Wells–Coppersmith (1994) kırılma uzunluğunun büyüğü. M4.0 → 30 km,
/// M5.8 → 50 km, M7.0 → 71 km, M7.8 → 145 km.
enum AftershockSequence {
    /// Artçıların arandığı süre (ana şoktan sonra).
    nonisolated static let window: TimeInterval = 30 * 86_400

    nonisolated static func zoneRadiusKm(forMagnitude magnitude: Double) -> Double {
        let gardnerKnopoff = pow(10, 0.1238 * magnitude + 0.983)
        let ruptureLength = pow(10, -2.44 + 0.59 * magnitude)
        return min(400, max(10, gardnerKnopoff, ruptureLength)).rounded()
    }

    /// Adaylardan artçıları seçer: alan içinde, ana şoktan sonra, ana şokun
    /// ajans kopyaları hariç, aynı artçının farklı ajans kayıtları tek sefer
    /// (bölgenin resmî ajansının kaydı kalır). En yeni önce.
    nonisolated static func select(
        mainshock: Earthquake,
        from candidates: [Earthquake],
        now: Date = Date(),
        limit: Int = 500
    ) -> [Earthquake] {
        let center = mainshock.clLocation
        let radiusMeters = zoneRadiusKm(forMagnitude: mainshock.magnitude) * 1_000
        let end = min(now, mainshock.date.addingTimeInterval(window))

        var seenIDs = Set<String>()
        let inZone = candidates.filter { quake in
            guard seenIDs.insert("\(quake.sourceTag):\(quake.id)").inserted,
                  quake.id != mainshock.id,
                  quake.date > mainshock.date,
                  quake.date <= end.addingTimeInterval(60) else { return false }
            let distance = quake.clLocation.distance(from: center)
            // Ana şokun başka ajanslardaki kaydı artçı değildir.
            if quake.date.timeIntervalSince(mainshock.date) <= 180,
               distance <= 30_000,
               abs(quake.magnitude - mainshock.magnitude) < 1 {
                return false
            }
            return distance <= radiusMeters
        }

        // Aynı artçının farklı ajans kayıtları tek sayılır (resmî ajans kalır).
        let unique = deduplicatedAgencyCopies(inZone)
        return Array(unique.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Aynı fiziksel depremin ajans kopyalarından tek kayıt bırakır: bölgenin
    /// resmî ajansı (`authorityRank`), eşitlikte büyüklüğü yüksek olan. Liste
    /// "Tümü" görünümü, harita ve artçılar aynı kuralı kullanır. 75 sn'lik
    /// zaman kovalarıyla ~O(n): 34 günlük harita arşivinde de hızlı.
    nonisolated static func deduplicatedAgencyCopies(_ quakes: [Earthquake]) -> [Earthquake] {
        let ranked = quakes.sorted {
            let lhs = EarthquakeListViewModel.authorityRank($0)
            let rhs = EarthquakeListViewModel.authorityRank($1)
            return lhs != rhs ? lhs < rhs : $0.magnitude > $1.magnitude
        }
        var kept: [Earthquake] = []
        kept.reserveCapacity(ranked.count)
        var buckets: [Int: [Earthquake]] = [:]
        let rule = CopyRule.current
        for quake in ranked {
            let key = Int((quake.date.timeIntervalSince1970 / rule.seconds).rounded(.down))
            let duplicate = (key - 1...key + 1).contains { k in
                buckets[k]?.contains(where: { isAgencyCopy($0, quake, rule: rule) }) ?? false
            }
            guard !duplicate else { continue }
            kept.append(quake)
            buckets[key, default: []].append(quake)
        }
        return kept
    }

    /// Aynı depremin başka ajanstaki kaydı mı? 75 sn ve 20 km ya da 20 sn ve
    /// 45 km (küçük depremlerde ajans konumları 20 km'den fazla ayrışabilir).
    /// Aynı ajansın iki kaydı iki ayrı depremdir. Sunucudaki `isAgencyCopy`
    /// ile aynı kural.
    nonisolated static func isAgencyCopy(_ a: Earthquake, _ b: Earthquake) -> Bool {
        isAgencyCopy(a, b, rule: .current)
    }

    /// Eşikler uzak yapılandırmadan değiştirilebilir (`dedupe`); sunucudaki
    /// kural ayrıca güncellenmelidir (worker-utils `isAgencyCopy`).
    struct CopyRule: Sendable {
        let seconds: Double
        let meters: Double
        let wideSeconds: Double
        let wideMeters: Double

        nonisolated static var current: CopyRule {
            CopyRule(
                seconds: RemoteConfig.number(\.dedupe, "seconds", default: 75, in: 10...300),
                meters: RemoteConfig.number(\.dedupe, "km", default: 20, in: 5...100) * 1_000,
                wideSeconds: RemoteConfig.number(\.dedupe, "wide_seconds", default: 20, in: 5...120),
                wideMeters: RemoteConfig.number(\.dedupe, "wide_km", default: 45, in: 10...150) * 1_000
            )
        }
    }

    nonisolated static func isAgencyCopy(_ a: Earthquake, _ b: Earthquake, rule: CopyRule) -> Bool {
        guard a.sourceTag != b.sourceTag else { return false }
        let seconds = abs(a.date.timeIntervalSince(b.date))
        guard seconds <= rule.seconds else { return false }
        let meters = a.clLocation.distance(from: b.clLocation)
        return meters <= rule.meters || (seconds <= rule.wideSeconds && meters <= rule.wideMeters)
    }
}
