import SwiftUI

/// Acil durum toplanma alanı işareti — uygulamanın sekme simgesiyle aynı
/// SF Symbol kullanılarak tüm boyutlarda net ve tutarlı görünür.
struct AssemblyAreaMarker: View {
    var size: CGFloat = 40
    var category: EmergencyPlaceCategory = .assemblyArea

    private var symbol: String { category.symbol }
    private var tint: Color { category.color }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
            // Düz dolgu: uygulamanın geri kalanı degradeyi bıraktı.
            .fill(tint)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                    .strokeBorder(.white.opacity(0.72), lineWidth: max(1, size * 0.035))
            }
            .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
            .accessibilityHidden(true)
    }
}

extension EmergencyPlaceCategory {
    var title: String {
        switch self {
        case .assemblyArea: L("assembly.category.assembly")
        case .pharmacy: L("assembly.category.pharmacy")
        case .clinic: L("assembly.category.clinic")
        case .hospital: L("assembly.category.hospital")
        case .grocery: L("assembly.category.grocery")
        }
    }

    var symbol: String {
        switch self {
        case .assemblyArea: "person.3.fill"
        case .pharmacy: "cross.case.fill"
        case .clinic: "stethoscope"
        case .hospital: "cross.fill"
        case .grocery: "cart.fill"
        }
    }

    var color: Color {
        switch self {
        case .assemblyArea: Color(red: 0.08, green: 0.62, blue: 0.36)
        case .pharmacy: Color(red: 0.46, green: 0.28, blue: 0.82)
        case .clinic: Color(red: 0.02, green: 0.56, blue: 0.62)
        case .hospital: Color(red: 0.90, green: 0.18, blue: 0.24)
        case .grocery: Color(red: 0.88, green: 0.48, blue: 0.08)
        }
    }
}

#Preview {
    ZStack {
        Color.gray
        AssemblyAreaMarker()
    }
}
