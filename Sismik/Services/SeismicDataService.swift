import CoreLocation
import Foundation

/// USGS ShakeMap'ten alınan, olay bazlı ölçüm + model birleşimi sarsıntı verisi.
/// ShakeMap bulunmayan olaylarda ekran `SeismicImpactModel` yedeğine döner.
struct SeismicImpactData {
    struct Contour: Identifiable {
        struct Path: Identifiable {
            let id: String
            let coordinates: [CLLocationCoordinate2D]
        }

        let id: String
        let mmi: Double
        let paths: [Path]
    }

    struct IntensityGrid {
        let longitudeStart: Double
        let longitudeEnd: Double
        let longitudeCount: Int
        let latitudeStart: Double
        let latitudeEnd: Double
        let latitudeCount: Int
        let values: [Double?]

        /// CoverageJSON ızgarasında çift doğrusal enterpolasyon. Izgara dışında
        /// nil döner; böylece kullanıcıya yanlış bir "ölçülmüş MMI" gösterilmez.
        func intensity(at coordinate: CLLocationCoordinate2D) -> Double? {
            guard longitudeCount > 1, latitudeCount > 1,
                  coordinate.longitude >= min(longitudeStart, longitudeEnd),
                  coordinate.longitude <= max(longitudeStart, longitudeEnd),
                  coordinate.latitude >= min(latitudeStart, latitudeEnd),
                  coordinate.latitude <= max(latitudeStart, latitudeEnd) else { return nil }

            let x = (coordinate.longitude - longitudeStart)
                / (longitudeEnd - longitudeStart) * Double(longitudeCount - 1)
            let y = (coordinate.latitude - latitudeStart)
                / (latitudeEnd - latitudeStart) * Double(latitudeCount - 1)
            guard x.isFinite, y.isFinite else { return nil }

            let x0 = max(0, min(longitudeCount - 1, Int(floor(x))))
            let y0 = max(0, min(latitudeCount - 1, Int(floor(y))))
            let x1 = min(longitudeCount - 1, x0 + 1)
            let y1 = min(latitudeCount - 1, y0 + 1)
            let fx = x - Double(x0)
            let fy = y - Double(y0)

            let samples: [(value: Double?, weight: Double)] = [
                (valueAt(x: x0, y: y0), (1 - fx) * (1 - fy)),
                (valueAt(x: x1, y: y0), fx * (1 - fy)),
                (valueAt(x: x0, y: y1), (1 - fx) * fy),
                (valueAt(x: x1, y: y1), fx * fy)
            ]
            let usable = samples.compactMap { sample -> (Double, Double)? in
                guard let value = sample.value, value.isFinite else { return nil }
                return (value, sample.weight)
            }
            let totalWeight = usable.reduce(0) { $0 + $1.1 }
            guard totalWeight > 0 else { return nil }
            return usable.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight
        }

        private func valueAt(x: Int, y: Int) -> Double? {
            let index = y * longitudeCount + x
            guard values.indices.contains(index) else { return nil }
            return values[index]
        }
    }

    let usgsEventID: String
    let contours: [Contour]
    let intensityGrid: IntensityGrid?
    let maximumMMI: Double?
    /// ShakeMap ürün özetindeki en yüksek PGA, g biriminde.
    let maximumPGA: Double?
    let communityIntensity: Double?
    let feltReports: Int?
    let alertLevel: String?
    let reviewStatus: String?
    let processedAt: Date?
    let matchDistanceKm: Double
    let matchTimeDifference: TimeInterval

    func intensity(at coordinate: CLLocationCoordinate2D) -> Double? {
        intensityGrid?.intensity(at: coordinate)
    }

    var isReviewed: Bool {
        reviewStatus?.lowercased() == "reviewed"
    }
}

enum SeismicDataService {
    private static let maximumResponseBytes = 8_000_000
    private static let cache = NSCache<NSString, CachedImpactWrapper>()
    private static let missingProducts = NSCache<NSString, NSDate>()

