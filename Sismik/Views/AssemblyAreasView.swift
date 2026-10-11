import SwiftUI
import MapKit

/// En yakın toplanma alanları ve temel sağlık noktaları.
///
/// Düzen Apple Haritalar'ın dilini izler: harita tam ekran, üstte tek satır
/// cam arama çubuğu ve kategori çipleri, altta sürüklenebilir bir panel.
/// Panel sistem sayfası gibi davranır; üç yüksekliği var — kısa (yalnızca
/// özet), yarım (liste) ve tam (uzun liste). Bir noktaya dokununca panel
/// iner ve nokta ayrı bir kartta açılır.
struct AssemblyAreasView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = AssemblyAreasViewModel()
    @Environment(LocationManager.self) private var locationManager

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selected: AssemblyArea?
    @State private var satellite = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var selectedCategories = Set(EmergencyPlaceCategory.allCases)
    @State private var filterFeedbackTrigger = 0
    @State private var filterReloadTask: Task<Void, Never>?
    @State private var showLocationDeniedAlert = false
    @State private var showLocationServicesOffAlert = false
    @State private var detent: AssemblyPanelDetent = .half
    @State private var topBarHeight: CGFloat = 120

    // MARK: Favoriler
    private let savedPlaces = SavedPlacesStore.shared
    @State private var showFavorites = false
    @State private var showFavoriteLimitAlert = false
    /// Pusula ekranı — alttan açılan bir kart değil, kendi sayfası olarak
    /// push edilir: kullanıcı bu ekranı elinde tutarak yürüyecek, kazara
    /// yapılan bir aşağı kaydırma onu kapatmamalı.
    @State private var offlineTarget: AssemblyArea?
    @State private var showIntro = false

    private var motion: Animation? { reduceMotion ? nil : SismikDesign.Motion.entranceSpring }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    map

                    VStack(spacing: 10) {
                        topBar
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topBarHeight = $0 }
                        mapButtons
                            // Tam panelde düğmeler panelin altında kalır.
                            .opacity(detent == .full ? 0 : 1)
                    }
                    .sismikContentWidth(compact: .infinity, regular: 580)

                    Group {
                        if let area = selected {
                            // Seçilen nokta eskisi gibi ayrı bir kartta;
                            // liste paneli o sırada aşağı çekilir.
                            SelectedPlaceCard(onDismiss: { selected = nil }) {
                                selectedCardContent(area)
                            }
                            .id(area.id)
                            .transition(.move(edge: .bottom))
                        } else {
                            AssemblyPanel(
                                detent: $detent,
                                heights: panelHeights(in: proxy.size),
                                onInteraction: { searchFocused = false },
                                header: { listHeader },
                                content: { listContent }
                            )
                            .transition(.move(edge: .bottom))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .sismikContentWidth(compact: .infinity, regular: 580)
                    .animation(motion, value: selected)
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if locationManager.authorizationStatus == .notDetermined,
                   await LocationManager.servicesEnabled() {
                    locationManager.requestPermission()
                }
                locationManager.requestLocation()
                if viewModel.areas.isEmpty { await reload() }
            }
            .alert(L("Konum İzni Gerekli"),
                   isPresented: $showLocationDeniedAlert) {
                Button(L("open.settings")) { openSystemSettings() }
                Button(L("İptal"), role: .cancel) {}
            } message: {
                Text(L("Sana en yakın toplanma alanlarını gösterebilmek için iOS Ayarlar'dan Sismik'e konum erişimi ver."))
            }
            .alert(L("Konum Servisleri Kapalı"),
                   isPresented: $showLocationServicesOffAlert) {
                Button(L("open.settings")) { openSystemSettings() }
                Button(L("İptal"), role: .cancel) {}
            } message: {
                Text(L("Cihazın Konum Servisleri kapalı. Ayarlar > Gizlilik ve Güvenlik > Konum Servisleri'nden açabilirsin."))
            }
            .onChange(of: locationManager.location?.coordinate.latitude) { oldValue, newValue in
                guard oldValue == nil, newValue != nil else { return }
                Task { await reload() }
            }
            // Bir nokta seçilince klavye kapanır; kart panelin yerini alır.
            .onChange(of: selected) { _, newValue in
                if newValue != nil { searchFocused = false }
            }
            // Arama yazılırken liste paneli klavyeye yer açar.
            .onChange(of: searchFocused) { _, focused in
                if focused, detent == .full { withAnimation(motion) { detent = .half } }
            }
            .sensoryFeedback(.selection, trigger: filterFeedbackTrigger)
            .sensoryFeedback(.selection, trigger: detent)
            .onDisappear { filterReloadTask?.cancel() }
            .sheet(isPresented: $showFavorites) {
                SavedPlacesSheet(origin: locationManager.location) { area in
                    focus(on: area)
                }
            }
            .navigationDestination(item: $offlineTarget) { area in
                OfflineDirectionsView(
                    name: area.name,
                    address: area.address,
                    coordinate: area.coordinate
                )
            }
            .alert(L("favorites.limit.title"),
                   isPresented: $showFavoriteLimitAlert) {
                Button(L("common.close"), role: .cancel) {}
            } message: {
                Text(L("favorites.limit.message", SavedPlacesStore.limit))
            }
        }
        // Tanıtım kartı NavigationStack'in ÜSTÜNDE: arkadaki haritayı ve
        // araç çubuğunu da karartarak dikkati kendine topluyor.
        .screenIntro(.assemblyAreas, isPresented: $showIntro)
    }

    /// Panelin üç yüksekliği. Tam panel arama çubuğunu örtmez.
    private func panelHeights(in size: CGSize) -> AssemblyPanelHeights {
        let full = max(320, size.height - topBarHeight - 18)
        return AssemblyPanelHeights(
            peek: 86,
            half: min(full, max(300, size.height * 0.44)),
            full: full
        )
    }

    // MARK: - Harita

    private var map: some View {
        AssemblyAreasMapView(
            cameraPosition: $cameraPosition,
            selected: $selected,
            areas: viewModel.areas,
            satellite: satellite
        )
        .onChange(of: viewModel.searchCenter?.latitude) { _, _ in focusCamera() }
        // Haritaya dokunmak klavyeyi kapatır (işaret seçimini engellemeden).
        .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
    }

    // MARK: - Üst çubuk: arama + kategori çipleri

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(L("assembly.search.placeholder"), text: $searchQuery)
                        .font(.subheadline)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .onSubmit { triggerSearch() }
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            Task { await reload() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("common.close"))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .sismikGlassChip(in: Capsule(), tint: .brandOrange, selected: false)
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)

                if searchFocused {
                    // Sistem arama çubuğundaki gibi: klavyeyi kapatır, yazılanı
                    // korur. Eskiden aramadan çıkmanın yolu yoktu.
                    Button(L("İptal")) { searchFocused = false }
                        .font(.body)
                        .foregroundStyle(Color.brandOrange)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    circleButton(
                        icon: savedPlaces.places.isEmpty ? "star" : "star.fill",
                        tint: savedPlaces.places.isEmpty ? .primary : .brandOrange,
                        label: L("favorites.title")
                    ) { showFavorites = true }

                    circleButton(icon: "questionmark", tint: .primary, label: L("intro.howItWorks")) {
                        showIntro = true
                    }
                }
            }
            .padding(.horizontal, 16)
            .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: searchFocused)

            PlaceCategoryFilter(
                selection: $selectedCategories,
                onSelectionChanged: {
                    filterFeedbackTrigger += 1
                    selected = nil
                    filterReloadTask?.cancel()
                    let categories = selectedCategories
                    filterReloadTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        await viewModel.reloadCurrent(categories: categories)
                    }
                }
            )
        }
        .padding(.top, 8)
    }

    private var mapButtons: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                MapModeButton(satellite: $satellite)
                locateButton
            }
            .padding(.trailing, 16)
        }
    }

    private func circleButton(icon: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .sismikGlassChip(in: Circle(), tint: .brandOrange, selected: false)
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        }
        .buttonStyle(.sismikPressable)
        .accessibilityLabel(label)
    }

    private var locateButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if locationManager.location == nil {
                requestLocationAccess()
            } else {
                recenterOnUser()
            }
        } label: {
            // Harita modu düğmesiyle aynı cam daire (uygulamanın harita dili).
            Image(systemName: locationManager.location != nil ? "location.fill" : "location.slash.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(locationManager.location != nil ? Color.brandOrange : .secondary)
                .frame(width: 44, height: 44)
                .sismikGlassChip(in: Circle(), tint: .brandOrange, selected: false)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .buttonStyle(.sismikPressable)
        .accessibilityLabel(L("map.recenter"))
    }

    private func triggerSearch() {
        searchFocused = false
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        selected = nil
        Task {
            await viewModel.searchRegion(query: searchQuery, categories: selectedCategories)
            withAnimation(motion) { detent = .half }
        }
    }

    // MARK: - Panel başlığı (her yükseklikte görünür)

    private var listHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.headline.weight(.semibold))
                .foregroundStyle(statusTint)
                .frame(width: 36, height: 36)
                .background(statusTint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(L("assembly.sheet.title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Group {
                    if let error = viewModel.errorMessage, viewModel.areas.isEmpty {
                        Text(error)
                    } else if viewModel.viewState.isInitialLoading {
                        Text(L("assembly.searching"))
                    } else {
                        Text(L("assembly.sheet.summary", viewModel.areas.count, nearestDistanceText))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .monospacedDigit()
            }

            Spacer(minLength: 8)

            if viewModel.isRefreshing || viewModel.viewState.isInitialLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L("assembly.searching"))
            }
        }
    }

    private var statusSymbol: String {
        if viewModel.errorMessage != nil, viewModel.areas.isEmpty { return "exclamationmark.triangle.fill" }
        return viewModel.isShowingOfflineData ? "icloud.slash.fill" : "figure.walk"
    }

    private var statusTint: Color {
        if viewModel.errorMessage != nil, viewModel.areas.isEmpty { return .orange }
        return viewModel.isShowingOfflineData ? .orange : .brandOrange
    }

    // MARK: - Panel içeriği (yarım ve tam yükseklikte)

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if viewModel.viewState.isInitialLoading && viewModel.areas.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in placeholderRow }
                } else if viewModel.areas.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(viewModel.areas.prefix(60).enumerated()), id: \.element.id) { index, area in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            focus(on: area)
                        } label: {
                            placeRow(area)
                        }
                        .buttonStyle(.sismikPressable)
                        if index < min(viewModel.areas.count, 60) - 1 {
                            Divider().padding(.leading, 64)
                        }
                    }
                    if !viewModel.sourceLabel.isEmpty {
                        Text(String(format: L("assembly.source.format"), viewModel.sourceLabel))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 14)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        // Sistem sayfası gibi: yarım yükseklikte içerik kaymaz, sürükleme
        // sayfayı büyütür; tam yükseklikte liste kayar ve en üstte aşağı
        // çekince sayfa yarıma iner.
        .scrollDisabled(detent != .full)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
            guard detent == .full, offset < -70 else { return }
            withAnimation(motion) { detent = .half }
        }
    }

    private func placeRow(_ area: AssemblyArea) -> some View {
        HStack(spacing: 12) {
            AssemblyAreaMarker(size: 38, category: area.category)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(area.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if savedPlaces.isSaved(area) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.brandOrange)
                    }
                }
                Text([area.category.title, area.address].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let d = area.distance {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(distanceText(d))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(L("assembly.walkMinutes", walkMinutes(d)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var placeholderRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color(.tertiarySystemFill)).frame(width: 150, height: 10)
                Capsule().fill(Color(.quaternarySystemFill)).frame(width: 100, height: 8)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(viewModel.errorMessage ?? L("assembly.error.nearbyEmpty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await reload() }
            } label: {
                RetryButtonLabel(title: L("retry"))
            }
            .buttonStyle(.sismikPrimary)
            .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Seçili nokta kartı (sistem sayfası düzeni)

    private func selectedCardContent(_ area: AssemblyArea) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(area.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text([area.category.title, area.distance.map(distanceText)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                // Sistem sayfalarındaki yuvarlak kapatma düğmesi.
                Button {
                    selected = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("assembly.back"))
            }

            // Apple Haritalar'daki eylem sırası: ilk kutu dolu (ana eylem),
            // diğerleri gri zeminli.
            HStack(spacing: 8) {
                Button {
                    area.mapItem().openInMaps(launchOptions: [
                        MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
                    ])
                } label: {
                    actionTile(icon: "figure.walk", title: L("assembly.action.directions"),
                               tint: area.category.color, prominent: true)
                }
                .buttonStyle(.sismikPressable)
                .accessibilityLabel(L("assembly.directions"))

                // Çevrimdışı yön bulma: Apple Haritalar'ın rotası sunucuya
                // gider ve şebeke çöktüğünde çalışmaz; pusula ve GPS
                // tamamen cihazda çalışır.
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    offlineTarget = area
                } label: {
                    actionTile(icon: "location.north.line.fill", title: L("assembly.action.compass"),
                               tint: area.category.color, prominent: false)
                }
                .buttonStyle(.sismikPressable)
                .accessibilityLabel(L("favorites.findDirection.a11y"))

                // "Buradayım": ailene toplanma alanının adını ve harita
                // bağlantısını gönder. Şebeke zayıfken mesaj aramadan geçer.
                ShareLink(item: shareMessage(for: area)) {
                    actionTile(icon: "person.wave.2.fill", title: L("assembly.action.share"),
                               tint: area.category.color, prominent: false)
                }
                .buttonStyle(.sismikPressable)
                .accessibilityLabel(L("assembly.share.a11y"))

                favoriteTile(area)
            }

            // Bilgi satırları: sistemin gruplanmış liste görünümü.
            if area.address != nil || area.distance != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if let address = area.address {
                        infoRow(icon: "mappin.and.ellipse", title: L("assembly.info.address"), value: address)
                    }
                    if area.address != nil, area.distance != nil {
                        Divider().padding(.leading, 44)
                    }
                    if let d = area.distance {
                        infoRow(icon: "figure.walk", title: L("assembly.info.walk"),
                                value: L("assembly.walkMinutes", walkMinutes(d)))
                    }
                }
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func actionTile(icon: String, title: String, tint: Color, prominent: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Color(.tertiarySystemFill)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(.rect)
    }

    private func favoriteTile(_ area: AssemblyArea) -> some View {
        let isSaved = savedPlaces.isSaved(area)
        return Button {
            if !isSaved && savedPlaces.isFull {
                showFavoriteLimitAlert = true
                return
            }
            let added = savedPlaces.toggle(area)
            UIImpactFeedbackGenerator(style: added ? .medium : .light).impactOccurred()
        } label: {
            actionTile(icon: isSaved ? "star.fill" : "star",
                       title: L(isSaved ? "assembly.action.saved" : "assembly.action.save"),
                       tint: isSaved ? .brandOrange : area.category.color, prominent: false)
                .symbolEffect(.bounce, value: isSaved)
        }
        .buttonStyle(.sismikPressable)
        .accessibilityLabel(isSaved ? L("favorites.remove") : L("favorites.add"))
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func shareMessage(for area: AssemblyArea) -> String {
        let c = area.coordinate
        let query = area.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let link = String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=%@", c.latitude, c.longitude, query)
        return L("assembly.share.message", area.name, link)
    }

    // MARK: - Kamera

    /// Listeden ya da favorilerden gelen noktaya odaklan. Nokta panelin
    /// üstünde kalsın diye kamera biraz güneye kaydırılır.
    private func focus(on area: AssemblyArea) {
        selected = area
        let meters: CLLocationDistance = 1_400
        let spanDegrees = meters / 111_320
        withAnimation(motion) {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: area.coordinate.latitude - spanDegrees * 0.28,
                    longitude: area.coordinate.longitude
                ),
                latitudinalMeters: meters,
                longitudinalMeters: meters
            ))
        }
    }

    private func requestLocationAccess() {
        if !CLLocationManager.locationServicesEnabled() {
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

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func recenterOnUser() {
        guard let loc = locationManager.location else { return }
        withAnimation(motion) {
            cameraPosition = .region(MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 3_000,
                longitudinalMeters: 3_000))
        }
    }

    private var nearestDistanceText: String {
        guard let d = viewModel.areas.first?.distance else { return "—" }
        return distanceText(d)
    }

    private func distanceText(_ meters: CLLocationDistance) -> String {
        meters < 1000 ? String(format: L("assembly.distance.m"), Int(meters))
                      : String(format: L("assembly.distance.km"), meters / 1000)
    }

    /// Yetişkin yürüme hızı ~80 m/dk.
    private func walkMinutes(_ meters: CLLocationDistance) -> Int { max(1, Int(meters / 80)) }

    private func reload() async {
        await viewModel.load(
            userLocation: locationManager.location,
            categories: selectedCategories
        )
        focusCamera()
    }

    private func focusCamera() {
        guard let center = viewModel.searchCenter else { return }
        let nearest = viewModel.areas.first?.distance ?? 0
        let span = max(2_400, nearest * 2.4 + 800)
        // Yarım panel haritanın alt kısmını örter; merkez güneye kaydırılır.
        let shift = detent == .peek ? 0 : (span / 111_320) * 0.22
        withAnimation(motion) {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: center.latitude - shift, longitude: center.longitude),
                latitudinalMeters: span,
                longitudinalMeters: span
            ))
        }
    }
}

