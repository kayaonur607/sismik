import SwiftUI

extension PlaceIcon {
    var color: Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    var displayName: String { L("places.icon.\(rawValue)") }
}

/// Yer simgesinin rozeti: renkli yuvarlatılmış kare, beyaz simge. Bildirim
/// uzantısı (`PlaceIconArtwork`) bildirimin sağına aynı çizimi koyar.
struct PlaceIconBadge: View {
    let icon: PlaceIcon
    var size: CGFloat = 30
    var dimmed = false

    var body: some View {
        Image(systemName: icon.symbolName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                (dimmed ? Color.secondary : icon.color),
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            )
            .accessibilityLabel(icon.displayName)
    }
}

/// 15 simgelik seçici. Başka bir yerde kullanılan simge soluk görünür ve
/// seçilemez: bildirimde hangi yerin tetiklendiği simgeden ayırt edilebilmeli.
struct PlaceIconPicker: View {
    @Binding var selection: PlaceIcon
    let unavailable: Set<PlaceIcon>

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(PlaceIcon.allCases) { icon in
                let taken = unavailable.contains(icon) && icon != selection
                Button {
                    guard !taken else { return }
                    SismikDesign.touchFeedback()
                    withAnimation(SismikDesign.Motion.interactiveSpring) { selection = icon }
                } label: {
                    VStack(spacing: 5) {
                        PlaceIconBadge(icon: icon, size: 44, dimmed: taken)
                            .overlay {
                                RoundedRectangle(cornerRadius: 44 * 0.26 + 3, style: .continuous)
                                    .strokeBorder(Color.appAction, lineWidth: 2.5)
                                    .padding(-4)
                                    .opacity(selection == icon ? 1 : 0)
                            }
                            .opacity(taken ? 0.35 : 1)
                        Text(icon.displayName)
                            .font(.caption2)
                            .foregroundStyle(taken ? .tertiary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(taken)
                .accessibilityAddTraits(selection == icon ? .isSelected : [])
                .accessibilityHint(taken ? L("places.icon.taken") : "")
            }
        }
        .padding(.vertical, 6)
    }
}
