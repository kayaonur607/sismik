import SwiftUI

/// Uygulama marka renkleri — uygulama ikonunun turuncu paletinden.
extension Color {
    /// Logo zemini: #FF7A00.
    static let brandOrange = Color(red: 1.0, green: 122.0 / 255, blue: 0)
    /// Logodaki sütunların tepesi: #FFC20E.
    static let brandAmber = Color(red: 1.0, green: 194.0 / 255, blue: 14.0 / 255)
    /// Logodaki sütunların dibi: #E8380A.
    static let brandEmber = Color(red: 232.0 / 255, green: 56.0 / 255, blue: 10.0 / 255)
    /// Uygulamadaki tüm standart etkileşimlerin tek accent rengi.
    /// Tehlike, başarı ve deprem seviyesi gibi semantik renkler bunun dışındadır.
    static let appAction = brandOrange
    static let brandGreen = Color(red: 0.20, green: 0.64, blue: 0.45)
}

/// `.foregroundStyle(.brandRed)` gibi kısayollar için ShapeStyle uzantısı.
extension ShapeStyle where Self == Color {
    static var brandRed: Color { Color(red: 0.969, green: 0.016, blue: 0.071) }
    static var brandOrange: Color { .brandOrange }
    static var brandGreen: Color { .brandGreen }
    static var appAction: Color { Color.appAction }
}

// MARK: - Cam yüzey

/// Tek bir cam dili: iOS 26'da sistemin native Liquid Glass'ı (dock ve
/// haritayla tutarlı), iOS 18–25'te uygulamanın mevcut `.ultraThinMaterial`
/// görünümü. Çağıran taraf sürüm kontrolü yapmak zorunda kalmaz.
extension View {
    /// Seçilebilir çip/buton yüzeyi: seçiliyken markanın rengiyle tonlanmış cam,
    /// değilken saydam cam. Eski sürümlerde degrade dolgu ↔ materyal.
    /// `.interactive()` BİLEREK KULLANILMIYOR. iOS 26'da etkileşimli cam
    /// dokunuşu kendisi ele alıyor: bu yüzey bir `Button` etiketi olarak
    /// kullanıldığında camın kendi dokunma işlemesi butonun hızlı dokunuşunu
    /// yutuyor ve düğme ancak biraz basılı tutulunca tetikleniyordu
    /// ("bazen çalışıyor, bazen çalışmıyor"). Basma geri bildirimini zaten
    /// `.sismikPressable` veriyor — ölçek + dokunsal titreşim.
    @ViewBuilder
    func sismikGlassChip(in shape: some Shape, tint: Color, selected: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if selected {
                self.glassEffect(.regular.tint(tint.opacity(0.85)), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(
                selected ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial),
                in: shape
            )
            .overlay(
                shape.stroke(selected ? tint.opacity(0.40) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// MARK: - Kaydırma kenarı efekti

extension View {
    /// İçerik gezinme ve sekme çubuklarının altına kayarken oluşan yumuşak
    /// bulanıklaşma/solma (sistemin kendi "scroll edge" efekti). iOS 26'da
    /// sistem bunu kendiliğinden yapıyor; iOS 27'de uygulamada görünmediği için
    /// aynı yerel efekt açıkça istenir. iOS 26 ve öncesine dokunulmaz.
    /// Kökte bir kez uygulanır: hiyerarşideki tüm kaydırma görünümlerine geçer.
    @ViewBuilder
    func sismikScrollEdgeEffect() -> some View {
        if #available(iOS 27.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            self
        }
    }
}

/// Harita ekranlarında standart ↔ uydu görünümü arasında geçiş butonu.
struct MapModeButton: View {
    @Binding var satellite: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { satellite.toggle() }
        } label: {
            icon
        }
        // Haritadaki diğer yuvarlak düğmelerle aynı basma davranışı.
        .buttonStyle(.sismikPressable)
        .accessibilityLabel(satellite ? L("map.standard") : L("map.satellite"))
    }

    /// iOS 26'da native cam; altında mevcut materyal + beyaz kenar görünümü
    /// birebir korunur.
    @ViewBuilder
    private var icon: some View {
        let symbol = Image(systemName: satellite ? "map.fill" : "globe.americas.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.primary)
            .frame(width: 44, height: 44)
        if #available(iOS 26.0, *) {
            // Aynı sebeple etkileşimsiz: bu da bir `Button` etiketi.
            symbol
                .glassEffect(.regular, in: .circle)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        } else {
            symbol
                .background(.ultraThinMaterial, in: .circle)
                .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}

// MARK: - Standardized iOS Button Styles & Helpers

/// Uygulama tasarım sistemi belirteçleri — Apple HIG ile uyumlu ortak tasarım dili.
enum SismikDesign {
    enum Radius {
        static let button: CGFloat = 18
        /// Liste, detay ve istatistik kartlarının ortak köşesi.
        static let card: CGFloat = 18
        static let chip: CGFloat = 10
        static let sheet: CGFloat = 28
    }

    enum Motion {
        static let interactiveSpring: Animation = .smooth(duration: 0.22, extraBounce: 0)
        static let entranceSpring: Animation = .smooth(duration: 0.4, extraBounce: 0)
        static let rowSpring: Animation = .smooth(duration: 0.25, extraBounce: 0)
    }

    /// Dokunsal geri bildirim üretici
    @MainActor
    static func touchFeedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// Uygulamanın tek birincil buton stili — tanıtımdaki "Devam Et" düğmesi.
/// Tam genişlik, 52pt, düz marka dolgusu; basınca hafifçe içeri çöker ve
/// dokunsal geri bildirim verir. Ana eylem
/// düğmeleri (devam, tekrar dene, paylaş, yol tarifi…) hep bunu kullanır;
/// titreşimi stil verdiği için eylemlerde ayrıca titreşim üretilmez.
struct SismikPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var height: CGFloat = 52
    var tint: Color = .appAction
    var font: Font = .headline.weight(.semibold)
    var cornerRadius: CGFloat = SismikDesign.Radius.button

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
            // Düz marka dolgusu. Eskiden üstte parlaklık degradesi, çaprazda
            // amber→köz geçişi ve rengin kendisiyle parlayan gölge vardı;
            // üçü birlikte düğmeyi "şablon" gösteriyordu.
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(reduceMotion ? nil : SismikDesign.Motion.interactiveSpring, value: configuration.isPressed)
            // Rengi değişen çağrı yerleri (tanıtım sayfaları) için: yeni ton
            // ani değil, geçişli gelir.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: tint)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { SismikDesign.touchFeedback() }
            }
    }
}

/// "Tekrar Dene" düğmelerinin ortak etiketi (birincil stil ile kullanılır).
struct RetryButtonLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Image(systemName: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
        }
    }
}