// MARK: - Sürüklenebilir panel

enum AssemblyPanelDetent: Hashable {
    case peek, half, full
}

struct AssemblyPanelHeights {
    let peek: CGFloat
    let half: CGFloat
    let full: CGFloat

    func height(for detent: AssemblyPanelDetent) -> CGFloat {
        switch detent {
        case .peek: peek
        case .half: half
        case .full: full
        }
    }
}

/// Sistem sayfasının (`.sheet` + `presentationDetents`) görünüm ve
/// davranışı. Gerçek sayfa sekme çubuğunu örtüp sekmeler arası geçişi
/// engellerdi; bu yüzden aynısı ekranın içinde kuruldu:
/// - iOS 26: kenarlardan içeride yüzen Liquid Glass, eşmerkezli köşe.
/// - iOS 18–25: sistem sayfa arka planı, üst köşeler yuvarlak.
/// - Tutamaç sistem ölçüsünde; yarım/kısa yükseklikte sayfanın her yerinden,
///   tam yükseklikte başlıktan sürüklenir. Bırakınca hıza göre oturur.
private struct AssemblyPanel<Header: View, Content: View>: View {
    @Binding var detent: AssemblyPanelDetent
    let heights: AssemblyPanelHeights
    var onInteraction: () -> Void = {}
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Sürükleme payı `@State`: bırakınca yükseklikle AYNI animasyonda
    /// sıfırlanır. `@GestureState` parmak kalkınca animasyonsuz sıfırlanıyor,
    /// panel bir kare eski yüksekliğe sıçrayıp sonra yeniye kayıyordu.
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false

