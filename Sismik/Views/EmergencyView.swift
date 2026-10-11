import SwiftUI
import CoreLocation

/// Acil durum ekranının ölçü sistemi. Değerler sabit değil, pencerenin
/// genişliğinden türetilir: aynı kart iPhone SE'de sıkışmadan küçülür,
/// Pro Max ve iPad'de orantısız şişmez. Tek üretim noktası
/// `EmergencyLayout.fitting(width:)`, tek dağıtım yolu `\.emergencyLayout`
/// ortam değeridir.
struct EmergencyLayout: Equatable {
    var pageInset: CGFloat
    var sectionSpacing: CGFloat
    var surfacePadding: CGFloat
    var surfaceRadius: CGFloat
    var innerRadius: CGFloat
    var itemSpacing: CGFloat
    var tilePadding: CGFloat
    var iconBox: CGFloat
    /// Apple'ın 44pt dokunma hedefi tabanı — hiçbir ölçekte küçülmez.
    var minimumTapTarget: CGFloat
    var primaryControlHeight: CGFloat
    var sectionHeaderHeight: CGFloat
    var compactTileHeight: CGFloat
    var identityTileHeight: CGFloat

    // 112 çağrı kartı
    var heroPadding: CGFloat
    var heroMinHeight: CGFloat
    var heroIconBox: CGFloat
    var heroActionBox: CGFloat
    var heroNumberFont: Font

    /// `width` içerik sütununun (sayfa kenar boşlukları dahil) genişliğidir.
    static func fitting(width: CGFloat) -> EmergencyLayout {
        // 393pt (iPhone 15/16) referans alınır; ölçek dar ekranda %12'ye kadar
        // küçülür, geniş ekranda %10'a kadar büyür. Sınırlar kasıtlı dardır:
        // acil durum ekranı her cihazda aynı tanıdık düzende kalmalı.
        let scale = min(max(width / 393, 0.88), 1.10)
        func s(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

        return EmergencyLayout(
            pageInset: s(16),
            sectionSpacing: s(16),
            surfacePadding: s(14),
            surfaceRadius: SismikDesign.Radius.card,
            innerRadius: s(15),
            itemSpacing: s(8),
            tilePadding: s(12),
            iconBox: s(34),
            minimumTapTarget: 44,
            primaryControlHeight: max(s(46), 44),
            // Tek satırlık bölüm başlıkları için 40pt ayrılıyordu; her kartın
            // tepesinde boşa giden bir şeritti.
            sectionHeaderHeight: s(28),
            compactTileHeight: s(96),
            identityTileHeight: s(86),
            heroPadding: s(18),
            heroMinHeight: s(144),
            heroIconBox: s(48),
            heroActionBox: s(36),
            // Numara Dynamic Type ile ölçeklenmeye devam etsin diye metin
            // stili kullanılır; yalnızca hangi stil olduğu ekrana göre değişir.
            heroNumberFont: .system(width >= 430 ? .largeTitle : .title, design: .rounded, weight: .black)
        )
    }
}

private struct EmergencyLayoutKey: EnvironmentKey {
    static let defaultValue = EmergencyLayout.fitting(width: 393)
}

extension EnvironmentValues {
    var emergencyLayout: EmergencyLayout {
        get { self[EmergencyLayoutKey.self] }
        set { self[EmergencyLayoutKey.self] = newValue }
    }
}

/// Acil durum ekranı — Yüksek görünürlüklü, donanım entegrasyonlu, 1-tık konum paylaşımı ve yardım araçları.
/// Ailem / Family bağımlılıkları tamamen kaldırılmış, afet durumlarında hızlı ve kesintisiz çalışacak şekilde tasarlanmıştır.
struct EmergencyView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isWide: Bool { horizontalSizeClass == .regular }
    /// Ölçülen içerik genişliği; ölçü sistemi bundan türetilir. İlk karede
    /// varsayılan referans genişlik kullanılır, ölçüm gelince yerine geçer.
    @State private var contentWidth: CGFloat = 393
    private var layout: EmergencyLayout { .fitting(width: contentWidth) }
    private let tools = EmergencyTools.shared
    @State private var showLocationDeniedAlert = false
    @State private var showLocationServicesOffAlert = false
    @State private var showIntro = false
    @State private var showTrappedMode = false