    static func cachedImpactData(for earthquake: Earthquake) -> SeismicImpactData? {
        cache.object(forKey: earthquake.id as NSString)?.data
    }

    static func hasRecentMissingProduct(for earthquake: Earthquake) -> Bool {
        guard let checked = missingProducts.object(forKey: earthquake.id as NSString) else { return false }
        // New events may acquire a ShakeMap later; do not cache absence indefinitely.
        return Date().timeIntervalSince(checked as Date) < 60
    }


    private final class CachedImpactWrapper {
        let data: SeismicImpactData
        init(_ data: SeismicImpactData) { self.data = data }
    }

    /// Aynı fiziksel olayı USGS ComCat'te bulur ve varsa ShakeMap MMI
    /// konturlarıyla düşük çözünürlüklü MMI ızgarasını getirir.
    static func impactData(for earthquake: Earthquake) async -> SeismicImpactData? {
        if let cached = cachedImpactData(for: earthquake) { return cached }
        if hasRecentMissingProduct(for: earthquake) { return nil }
        return await withTaskGroup(of: SeismicImpactData?.self) { group in
            group.addTask { await fetchImpactData(for: earthquake) }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private static func fetchImpactData(for earthquake: Earthquake) async -> SeismicImpactData? {
        let cacheKey = earthquake.id as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.data
        }

        do {
            guard let match = try await matchingUSGSEvent(for: earthquake),
                  match.distanceKm <= 120,
                  match.timeDifference <= 180,
                  abs(match.magnitude - earthquake.magnitude) <= 1.2 else { return nil }

            let detailData = try await fetch(match.detailURL)
            let detail = try JSONDecoder().decode(USGSDetail.self, from: detailData)
            guard let products = detail.properties.products?.shakemap, !products.isEmpty else {
                guard !Task.isCancelled else { return nil }
                missingProducts.setObject(NSDate(), forKey: cacheKey)
                return nil
            }

            let product = products.max {
                if $0.preferredWeight != $1.preferredWeight {
                    return $0.preferredWeight < $1.preferredWeight
                }
                return $0.updateTime < $1.updateTime
            }
            guard let product else { return nil }

            // ShakeMap ürünlerinde kontur dosyası farklı isimlerle sunulabilir;
            // en zengin ve eksiksiz geometriyi çekmek için sırayla arıyoruz.
            let contourURL = product.contents["download/cont_mmi.json"]?.url
                ?? product.contents["download/cont_mi.json"]?.url
                ?? product.contents["download/intensity.json"]?.url
                ?? product.contents["download/shakemap.geojson"]?.url
            let coverageURL = product.contents["download/coverage_mmi_low_res.covjson"]?.url
            let pgaCoverageURL = product.contents["download/coverage_pga_low_res.covjson"]?.url
                ?? product.contents["download/coverage_pga_medium_res.covjson"]?.url

            async let contours = loadContours(from: contourURL)
            async let grid = loadIntensityGrid(from: coverageURL)
            async let coverageMaximumPGA = loadMaximumPGA(from: pgaCoverageURL)

            let resolvedContours = await contours
            let resolvedGrid = await grid
            let resolvedCoverageMaximumPGA = await coverageMaximumPGA
            let summaryMaximumPGA = validPGA(double(product.properties["maxpga"]))
            let result = SeismicImpactData(
                usgsEventID: detail.id,
                contours: resolvedContours,
                intensityGrid: resolvedGrid,
                maximumMMI: double(product.properties["maxmmi"]) ?? detail.properties.mmi,
                maximumPGA: summaryMaximumPGA ?? resolvedCoverageMaximumPGA,
                communityIntensity: detail.properties.cdi,
                feltReports: detail.properties.felt,
                alertLevel: detail.properties.alert,
                reviewStatus: product.properties["review-status"] ?? product.properties["map-status"] ?? detail.properties.status,
                processedAt: isoDate(product.properties["process-timestamp"]),
                matchDistanceKm: match.distanceKm,
                matchTimeDifference: match.timeDifference
            )
            guard !Task.isCancelled else { return nil }
            cache.setObject(CachedImpactWrapper(result), forKey: cacheKey)
            return result
        } catch {
            AppLog.network.error("USGS ShakeMap load failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func matchingUSGSEvent(for earthquake: Earthquake) async throws -> USGSMatch? {
        if earthquake.provider.lowercased() == "usgs" {
            let rawID = earthquake.id.hasPrefix("usgs-")
                ? String(earthquake.id.dropFirst("usgs-".count))
                : earthquake.id
            guard let url = URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/detail/\(rawID).geojson") else {
                return nil
            }
            return USGSMatch(
                id: rawID,
                magnitude: earthquake.magnitude,
                detailURL: url,
                distanceKm: 0,
                timeDifference: 0
            )
        }

        var components = URLComponents(string: "https://earthquake.usgs.gov/fdsnws/event/1/query")
        let start = earthquake.date.addingTimeInterval(-180)
        let end = earthquake.date.addingTimeInterval(180)
        components?.queryItems = [
            URLQueryItem(name: "format", value: "geojson"),
            URLQueryItem(name: "orderby", value: "time"),
            URLQueryItem(name: "starttime", value: ISO8601.formatter.string(from: start)),
            URLQueryItem(name: "endtime", value: ISO8601.formatter.string(from: end)),
            URLQueryItem(name: "latitude", value: String(earthquake.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(earthquake.coordinate.longitude)),
            URLQueryItem(name: "maxradiuskm", value: "120"),
            URLQueryItem(name: "minmagnitude", value: String(max(0, earthquake.magnitude - 1.2))),
            URLQueryItem(name: "limit", value: "20")
        ]
        guard let url = components?.url else { return nil }
        let data = try await fetch(url)
        let summary = try JSONDecoder().decode(USGSSummary.self, from: data)

        let origin = CLLocation(
            latitude: earthquake.coordinate.latitude,
            longitude: earthquake.coordinate.longitude
        )
        return summary.features.compactMap { feature -> USGSMatch? in
            let coordinates = feature.geometry.coordinates
            guard coordinates.count >= 2, let longitude = coordinates[0], let latitude = coordinates[1],
                  let detailURL = URL(string: feature.properties.detail) else { return nil }
            let location = CLLocation(latitude: latitude, longitude: longitude)
            let distance = origin.distance(from: location) / 1_000
            let timeDifference = abs(Date(timeIntervalSince1970: feature.properties.time / 1_000)
                .timeIntervalSince(earthquake.date))
            return USGSMatch(
                id: feature.id,
                magnitude: feature.properties.mag,
                detailURL: detailURL,
                distanceKm: distance,
                timeDifference: timeDifference
            )
        }.min { lhs, rhs in
            let lhsScore = lhs.distanceKm / 30 + lhs.timeDifference / 60
                + abs(lhs.magnitude - earthquake.magnitude) * 2
            let rhsScore = rhs.distanceKm / 30 + rhs.timeDifference / 60
                + abs(rhs.magnitude - earthquake.magnitude) * 2
            return lhsScore < rhsScore
        }
    }

    private static func loadContours(from rawURL: String?) async -> [SeismicImpactData.Contour] {
        guard let rawURL, let url = URL(string: rawURL),
              let data = try? await fetch(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]],
              !features.isEmpty else { return [] }

        // USGS ShakeMap hesaplama ızgarasının dış sınırlarını belirle.
        var allCoordinates: [[Double]] = []
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else { continue }
            if type == "MultiLineString", let multi = geometry["coordinates"] as? [[[Double]]] {
                for line in multi { allCoordinates.append(contentsOf: line) }
            } else if type == "LineString", let line = geometry["coordinates"] as? [[Double]] {
                allCoordinates.append(contentsOf: line)
            } else if type == "Polygon", let poly = geometry["coordinates"] as? [[[Double]]] {
                for ring in poly { allCoordinates.append(contentsOf: ring) }
            } else if type == "MultiPolygon", let multiPoly = geometry["coordinates"] as? [[[[Double]]]] {
                for poly in multiPoly {
                    for ring in poly { allCoordinates.append(contentsOf: ring) }
                }
            }
        }

        let minLon = allCoordinates.compactMap { $0.first }.min() ?? -180
        let maxLon = allCoordinates.compactMap { $0.first }.max() ?? 180
        let minLat = allCoordinates.compactMap { $0.count > 1 ? $0[1] : nil }.min() ?? -90
        let maxLat = allCoordinates.compactMap { $0.count > 1 ? $0[1] : nil }.max() ?? 90

        // Sınır yapay çizgilerini ayıklarken toleransı dar tutuyoruz;
        // böylece kenara yaklaşan gerçek sismik konturlar yanlışlıkla silinmez.
        let lonEpsilon = max(0.001, (maxLon - minLon) * 0.002)
        let latEpsilon = max(0.001, (maxLat - minLat) * 0.002)

        func isBorderPoint(_ pair: [Double]) -> (south: Bool, north: Bool, west: Bool, east: Bool) {
            guard pair.count >= 2 else { return (false, false, false, false) }
            let lon = pair[0]
            let lat = pair[1]
            return (
                south: abs(lat - minLat) <= latEpsilon,
                north: abs(lat - maxLat) <= latEpsilon,
                west: abs(lon - minLon) <= lonEpsilon,
                east: abs(lon - maxLon) <= lonEpsilon
            )
        }

        func isBoundarySegment(_ p1: [Double], _ p2: [Double]) -> Bool {
            let b1 = isBorderPoint(p1)
            let b2 = isBorderPoint(p2)
            if b1.south && b2.south { return true }
            if b1.north && b2.north { return true }
            if b1.west && b2.west { return true }
            if b1.east && b2.east { return true }
            return false
        }

        return features.enumerated().compactMap { index, feature in
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else { return nil }

            // USGS farklı ürünlerinde MMI değerini farklı anahtarlarla sunabilir.
            let rawMMI = double(properties["value"])
                ?? double(properties["mmi"])
                ?? double(properties["intensity"])
                ?? double(properties["PARAMVALUE"])
                ?? double(properties["paramvalue"])
                ?? double(properties["MMI"])
            guard let mmi = rawMMI else { return nil }

            let rawPaths: [[[Double]]]
            if type == "MultiLineString" {
                rawPaths = geometry["coordinates"] as? [[[Double]]] ?? []
            } else if type == "LineString", let path = geometry["coordinates"] as? [[Double]] {
                rawPaths = [path]
            } else if type == "Polygon", let poly = geometry["coordinates"] as? [[[Double]]] {
                rawPaths = poly
            } else if type == "MultiPolygon", let multiPoly = geometry["coordinates"] as? [[[[Double]]]] {
                rawPaths = multiPoly.flatMap { $0 }
            } else {
                rawPaths = []
            }

            var cleanPaths: [[[Double]]] = []
            for rawPath in rawPaths {
                var currentSubpath: [[Double]] = []
                for point in rawPath {
                    guard point.count >= 2, point[0].isFinite, point[1].isFinite else { continue }
                    guard let prev = currentSubpath.last else {
                        currentSubpath.append(point)
                        continue
                    }
                    if isBoundarySegment(prev, point) {
                        if currentSubpath.count >= 2 {
                            cleanPaths.append(currentSubpath)
                        }
                        currentSubpath = [point]
                    } else {
                        currentSubpath.append(point)
                    }
                }
                if currentSubpath.count >= 2 {
                    cleanPaths.append(currentSubpath)
                }
            }

            var pathIndexCounter = 0
            let paths = cleanPaths.compactMap { cleanPath -> SeismicImpactData.Contour.Path? in
                let rawCoordinates = cleanPath.compactMap { pair -> CLLocationCoordinate2D? in
                    guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite else { return nil }
                    return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                }
                guard rawCoordinates.count >= 2 else { return nil }

                // Ramer-Douglas-Peucker ile tepe ve kıvrımları bozmadan ara doğrusal noktaları sadeleştir.
                var coordinates = simplifyPoints(rawCoordinates, epsilon: 0.0005)
                guard coordinates.count >= 2 else { return nil }

                // Kapalı kontur halkalarını koru
                if let first = coordinates.first, let last = coordinates.last,
                   abs(first.latitude - last.latitude) <= 0.0001,
                   abs(first.longitude - last.longitude) <= 0.0001,
                   coordinates.count >= 3 {
                    coordinates[coordinates.count - 1] = first
                }

                let pathID = "\(index)-\(mmi)-\(pathIndexCounter)"
                pathIndexCounter += 1
                return SeismicImpactData.Contour.Path(
                    id: pathID,
                    coordinates: coordinates
                )
            }
            guard !paths.isEmpty else { return nil }
            return SeismicImpactData.Contour(id: "\(index)-\(mmi)", mmi: mmi, paths: paths)
        }
    }

    /// Ramer-Douglas-Peucker sadeleştirme algoritması: Geometrik kıvrımları ve tepe
    /// noktalarını %100 koruyarak gereksiz doğrusal ara noktaları eler; GPU ve CPU
    /// çizim yükünü belirgin azaltır.
    private static func simplifyPoints(
        _ points: [CLLocationCoordinate2D],
        epsilon: Double
    ) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }

