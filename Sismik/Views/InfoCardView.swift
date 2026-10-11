import SwiftUI

/// Bilgi kartı sayfası: simgeli başlık, madde madde yenilikler ve isteğe
/// bağlı bir eylem düğmesi. Uygulamanın kart dili (yuvarlak beyaz yüzey,
/// renkli simge kutusu, turuncu birincil düğme) korunur.
struct InfoCardView: View {
    let card: InfoCard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let tint = card.tintColor
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(tint: tint)

                    if let body = card.body, !body.isEmpty {
                        notes(body.resolved, tint: tint)
                    }

                    if let items = card.items, !items.isEmpty {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                row(item, tint: tint)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 8)
                                    .animation(
                                        reduceMotion ? nil : SismikDesign.Motion.entranceSpring.delay(0.05 * Double(index)),
                                        value: appeared
                                    )
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)

            buttons
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel(L("common.close"))
        }
        .presentationDetents(isCompact ? [.medium, .large] : [.large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            InfoCardCenter.shared.markSeen(card)
            appeared = true
        }
    }

    /// Kısa içerik (ör. tek paragraflık sürüm notu) yarım sayfada açılır.
    private var isCompact: Bool {
        (card.items?.count ?? 0) <= 2 && (card.body?.resolved.count ?? 0) <= 280
    }

    private func header(tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: card.icon ?? "sparkles")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            Text(card.title.resolved)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle.resolved)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.trailing, 36)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Serbest metin: App Store notlarındaki "-", "•", "*" ile başlayan
    /// satırlar madde işaretli, diğerleri paragraf olarak gösterilir.
    private func notes(_ text: String, tint: Color) -> some View {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let bullet = Self.bulletText(line) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(bullet)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(line)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : SismikDesign.Motion.entranceSpring, value: appeared)
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "• ", "* ", "– ", "·"] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func row(_ item: InfoCard.Item, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.resolved)
                    .font(.subheadline.weight(.bold))
                Text(item.body.resolved)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 10) {
            if let action = card.action, let url = URL(string: action.url) {
                Button {
                    dismiss()
                    // Sayfa kapandıktan sonra açılsın: aynı anda iki sunum çakışmasın.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        openURL(url)
                    }
                } label: {
                    Text(action.label.resolved)
                }
                .buttonStyle(.sismikPrimary)

                Button(L("infocard.later")) { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                Button(L("infocard.continue")) { dismiss() }
                    .buttonStyle(.sismikPrimary)
            }
        }
    }
}
