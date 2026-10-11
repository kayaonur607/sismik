import SwiftUI
import CoreLocation
import MapKit

struct SeismicImpactModel {
    let earthquake: Earthquake

    /// Odak Derinliği (km) — Bilinmiyorsa sığ deprem kabul edilir (10 km).
    var depthKm: Double {
        max(1.0, earthquake.depth)
    }

    var magnitude: Double {
        earthquake.magnitude
    }

    /// ShakeMap ürünü bulunmayan veya diğer kaynaklardan (AFAD, EMSC, USGS, NOA vb.) gelen tüm
    /// depremler için USGS ShakeMap standardında tam kapsamlı eş-şiddet konturları üretir.
    /// Üretilmiş konturların süreç ömrü boyunca yaşayan önbelleği.
    ///
    /// Bu özellik SwiftUI gövdelerinden okunuyor ve gövdeler her durum
    /// değişiminde yeniden değerlendiriliyor (katman seçici, yükleme bayrakları,
    /// AI kartı, animasyonlu Mercalli sayacı...). Her okumada dokuz halkanın
    /// binlerce noktası `sin/cos/asin/atan2` ile baştan üretiliyordu — ShakeMap
    /// çizimlerinin işlemciyi yormasının başlıca sebebi buydu. Sonuç yalnızca
    /// depremin kimliğine bağlı olduğundan bir kez hesaplanıp saklanır.
    private static let contourCache = NSCache<NSString, EstimatedContourBox>()

    private final class EstimatedContourBox {
        let contours: [SeismicImpactData.Contour]
        init(_ contours: [SeismicImpactData.Contour]) { self.contours = contours }
    }

    var estimatedContoursAsSeismicContours: [SeismicImpactData.Contour] {
        let cacheKey = earthquake.id as NSString
        if let cached = Self.contourCache.object(forKey: cacheKey) {
            return cached.contours
        }
        let generated = generateEstimatedContours()
        Self.contourCache.setObject(EstimatedContourBox(generated), forKey: cacheKey)
        return generated
    }

    private func generateEstimatedContours() -> [SeismicImpactData.Contour] {
        let centerMMI = estimatedMMI(atEpicentralDistance: 0)
        let maxTargetMMI = min(10, max(2, Int(floor(centerMMI))))
        var contours: [SeismicImpactData.Contour] = []

        for mmi in 2...maxTargetMMI {
            let radius = radiusKm(forMMI: Double(mmi))
            guard radius >= 0.4 else { continue }
            let coords = geodesicPolygon(radiusKm: radius, pointCount: Self.pointCount(forRadiusKm: radius))
            contours.append(
                SeismicImpactData.Contour(
                    id: "estimated-\(earthquake.id)-\(mmi)",
                    mmi: Double(mmi),
                    paths: [
                        SeismicImpactData.Contour.Path(
                            id: "estimated-\(earthquake.id)-\(mmi)-0",
                            coordinates: coords
                        )
                    ]
                )
            )
        }

        // Çok küçük veya sığ odaklı depremlerde (ör. M < 2.0) merkez üssü çevresinde
        // minimum hissedilme sınırını gösterir.
        if contours.isEmpty {
            let fallbackMMI = max(2, min(10, Int(round(centerMMI))))
            let fallbackRadius = max(0.5, min(3.0, magnitude * 0.7))
            let coords = geodesicPolygon(radiusKm: fallbackRadius, pointCount: Self.pointCount(forRadiusKm: fallbackRadius))
            contours.append(
                SeismicImpactData.Contour(
                    id: "estimated-\(earthquake.id)-\(fallbackMMI)",
                    mmi: Double(fallbackMMI),
                    paths: [
                        SeismicImpactData.Contour.Path(
                            id: "estimated-\(earthquake.id)-\(fallbackMMI)-0",
                            coordinates: coords
                        )
                    ]
                )
            )
        }

        return contours
    }

    /// Hypocentral distance (Odak uzaklığı) $R_{hyp} = \sqrt{d_{epi}^2 + h_{depth}^2}$
    func hypocentralDistanceKm(fromEpicentralDistance distanceKm: Double) -> Double {
        let epi = max(0, distanceKm)
        return hypot(epi, depthKm)
    }