    private var currentHeight: CGFloat {
        let base = heights.height(for: detent)
        let proposed = base - dragTranslation
        // Sınırların ötesinde lastik gibi direnir.
        if proposed > heights.full { return heights.full + (proposed - heights.full) * 0.2 }
        if proposed < heights.peek { return heights.peek - (heights.peek - proposed) * 0.2 }
        return proposed
    }

    private var snapAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                // Sistem tutamacı: 36 × 5, üçüncül etiket rengi.
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                header()
                    .padding(.horizontal, 20)
            }
            .padding(.bottom, 12)
            .contentShape(.rect)
            // Tam yükseklikte yalnızca başlık sürükler (liste kendi kayar).
            .gesture(detent == .full ? drag : nil)
            .onTapGesture { cycle() }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: L(detent == .full ? "assembly.sheet.collapse" : "assembly.sheet.expand")) { cycle() }

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(currentHeight > heights.peek + 24 ? 1 : 0)
                .allowsHitTesting(detent != .peek)
        }
        .frame(height: max(heights.peek * 0.8, currentHeight), alignment: .top)
        .frame(maxWidth: .infinity)
        .modifier(NativeSheetSurface())
        // Kısa ve yarım yükseklikte sayfanın her yerinden sürüklenir
        // (dokunuşlar satırlara geçer). Hareket tek yerden bağlı: başlıkta
        // da bağlıyken iki kez işleniyor, iki ayrı oturma animasyonu
        // birbirine karışıyordu.
        .simultaneousGesture(detent == .full ? nil : drag)
        // Parmak altında gecikmesiz izler; üst görünümdeki animasyonlar
        // sürüklenen yüksekliğe karışmaz.
        .transaction { if isDragging { $0.animation = nil } }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onInteraction()
                }
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                let predicted = heights.height(for: detent) - value.predictedEndTranslation.height
                let candidates: [AssemblyPanelDetent] = [.peek, .half, .full]
                let target = candidates.min {
                    abs(heights.height(for: $0) - predicted) < abs(heights.height(for: $1) - predicted)
                } ?? detent
                isDragging = false
                // Yükseklik ve sürükleme payı tek işlemde: panel parmağın
                // bıraktığı yerden hedefe kayar, geri sıçramaz.
                withAnimation(snapAnimation) {
                    detent = target
                    dragTranslation = 0
                }
            }
    }

    private func cycle() {
        onInteraction()
        let next: AssemblyPanelDetent = switch detent {
        case .peek: .half
        case .half: .full
        case .full: .half
        }
        withAnimation(snapAnimation) { detent = next }
    }
}

