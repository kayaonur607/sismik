import SwiftUI

/// Deprem güvenlik rehberi — öncesi, anı ve sonrası için kısa adımlar.
struct SafetyGuideView: View {
    private struct Step: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private var during: [Step] {
        [
            .init(icon: "figure.fall", title: L("safety.during.drop.title"), detail: L("safety.during.drop.detail")),
            .init(icon: "hands.and.sparkles.fill", title: L("safety.during.cover.title"), detail: L("safety.during.cover.detail")),
            .init(icon: "hand.raised.fill", title: L("safety.during.hold.title"), detail: L("safety.during.hold.detail"))
        ]
    }

    private var after: [Step] {
        [
            .init(icon: "door.left.hand.open", title: L("safety.after.exit.title"), detail: L("safety.after.exit.detail")),
            .init(icon: "shoeprints.fill", title: L("safety.after.assembly.title"), detail: L("safety.after.assembly.detail")),
            .init(icon: "phone.down.fill", title: L("safety.after.lines.title"), detail: L("safety.after.lines.detail"))
        ]
    }

    private var before: [Step] {
        [
            .init(icon: "backpack.fill", title: L("safety.before.bag.title"), detail: L("safety.before.bag.detail")),
            .init(icon: "house.fill", title: L("safety.before.home.title"), detail: L("safety.before.home.detail")),
            .init(icon: "person.3.fill", title: L("safety.before.plan.title"), detail: L("safety.before.plan.detail"))
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                section(L("safety.section.during"), color: .red, steps: during)
                section(L("safety.section.after"), color: .brandOrange, steps: after)
                section(L("safety.section.before"), color: .brandGreen, steps: before)
            }
            .padding(16)
            .sismikContentWidth()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(L("safety.guide.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, color: Color, steps: [Step]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased(with: AppLanguage.currentLocale))
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(color)

            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 60) }
                    HStack(spacing: 14) {
                        Image(systemName: step.icon)
                            .font(.title3)
                            .foregroundStyle(color)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.subheadline.weight(.semibold))
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
    }
}