    /// Akkar-Bommer & USGS GMPE azalım modeliyle tahmini Peak Ground Acceleration (PGA) g biriminde.
    func pgaG(atEpicentralDistance distanceKm: Double) -> Double {
        let rHyp = hypocentralDistanceKm(fromEpicentralDistance: distanceKm)
        let logPGA = 0.58 * magnitude - 1.25 * log10(rHyp + 6.0) - 0.0021 * rHyp - 2.20
        return max(0.00001, pow(10, logPGA))
    }

    /// ShakeMap bulunmadığında tahmini PGA azalımını Wald ve arkadaşlarının
    /// MMI–PGA bağıntısıyla hissedilen şiddete dönüştürür.
    func estimatedMMI(atEpicentralDistance distanceKm: Double) -> Double {
        // Wald bağıntısı PGA'yı g değil cm/s² cinsinden kullanır.
        Self.mmi(fromPGACmPerSecSquared: pgaG(atEpicentralDistance: distanceKm) * 980.665)
    }

    /// Deprem nesnesi olmadan aynı azalım + Wald zinciri: senaryo depremleri
    /// (fayın olası en büyük depremi) ve geçmiş katalog kayıtları için.
    static func estimatedMMI(magnitude: Double, depthKm: Double, epicentralDistanceKm: Double) -> Double {
        let r = hypot(max(0, epicentralDistanceKm), max(1, depthKm))
        let logPGA = 0.58 * magnitude - 1.25 * log10(r + 6.0) - 0.0021 * r - 2.20
        return mmi(fromPGACmPerSecSquared: max(0.00001, pow(10, logPGA)) * 980.665)
    }

    /// Wald ve ark. (1999) MMI–PGA bağıntısı. Tahmini azalım ve istasyonda
    /// ÖLÇÜLEN ivme (ORFEUS RRSM) aynı ölçekle şiddete çevrilir.
    static func mmi(fromPGACmPerSecSquared pga: Double) -> Double {
        guard pga.isFinite, pga > 0 else { return 0 }
        let mmi = pga >= 80 ? 3.66 * log10(pga) - 1.66 : 2.20 * log10(pga) + 1.00
        return min(10.0, max(0.0, mmi))
    }