/// Uygulama genelinde ikincil cam/mat dokunsal buton stili.
struct SismikSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var height: CGFloat = 48
    var cornerRadius: CGFloat = SismikDesign.Radius.button

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
            .background(
                configuration.isPressed ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(reduceMotion ? nil : SismikDesign.Motion.interactiveSpring, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { SismikDesign.touchFeedback() }
            }
    }
}

/// Deprem listesi ve öne çıkan kartlar: basılı tutunca hafifçe içeri çöker
/// ve dokunsal geri bildirim verir.
struct SismikListRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .brightness(configuration.isPressed ? -0.02 : 0.0)
            // Gölge yok: gruplu arka plan üstündeki kart zaten ayrışıyor.
            // Satır başına gölge kaydırmada ekran dışı çizim de demekti.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { SismikDesign.touchFeedback() }
            }
    }
}

/// İkonlar, çember düğmeler ve özel butonlar için evrensel Apple dokunma yaylanması.
struct SismikPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.86 : 1.0)
            .animation(reduceMotion ? nil : SismikDesign.Motion.interactiveSpring, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { SismikDesign.touchFeedback() }
            }
    }
}

extension ButtonStyle where Self == SismikPrimaryButtonStyle {
    static var sismikPrimary: SismikPrimaryButtonStyle { SismikPrimaryButtonStyle() }
    static func sismikPrimary(
        height: CGFloat = 52,
        tint: Color = .appAction,
        font: Font = .headline.weight(.semibold),
        cornerRadius: CGFloat = SismikDesign.Radius.button
    ) -> SismikPrimaryButtonStyle {
        SismikPrimaryButtonStyle(height: height, tint: tint, font: font, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == SismikSecondaryButtonStyle {
    static var sismikSecondary: SismikSecondaryButtonStyle { SismikSecondaryButtonStyle() }
    static func sismikSecondary(
        height: CGFloat = 48,
        cornerRadius: CGFloat = SismikDesign.Radius.button
    ) -> SismikSecondaryButtonStyle {
        SismikSecondaryButtonStyle(height: height, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == SismikListRowButtonStyle {
    static var sismikListRow: SismikListRowButtonStyle { SismikListRowButtonStyle() }
}

extension ButtonStyle where Self == SismikPressableButtonStyle {
    static var sismikPressable: SismikPressableButtonStyle { SismikPressableButtonStyle() }
    static func sismikPressable(scale: CGFloat = 0.94) -> SismikPressableButtonStyle {
        SismikPressableButtonStyle(pressedScale: scale)
    }
}

// MARK: - Uyarlanabilir içerik genişliği

/// Okunabilir metin sütunu genişliği. iPhone'da (compact) telefon için
/// ayarlanmış 540pt korunur; iPad ve Mac penceresinde (regular) sütun
/// genişler, böylece içerik geniş ekranda dar bir şeride sıkışmaz.
private struct SismikContentWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let compact: CGFloat
    let regular: CGFloat
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: horizontalSizeClass == .regular ? regular : compact)
            .frame(maxWidth: .infinity, alignment: horizontalSizeClass == .regular ? alignment : .center)
    }
}

extension View {
    /// Tek bir sütunda okunan içerik (liste, detay, istatistik) için ortak genişlik.
    ///
    /// `alignment` yalnızca geniş pencerede etkilidir. Sistemin büyük başlığı
    /// (`.navigationBarTitleDisplayMode(.large)`) güvenli alanın sol kenarına
    /// çizilir; içerik ortalandığında iPad yatayda başlık solda tek başına
    /// kalıp kart sütunu ortada duruyordu. Büyük başlıklı ekranlar `.leading`
    /// vererek sütunu başlıkla aynı hizaya oturtur; başlıksız ekranlar
    /// (satın alma, tanıtım, sayfa olarak açılan formlar) ortalı kalır.
    func sismikContentWidth(
        compact: CGFloat = 540,
        regular: CGFloat = 900,
        alignment: Alignment = .center
    ) -> some View {
        modifier(SismikContentWidth(compact: compact, regular: regular, alignment: alignment))
    }
}