        var maxDistance = 0.0
        var index = 0
        let first = points[0]
        let last = points[points.count - 1]

        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(point: points[i], lineStart: first, lineEnd: last)
            if d > maxDistance {
                maxDistance = d
                index = i
            }
        }

        if maxDistance > epsilon {
            let left = simplifyPoints(Array(points[0...index]), epsilon: epsilon)
            let right = simplifyPoints(Array(points[index..<points.count]), epsilon: epsilon)
            return left.dropLast() + right
        } else {
            return [first, last]
        }
    }

    private static func perpendicularDistance(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> Double {
        let dx = lineEnd.longitude - lineStart.longitude
        let dy = lineEnd.latitude - lineStart.latitude
        let mag = hypot(dx, dy)
        if mag < 1e-9 {
            return hypot(point.longitude - lineStart.longitude, point.latitude - lineStart.latitude)
        }
        let u = ((point.longitude - lineStart.longitude) * dx + (point.latitude - lineStart.latitude) * dy) / (mag * mag)
        let clampedU = max(0, min(1, u))
        let projX = lineStart.longitude + clampedU * dx
        let projY = lineStart.latitude + clampedU * dy
        return hypot(point.longitude - projX, point.latitude - projY)
    }

    private static func loadIntensityGrid(from rawURL: String?) async -> SeismicImpactData.IntensityGrid? {
        guard let rawURL, let url = URL(string: rawURL),
              let data = try? await fetch(url),
              let coverage = try? JSONDecoder().decode(CoverageJSON.self, from: data),
              coverage.ranges.mmi.shape.count == 2 else { return nil }
        let longitudeCount = coverage.domain.axes.x.num
        let latitudeCount = coverage.domain.axes.y.num
        guard longitudeCount > 1,
              latitudeCount > 1,
              longitudeCount <= coverage.ranges.mmi.values.count / latitudeCount,
              longitudeCount * latitudeCount == coverage.ranges.mmi.values.count else { return nil }
        return SeismicImpactData.IntensityGrid(
            longitudeStart: coverage.domain.axes.x.start,
            longitudeEnd: coverage.domain.axes.x.stop,
            longitudeCount: longitudeCount,
            latitudeStart: coverage.domain.axes.y.start,
            latitudeEnd: coverage.domain.axes.y.stop,
            latitudeCount: latitudeCount,
            values: coverage.ranges.mmi.values
        )
    }

    /// CoverageJSON PGA değerleri güncel ShakeMap ürünlerinde çoğunlukla
    /// doğal logaritmik g (`ln(g)`) olarak yayımlanır. Özet `maxpga` alanı
    /// eksikse ızgaradaki gerçek maksimumu okuyup g birimine dönüştürür.
    private static func loadMaximumPGA(from rawURL: String?) async -> Double? {
        guard let rawURL, let url = URL(string: rawURL),
              let data = try? await fetch(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ranges = root["ranges"] as? [String: Any],
              let pgaRange = ranges["PGA"] as? [String: Any],
              let rawValues = pgaRange["values"] as? [Any] else { return nil }

        let maximumRaw = rawValues.compactMap(double).filter(\.isFinite).max()
        guard let maximumRaw else { return nil }

        let parameters = root["parameters"] as? [String: Any]
        let pgaParameter = parameters?["PGA"] as? [String: Any]
        let unit = pgaParameter?["unit"] as? [String: Any]
        let symbol = unit?["symbol"] as? [String: Any]
        let symbolValue = (symbol?["value"] as? String)?.lowercased() ?? ""
        let label = unit?["label"] as? [String: Any]
        let labelValue = (label?["en"] as? String)?.lowercased() ?? ""
        let unitDescription = symbolValue + " " + labelValue

        let valueInG: Double
        if unitDescription.contains("ln(") || unitDescription.contains("natural logarithm") {
            valueInG = exp(maximumRaw)
        } else if unitDescription.contains("%") || unitDescription.contains("pctg") || unitDescription.contains("percent") {
            valueInG = maximumRaw / 100
        } else {
            valueInG = maximumRaw
        }
        return validPGA(valueInG)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Sismik-iOS/2.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func double(_ value: String?) -> Double? {
        value.flatMap(Double.init)
    }

    private static func validPGA(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 10 else { return nil }
        return value
    }

    private static func isoDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601.date(from: value)
    }
}

private struct USGSMatch {
    let id: String
    let magnitude: Double
    let detailURL: URL
    let distanceKm: Double
    let timeDifference: TimeInterval
}

private struct USGSSummary: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let id: String
        let properties: Properties
        let geometry: Geometry
    }

    struct Properties: Decodable {
        let mag: Double
        let time: Double
        let detail: String
    }

    struct Geometry: Decodable {
        /// USGS eski kayıtlarda derinliği `null` yazabilir.
        let coordinates: [Double?]
    }
}

private struct USGSDetail: Decodable {
    let id: String
    let properties: Properties

    struct Properties: Decodable {
        let mmi: Double?
        let cdi: Double?
        let felt: Int?
        let alert: String?
        let status: String?
        let products: Products?
    }

    struct Products: Decodable {
        let shakemap: [ShakeMapProduct]?
    }

    struct ShakeMapProduct: Decodable {
        let updateTime: Double
        let preferredWeight: Double
        let properties: [String: String]
        let contents: [String: Content]
    }

    struct Content: Decodable {
        let url: String
    }
}

private struct CoverageJSON: Decodable {
    let domain: Domain
    let ranges: Ranges

    struct Domain: Decodable {
        let axes: Axes
    }

    struct Axes: Decodable {
        let x: Axis
        let y: Axis
    }

    struct Axis: Decodable {
        let start: Double
        let stop: Double
        let num: Int
    }

    struct Ranges: Decodable {
        let mmi: Range

        enum CodingKeys: String, CodingKey {
            case mmi = "MMI"
        }
    }

    struct Range: Decodable {
        let shape: [Int]
        let values: [Double?]
    }
}
