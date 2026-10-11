import StoreKit
import SwiftUI

/// Sismik Premium satın alma ekranı.
///
/// Düzen: marka satırı → özellik vitrini (sayfa göstergesi ve değişen
/// açıklamayla) → planlar → güven ve yasal metinler. Satın al düğmesi ve
/// yenileme bilgisi ekranın altında sabit durur.
/// Fiyatlar ve uygunluk doğrudan App Store'dan gelir.
struct PaywallView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    private let store = PremiumStore.shared
    @State private var selectedProductID = PremiumStore.yearlyID
    /// Vitrinde gösterilen özellik; ekran açıldığı bağlama göre başlar.
    @State private var feature: PaywallFeature
    @State private var showManageSubscriptions = false
    @State private var isLoadingProducts = false
    @State private var selectionFeedback = 0
    @State private var purchaseFeedback = 0
    @State private var activationFeedback = 0
    /// Ücretsiz deneme hakkı olan abonelikler (App Store'a sorulur; daha önce
    /// deneme kullanan hesapta boş kalır, deneme hiç vaat edilmez).
    @State private var trialEligibleIDs: Set<String> = []

    private let termsURL = URL(string: "https://sismik-app.web.app/terms/")!
    private let privacyURL = URL(string: "https://sismik-app.web.app/privacy/")!

    init(initialFeature: PaywallFeature = .places) {
        _feature = State(initialValue: initialFeature)
    }

    var body: some View {
        ScrollView {
            paywallContent
        }
        .scrollIndicators(.never)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .topTrailing) { closeButton }
        // Satın al düğmesi ekranın altında sabit: eskiden planların altında,
        // çoğu telefonda ilk ekranın dışında kalıyordu.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.isPremium && !availableProducts.isEmpty {
                purchaseSection
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .sismikContentWidth(compact: 620, regular: 720)
                    .background(.bar)
            }
        }
        .task { await preparePaywall() }
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sensoryFeedback(.impact(weight: .medium), trigger: purchaseFeedback)
        // Titreşim yalnızca yetki KAZANILDIĞINDA. Doğrudan `store.isPremium`
        // Bool'una bağlıyken her iki yönde de tetikleniyordu: paywall açıkken
        // abonelik düşerse "başarı" titreşimi veriyordu.
        .sensoryFeedback(.success, trigger: activationFeedback)
        .onChange(of: store.isPremium) { _, isPremium in
            if isPremium { activationFeedback += 1 }
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
    }

    private var closeButton: some View {
        Button(L("paywall.close"), systemImage: "xmark") {
            dismiss()
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(width: 44, height: 44)
        .background(Color(.secondarySystemGroupedBackground), in: .circle)
        .contentShape(.circle)
        .accessibilityHint(L("paywall.close.hint"))
        .padding(.trailing, 16)
        .safeAreaPadding(.top, 8)
    }

    private var paywallContent: some View {
        VStack(spacing: 26) {
            header

            if store.isPremium {
                inlineSuccessCard
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else {
                PaywallShowcase(selection: $feature)

                VStack(alignment: .leading, spacing: 12) {
                    Text(L("paywall.section.plans"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    productOptions
                }

                trustAndLegal
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .sismikContentWidth(compact: 620, regular: 720)
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: store.isPremium)
    }


    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image("LogoOrange")
                    .resizable().scaledToFit()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text(verbatim: "Sismik Premium")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(L("paywall.hero.title"))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 52)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var inlineSuccessCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: activationFeedback)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("paywall.success.title"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(L("paywall.success.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text(L("Kullanmaya Başla"))
                        .font(.headline.weight(.bold))
                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.bold))
                }
                .frame(maxWidth: .infinity)
            }
            // Uygulamanın standart birincil butonu: basınca içeri çöker ve
            // dokunsal geri bildirim verir.
            .buttonStyle(.sismikPrimary(height: 52))

            Button(
                L("subscription.manage"),
                systemImage: "person.crop.circle.badge.checkmark"
            ) {
                showManageSubscriptions = true
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }

    private var monthlyProduct: Product? {
        store.products.first { $0.id == PremiumStore.monthlyID }
    }

    private var yearlyProduct: Product? {
        store.products.first { $0.id == PremiumStore.yearlyID }
    }

    private var lifetimeProduct: Product? {
        store.products.first { $0.id == PremiumStore.lifetimeID }
    }

    /// Yıllık (varsayılan seçim), aylık ve tek seferlik ömür boyu plan.
    /// App Store'un döndürmediği plan gösterilmez.
    private var availableProducts: [Product] {
        [yearlyProduct, monthlyProduct, lifetimeProduct].compactMap { $0 }
    }

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID }
    }

    private var savingsPercent: Int? {
        guard let monthly = monthlyProduct?.price,
              let yearly = yearlyProduct?.price,
              monthly > 0 else { return nil }
        let annualMonthlyPrice = monthly * 12
        let ratio = (annualMonthlyPrice - yearly) / annualMonthlyPrice
        let percent = Int((NSDecimalNumber(decimal: ratio).doubleValue * 100).rounded())
        return percent > 0 ? percent : nil
    }

    private var yearlyPerMonthText: String? {
        guard let yearlyProduct else { return nil }
        return yearlyProduct.priceFormatStyle.format(yearlyProduct.price / 12)
    }

    private var monthlyPerYearText: String? {
        guard let monthlyProduct else { return nil }
        return monthlyProduct.priceFormatStyle.format(monthlyProduct.price * 12)
    }

    @ViewBuilder
    private var productOptions: some View {
        if isLoadingProducts && store.products.isEmpty {
            VStack(spacing: 12) {
                PaywallPlanSkeleton()
                PaywallPlanSkeleton()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("paywall.loading"))
        } else if availableProducts.isEmpty {
            productErrorState
        } else {
            PremiumPlanPicker(
                products: availableProducts,
                selectedProductID: selectedProductID,
                comparisonText: comparisonText,
                badgeText: badgeText,
                onSelect: selectProduct
            )
            .disabled(store.isPurchasing)
        }
    }

    private var productErrorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(PremiumPalette.orange)
            Text(L("paywall.products.unavailable"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("paywall.products.retry")) {
                Task { await loadProducts() }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    /// Seçili ürünün kullanılabilir ücretsiz deneme süresi ("1 hafta").
    private func trialText(for product: Product?) -> String? {
        guard let product, trialEligibleIDs.contains(product.id),
              let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        return Self.periodText(offer.period)
    }

    static func periodText(_ period: Product.SubscriptionPeriod) -> String {
        let key: String
        switch period.unit {
        case .day: key = period.value == 7 ? "paywall.period.week" : "paywall.period.day"
        case .week: key = "paywall.period.week"
        case .month: key = "paywall.period.month"
        case .year: key = "paywall.period.year"
        @unknown default: key = "paywall.period.day"
        }
        let value = period.unit == .day && period.value == 7 ? 1 : period.value
        return String(format: L(key), value)
    }

    private func comparisonText(for product: Product) -> String {
        if product.id == PremiumStore.lifetimeID {
            return L("paywall.lifetime.detail")
        }
        if product.id == PremiumStore.yearlyID, let yearlyPerMonthText {
            return String(format: L("paywall.perMonthEquiv"), yearlyPerMonthText)
        }
        if let monthlyPerYearText {
            return String(format: L("paywall.perYearEquiv"), monthlyPerYearText)
        }
        return product.id == PremiumStore.yearlyID
            ? L("paywall.perYear")
            : L("paywall.perMonth")
    }

    private func badgeText(for product: Product) -> String? {
        // Ömür boyu kartında rozet yok: "tek ödeme" hem açıklamada hem fiyat
        // biriminde zaten yazıyor, üçüncü tekrar gürültüydü.
        if product.id == PremiumStore.lifetimeID { return nil }
        if let trial = trialText(for: product) {
            return String(format: L("paywall.trial.badge"), trial)
        }
        guard product.id == PremiumStore.yearlyID else { return nil }
        if let savingsPercent {
            return String(format: L("paywall.save"), savingsPercent)
        }
        return L("paywall.bestValue")
    }

    private func selectProduct(_ product: Product) {
        guard selectedProductID != product.id else { return }
        selectedProductID = product.id
        selectionFeedback += 1
    }

    /// Satın al düğmesi ve seçilen planın yenileme bilgisi (sabit alt panel).
    private var purchaseSection: some View {
        VStack(spacing: 8) {
            Button(action: purchaseSelectedProduct) {
                HStack(spacing: 8) {
                    if store.isPurchasing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(purchaseButtonTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "arrow.right")
                            .font(.footnote.weight(.bold))
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.sismikPrimary)
            .disabled(store.isPurchasing || selectedProduct == nil)
            .opacity(selectedProduct == nil ? 0.5 : 1)
            .accessibilityHint(L("paywall.purchase.hint"))

            if let renewalText {
                Text(renewalText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var purchaseButtonTitle: String {
        if selectedProductID == PremiumStore.lifetimeID { return L("paywall.lifetime.buy") }
        return trialText(for: selectedProduct) != nil ? L("paywall.trial.cta") : L("paywall.subscribe")
    }

    private var renewalText: String? {
        guard let product = selectedProduct else { return nil }
        if product.id == PremiumStore.lifetimeID {
            return String(format: L("paywall.renewal.lifetime"), product.displayPrice)
        }
        // Deneme varsa ücretin ne zaman ve ne kadar alınacağı düğmenin hemen
        // altında açıkça yazılır (App Store İnceleme 3.1.2).
        if let trial = trialText(for: product) {
            return String(
                format: L(product.id == PremiumStore.yearlyID ? "paywall.renewal.trial.year" : "paywall.renewal.trial.month"),
                trial, product.displayPrice
            )
        }
        return product.id == PremiumStore.yearlyID
            ? String(format: L("paywall.renewal.simple.year"), product.displayPrice)
            : String(format: L("paywall.renewal.simple.month"), product.displayPrice)
    }

    private var trustAndLegal: some View {
        VStack(spacing: 14) {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(error)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { trustLabels }
                VStack(spacing: 8) { trustLabels }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            Text(L("paywall.legal"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { footerActions }
                VStack(spacing: 10) { footerActions }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trustLabels: some View {
        // Ömür boyu satın almada iptal edilecek bir abonelik yok.
        if selectedProductID == PremiumStore.lifetimeID {
            Label(L("paywall.lifetime.detail"), systemImage: "checkmark.shield.fill")
        } else {
            Label(L("paywall.cancelAnytime"), systemImage: "checkmark.shield.fill")
        }
        Label(L("paywall.securePayment"), systemImage: "creditcard.fill")
    }

    @ViewBuilder
    private var footerActions: some View {
        Button(L("paywall.restore")) {
            Task { await store.restorePurchases() }
        }
        .frame(minHeight: 44)
        .disabled(store.isPurchasing)
        Link(L("paywall.terms"), destination: termsURL).frame(minHeight: 44)
        Link(L("paywall.privacy"), destination: privacyURL).frame(minHeight: 44)
    }

    private func preparePaywall() async {
        await loadProducts()
        await refreshTrialEligibility()
        await store.refreshEntitlements()
    }

    private func refreshTrialEligibility() async {
        var eligible: Set<String> = []
        for product in store.products {
            guard let subscription = product.subscription,
                  subscription.introductoryOffer?.paymentMode == .freeTrial else { continue }
            if await subscription.isEligibleForIntroOffer { eligible.insert(product.id) }
        }
        trialEligibleIDs = eligible
    }

    private func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        await store.loadProducts()

        if yearlyProduct != nil {
            selectedProductID = PremiumStore.yearlyID
        } else if let monthlyProduct {
            selectedProductID = monthlyProduct.id
        }
    }

    private func purchaseSelectedProduct() {
        guard let selectedProduct else { return }
        purchaseFeedback += 1
        Task { await store.purchase(selectedProduct) }
    }
}