// MARK: - Sistem sayfası yüzeyi

/// Panel ve nokta kartının ortak yüzeyi (sistem sayfasının görünümü):
/// iOS 26'da kenarlardan içeride yüzen Liquid Glass, eşmerkezli köşe;
/// iOS 18–25'te sistem sayfa arka planı, üst köşeler yuvarlak ve alt
/// kenar sekme çubuğunun altına akar.
private struct NativeSheetSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background {
                    Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                }
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        } else {
            content
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.12), radius: 12, y: -1)
                        .ignoresSafeArea(edges: .bottom)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous))
        }
    }
}

/// Seçilen noktanın kartı: sistem sayfası gibi tutamaçlı, aşağı çekince
/// kapanır. Yeterince çekilmezse yerine yaylanarak döner.
private struct SelectedPlaceCard<Content: View>: View {
    var onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.top, 6)
            content()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .modifier(NativeSheetSurface())
        .offset(y: offset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    isDragging = true
                    let y = value.translation.height
                    // Aşağı serbest, yukarı dirençli.
                    offset = y > 0 ? y : y * 0.15
                }
                .onEnded { value in
                    isDragging = false
                    if value.translation.height > 90 || value.predictedEndTranslation.height > 260 {
                        onDismiss()
                    } else {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88)) { offset = 0 }
                    }
                }
        )
        .transaction { if isDragging { $0.animation = nil } }
        .accessibilityAction(.escape, onDismiss)
    }
}

