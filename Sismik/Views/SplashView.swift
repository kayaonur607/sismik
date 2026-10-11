import SwiftUI

/// Sakin, marka odaklı ve Dynamic Type uyumlu açılış ekranı.
///
/// Sahneleme kasıtlıdır: **önce yalnızca logo**, sonra marka metni, en son
/// yükleme çarkı. İlk kare native açılış ekranıyla (Info.plist `UILaunchScreen`
/// → `LaunchBackground` + `LaunchMark`) piksel piksel aynıdır — aynı turuncu
/// zemin, aynı boyutta ve aynı yerde logo. Böylece uygulama artık boş turuncu
/// bir ekranla açılmaz ve iki ekran arasındaki geçişte sıçrama olmaz; marka
/// metni ile çark bu ilk karenin ÜZERİNE sırayla girer. Zemin düz kalır:
/// dekoratif sismik halkalar kaldırıldı.
struct SplashView: View {
    var onFinish: () -> Void
    /// Yalnızca `#Preview` için: gerçek ağ/servis çağrılarını atlayıp yalnızca
    /// giriş animasyonunu oynatır. Üretim çağrı noktalarını etkilemez.
    var previewMode: Bool = false
    /// Yalnızca `#Preview` için: sistem ayarından bağımsız olarak Reduce
    /// Motion durumunu zorlar. `.environment(\.accessibilityReduceMotion, _)`
    /// artık yazılabilir değil, bu yüzden yerel bir geçersiz kılma kullanılır.
    var previewReducedMotion: Bool = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReducedMotion }

    @State private var exiting = false
    /// Marka metni (kelime işareti + slogan) göründü mü. Kapalıyken ekranda
    /// yalnızca logo durur ve tam merkezdedir.
    @State private var brandRevealed = false
    @State private var showLoading = false
    @State private var pulseWaveform = false
    /// Marka metin bloğunun ölçülen yüksekliği. Logo, metin girmeden önce
    /// ekranın tam ortasında dursun diye blok bu kadar aşağı kaydırılır.
    @State private var brandTextHeight: CGFloat = 0

    /// Native açılış ekranı görselinin tuval oranı: 1024 birimlik simge,
    /// 4352 birimlik tuvale gömülüdür. Logo çerçevesi ekran genişliğinin bu
    /// oranı kadar olduğunda splash'teki logo, açılış ekranındakiyle birebir
    /// aynı boyutta ve aynı yerde çizilir.
    /// Yerel açılış ekranındaki işaretle aynı boyut (LaunchMark 96 pt, iOS
    /// ölçeklemeden ortalar): ilk kare açılış ekranıyla birebir örtüşür.
    private static let logoSide: CGFloat = 96
    private static let brandSpacing: CGFloat = 22

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.6"
        return L("splash.version", version)
    }

    var body: some View {
        GeometryReader { proxy in
            let logoSide = Self.logoSide

            ZStack {
                Color("LaunchBackground")
                    .ignoresSafeArea()

                brandMark(logoSide: logoSide)
                bottomStatus
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sismik")
        .scaleEffect(exiting && !reduceMotion ? 1.03 : 1.0)
        .opacity(exiting ? 0 : 1)
        .task {
            // Sahneleme ve arka plan hazırlığı paralel yürür: animasyon ağ
            // isteklerini geciktirmez, erken biten hazırlık da sahnelemeyi
            // yarıda kesmez (çıkış `intro`yu bekler).
            let intro = Task { await runIntroSequence() }

            // Preview'lar gerçek ağ/servis çağrısı yapmaz.
            guard !previewMode else {
                await intro.value
                return
            }

            await prepareApp(waitingFor: intro)
        }
    }

    // MARK: - Giriş sahnelemesi

    /// Logo → marka metni → (hazırlık sürerse) çark. Reduce Motion açıkken
    /// aynı sıra korunur ama beklemeler ve hareket kaldırılır.
    private func runIntroSequence() async {
        guard !reduceMotion else {
            brandRevealed = true
            return
        }

        // 1. Logo: açılış ekranındaki kareyle aynı yerde, aynı boyutta durur.
        //    Tek başına nefes alması için kısa bir bekleme.
        try? await Task.sleep(for: .milliseconds(260))
        guard !Task.isCancelled else { return }

        // 2. Marka metni: logo yukarı yerleşirken alta girer.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            brandRevealed = true
        }
        pulseWaveform = true

        // Yerleşme animasyonu görülmeden çıkılmasın: hazırlık önbellekten
        // anında dönse bile splash bu ana kadar açık kalır (bkz. `prepareApp`).
        try? await Task.sleep(for: .milliseconds(420))
    }

    // MARK: - Kompozisyon

    private func brandMark(logoSide: CGFloat) -> some View {
        VStack(spacing: Self.brandSpacing) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: logoSide, height: logoSide)

            brandText
                .opacity(brandRevealed ? 1 : 0)
                .scaleEffect(brandRevealed || reduceMotion ? 1 : 0.96, anchor: .top)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    brandTextHeight = height
                }
        }
        .padding(.horizontal, 28)
        // Metin girmeden önce blok, logo tam merkeze gelecek kadar aşağıdadır;
        // metin belirirken blok yukarı kayıp son yerine oturur.
        .offset(y: brandRevealed ? 0 : (brandTextHeight + Self.brandSpacing) / 2)
    }

    private var brandText: some View {
        VStack(spacing: 10) {
            Text(verbatim: "Sismik")
                .font(.system(size: 26, weight: .heavy, design: .default))
                .tracking(4.5)
                .foregroundStyle(.white)

            Text(L("splash.tagline"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            // Markayı tamamlayan, Reduce Motion ile duran sismik dalga.
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 32, height: 1)
                Image(systemName: "waveform.path.ecg")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolEffect(.pulse, options: .repeating, isActive: pulseWaveform && !reduceMotion)
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 32, height: 1)
            }
            .padding(.top, 4)
            .accessibilityHidden(true)
        }
    }

    /// Yükleme çarkı + sürüm: merkezdeki marka bloğunu etkilemeden ayrı bir
    /// katman olarak alta sabitlenir. Çark sıranın sonuncusudur — logo ve
    /// marka metni yerleştikten sonra, hazırlık gerçekten sürüyorsa belirir.
    private var bottomStatus: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .opacity(showLoading ? 1 : 0)
                    .scaleEffect(showLoading || reduceMotion ? 1 : 0.7)
                Text(appVersion)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .opacity(brandRevealed ? 1.0 : 0.0)
            .padding(.bottom, 44)
        }
    }

    // MARK: - Arka Plan Hazırlıkları

    @MainActor
    private func prepareApp(waitingFor intro: Task<Void, Never>) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Arka plan hazırlıklarını paralel olarak başlat. Zorunlu güncelleme
        // kapısı burada kısaltılsa bile bypass edilmez: SismikApp'in kök
        // seviyesindeki kendi `checkIfNeeded()` çağrısı bağımsız çalışır ve
        // `UpdateGateOverlay` her koşulda görünür kalır.
        let prepTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await PremiumStore.shared.refreshEntitlements()
                }
                group.addTask { @MainActor in
                    NotificationManager.shared.scheduleIfEnabled()
                }
                group.addTask {
                    _ = await EarthquakeService.shared.liveSnapshot()
                }
            }
        }

        // Çark sıranın SONUNCUSUDUR: eşik, marka bloğunun yerine oturduğu ana
        // (≈760 ms) ayarlıdır — logo ve metin girmeden çark belirmez. Hazırlık
        // bundan önce biterse çark hiç görünmez.
        let loaderTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(760))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
                showLoading = true
            }
        }

        // Kritik olmayan ağ görevleri (premium, canlı veri) yavaş bağlantıda
        // splash'i süresiz açık tutmasın diye üst sınırla yarıştırılır.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await prepTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }

        loaderTask.cancel()
        if showLoading {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                showLoading = false
            }
        }

        // Akıcı görsel geçiş için kısa minimum bekleme (hantal gecikmeler kaldırıldı)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let minimumDuration: Double = reduceMotion ? 0.15 : 0.45
        if elapsed < minimumDuration {
            let remaining = minimumDuration - elapsed
            try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
        }

        // Logo ve marka metni yerine oturmadan çıkılmaz — hazırlık önbellekten
        // anında dönse bile sahneleme yarıda kesilmez.
        await intro.value

        // Çıkış: Hafif büyüyerek ve solarak ana ekrana geçiş
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            exiting = true
        }

        try? await Task.sleep(for: .milliseconds(reduceMotion ? 10 : 250))
        guard !Task.isCancelled else { return }
        onFinish()
    }
}

// MARK: - Previews

#Preview("Splash - Light") {
    SplashView(onFinish: {}, previewMode: true)
        .preferredColorScheme(.light)
}

#Preview("Splash - Dark") {
    SplashView(onFinish: {}, previewMode: true)
        .preferredColorScheme(.dark)
}

#Preview("Splash - Reduce Motion") {
    SplashView(onFinish: {}, previewMode: true, previewReducedMotion: true)
}