    private var localEmergencyNumber: String { EmergencyNumber.local }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Lazy DEĞİL: bölüm sayısı sabit ve az. LazyVStack, kart
                // formu açıkken klavye ekranı yeniden yerleştirince kart
                // bölümünü bellekten atıyor, sheet durumu sıfırlanıp form
                // kendiliğinden kapanıyordu.
                //
                // Sıra aciliyete göre: arama → enkaz modu → durum bildirimi →
                // ses/ışık araçları → konum → sağlık kartları → hazırlık.
                VStack(spacing: layout.sectionSpacing) {
                    callEmergencyHeroCard
                    trappedModeCard
                    quickStatusSection
                    emergencyToolsGrid
                    locationSharingCard
                    EmergencyCardSectionView()
                    preparednessLinks
                    disclaimer
                }
                .padding(.horizontal, layout.pageInset)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .sismikContentWidth()
                // Alt görünümler (ör. acil kart bölümü) aynı ölçü sistemini
                // ortamdan okur; ikinci bir ölçüm noktası oluşmaz.
                .environment(\.emergencyLayout, layout)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                guard width > 0 else { return }
                contentWidth = width
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L("Acil Durum"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ScreenIntroButton { showIntro = true }
                }
            }
            // Tanıtım ilk girişte kendiliğinden açılmaz: acil anda ekranı
            // bir kartla kapatmak yerine araçlar doğrudan kullanılabilir
            // kalır. Başlıktaki soru işaretiyle açılır.
        }
        // SOS mors veya ekran flaşı sırasında ekranı parlak beyaza getiren overlay
        .overlay {
            if tools.screenFlashOn {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.06), value: tools.screenFlashOn)
        .screenIntro(.emergency, isPresented: $showIntro)
        .fullScreenCover(isPresented: $showTrappedMode) { TrappedModeView() }
        .onDisappear { tools.stopAll() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { tools.stopAll() }
        }
    }

    // MARK: - Ortak kart dili

    /// Uygulamanın kart dili: ikincil zemin, ortak köşe, çerçevesiz.
    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(layout.surfacePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: layout.surfaceRadius, style: .continuous))
    }

    /// Kart başlığı: renkli simge karosu + başlık (+ isteğe bağlı rozet).
    private func sectionHeader(_ title: String, icon: String, tint: Color, badge: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: layout.iconBox, height: layout.iconBox)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.brandGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.brandGreen.opacity(0.12), in: Capsule())
            }
        }
        .frame(minHeight: layout.sectionHeaderHeight)
    }

    // MARK: - 112 Acil Çağrı Hero Kartı

    private var callEmergencyHeroCard: some View {
        let number = localEmergencyNumber
        let card = callEmergencyHeroCardContent(number: number)
        return Group {
            if let url = URL(string: "tel://\(number)") {
                Link(destination: url) { card }
            } else {
                card
            }
        }
        .buttonStyle(EmergencyCallButtonStyle())
        .accessibilityLabel(String(format: L("%@ Acil Çağrı Merkezini ara"), number))
        .accessibilityHint(L("Telefon aramasını başlatır"))
    }

    private func callEmergencyHeroCardContent(number: String) -> some View {
        // Düz acil kırmızısı: ekranın en ciddi öğesi süssüz.
        HStack(spacing: layout.itemSpacing * 1.6) {
            Image(systemName: "phone.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(Self.emergencyRed)
                .frame(width: layout.heroIconBox, height: layout.heroIconBox)
                .background(.white, in: .rect(cornerRadius: layout.heroIconBox * 0.32, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(L("HAYATİ ACİL DURUM"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(number)
                    .font(layout.heroNumberFont.monospacedDigit())
                    .foregroundStyle(.white)
                Text(L("Acil Çağrı Merkezini Ara"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: layout.heroActionBox, height: layout.heroActionBox)
                .background(.white.opacity(0.16), in: .circle)
        }
        .padding(layout.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.emergencyRed, in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
    }

    private static let emergencyRed = Color(red: 0.80, green: 0.10, blue: 0.13)

    // MARK: - Enkaz modu

    /// Enkaz altında kalan için tek dokunuş: düdük + SOS ışığı döngüde, ekran
    /// açık. Arama kartının hemen altında, en görünür ikinci eylem.
    private var trappedModeCard: some View {
        Button {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            tools.stopAll()
            showTrappedMode = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: layout.iconBox + 6, height: layout.iconBox + 6)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("trapped.entry"))
                        .font(.headline.weight(.bold))
                    Text(L("ob2.emergency.trapped.caption"))
                        .font(.caption.weight(.medium))
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(layout.surfacePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.brandOrange, in: RoundedRectangle(cornerRadius: layout.surfaceRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.sismikPressable(scale: 0.98))
        .accessibilityHint(L("trapped.entry.hint"))
    }

    // MARK: - Durum bildirimi

    private var quickStatusSection: some View {
        surface {
            VStack(alignment: .leading, spacing: layout.itemSpacing) {
                sectionHeader(L("Hızlı Durum Mesajları"), icon: "message.fill", tint: .blue)

                HStack(spacing: layout.itemSpacing) {
                    statusButton(
                        title: L("Güvendeyim"), subtitle: L("Durum + Konum Paylaş"),
                        icon: "checkmark.shield.fill", tint: .brandGreen, message: safeMessageText
                    )
                    statusButton(
                        title: L("Yardım Lazım"), subtitle: L("Acil Çağrı + Konum"),
                        icon: "exclamationmark.shield.fill", tint: .red, message: helpMessageText
                    )
                }
            }
        }
    }

    private func statusButton(title: String, subtitle: String, icon: String, tint: Color, message: String) -> some View {
        ShareLink(item: message) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .opacity(0.9)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(layout.tilePadding)
        }
        .buttonStyle(.sismikPrimary(height: layout.compactTileHeight, tint: tint))
    }

    // MARK: - Ses ve ışık araçları

    private var emergencyToolsGrid: some View {
        surface {
            VStack(alignment: .leading, spacing: layout.itemSpacing) {
                sectionHeader(L("Donanım Acil Araçları"), icon: "speaker.wave.2.fill", tint: .orange, badge: L("Çevrimdışı Çalışır"))

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: layout.itemSpacing),
                        count: dynamicTypeSize.isAccessibilitySize ? 1 : (isWide ? 4 : 2)
                    ),
                    spacing: layout.itemSpacing
                ) {
                    toolTile(title: L("Düdük (Tiz)"), subtitle: L("Enkaz altı arama"),
                             icon: "wind", active: tools.isWhistleOn, tint: .cyan) { tools.toggleWhistle() }
                    toolTile(title: L("Siren (2 Tonlu)"), subtitle: L("Yüksek desibel"),
                             icon: "speaker.wave.3.fill", active: tools.isSirenOn, tint: .red) { tools.toggleSiren() }
                    toolTile(title: L("El Feneri"), subtitle: L("Kamera flaşı"),
                             icon: "flashlight.on.fill", active: tools.isTorchOn, tint: .yellow) { tools.toggleTorch() }
                    toolTile(title: L("SOS Flaşör"), subtitle: L("Mors ışık sinyali"),
                             icon: "light.beacon.max.fill", active: tools.isSOSOn, tint: .orange) { tools.toggleSOS() }
                }

                if tools.isWhistleOn || tools.isSirenOn || tools.isTorchOn || tools.isSOSOn {
                    Button { tools.stopAll() } label: {
                        Label(L("emergency.tools.stopAll"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.sismikSecondary)
                    .transition(.opacity)
                }
            }
        }
    }

    /// Araç karosu. Açıkken kendi renginde dolar (siren kırmızı, fener sarı…):
    /// hangi aracın çalıştığı uzaktan da seçilir.
    private func toolTile(title: String, subtitle: String, icon: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(active ? .white : tint)
                        .frame(width: layout.iconBox, height: layout.iconBox)
                        .background(active ? Color.white.opacity(0.22) : tint.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Spacer()
                    if active {
                        Image(systemName: "stop.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(active ? .white : .primary)
                    Text(active ? L("emergency.tool.stop") : subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(active ? .white.opacity(0.9) : .secondary)
                }
            }
            .padding(layout.tilePadding)
            .frame(maxWidth: .infinity, minHeight: layout.compactTileHeight, alignment: .topLeading)
            .background(
                active ? AnyShapeStyle(Self.activeFill(tint)) : AnyShapeStyle(Color(.tertiarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: layout.innerRadius, style: .continuous)
            )
        }
        .buttonStyle(.sismikPressable(scale: 0.98))
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: active)
        .accessibilityValue(active ? L("status.on") : L("status.off"))
    }

    /// Açık araç zemini: sarı ve camgöbeğinde beyaz yazı okunmuyordu;
    /// koyulaştırılmış tonları kullanılır.
    private static func activeFill(_ tint: Color) -> Color {
        switch tint {
        case .yellow: Color(red: 0.78, green: 0.58, blue: 0.0)
        case .cyan: Color(red: 0.0, green: 0.55, blue: 0.68)
        default: tint
        }
    }

    // MARK: - Konum

    private var locationSharingCard: some View {
        surface {
            VStack(alignment: .leading, spacing: layout.itemSpacing) {
                sectionHeader(L("Canlı Konum Koordinatları"), icon: "location.fill", tint: .blue)

                if let loc = locationManager.location {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude))
                                .font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Text(accuracyText(loc))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= 50 ? Color.brandGreen : .orange)
                        }
                        Spacer()
                        Button {
                            locationManager.requestLocation()
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.appAction)
                                .frame(width: layout.minimumTapTarget, height: layout.minimumTapTarget)
                                .background(Color.appAction.opacity(0.12), in: Circle())
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("retry"))
                    }

                    ShareLink(item: locationShareText(loc)) {
                        Label(L("Koordinatları Paylaş"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.sismikPrimary(height: max(layout.primaryControlHeight, 50)))
                } else {
                    Text(L("Konum bilginize erişilemiyor veya izin verilmedi."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        requestLocationAccess()
                    } label: {
                        Label(L("Konum İzni Al"), systemImage: "location.fill")
                    }
                    .buttonStyle(.sismikPrimary(height: max(layout.primaryControlHeight, 50)))
                }
            }
        }
        .alert(L("Konum İzni Gerekli"), isPresented: $showLocationDeniedAlert) {
            Button(L("open.settings")) { openSystemSettings() }
            Button(L("İptal"), role: .cancel) {}
        } message: {
            Text(L("Konumunu acil durum ekipleriyle paylaşabilmek için iOS Ayarlar'dan Sismik'e izin vermelisin."))
        }
        .alert(L("Konum Servisleri Kapalı"), isPresented: $showLocationServicesOffAlert) {
            Button(L("open.settings")) { openSystemSettings() }
            Button(L("İptal"), role: .cancel) {}
        } message: {
            Text(L("Cihazın Konum Servisleri kapalı. Ayarlar > Gizlilik ve Güvenlik > Konum Servisleri'nden açabilirsin."))
        }
    }

    /// Gerçek GPS doğruluğu. Eskiden her durumda "GPS Hassasiyeti Yüksek"
    /// yazıyordu; kurtarma ekibine giden konumun ne kadar kesin olduğu önemli.
    private func accuracyText(_ location: CLLocation) -> String {
        guard location.horizontalAccuracy >= 0 else { return L("emergency.location.accuracy.unknown") }
        return L("emergency.location.accuracy", Int(location.horizontalAccuracy.rounded()))
    }

    private func requestLocationAccess() {
        Task { @MainActor in
            guard await LocationManager.servicesEnabled() else {
                showLocationServicesOffAlert = true
                return
            }
            switch locationManager.authorizationStatus {
            case .notDetermined:
                locationManager.requestPermission()
            case .denied, .restricted:
                showLocationDeniedAlert = true
            default:
                locationManager.requestLocation()
            }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Hazırlık ve rehberler

    private var preparednessLinks: some View {
        VStack(spacing: 0) {
            NavigationLink { LocationRiskView() } label: {
                hubRow(L("risk.title"), L("risk.hub.subtitle"), icon: "gauge.with.dots.needle.67percent", tint: FaultRisk.high.color)
            }
            .buttonStyle(.plain)
            hubDivider
            NavigationLink { SafetyGuideView() } label: {
                hubRow(L("Güvenlik Rehberi (Çök-Kapan-Tutun)"), L("Deprem anı ve sonrasında yapılması gerekenler"),
                       icon: "shield.lefthalf.filled", tint: .brandOrange)
            }
            .buttonStyle(.plain)
            hubDivider
            NavigationLink { FirstAidGuideView() } label: {
                hubRow(L("firstaid.title"), L("firstaid.hub.subtitle"), icon: "cross.case.fill", tint: .red)
            }
            .buttonStyle(.plain)
            hubDivider
            NavigationLink { FamilyPlanView() } label: {
                hubRow(L("family.title"), L("family.hub.subtitle"), icon: "person.2.fill", tint: .blue)
            }
            .buttonStyle(.plain)
            hubDivider
            NavigationLink { PreparednessChecklistView() } label: {
                hubRow(L("Deprem Çantası Hazırlık Listesi"), L("Acil durum malzemeleri ve aile afet planı"),
                       icon: "checklist", tint: .brandGreen)
            }
            .buttonStyle(.plain)
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: layout.surfaceRadius, style: .continuous))
    }

    private var hubDivider: some View {
        Divider().padding(.leading, layout.surfacePadding + layout.iconBox + 12)
    }

    private func hubRow(_ title: String, _ subtitle: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: layout.iconBox, height: layout.iconBox)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, layout.surfacePadding)
        .padding(.vertical, layout.surfacePadding * 0.85)
        .frame(minHeight: max(layout.minimumTapTarget, layout.iconBox + layout.surfacePadding * 2))
        .contentShape(.rect)
    }

    // MARK: - Yasal Uyarı

    private var disclaimer: some View {
        let number = localEmergencyNumber
        return Text(String(format: L("Sismik bir erken uyarı sistemi değildir. Hayati acil durumlarda lütfen vakit kaybetmeden %@ Acil Çağrı Merkezini arayın."), number))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }

    // MARK: - Şablon Mesaj Üreticileri

    private var safeMessageText: String {
        var base = L("Güvendeyim. Herhangi bir olumsuz durum yok, iyiyim.")
        if let loc = locationManager.location {
            base += "\n" + (L("Acil Durum Konumum:")) + "\nhttps://maps.apple.com/?ll=\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
        }
        return base
    }

    private var helpMessageText: String {
        var base = L("ACİL DURUM! Yardıma ihtiyacım var, güvende değilim!")
        if let loc = locationManager.location {
            base += "\n" + (L("Bulunduğum Konum:")) + "\nhttps://maps.apple.com/?ll=\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
        }
        return base
    }

    private func locationShareText(_ loc: CLLocation) -> String {
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        let maps = "https://maps.apple.com/?ll=\(lat),\(lon)"
        return String(format: L("Acil durum konumum (Enlem: %.5f, Boylam: %.5f):\n%@"), lat, lon, maps)
    }
}

private struct EmergencyCallButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
