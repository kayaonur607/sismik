import SwiftUI

/// Bir ekranın ne işe yaradığını anlatan kısa tanıtım.
///
/// Açılıştaki `OnboardingView`den ayrı ve bilerek küçük: ekranın başlığındaki
/// soru işaretiyle açılır. İlk girişte kendiliğinden açılmaz — Noktalar'da
/// konum izni isteğiyle üst üste biniyor, Acil Durum'da ise acil anda ekranı
/// bir kartla kapatıyordu.
struct ScreenIntro: Identifiable, Sendable {
    struct Item: Identifiable, Sendable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    let id: String
    let symbol: String
    let title: String
    let subtitle: String
    let items: [Item]
    let tint: Color
}

/// Ekran tanıtımı — sayfa değil, üstte beliren küçük bir kart.
///
/// Alttan açılan bir sayfa (`sheet`) ekranı tamamen devralıyor ve kullanıcıyı
/// "başka bir yere gittim" hissine sokuyordu. Oysa buradaki metin, arkasındaki
/// ekranı ANLATIYOR: kart üstte durup arkayı görünür bıraktığında anlattığı
/// şeyle bağı kopmuyor. Boşluğa dokunmak da kapatır.
private struct ScreenIntroCard: View {
    let intro: ScreenIntro
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    VStack(spacing: 10) {
                        ForEach(intro.items) { item in
                            row(item)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 18)
            }
            // Kart ekranı doldurmaz: uzun listelerde içeride kaydırılır,
            // kısa olanlarda kendi boyuna oturur.
            .scrollBounceBehavior(.basedOnSize)

            Button(action: onDismiss) {
                Text(L("intro.gotIt"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.sismikPrimary(tint: intro.tint))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: 420)
        .frame(maxHeight: 560)
        .background(Color(.systemBackground), in: .rect(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 30, y: 12)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(14)
            .accessibilityLabel(L("common.close"))
        }
        .padding(.horizontal, 22)
        .scaleEffect(appeared ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { appeared = true }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: intro.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(intro.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: intro.tint.opacity(0.30), radius: 10, y: 4)

            Text(intro.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            Text(intro.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func row(_ item: ScreenIntro.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(intro.tint)
                .frame(width: 30, height: 30)
                .background(intro.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.bold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ScreenIntroPopup: ViewModifier {
    let intro: ScreenIntro
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        Color.black
                            .opacity(0.38)
                            .ignoresSafeArea()
                            .onTapGesture { close() }
                            .accessibilityHidden(true)

                        ScreenIntroCard(intro: intro) { close() }
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isPresented)
    }

    private func close() {
        isPresented = false
    }
}

extension View {
    /// Ekranın ne işe yaradığını anlatan tanıtım kartını üstte gösterir.
    func screenIntro(_ intro: ScreenIntro, isPresented: Binding<Bool>) -> some View {
        modifier(ScreenIntroPopup(intro: intro, isPresented: isPresented))
    }
}

// MARK: - Ekran tanımları

extension ScreenIntro {
    /// Güvenli Noktalar ekranı.
    static var assemblyAreas: ScreenIntro {
        ScreenIntro(
            id: "assemblyAreas.v1",
            symbol: "person.3.sequence.fill",
            title: L("intro.assembly.title"),
            subtitle: L("intro.assembly.subtitle"),
            items: [
                Item(
                    symbol: "line.3.horizontal.decrease.circle.fill",
                    title: L("intro.assembly.filter.title"),
                    detail: L("intro.assembly.filter.detail")
                ),
                Item(
                    symbol: "magnifyingglass",
                    title: L("intro.assembly.search.title"),
                    detail: L("intro.assembly.search.detail")
                ),
                Item(
                    symbol: "star.fill",
                    title: L("intro.assembly.favorite.title"),
                    detail: L("intro.assembly.favorite.detail")
                ),
                Item(
                    symbol: "location.north.line.fill",
                    title: L("intro.assembly.offline.title"),
                    detail: L("intro.assembly.offline.detail")
                )
            ],
            tint: Color(red: 0.08, green: 0.62, blue: 0.36)
        )
    }

    /// Acil Durum ekranı.
    static var emergency: ScreenIntro {
        ScreenIntro(
            id: "emergency.v1",
            symbol: "cross.case.fill",
            title: L("intro.emergency.title"),
            subtitle: L("intro.emergency.subtitle"),
            items: [
                Item(
                    symbol: "phone.fill",
                    title: L("intro.emergency.call.title"),
                    detail: L("intro.emergency.call.detail")
                ),
                Item(
                    symbol: "speaker.wave.3.fill",
                    title: L("intro.emergency.tools.title"),
                    detail: L("intro.emergency.tools.detail")
                ),
                Item(
                    symbol: "location.fill",
                    title: L("intro.emergency.location.title"),
                    detail: L("intro.emergency.location.detail")
                ),
                Item(
                    symbol: "checklist",
                    title: L("intro.emergency.prepare.title"),
                    detail: L("intro.emergency.prepare.detail")
                )
            ],
            tint: Color(red: 0.86, green: 0.18, blue: 0.24)
        )
    }
}

/// Başlıktaki soru işareti — tanıtımı yeniden açar.
struct ScreenIntroButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle")
                .font(.subheadline.weight(.bold))
        }
        .accessibilityLabel(L("intro.howItWorks"))
    }
}
