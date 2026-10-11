import Foundation
import MapKit
import SwiftUI

/// Fay hattının halk diliyle risk seviyesi.
enum FaultRisk: Int, CaseIterable {
    case high
    case mediumHigh
    case medium
    case unknown

    /// Kayma hızından (mm/yıl) risk seviyesi — gerçek tehlike göstergesi.
    /// Hızlı kayan faylar daha sık ve büyük deprem üretir.
    init(slipRate: Double?) {
        guard let r = slipRate else { self = .unknown; return }
        switch r {
        case 15...:       self = .high
        case 5..<15:      self = .mediumHigh
        case 0.1..<5:     self = .medium
        default:          self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .high:       return Color(red: 0.90, green: 0.16, blue: 0.22) // kırmızı
        case .mediumHigh: return Color(red: 0.97, green: 0.45, blue: 0.16) // turuncu
        case .medium:     return Color(red: 0.98, green: 0.78, blue: 0.20) // sarı
        case .unknown:    return Color(red: 0.70, green: 0.70, blue: 0.62) // gri
        }
    }

    var label: String {
        switch self {
        case .high:       return L("faultRisk.high.label")
        case .mediumHigh: return L("faultRisk.mediumHigh.label")
        case .medium:     return L("faultRisk.medium.label")
        case .unknown:    return L("faultRisk.unknown.label")
        }
    }


    /// Lejantta gösterilecek kısa açıklama (kayma hızı).
    var detail: String {
        switch self {
        case .high:       return L("faultRisk.high.detail")
        case .mediumHigh: return L("faultRisk.mediumHigh.detail")
        case .medium:     return L("faultRisk.medium.detail")
        case .unknown:    return L("faultRisk.unknown.detail")
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .high:       return 2.6
        case .mediumHigh: return 2.0
        case .medium:     return 1.35
        case .unknown:    return 1.0
        }
    }
}

/// Tek bir aktif fay çizgisi parçası (GEM Global Active Faults).
/// MKPolyline geometry is immutable after decoding. The segment is therefore
/// safe to return from the detached GeoJSON parsing task.
struct FaultSegment: Identifiable, @unchecked Sendable {
    let id = UUID()
    let polyline: MKPolyline
    let name: String
    let risk: FaultRisk
    /// GEM `slip_type` ("Dextral", "Reverse", "Normal-Sinistral"…).
    var slipType: String = ""
    /// GEM `slip_rate` (mm/yıl); bilinmiyorsa nil.
    var slipRate: Double?

    var color: Color { risk.color }
    /// Yüksek riskli faylar daha kalın çizilir.
    var lineWidth: CGFloat {
        risk.lineWidth
    }
}
