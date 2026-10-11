import SwiftUI

/// Uygulama genelinde aynı placeholder görünümünü ve erişilebilirlik davranışını sağlar.
private struct SkeletonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    func skeletonStyle() -> some View {
        modifier(SkeletonStyle())
    }
}

struct LoadingCardSkeleton: View {
    var rowCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 5)
                .fill(.secondary.opacity(0.22))
                .frame(width: 150, height: 18)

            ForEach(0..<rowCount, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.secondary.opacity(0.18))
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.secondary.opacity(0.20))
                            .frame(height: 13)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.secondary.opacity(0.14))
                            .frame(width: index.isMultiple(of: 2) ? 130 : 190, height: 10)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .skeletonStyle()
    }
}
