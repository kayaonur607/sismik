import StoreKit
import SwiftUI

/// Premium yüzeyleri logonun paletinde kalır (#FF7A00).
enum PremiumPalette {
    static let orange = Color.brandOrange
}

/// Paywall'daki plan türü: kart başlığı ve fiyat birimi buna göre yazılır.
enum PremiumPlanKind {
    case monthly, yearly, lifetime

    init(productID: String) {
        switch productID {
        case PremiumStore.yearlyID: self = .yearly
        case PremiumStore.lifetimeID: self = .lifetime
        default: self = .monthly
        }
    }

    var title: String {
        switch self {
        case .monthly: L("paywall.monthly")
        case .yearly: L("paywall.yearly")
        case .lifetime: L("paywall.lifetime")
        }
    }

    /// Fiyatın altındaki birim: "/ ay", "/ yıl" ya da "tek seferlik".
    var unit: String {
        switch self {
        case .monthly: L("paywall.perMonth")
        case .yearly: L("paywall.perYear")
        case .lifetime: L("paywall.lifetime.unit")
        }
    }
}

struct PremiumPlanPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let products: [Product]
    let selectedProductID: String
    let comparisonText: (Product) -> String
    let badgeText: (Product) -> String?
    let onSelect: (Product) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ForEach(products, id: \.id) { product in
                PaywallPlanCard(
                    product: product,
                    isSelected: selectedProductID == product.id,
                    kind: PremiumPlanKind(productID: product.id),
                    comparisonText: comparisonText(product),
                    badgeText: badgeText(product),
                    action: { onSelect(product) }
                )
            }
        }
    }
}

private struct PaywallPlanCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let product: Product
    let isSelected: Bool
    let kind: PremiumPlanKind
    let comparisonText: String
    let badgeText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Tek satır: seçim, plan adı + rozet ve karşılaştırma solda, fiyat
            // sağda. Erişilebilir yazı boyutlarında alt alta dizilir.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isSelected ? PremiumPalette.orange : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(kind.title)
                                .font(.headline)
                            if let badgeText {
                                Text(badgeText)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(PremiumPalette.orange.opacity(0.12), in: .capsule)
                            }
                        }
                        Text(comparisonText)
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 1) {
                    Text(product.displayPrice)
                        .font(.title3.weight(.bold)).monospacedDigit()
                    Text(kind.unit)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: SismikDesign.Radius.card)
                    .strokeBorder(isSelected ? PremiumPalette.orange : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isSelected)
        }
        .buttonStyle(.sismikPressable(scale: 0.99))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
        .accessibilityValue("\(product.displayPrice), \(kind.unit), \(comparisonText), \(isSelected ? L("paywall.selected") : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct PaywallPlanSkeleton: View {
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color.secondary.opacity(0.14)).frame(width: 70, height: 12)
                Capsule().fill(Color.secondary.opacity(0.10)).frame(width: 100, height: 10)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Capsule().fill(Color.secondary.opacity(0.14)).frame(width: 60, height: 14)
                Capsule().fill(Color.secondary.opacity(0.10)).frame(width: 40, height: 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.button))
    }
}
