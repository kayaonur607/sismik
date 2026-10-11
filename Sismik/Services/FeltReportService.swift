import CoreLocation
import Foundation
import os

/// "Hissettim / Hissetmedim" raporları: deprem başına herkese açık anonim
/// sayaçlar (sunucuda tek belge, rapor başına tek yazım). Cihaz her depreme
/// bir kez yanıt verir; koruma cihaz tarafında tutulur (UserDefaults).
enum FeltReportService {
    private static let storageKey = "felt.reportedIds.v1"
    private static let cache = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    private static func loadReported() -> Set<String> {
        cache.withLock { stored in
            if let stored { return stored }
            let list = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
            let set = Set(list)
            stored = set
            return set
        }
    }

    static func hasReported(_ id: String) -> Bool {
        if loadReported().contains(id) { return true }
        // Geriye dönük uyumluluk: eski sürümlerde yazılmış olabilecek tekil anahtarı kontrol et
        return UserDefaults.standard.bool(forKey: "felt.reported.\(id)")
    }

    /// "Hissettim haritası" hücresi (~11 km'lik ızgara; sunucu yuvarlar).
    struct Cell: Identifiable, Hashable {
        let latitude: Double
        let longitude: Double
        let count: Int
        var id: String { "\(latitude)_\(longitude)" }
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    struct Summary {
        let count: Int
        let cells: [Cell]
    }

    /// Hissedenlerin sayısı ve konum hücreleri (sunucu + CDN önbellekli).
    static func summary(for id: String) async -> Summary? {
        // Uzak yapılandırmayla kapatılabilir (`features.felt_reports`).
        guard RemoteConfig.isEnabled(.feltReports) else { return nil }
        var comps = URLComponents(string: BackendConfig.baseURL + "/felt")
        comps?.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = comps?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = object["count"] as? Int else { return nil }
        let cells = (object["cells"] as? [[String: Any]] ?? []).compactMap { item -> Cell? in
            guard let lat = item["lat"] as? Double, let lon = item["lon"] as? Double,
                  let cellCount = item["count"] as? Int, cellCount > 0 else { return nil }
            return Cell(latitude: lat, longitude: lon, count: cellCount)
        }
        return Summary(count: count, cells: cells)
    }

    /// Tek dokunuş anonim rapor; başarılıysa cihazda işaretlenir. `felt:
    /// false` bildirimdeki "Hissetmedim" düğmesidir.
    @discardableResult
    static func report(_ id: String, felt: Bool = true) async -> Bool {
        guard !hasReported(id) else { return true }
        guard RemoteConfig.isEnabled(.feltReports),
              let url = URL(string: BackendConfig.baseURL + "/felt") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["id": id, "kind": felt ? "felt" : "not_felt"]
        // Harita için kaba konum: 0,1°'ye yuvarlanır (~11 km), cihazdan
        // hassas konum hiç çıkmaz. Konum izni yoksa rapor konumsuz gider.
        if felt, let coordinate = LocationManager.cachedCoordinate {
            body["lat"] = (coordinate.latitude * 10).rounded() / 10
            body["lon"] = (coordinate.longitude * 10).rounded() / 10
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return false
        }
        cache.withLock { stored in
            var current = Array(stored ?? Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? []))
            if !current.contains(id) {
                current.append(id)
                if current.count > 300 {
                    current.removeFirst(current.count - 300)
                }
                UserDefaults.standard.set(current, forKey: storageKey)
                stored = Set(current)
            }
        }
        return true
    }
}