// MARK: - Kategori Filtre Çipleri

private struct PlaceCategoryFilter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Set<EmergencyPlaceCategory>
    let onSelectionChanged: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EmergencyPlaceCategory.allCases) { category in
                    categoryButton(category)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private func categoryButton(_ category: EmergencyPlaceCategory) -> some View {
        let isSelected = selection.contains(category)
        return Button {
            withAnimation(reduceMotion ? nil : SismikDesign.Motion.rowSpring) {
                if isSelected {
                    guard selection.count > 1 else { return }
                    selection.remove(category)
                } else {
                    selection.insert(category)
                }
            }
            onSelectionChanged()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .font(.caption.weight(.bold))
                Text(category.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 13)
            .frame(height: 36)
            .sismikGlassChip(in: Capsule(), tint: category.color, selected: isSelected)
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(.sismikPressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Harita Bileşeni

struct AssemblyAreasMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    @Binding var selected: AssemblyArea?
    let areas: [AssemblyArea]
    let satellite: Bool

    /// SwiftUI Map her işaret için ayrı görünüm kurar; şehir merkezinde
    /// yüzlerce market/eczane kaydırmayı ağırlaştırıyordu. En yakın 150
    /// yer (liste zaten uzaklığa göre sıralı) ile seçili yer çizilir.
    private var visibleAreas: [AssemblyArea] {
        var visible = Array(areas.prefix(150))
        if let selected, !visible.contains(where: { $0.id == selected.id }) { visible.append(selected) }
        return visible
    }

    var body: some View {
        Map(position: $cameraPosition, selection: $selected) {
            UserAnnotation()
            ForEach(visibleAreas) { area in
                Marker(area.name, systemImage: area.category.symbol, coordinate: area.coordinate)
                    .tint(area.category.color)
                    .tag(area)
            }
        }
        // Düz zemin ve Apple'ın kendi yer işaretleri kapalı: 3B arazi GPU'yu
        // yoruyordu, restoran/mağaza simgeleri de toplanma işaretleriyle
        // karışıyordu. Haritadaki tek yer işareti bizimkiler.
        .mapStyle(satellite
                  ? .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
                  : .standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass() }
        .ignoresSafeArea()
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}
