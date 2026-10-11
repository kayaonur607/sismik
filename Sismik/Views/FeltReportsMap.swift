import MapKit
import SwiftUI

/// "Hissettim" raporlarının ~11 km'lik hücrelerdeki dağılımı. Rengin
/// yoğunluğu hücredeki rapor sayısını en kalabalık hücreye göre gösterir;
/// merkez üssü işaretlidir. Kart içinde durağan bir önizleme: kaydırma ve
/// yakınlaştırma kapalı, ekranı kaydırırken harita parmağı yakalamaz.
struct FeltReportsMap: View {
    let epicenter: CLLocationCoordinate2D
    let cells: [FeltReportService.Cell]

    /// Hücre yarıçapı: 0,1° ızgaranın yarısından biraz fazla, komşular
    /// birbirine değsin.
    private static let cellRadius: CLLocationDistance = 6_500

    private var maxCount: Int { cells.map(\.count).max() ?? 1 }

    private var region: MKCoordinateRegion {
        let lats = cells.map(\.latitude) + [epicenter.latitude]
        let lons = cells.map(\.longitude) + [epicenter.longitude]
        let minLat = lats.min() ?? epicenter.latitude, maxLat = lats.max() ?? epicenter.latitude
        let minLon = lons.min() ?? epicenter.longitude, maxLon = lons.max() ?? epicenter.longitude
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max(0.4, (maxLat - minLat) * 1.4), longitudeDelta: max(0.4, (maxLon - minLon) * 1.4))
        )
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            ForEach(cells) { cell in
                MapCircle(center: cell.coordinate, radius: Self.cellRadius)
                    .foregroundStyle(color(for: cell).opacity(0.55))
                    .stroke(color(for: cell), lineWidth: 0.5)
            }
            Annotation("", coordinate: epicenter) {
                Image(systemName: "star.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.red, in: Circle())
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .accessibilityLabel(L("felt.map.caption"))
    }

    /// Az rapor: açık sarı; çok rapor: koyu turuncu-kırmızı.
    private func color(for cell: FeltReportService.Cell) -> Color {
        let share = Double(cell.count) / Double(max(1, maxCount))
        switch share {
        case ..<0.25: return Color(red: 1.0, green: 0.80, blue: 0.25)
        case ..<0.5: return Color(red: 1.0, green: 0.62, blue: 0.15)
        case ..<0.75: return Color(red: 0.96, green: 0.42, blue: 0.10)
        default: return Color(red: 0.86, green: 0.18, blue: 0.10)
        }
    }
}