    /// Monotonik azalım eğrisinde verilen MMI seviyesinin dış sınırını bulur.
    /// Sonuç 1.200 km ile sınırlıdır; daha uzağı uygulama ölçeğinde belirsizdir.
    func radiusKm(forMMI targetMMI: Double) -> Double {
        guard targetMMI > 0, estimatedMMI(atEpicentralDistance: 0) >= targetMMI else { return 0 }

        let maximumRadius = 1_200.0
        var lower = 0.0
        var upper = 1.0
        while upper < maximumRadius, estimatedMMI(atEpicentralDistance: upper) >= targetMMI {
            lower = upper
            upper = min(maximumRadius, upper * 2)
        }
        if upper == maximumRadius,
           estimatedMMI(atEpicentralDistance: upper) >= targetMMI {
            return maximumRadius
        }

        // 32 adım kilometrenin çok altında çözünürlük sağlar ve harita için
        // fazlasıyla yeterlidir.
        for _ in 0..<32 {
            let midpoint = (lower + upper) / 2
            if estimatedMMI(atEpicentralDistance: midpoint) >= targetMMI {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return lower
    }

    /// Halkanın çevre uzunluğuna göre köşe sayısı. Sabit 180 nokta, ekranda
    /// birkaç piksel tutan iç halkalar için de üretiliyor ve hem hesaplama hem
    /// de MapKit'in her karo için yeniden çizdiği geometri gereksiz büyüyordu.
    /// Bu değerlerde çizgi gözle ayırt edilemeyecek kadar pürüzsüz kalır.
    private static func pointCount(forRadiusKm radius: Double) -> Int {
        switch radius {
        case ..<10:  48
        case ..<60:  72
        case ..<200: 96
        default:     128
        }
    }

    private func geodesicPolygon(radiusKm: Double, pointCount: Int = 90) -> [CLLocationCoordinate2D] {
        let center = earthquake.coordinate.clCoordinate
        let earthRadiusKm = 6_371.0088
        let latitude = center.latitude * .pi / 180
        let longitude = center.longitude * .pi / 180
        let count = max(36, pointCount)

        // Odak derinliği ve episantr uzaklığına bağlı olarak hafif doğal jeolojik eliptisite
        // (Radyasyon paterni ve sismik dalga yayılımı).
        let strikeAngle = (abs(earthquake.coordinate.latitude * 17.0 + earthquake.coordinate.longitude * 31.0)
            .truncatingRemainder(dividingBy: 180.0)) * .pi / 180.0
        let ellipticity = min(0.10, max(0.02, (12.0 / (radiusKm + 15.0)) * 0.08))

        return (0...count).map { index in
            let bearing = (Double(index) / Double(count)) * 2 * Double.pi
            let modulatedRadiusKm = radiusKm * (1.0 + ellipticity * cos(2.0 * (bearing - strikeAngle)))
            let angularDistance = modulatedRadiusKm / earthRadiusKm

            let targetLatitude = asin(
                sin(latitude) * cos(angularDistance)
                    + cos(latitude) * sin(angularDistance) * cos(bearing)
            )
            let targetLongitude = longitude + atan2(
                sin(bearing) * sin(angularDistance) * cos(latitude),
                cos(angularDistance) - sin(latitude) * sin(targetLatitude)
            )
            return CLLocationCoordinate2D(
                latitude: targetLatitude * 180 / .pi,
                longitude: targetLongitude * 180 / .pi
            )
        }
    }

    /// Peak Ground Velocity (PGV) cm/s biriminde.
    func pgvCmPerSec(atEpicentralDistance distanceKm: Double) -> Double {
        let rHyp = hypocentralDistanceKm(fromEpicentralDistance: distanceKm)
        let logPGV = 0.65 * magnitude - 1.10 * log10(rHyp + 5.0) - 1.55
        return max(0.001, pow(10, logPGV))
    }

    /// Depremin resmi sismoloji kaynağına (AFAD, USGS, EMSC, NOA) göre kalibre edilmiş hız modeli.
    var velocityModel: SeismicVelocityModel {
        SeismicVelocityModel.model(for: earthquake.provider)
    }

    /// Depremin derinliği, episantr uzaklığı ve sismik kaynağın hız modeline göre hesaplanan kesin dalga varışları.
    func waveArrivals(atEpicentralDistance distanceKm: Double) -> SeismicWaveArrivals {
        let model = velocityModel
        let h = max(0, earthquake.depth)
        let delta = max(0, distanceKm)
        let hypDist = sqrt(delta * delta + h * h)

        // 1. Direkt Dalga (Pg / Sg)
        let tPg = hypDist / model.vpCrust
        let tSg = hypDist / model.vsCrust

        // 2. Kırılan Dalga / Moho Baş Dalgası (Pn / Sn)
        let pInfo: WavePhaseArrival
        let sInfo: WavePhaseArrival

        if h < model.mohoDepthKm && model.vpMantle > model.vpCrust {
            let dh = 2 * model.mohoDepthKm - h
            let pCrit = (dh * sqrt(model.vpMantle * model.vpMantle - model.vpCrust * model.vpCrust)) / (model.vpMantle * model.vpCrust)
            let tPn = (delta / model.vpMantle) + pCrit

            if tPn < tPg && delta > 80.0 {
                pInfo = WavePhaseArrival(
                    phaseName: "Pn",
                    arrivalDate: earthquake.date.addingTimeInterval(tPn),
                    travelSeconds: tPn,
                    velocityKmS: model.vpMantle,
                    isHeadWave: true
                )
            } else {
                pInfo = WavePhaseArrival(
                    phaseName: "Pg",
                    arrivalDate: earthquake.date.addingTimeInterval(tPg),
                    travelSeconds: tPg,
                    velocityKmS: model.vpCrust,
                    isHeadWave: false
                )
            }
        } else {
            pInfo = WavePhaseArrival(
                phaseName: "P",
                arrivalDate: earthquake.date.addingTimeInterval(tPg),
                travelSeconds: tPg,
                velocityKmS: model.vpCrust,
                isHeadWave: false
            )
        }

        if h < model.mohoDepthKm && model.vsMantle > model.vsCrust {
            let dh = 2 * model.mohoDepthKm - h
            let sCrit = (dh * sqrt(model.vsMantle * model.vsMantle - model.vsCrust * model.vsCrust)) / (model.vsMantle * model.vsCrust)
            let tSn = (delta / model.vsMantle) + sCrit

            if tSn < tSg && delta > 80.0 {
                sInfo = WavePhaseArrival(
                    phaseName: "Sn",
                    arrivalDate: earthquake.date.addingTimeInterval(tSn),
                    travelSeconds: tSn,
                    velocityKmS: model.vsMantle,
                    isHeadWave: true
                )
            } else {
                sInfo = WavePhaseArrival(
                    phaseName: "Sg",
                    arrivalDate: earthquake.date.addingTimeInterval(tSg),
                    travelSeconds: tSg,
                    velocityKmS: model.vsCrust,
                    isHeadWave: false
                )
            }
        } else {
            sInfo = WavePhaseArrival(
                phaseName: "S",
                arrivalDate: earthquake.date.addingTimeInterval(tSg),
                travelSeconds: tSg,
                velocityKmS: model.vsCrust,
                isHeadWave: false
            )
        }

        // 3. Yüzey Dalgası (Rayleigh / Lg)
        let tSurf = delta / model.vSurf
        let surfInfo = WavePhaseArrival(
            phaseName: "Lg",
            arrivalDate: earthquake.date.addingTimeInterval(tSurf),
            travelSeconds: tSurf,
            velocityKmS: model.vSurf,
            isHeadWave: false
        )

        let spInterval = max(0, sInfo.travelSeconds - pInfo.travelSeconds)

        return SeismicWaveArrivals(
            pWave: pInfo,
            sWave: sInfo,
            surfaceWave: surfInfo,
            spIntervalSeconds: spInterval,
            velocityModel: model,
            epicentralDistanceKm: delta,
            hypocentralDistanceKm: hypDist
        )
    }
}

// MARK: - Deprem Kaynaklarına Özel Sismolojik Hız Modelleri

/// AFAD, USGS, EMSC ve NOA sismoloji ağlarının resmi bölgesel/küresel kabuk hız modelleri.
struct SeismicVelocityModel: Hashable, Sendable {
    let sourceName: String
    let modelName: String
    let vpCrust: Double      // Pg hızı (km/s)
    let vsCrust: Double      // Sg hızı (km/s)
    let mohoDepthKm: Double  // Moho süreksizlik derinliği (km)
    let vpMantle: Double     // Pn hızı (km/s)
    let vsMantle: Double     // Sn hızı (km/s)
    let vSurf: Double        // Yüzey dalgası (Rayleigh / Lg) hızı (km/s)
    let descriptionTR: String
    let descriptionEN: String

    static func model(for provider: String) -> SeismicVelocityModel {
        switch provider.lowercased() {
        case "afad":
            return SeismicVelocityModel(
                sourceName: "AFAD",
                modelName: "AFAD-RED 1D Anadolu Hız Modeli",
                vpCrust: 5.95,
                vsCrust: 3.44,
                mohoDepthKm: 32.0,
                vpMantle: 7.90,
                vsMantle: 4.45,
                vSurf: 3.05,
                descriptionTR: "AFAD sismoloji istasyon ağı ve Türkiye 1D kabuk hız parametreleri (Vp=5.95 km/s, Vs=3.44 km/s, Moho=32 km).",
                descriptionEN: "AFAD regional seismological network and Anatolian 1D crustal velocity parameters (Vp=5.95 km/s, Vs=3.44 km/s, Moho=32 km)."
            )
        case "noa":
            return SeismicVelocityModel(
                sourceName: "NOA (Atina)",
                modelName: "NOA Ege & Helenik Yay Hız Modeli",
                vpCrust: 5.90,
                vsCrust: 3.41,
                mohoDepthKm: 28.0,
                vpMantle: 7.85,
                vsMantle: 4.42,
                vSurf: 3.00,
                descriptionTR: "Atina Ulusal Gözlemevi Ege ve Doğu Akdeniz incelmiş kabuk modeli (Vp=5.90 km/s, Vs=3.41 km/s, Moho=28 km).",
                descriptionEN: "National Observatory of Athens Aegean & Hellenic Arc crustal velocity model (Vp=5.90 km/s, Vs=3.41 km/s, Moho=28 km)."
            )
        case "usgs":
            return SeismicVelocityModel(
                sourceName: "USGS",
                modelName: "USGS IASPEI-91 Küresel Modeli",
                vpCrust: 5.80,
                vsCrust: 3.36,
                mohoDepthKm: 35.0,
                vpMantle: 8.04,
                vsMantle: 4.48,
                vSurf: 3.15,
                descriptionTR: "USGS ve Uluslararası Sismoloji Birliği IASPEI-91 küresel yer modeli (Vp=5.80 km/s, Vs=3.36 km/s, Pn=8.04 km/s).",
                descriptionEN: "USGS & International Association of Seismology IASPEI-91 global Earth model (Vp=5.80 km/s, Vs=3.36 km/s, Pn=8.04 km/s)."
            )
        case "emsc":
            return SeismicVelocityModel(
                sourceName: "EMSC",
                modelName: "EMSC AK135 Litosfer Hız Modeli",
                vpCrust: 5.80,
                vsCrust: 3.46,
                mohoDepthKm: 35.0,
                vpMantle: 8.04,
                vsMantle: 4.48,
                vSurf: 3.10,
                descriptionTR: "Avrupa-Akdeniz Sismoloji Merkezi AK135 litosfer hız modeli (Vp=5.80 km/s, Vs=3.46 km/s, Pn=8.04 km/s).",
                descriptionEN: "European-Mediterranean Seismological Centre AK135 lithospheric velocity model (Vp=5.80 km/s, Vs=3.46 km/s, Pn=8.04 km/s)."
            )
        default:
            return SeismicVelocityModel(
                sourceName: provider.uppercased(),
                modelName: "IASPEI-91 Standart Sismik Hız Modeli",
                vpCrust: 6.00,
                vsCrust: 3.50,
                mohoDepthKm: 33.0,
                vpMantle: 8.00,
                vsMantle: 4.50,
                vSurf: 3.10,
                descriptionTR: "Uluslararası standart sismolojik kabuk ve üst manto hız modeli.",
                descriptionEN: "Standard international seismological crust and upper-mantle velocity model."
            )
        }
    }
}

/// Sismik dalga fazının (P, S, Yüzey) varış ve hız özellikleri.
struct WavePhaseArrival: Hashable, Sendable {
    let phaseName: String         // "Pg", "Pn", "Sg", "Sn", "Lg"
    let arrivalDate: Date
    let travelSeconds: Double
    let velocityKmS: Double
    let isHeadWave: Bool
}

/// Depreme ve konuma özel tam sismik dalga varış paketi.
struct SeismicWaveArrivals: Hashable, Sendable {
    let pWave: WavePhaseArrival
    let sWave: WavePhaseArrival
    let surfaceWave: WavePhaseArrival
    let spIntervalSeconds: Double
    let velocityModel: SeismicVelocityModel
    let epicentralDistanceKm: Double
    let hypocentralDistanceKm: Double
}

struct SeismicIntensityDescriptor {
    let value: Double


    var roundedLevel: Int {
        if value < 1.0 { return 0 }
        return min(12, max(1, Int(value.rounded())))
    }

    var roman: String {
        if roundedLevel == 0 { return "0" }
        return ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"][roundedLevel - 1]
    }

    var color: Color {
        switch roundedLevel {
        case 0: .secondary
        case 1...2: .blue
        case 3...4: .green
        case 5...6: .yellow
        case 7...8: .orange
        default: .red
        }
    }

    func title(isTurkish: Bool? = nil) -> String {
        switch roundedLevel {
        case 0: L("intensity.title.0")
        case 1...2: L("intensity.title.1_2")
        case 3...4: L("intensity.title.3_4")
        case 5: L("intensity.title.5")
        case 6: L("intensity.title.6")
        case 7...8: L("intensity.title.7_8")
        default: L("intensity.title.severe")
        }
    }

    func description(isTurkish: Bool? = nil) -> String {
        switch roundedLevel {
        case 0: L("intensity.desc.0")
        case 1...2: L("intensity.desc.1_2")
        case 3...4: L("intensity.desc.3_4")
        case 5: L("intensity.desc.5")
        case 6: L("intensity.desc.6")
        case 7...8: L("intensity.desc.7_8")
        default: L("intensity.desc.severe")
        }
    }
}

extension SeismicIntensityDescriptor {
}
