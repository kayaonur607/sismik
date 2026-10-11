import Foundation
import CoreLocation
import MapKit

enum EmergencyPlaceCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case assemblyArea
    case pharmacy
    case clinic
    case hospital
    case grocery

    var id: String { rawValue }

    var searchPriority: Int {
        switch self {
        case .hospital: 5
        case .clinic: 4
        case .pharmacy: 3
        case .grocery: 2
        case .assemblyArea: 1
        }
    }
}

/// Harita sağlayıcıları veya OpenStreetMap acil durum verisinden gelen
/// toplanma alanı ya da temel sağlık noktası.
struct AssemblyArea: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String?
    let coordinate: CLLocationCoordinate2D
    let category: EmergencyPlaceCategory
    /// Kullanıcı konumuna metre cinsinden uzaklık (varsa).
    var distance: CLLocationDistance?

    init(id: String,
         name: String,
         address: String?,
         coordinate: CLLocationCoordinate2D,
         category: EmergencyPlaceCategory = .assemblyArea,
         distance: CLLocationDistance?,
         phone: String? = nil,
         note: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.category = category
        self.distance = distance
        self.phone = phone
        self.note = note
    }

    /// Favori kaydından geri dönen yerlerde dolu olabilir; harita
    /// sağlayıcılarından gelen kayıtlarda `nil`dir.
    let phone: String?
    let note: String?

    var clLocation: CLLocation {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Apple Haritalar'da yol tarifi için MKMapItem üretir.
    func mapItem() -> MKMapItem {
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: clLocation, address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
        item.name = name
        return item
    }

    static func == (lhs: AssemblyArea, rhs: AssemblyArea) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
