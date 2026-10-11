import SwiftUI

struct StatisticsKPITile: View {
    let value: String
    let label: String
    let icon: String
    let tint: Color
    /// Sağlanırsa değer değişimi "sayaç" gibi kayarak animasyon yapar.
    var numericValue: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(numericValue.map { .numericText(value: $0) } ?? .numericText())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
