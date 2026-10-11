import SwiftUI
import MapKit
import UserNotifications

/// Yer ekleme/düzenleme: tepede harita hero'su, altında kaydırılabilir form.
///
/// Harita bir bölüm başlığı değil, ekranın kahramanı: 340 punto yüksekliğinde,
/// kenardan kenara. İlk denemedeki 210 punto yarıçap dairesini okunamaz
/// kılıyordu.
///
/// Form kullanmanın iki somut faydası var: klavye açıldığında içerik
/// kendiliğinden kayıyor (alt panelin ekranı kaplaması ve geri dönememe
/// sorunu ortadan kalkıyor) ve "konumuma git" düğmesi haritanın kendi
/// alanında kaldığı için hiçbir şeyin arkasında kalmıyor.
struct NotificationPlaceMapEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft: NotificationPlace
    @State private var camera: MapCameraPosition
    @State private var estimate: Int?
    /// Son 30 günde bu ayarla bildirim gelecek depremler (haritada noktalar).
    @State private var matchedQuakes: [Earthquake] = []
    /// Kullanıcı adı kendisi yazdıysa otomatik öneri üzerine yazmaz.
    @State private var nameEditedByUser = false
    @State private var geocodeTask: Task<Void, Never>?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var estimateTask: Task<Void, Never>?
    /// 34 günlük arşiv BİR KEZ okunur. Her harita hareketinde diskten
    /// yeniden yüklemek sayfayı takıyordu.
    @State private var archive: [Earthquake] = []
    @State private var showLocationDenied = false
    @State private var showLocationServicesOff = false
    /// iOS'un kritik uyarı durumu; eşik açıkken izin yoksa bölüm bunu söyler.
    @State private var criticalSetting: UNNotificationSetting = .notSupported
    @AppStorage("notif.criticalAlertRequested") private var criticalAlertRequested = false
    @FocusState private var nameFocused: Bool
    @State private var showPaywall = false
    private let premium = PremiumStore.shared

    /// Ücretsiz katmanda yarıçap 50 km ile sınırlı (sunucu da aynı sınırı uygular).
    private var maxRadiusKm: Double {
        premium.isPremium ? NotificationPlace.maxRadiusKm : NotificationPlace.freeMaxRadiusKm
    }

    private let isNew: Bool
    private let usedIcons: Set<PlaceIcon>
    private let onSave: (NotificationPlace) -> Void
    private let onDelete: ((String) -> Void)?

    /// Hero yüksekliği: yarıçap dairesi ve çevresi rahat okunsun, altındaki
    /// ilk form satırı da ekranda kalsın.
    private let heroHeight: CGFloat = 340

    init(
        place: NotificationPlace,
        isNew: Bool,
        usedIcons: Set<PlaceIcon>,
        onSave: @escaping (NotificationPlace) -> Void,
        onDelete: ((String) -> Void)? = nil
    ) {
        _draft = State(initialValue: place)
        _camera = State(initialValue: .region(Self.region(for: place)))
        self.isNew = isNew
        self.usedIcons = usedIcons
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        Form {
            Section {
                mapHero
                    .frame(height: heroHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                slider(
                    title: L("places.editor.radius"),
                    value: String(format: "%.0f km", draft.radiusKm),
                    tint: Color.appAction,
                    binding: $draft.radiusKm,
                    range: NotificationPlace.minRadiusKm...maxRadiusKm,
                    step: 5
                )
                presetRow
                if !premium.isPremium {
                    premiumUpsellRow
                }
            } footer: {
                Text(L("places.editor.mapFooter"))
            }

            Section {
                HStack(spacing: 12) {
                    PlaceIconBadge(icon: draft.icon, size: 40)
                        .contentTransition(.symbolEffect(.replace))
                    TextField(L("places.editor.name"), text: Binding(
                        get: { draft.name },
                        set: { draft.name = $0; nameEditedByUser = true }
                    ))
                        .textInputAutocapitalization(.words)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { nameFocused = false }
                }
                .padding(.vertical, 4)

                PlaceIconPicker(selection: $draft.icon, unavailable: usedIcons)
                    .onChange(of: draft.icon) { oldIcon, newIcon in
                        applyIconName(from: oldIcon, to: newIcon)
                    }
            } footer: {
                Text(L("places.editor.iconFooter"))
            }

            Section {
                slider(
                    title: L("places.editor.magnitude"),
                    value: "M \(draft.minMagnitude.formatted(.number.precision(.fractionLength(1))))+",
                    tint: MagnitudeLevel(magnitude: draft.minMagnitude).color,
                    binding: $draft.minMagnitude,
                    range: NotificationPlace.minMagnitudeFloor...NotificationPlace.minMagnitudeCeiling,
                    step: 0.5
                )
            } footer: {
                Label {
                    Text(estimate.map { L("places.estimate", $0) } ?? L("places.estimate.loading"))
                        .contentTransition(.numericText())
                } icon: {
                    Image(systemName: "info.circle")
                }
                .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: estimate)
            }

            feltSection

            // Kritik uyarı premium: ücretsiz yerde bu bölüm gösterilmez.
            if premium.isPremium {
                criticalSection
            }

            if !isNew, let onDelete {
                Section {
                    Button(role: .destructive) {
                        onDelete(draft.id)
                        dismiss()
                    } label: {
                        Text(L("places.editor.delete")).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isNew ? L("places.editor.newTitle") : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("common.save")) {
                    nameFocused = false
                    onSave(draft)
                    dismiss()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L("places.editor.done")) { nameFocused = false }
            }
        }
        .task {
            // Premium'u biten kullanıcının geniş yarıçaplı yeri: sunucu zaten
            // 50 km'ye kırpıyor; düzenleyici de gerçekte geçerli değeri gösterir.
            if !premium.isPremium, draft.radiusKm > maxRadiusKm { draft.radiusKm = maxRadiusKm }
            await prepare()
        }
        .fullScreenCover(isPresented: $showPaywall) { PaywallView(initialFeature: .places) }
        .onChange(of: draft.radiusKm) { _, _ in
            // Yarıçap büyüdükçe kamera geri çekilir: daire her zaman ekranda.
            withAnimation(reduceMotion ? nil : SismikDesign.Motion.rowSpring) {
                camera = .region(Self.region(for: draft))
            }
            scheduleEstimate()
        }
        .onChange(of: draft.feltIntensity) { _, _ in scheduleEstimate() }
        .onChange(of: draft.minMagnitude) { _, newValue in
            // Kritik eşik bildirim eşiğinin altında kalamaz.
            if let critical = draft.criticalMagnitude, critical < newValue {
                draft.criticalMagnitude = NotificationPlace.clampedCritical(critical, minMagnitude: newValue)
            }
            scheduleEstimate()
        }
        .alert(L("settings.locationRequired"), isPresented: $showLocationDenied) {
            Button(L("open.settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(L("cancel"), role: .cancel) {}
        }
        .alert(L("settings.locationRequired"), isPresented: $showLocationServicesOff) {
            Button(L("common.ok"), role: .cancel) {}
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !usedIcons.contains(draft.icon)
            && draft.hasValidCoordinate
    }

    // MARK: - Harita hero'su

    private var mapHero: some View {
        ZStack(alignment: .top) {
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                MapCircle(center: draft.coordinate, radius: draft.radiusKm * 1000)
                    .foregroundStyle(Color.appAction.opacity(0.13))
                    .stroke(Color.appAction, lineWidth: 2)
                // Son 30 günde bu ayarla bildirim gelecek depremler.
                ForEach(matchedQuakes) { quake in
                    Annotation("", coordinate: quake.coordinate.clCoordinate, anchor: .center) {
                        Circle()
                            .fill(quake.magnitudeColor)
                            .stroke(.white, lineWidth: 1)
                            .frame(width: Self.dotSize(quake.magnitude), height: Self.dotSize(quake.magnitude))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { context in
                let center = context.region.center
                guard abs(center.latitude - draft.latitude) > 0.0001
                    || abs(center.longitude - draft.longitude) > 0.0001 else { return }
                draft.latitude = center.latitude
                draft.longitude = center.longitude
                // Elle taşınan "Bulunduğum yer" artık cihazı takip etmemeli;
                // aksi hâlde bir sonraki konum güncellemesi seçimi geri alırdı.
                if draft.kind == .current { draft.kind = .pinned }
                scheduleEstimate()
                suggestNameIfNeeded()
            }
            .overlay(alignment: .center) { centerPin }
            .overlay(alignment: .bottomTrailing) { myLocationButton }

            searchOverlay
        }
    }

    private var centerPin: some View {
        Circle()
            .fill(Color.appAction)
            .stroke(.white, lineWidth: 2.6)
            .frame(width: 16, height: 16)
            .shadow(radius: 2, y: 1)
            .allowsHitTesting(false)
    }

    /// Haritanın KENDİ alanı içinde — hiçbir şeyin arkasında kalmıyor.
    private var myLocationButton: some View {
        Button {
            SismikDesign.touchFeedback()
            centerOnUser()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appAction)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .padding(14)
        .accessibilityLabel(L("places.pick.current"))
    }

    private var searchOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("places.pick.searchPrompt"), text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.prefix(4).enumerated()), id: \.element) { index, item in
                        Button { select(item) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name ?? L("places.pick.unnamed"))
                                    .font(.subheadline).foregroundStyle(.primary)
                                if let subtitle = Self.subtitle(for: item) {
                                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < min(results.count, 4) - 1 { Divider().padding(.leading, 12) }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(.top, 5)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .onChange(of: query) { _, value in scheduleSearch(value) }
        .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: results.count)
    }

    // MARK: - Premium teşviki

    /// Ücretsiz yarıçap sınırının hemen altında: daha geniş alanı ve kritik
    /// uyarıyı premium'la açar.
    private var premiumUpsellRow: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.appAction)
                    .frame(width: 28, height: 28)
                    .background(Color.appAction.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("places.free.radius.title"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L("places.free.radius.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hazır ayarlar

    private struct Preset: Identifiable {
        let id: String
        let symbol: String
        let radiusKm: Double
        let minMagnitude: Double
        let feltIntensity: Int?
    }

    /// Tek dokunuşla yarıçap, büyüklük ve hissedilir kural. Ücretsiz katmanda
    /// yarıçap 50 km'ye kırpılır.
    private static let presets: [Preset] = [
        Preset(id: "near", symbol: "figure.walk", radiusKm: 25, minMagnitude: 2.5, feltIntensity: nil),
        Preset(id: "city", symbol: "building.2", radiusKm: 50, minMagnitude: 3.0, feltIntensity: 4),
        Preset(id: "region", symbol: "map", radiusKm: 150, minMagnitude: 4.0, feltIntensity: 4)
    ]

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(Self.presets) { preset in
                let radius = min(preset.radiusKm, maxRadiusKm)
                let selected = draft.radiusKm == radius && draft.minMagnitude == preset.minMagnitude
                    && draft.feltIntensity == preset.feltIntensity
                Button {
                    SismikDesign.touchFeedback()
                    withAnimation(reduceMotion ? nil : SismikDesign.Motion.rowSpring) {
                        draft.radiusKm = radius
                        draft.minMagnitude = preset.minMagnitude
                        draft.feltIntensity = preset.feltIntensity
                        if let critical = draft.criticalMagnitude, critical < preset.minMagnitude {
                            draft.criticalMagnitude = NotificationPlace.clampedCritical(critical, minMagnitude: preset.minMagnitude)
                        }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: preset.symbol)
                            .font(.subheadline.weight(.semibold))
                        Text(L("places.preset.\(preset.id)"))
                            .font(.caption.weight(.semibold))
                        Text(verbatim: "\(Int(radius)) km · M\(preset.minMagnitude.formatted(.number.precision(.fractionLength(1))))+")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .foregroundStyle(selected ? Color.appAction : .primary)
                    .background(selected ? Color.appAction.opacity(0.12) : Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Color.appAction : .clear, lineWidth: 1.5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Hissedilir depremler

    /// Sabit yarıçapın eksiğini kapatır: uzaktaki güçlü deprem bu yerde
    /// hissedilecekse de bildirim gelir; yakındaki ama hissedilmeyecek küçük
    /// deprem için büyüklük eşiği yine geçerlidir.
    private var feltSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { draft.feltIntensity != nil },
                set: { isOn in
                    withAnimation(reduceMotion ? nil : SismikDesign.Motion.rowSpring) {
                        draft.feltIntensity = isOn ? 4 : nil
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("places.felt.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(L("places.felt.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appAction)

            if let intensity = draft.feltIntensity {
                Picker(L("places.felt.level"), selection: Binding(
                    get: { intensity },
                    set: { draft.feltIntensity = $0 }
                )) {
                    ForEach(NotificationPlace.feltIntensityOptions, id: \.self) { level in
                        Text(L("places.felt.level.\(level)")).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(L("places.felt.level.\(intensity).detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L("places.felt.section"))
        } footer: {
            Text(L("places.felt.footer"))
        }
    }

    private static func dotSize(_ magnitude: Double) -> CGFloat {
        CGFloat(min(16, max(6, magnitude * 2.4)))
    }

    /// Simge seçilince adı da yazılır ("Ev", "İş", "Aile"…). Kullanıcının
    /// kendi yazdığı ad korunur; yalnızca boş ad, haritadan önerilen ad ya da
    /// önceki simgenin adı değiştirilir. "Diğer" ad olarak anlamsız: yazılmaz.
    /// Simge adı seçildikten sonra harita önerisi onu ezmez.
    private func applyIconName(from oldIcon: PlaceIcon, to newIcon: PlaceIcon) {
        guard newIcon != .other else { return }
        let current = draft.name.trimmingCharacters(in: .whitespaces)
        let iconNames = Set(PlaceIcon.allCases.map(\.displayName))
        let replaceable = current.isEmpty || !nameEditedByUser || iconNames.contains(current)
            || current == oldIcon.displayName
        guard replaceable else { return }
        geocodeTask?.cancel()
        draft.name = String(newIcon.displayName.prefix(NotificationPlace.maxNameLength))
        nameEditedByUser = true
    }

    /// Ad boşsa (ya da önceki öneriyse) pinin bulunduğu yerin adını önerir.
    private func suggestNameIfNeeded() {
        guard !nameEditedByUser else { return }
        geocodeTask?.cancel()
        let coordinate = draft.coordinate
        geocodeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let name = await Self.placeName(at: coordinate), !Task.isCancelled,
                  !nameEditedByUser else { return }
            draft.name = String(name.prefix(NotificationPlace.maxNameLength))
        }
    }

    private static func placeName(at coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            return item.addressRepresentations?.cityName ?? item.name
        } else {
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            return placemark?.subLocality ?? placemark?.locality ?? placemark?.administrativeArea
        }
    }

    // MARK: - Kritik uyarı

    private static let criticalRed = Color(red: 0.80, green: 0.10, blue: 0.12)

    /// Kritik uyarı yer başına bir tercihtir: kapalıyken bu yerin hiçbir
    /// bildirimi sessiz modu aşmaz. Açıldığında varsayılan eşik M5.0 (ya da
    /// yerin bildirim eşiği daha yüksekse o).
    private var criticalSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { draft.criticalMagnitude != nil },
                set: { isOn in
                    withAnimation(reduceMotion ? nil : SismikDesign.Motion.rowSpring) {
                        draft.criticalMagnitude = isOn
                            ? NotificationPlace.clampedCritical(5.0, minMagnitude: draft.minMagnitude)
                            : nil
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("places.editor.critical.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(L("places.editor.critical.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Self.criticalRed)

            if let critical = draft.criticalMagnitude {
                slider(
                    title: L("places.editor.critical.threshold"),
                    value: "M \(critical.formatted(.number.precision(.fractionLength(1))))+",
                    tint: Self.criticalRed,
                    binding: Binding(
                        get: { draft.criticalMagnitude ?? critical },
                        set: { draft.criticalMagnitude = NotificationPlace.clampedCritical($0, minMagnitude: draft.minMagnitude) }
                    ),
                    range: max(NotificationPlace.criticalMagnitudeFloor, draft.minMagnitude)...NotificationPlace.criticalMagnitudeCeiling,
                    step: 0.5
                )

                if criticalSetting != .enabled {
                    criticalPermissionHint
                }
            }
        } footer: {
            Text(L("places.editor.critical.footer"))
        }
        .task { criticalSetting = await NotificationManager.shared.criticalAlertSetting() }
    }

    /// Eşik seçildi ama iOS kritik uyarı iznini vermemiş: bildirim normal sesle
    /// gelir. Sorulmadıysa izin istenir, reddedildiyse Ayarlar açılır.
    private var criticalPermissionHint: some View {
        let deniedBefore = criticalAlertRequested && criticalSetting != .enabled
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Self.criticalRed)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("places.editor.critical.permission"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L(deniedBefore ? "open.settings" : "permissions.critical.enable")) {
                    if deniedBefore {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                        return
                    }
                    Task { @MainActor in
                        criticalAlertRequested = true
                        _ = await NotificationManager.shared.requestAuthorization(includeCriticalAlert: true)
                        criticalSetting = await NotificationManager.shared.criticalAlertSetting()
                        await NotificationManager.shared.refreshCriticalAlertState()
                    }
                }
                .font(.caption.weight(.semibold))
                .tint(Color.appAction)
            }
        }
        .padding(.vertical, 2)
    }

    private func slider(
        title: String, value: String, tint: Color,
        binding: Binding<Double>, range: ClosedRange<Double>, step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            Slider(value: binding, in: range, step: step).tint(Color.appAction)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Davranış

    /// Daire hero'nun ~%62'sini kaplasın: yarıçap değişimi görünür olsun ama
    /// çevre de görünsün.
    private static func region(for place: NotificationPlace) -> MKCoordinateRegion {
        let span = place.radiusKm * 1000 * 3.2
        return MKCoordinateRegion(
            center: place.coordinate,
            latitudinalMeters: span,
            longitudinalMeters: span
        )
    }

    private func prepare() async {
        // Arşiv bir kez okunur ve ajans kopyaları bir kez ayıklanır: tahmin
        // ve haritadaki noktalar aynı depremi dört kez saymaz.
        let loaded = await QuakeCache.shared.loadMapArchive()
        archive = await Task.detached(priority: .userInitiated) {
            AftershockSequence.deduplicatedAgencyCopies(loaded)
        }.value
        if !isNew { nameEditedByUser = true }
        await requestLocationIfNeeded()
        scheduleEstimate()
    }

    private func requestLocationIfNeeded() async {
        guard isNew else { return }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            guard await LocationManager.servicesEnabled() else {
                showLocationServicesOff = true
                return
            }
            locationManager.requestPermission()
        case .denied, .restricted:
            break
        default:
            locationManager.requestLocation()
            if !draft.hasValidCoordinate, let coordinate = LocationManager.cachedCoordinate {
                draft.latitude = coordinate.latitude
                draft.longitude = coordinate.longitude
                camera = .region(Self.region(for: draft))
            }
        }
    }

    private func centerOnUser() {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            showLocationDenied = true
            return
        case .notDetermined:
            locationManager.requestPermission()
            return
        default:
            break
        }
        guard let coordinate = LocationManager.cachedCoordinate else {
            locationManager.requestLocation()
            return
        }
        draft.latitude = coordinate.latitude
        draft.longitude = coordinate.longitude
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            camera = .region(Self.region(for: draft))
        }
        scheduleEstimate()
    }

    /// Tahmin, kaydırıcının her adımında değil; 250 ms sessizlikten sonra bir
    /// kez ve önceden yüklenmiş arşiv üzerinden hesaplanır.
    private func scheduleEstimate() {
        estimateTask?.cancel()
        estimateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await recomputeEstimate()
        }
    }

    private func recomputeEstimate() async {
        guard draft.hasValidCoordinate, !archive.isEmpty else {
            estimate = nil
            return
        }
        let place = draft
        let quakes = archive
        let since = Date().addingTimeInterval(-30 * 86_400)
        let matched = await Task.detached(priority: .userInitiated) {
            NotificationPlacesStore.matchedQuakes(for: place, in: quakes, since: since)
        }.value
        guard !Task.isCancelled else { return }
        estimate = matched.count
        // Haritada en fazla 150 nokta (en büyükler).
        matchedQuakes = Array(matched.sorted { $0.magnitude > $1.magnitude }.prefix(150))
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ text: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            results = Array(response.mapItems.prefix(8))
        } catch {
            guard !Task.isCancelled else { return }
            results = []
        }
        isSearching = false
    }

    private func select(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        draft.latitude = coordinate.latitude
        draft.longitude = coordinate.longitude
        if draft.kind == .current { draft.kind = .pinned }
        if !nameEditedByUser, let name = item.name {
            draft.name = String(name.prefix(NotificationPlace.maxNameLength))
        }
        results = []
        query = ""
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            camera = .region(Self.region(for: draft))
        }
        scheduleEstimate()
    }

    private static func subtitle(for item: MKMapItem) -> String? {
        let placemark = item.placemark
        let parts = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .filter { $0 != item.name }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
