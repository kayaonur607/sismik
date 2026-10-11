import SwiftUI

/// Depremin beklenen insani etkisi: GDACS (BM/AB) ya da USGS PAGER'ın nüfus
/// ve hasar modeline göre yayımladığı uyarı seviyesi. Sunucu değeri deprem
/// kaydının `alertLevel` alanına işler (functions/src/gdacs.ts); M4.5 altı ve
/// değerlendirilmemiş depremlerde yoktur.
enum ImpactLevel: String, CaseIterable, Comparable {
    case green, yellow, orange, red

    init?(_ raw: String?) {
        guard let raw, let level = ImpactLevel(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        self = level
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: ImpactLevel, rhs: ImpactLevel) -> Bool { lhs.rank < rhs.rank }

    /// Listede ve kartlarda ayrıca işaretlenen seviyeler (turuncu, kırmızı).
    var isSignificant: Bool { self >= .orange }

    var color: Color {
        switch self {
        case .green: Color(red: 0.20, green: 0.62, blue: 0.32)
        case .yellow: Color(red: 0.85, green: 0.65, blue: 0.05)
        case .orange: Color(red: 0.93, green: 0.45, blue: 0.10)
        case .red: Color(red: 0.80, green: 0.10, blue: 0.12)
        }
    }

    var name: String { L("impact.level.\(rawValue)") }
    var detail: String { L("impact.detail.\(rawValue)") }
}

extension Earthquake {
    var impactLevel: ImpactLevel? { ImpactLevel(alertLevel) }
}

/// Küçük renkli rozet: "Etki: Turuncu".
struct ImpactLevelBadge: View {
    let level: ImpactLevel
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(level.color)
                .frame(width: 7, height: 7)
            Text(compact ? level.name : "\(L("impact.title")): \(level.name)")
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(level.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(level.color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L("impact.title")): \(level.name)")
    }
}

/// Deprem detayında etki seviyesi kartı: seviye, anlamı ve kaynağı.
struct ImpactLevelCard: View {
    let level: ImpactLevel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: level.isSignificant ? "exclamationmark.triangle.fill" : "person.3.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(level.color)
                .frame(width: 36, height: 36)
                .background(level.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(L("impact.title"))
                        .font(.subheadline.weight(.bold))
                    ImpactLevelBadge(level: level, compact: true)
                }
                Text(level.detail)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("impact.source"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                .strokeBorder(level.color.opacity(level.isSignificant ? 0.5 : 0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
