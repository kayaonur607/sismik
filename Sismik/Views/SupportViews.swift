import SwiftUI

struct HelpCenterView: View {
    /// Sheet olarak sunulduğunda (yalnızca iPad liste-detay düzeni) sağ üstte
    /// "Kapat" gösterilir. Sayfa olarak push edildiğinde geri düğmesi zaten
    /// vardır; ikinci bir kapatma düğmesi araç çubuğunu kalabalıklaştırır.
    var showsCloseButton: Bool = false

    @Environment(\.dismiss) private var dismiss

    private var questions: [FrequentlyAskedQuestion] {
        [
            .init(
                id: "updates",
                icon: "arrow.triangle.2.circlepath",
                tint: .blue,
                title: L("help.faq.updates.title"),
                answer: L("help.faq.updates.answer")
            ),
            .init(
                id: "differences",
                icon: "point.3.connected.trianglepath.dotted",
                tint: .orange,
                title: L("help.faq.differences.title"),
                answer: L("help.faq.differences.answer")
            ),
            .init(
                id: "region-playback",
                // Haritadaki bölge oynatma düğmesiyle aynı simge: kullanıcı
                // cevapta anlatılan düğmeyi ekranda tanısın.
                icon: "clock.arrow.circlepath",
                tint: .purple,
                title: L("help.faq.playback.title"),
                answer: L("help.faq.playback.answer")
            ),
            .init(
                id: "places",
                // Haritadaki "yerleri göster" düğmesiyle aynı simge.
                icon: "mappin.and.ellipse",
                tint: .appAction,
                title: L("help.faq.places.title"),
                answer: L("help.faq.places.answer")
            ),
            .init(
                id: "places-map",
                icon: "hand.tap.fill",
                tint: .teal,
                title: L("help.faq.placesMap.title"),
                answer: L("help.faq.placesMap.answer")
            ),
            .init(
                id: "notifications",
                icon: "bell.badge.fill",
                tint: .red,
                title: L("help.faq.notifications.title"),
                answer: L("help.faq.notifications.answer")
            ),
            .init(
                id: "location",
                icon: "location.fill",
                tint: .green,
                title: L("help.faq.location.title"),
                answer: L("help.faq.location.answer")
            ),
            .init(
                id: "restore",
                icon: "arrow.clockwise.circle.fill",
                tint: .indigo,
                title: L("help.faq.restore.title"),
                answer: L("help.faq.restore.answer")
            )
        ]
    }

    var body: some View {
        List {
                Section {
                    ForEach(questions) { question in
                        FAQDisclosureRow(question: question)
                    }
                } header: {
                    Text(L("help.faq.sectionTitle"))
                }

                Section {
                    Link(destination: SupportLinks.feedbackURL) {
                        SupportLinkLabel(
                            icon: "envelope.fill",
                            tint: .appAction,
                            title: L("help.feedback.title"),
                            subtitle: L("help.feedback.subtitle")
                        )
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text(L("help.feedback.footer"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("help.navTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("common.close")) { dismiss() }
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color.appAction)
                    }
                }
            }
            .tint(.appAction)
    }
}

struct AboutView: View {
    var body: some View {
        List {
                Section {
                    AboutAppHeader()
                }

                Section {
                    Link(destination: SupportLinks.ratingURL) {
                        SupportLinkLabel(
                            icon: "star.fill",
                            tint: .yellow,
                            title: L("about.rate.title"),
                            subtitle: L("about.rate.subtitle")
                        )
                    }
                    .foregroundStyle(.primary)

                    Link(destination: SupportLinks.privacyURL) {
                        SupportLinkLabel(
                            icon: "hand.raised.fill",
                            tint: .blue,
                            title: L("about.privacy.title")
                        )
                    }
                    .foregroundStyle(.primary)

                    Link(destination: SupportLinks.eulaURL) {
                        SupportLinkLabel(
                            icon: "doc.text.fill",
                            tint: .purple,
                            title: L("about.eula.title"),
                            subtitle: "Apple Standard EULA"
                        )
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text(L("about.legalSection"))
                }
                .foregroundStyle(.primary)

                Section {
                    LabeledContent(L("about.version"), value: SupportLinks.version)
                    LabeledContent(L("about.build.label"), value: SupportLinks.build)
                } footer: {
                    Text(L("about.sources.footer"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("about.navTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .tint(.appAction)
    }
}

private struct FrequentlyAskedQuestion: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
    let answer: String
}

private struct FAQDisclosureRow: View {
    let question: FrequentlyAskedQuestion

    var body: some View {
        DisclosureGroup {
            Text(question.answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: question.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(question.tint)
                    .frame(width: 30, height: 30)
                    .background(question.tint.opacity(0.12), in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)

                Text(question.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .tint(.appAction)
    }
}

private struct AboutAppHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image("LogoOrange")
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 58)
                .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text("Sismik")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(L("splash.tagline"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct SupportLinkLabel: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private enum SupportLinks {
    static let privacyURL = URL(string: "https://sismik-app.web.app/privacy/")!
    static let eulaURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let ratingURL = URL(string: "https://apps.apple.com/app/id6787776158?action=write-review")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    @MainActor
    static var feedbackURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "sismikapplication@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Sismik Feedback"),
            URLQueryItem(
                name: "body",
                value: "\n\nSismik \(version) (\(build))\niOS \(UIDevice.current.systemVersion)"
            )
        ]
        return components.url ?? URL(string: "mailto:sismikapplication@gmail.com")!
    }
}
