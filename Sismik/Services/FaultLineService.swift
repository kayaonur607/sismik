import Foundation
import MapKit

/// GEM Global Active Faults verisi (tüm dünya) uygulamayla birlikte gelir ve
/// MKPolyline parçalarına ayrılır.
///
/// Eskiden ilk kullanımda sunucudan indiriliyordu (sıkıştırılmış ~2,2 MB);
/// sunucudaki kopya uygulamadakiyle bayt bayt aynı olduğu için bu indirme her
/// kurulumda boşa Hosting trafiğiydi. Sunucudaki `/faults` ucu yalnızca eski
/// sürümler için duruyor.
enum FaultLineService {

    enum FaultError: LocalizedError {
        case missingFile
        var errorDescription: String? {
            switch self {
            case .missingFile: return "Fay hattı verisi bulunamadı."
            }
        }
    }

    /// Eski sürümlerin indirip önbelleğe yazdığı kopya (aynı veri, ~7 MB).
    private static var legacyCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("faults-v3.geojson")
    }

    static func loadSegments() async throws -> [FaultSegment] {
        // Güncellemeyle gelen kullanıcıda eski kopya diskte yer kaplamasın.
        try? FileManager.default.removeItem(at: legacyCacheURL)
        guard let url = Bundle.main.url(forResource: "gem_faults_world", withExtension: "geojson") else {
            throw FaultError.missingFile
        }
        return try decode(from: url)
    }

    private static func decode(from fileURL: URL) throws -> [FaultSegment] {
        let data = try Data(contentsOf: fileURL)
        let objects = try MKGeoJSONDecoder().decode(data)

        var segments: [FaultSegment] = []
        for case let feature as MKGeoJSONFeature in objects {
            let (name, risk, slipType, slipRate) = parse(feature.properties)
            for geometry in feature.geometry {
                if let polyline = geometry as? MKPolyline {
                    segments.append(FaultSegment(polyline: polyline, name: name, risk: risk, slipType: slipType, slipRate: slipRate))
                } else if let multi = geometry as? MKMultiPolyline {
                    for polyline in multi.polylines {
                        segments.append(FaultSegment(polyline: polyline, name: name, risk: risk, slipType: slipType, slipRate: slipRate))
                    }
                }
            }
        }
        return segments
    }

    private static func parse(_ data: Data?) -> (name: String, risk: FaultRisk, slipType: String, slipRate: Double?) {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("", .unknown, "", nil)
        }
        let name = (json["name"] as? String) ?? ""
        let slipRate = (json["slip_rate"] as? NSNumber)?.doubleValue
        let slipType = (json["slip_type"] as? String) ?? ""
        return (name, FaultRisk(slipRate: slipRate), slipType, slipRate)
    }
}
