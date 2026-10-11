import Charts
import CoreLocation
import SwiftUI

/// Konum Risk Profili: en yakın aktif fay, bölgedeki geçmiş büyük depremler
/// ve bina yapım döneminden bir risk özeti ve paylaşılabilir risk kartı.
/// Herkese açık (ücretsiz); hesap cihazda ve doğrudan USGS'ten yapılır.
struct LocationRiskView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seçilen konum: `nil` mevcut konum.
    @State private var selectedPlace: RiskPlace?
    @State private var profile: LocationRiskProfile?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var buildingEra: BuildingEra = .unknown


    private var targetCoordinate: CLLocationCoordinate2D? {
        selectedPlace?.coordinate ?? locationManager.location?.coordinate
    }

    private var placeTitle: String {
        selectedPlace?.name ?? L("risk.location.current")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                locationPicker

                if let profile {
                    heroCard(profile)
                    probabilityCard(profile)
                    strongestFeltCard(profile)
                    faultsCard(profile)
                    historyCard(profile)
                    recentActivityCard(profile)
                    buildingCard(profile)
                    adviceCard(profile)
                } else if targetCoordinate == nil {
                    messageCard(icon: "location.slash", text: L("risk.locationRequired"))
                } else if loadFailed {
                    VStack(spacing: 12) {
                        messageCard(icon: "wifi.exclamationmark", text: L("risk.error"))
                        Button { Task { await reload() } } label: { RetryButtonLabel(title: L("retry")) }
                            .buttonStyle(.sismikPrimary)
                    }
                } else {
                    loadingCard
                }

                disclaimer(profile?.hazardAuthority ?? .global)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("risk.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if selectedPlace == nil, locationManager.location == nil {
                locationManager.requestLocation()
            }
            buildingEra = RiskBuildingEraStore.era(for: targetCoordinate)
            await reload()
        }
        .onChange(of: locationManager.location?.coordinate.latitude) { _, _ in
            guard selectedPlace == nil, profile == nil else { return }
            Task { await reload() }
        }
        .onChange(of: buildingEra) { _, era in
            RiskBuildingEraStore.set(era, for: targetCoordinate)
            // Bina göstergesi yerel; ağa gitmeden puan güncellenir.
            if let current = profile {
                withAnimation(reduceMotion ? nil : SismikDesign.Motion.rowSpring) {
                    profile = current.with(buildingEra: era)
                }
            }
        }
    }

    // MARK: Konum seçimi

    private var availablePlaces: [RiskPlace] {
        let notificationPlaces = NotificationPlacesStore.shared.places
            .filter { $0.kind != .current }
            .map { RiskPlace(id: "n-\($0.id)", name: $0.name, coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        let savedPlaces = SavedPlacesStore.shared.places
            .map { RiskPlace(id: "s-\($0.id)", name: $0.name, coordinate: $0.coordinate) }
        return (notificationPlaces + savedPlaces).filter { !$0.name.isEmpty }
    }

    private var locationPicker: some View {
        Menu {
            Button {
                select(nil)
            } label: {
                Label(L("risk.location.current"), systemImage: "location.fill")
            }
            if !availablePlaces.isEmpty {
                Divider()
                ForEach(availablePlaces) { place in
                    Button(place.name) { select(place) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedPlace == nil ? "location.fill" : "mappin.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appAction)
                Text(placeTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.button))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("risk.location.pick"))
        .accessibilityValue(placeTitle)
    }

    private func select(_ place: RiskPlace?) {
        guard place?.id != selectedPlace?.id else { return }
        selectedPlace = place
        profile = nil
        buildingEra = RiskBuildingEraStore.era(for: targetCoordinate)
        Task { await reload() }
    }

    private func reload() async {
        guard let coordinate = targetCoordinate, !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            let result = try await LocationRiskService.profile(for: coordinate, buildingEra: buildingEra)
            withAnimation(reduceMotion ? nil : SismikDesign.Motion.entranceSpring) { profile = result }
        } catch {
            loadFailed = true
        }
    }

    // MARK: Özet

    private func heroCard(_ profile: LocationRiskProfile) -> some View {
        let color = profile.level.color
        return HStack(spacing: 18) {
            RiskGauge(score: profile.score, color: color)
                .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 6) {
                Text(profile.level.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(color)
                Text(profile.level.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .riskCardSurface(stroke: color.opacity(0.25))
        .accessibilityElement(children: .combine)
    }

    // MARK: Olasılık

    private func probabilityCard(_ profile: LocationRiskProfile) -> some View {
        RiskSection(icon: "chart.bar.fill", tint: .orange, title: L("risk.prob.title"), subtitle: L("risk.prob.subtitle")) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    ForEach([1, 10, 50], id: \.self) { years in
                        Text(String(format: L("risk.prob.years"), years))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
                ForEach([5.0, 6.0], id: \.self) { magnitude in
                    GridRow {
                        Text("M\(Int(magnitude))+")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(MagnitudeLevel(magnitude: magnitude).textColor)
                        ForEach([1.0, 10.0, 50.0], id: \.self) { years in
                            let p = profile.probability(minimumMagnitude: magnitude, years: years)
                            Text(RiskFormat.percent(p))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(RiskFormat.probabilityColor(p))
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RiskFootnote(text: L("risk.prob.footnote"))
        }
    }

    // MARK: En güçlü sarsıntı

    private func strongestFeltCard(_ profile: LocationRiskProfile) -> some View {
        RiskSection(icon: "waveform.path.ecg", tint: .red, title: L("risk.felt.title"), subtitle: L("risk.felt.subtitle")) {
            if let quake = profile.history.strongestFelt {
                let descriptor = SeismicIntensityDescriptor(value: quake.intensityHere)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(descriptor.title())
                            .font(.title3.weight(.bold))
                            .foregroundStyle(descriptor.color)
                        Spacer()
                        Text("MMI \(descriptor.roman)")
                            .font(.caption.weight(.black))
                            .foregroundStyle(descriptor.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(descriptor.color.opacity(0.12), in: Capsule())
                    }
                    Text(descriptor.description())
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(RiskFormat.quakeLine(quake))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RiskFootnote(text: L("risk.felt.footnote"))
            } else {
                RiskFootnote(text: L("risk.felt.none"))
            }
        }
    }

    // MARK: Faylar

    private func faultsCard(_ profile: LocationRiskProfile) -> some View {
        RiskSection(icon: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill",
                    tint: profile.nearestFault?.risk.color ?? .secondary,
                    title: L("risk.faults.title"), subtitle: L("risk.faults.subtitle")) {
            if profile.faults.isEmpty {
                RiskFootnote(text: L("risk.factor.fault.none"))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(profile.faults) { fault in
                        faultRow(fault)
                        if fault.id != profile.faults.last?.id { Divider() }
                    }
                }
                RiskFootnote(text: L("risk.faults.footnote"))
            }
        }
    }

    private func faultRow(_ fault: LocationRiskProfile.NearbyFault) -> some View {
        let scenario = SeismicIntensityDescriptor(value: fault.scenarioIntensity)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(RiskFormat.faultTitle(fault))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(fault.risk.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(fault.risk.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(fault.risk.color.opacity(0.12), in: Capsule())
            }
            Text(RiskFormat.faultFacts(fault))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: L("risk.faults.scenario"),
                        fault.maxMagnitude.formatted(.number.precision(.fractionLength(1))),
                        scenario.title(), scenario.roman))
                .font(.footnote)
                .foregroundStyle(scenario.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Geçmiş

    private func historyCard(_ profile: LocationRiskProfile) -> some View {
        let history = profile.history
        return RiskSection(icon: "clock.arrow.circlepath", tint: .brandOrange,
                           title: L("risk.history.title"), subtitle: L("risk.history.subtitle")) {
            HStack(spacing: 8) {
                RiskCountChip(label: "M4+", value: history.m4Since1973, caption: L("risk.history.since1973"))
                RiskCountChip(label: "M5+", value: history.m5, caption: L("risk.history.since1900"))
                RiskCountChip(label: "M6+", value: history.m6, caption: L("risk.history.since1900"))
                RiskCountChip(label: "M7+", value: history.m7, caption: L("risk.history.since1900"))
            }

            if history.m5 > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("risk.history.decades"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Chart(history.decades) { decade in
                        BarMark(
                            x: .value("decade", String(decade.start)),
                            y: .value("count", decade.count)
                        )
                        .foregroundStyle(Color.brandOrange)
                        .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            // Her 30 yılda bir etiket: 1900, 1930, … üst üste binmez.
                            if let label = value.as(String.self), let year = Int(label), year % 30 == 0 {
                                AxisValueLabel()
                            }
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(); AxisValueLabel() } }
                    .frame(height: 120)
                    .accessibilityLabel(L("risk.history.decades"))
                }
            }

            if !history.largest.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("risk.history.largest"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(history.largest) { quake in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("M\(quake.magnitude.formatted(.number.precision(.fractionLength(1))))")
                                .font(.footnote.weight(.black).monospacedDigit())
                                .foregroundStyle(MagnitudeLevel(magnitude: quake.magnitude).textColor)
                                .frame(width: 46, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(quake.place.isEmpty ? "—" : quake.place)
                                    .font(.footnote)
                                    .lineLimit(1)
                                Text(verbatim: "\(String(quake.year)) · \(String(format: L("risk.distance.away"), RiskFormat.km(quake.distanceKm)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            RiskFootnote(text: L("risk.history.footnote"))
        }
    }

    // MARK: Son etkinlik

    private func recentActivityCard(_ profile: LocationRiskProfile) -> some View {
        let history = profile.history
        let status = RiskFormat.activityStatus(profile.recentActivityRatio)
        return RiskSection(icon: "waveform", tint: status.color, title: L("risk.recent.title"), subtitle: L("risk.recent.subtitle")) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(history.m4LastYear)")
                    .font(.title2.weight(.bold).monospacedDigit())
                Text(String(format: L("risk.recent.average"),
                            history.m4YearlyAverage.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.currentLocale))))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(status.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(status.color.opacity(0.12), in: Capsule())
            }
            RiskFootnote(text: L("risk.recent.footnote"))
        }
    }

    // MARK: Bina

    private func buildingCard(_ profile: LocationRiskProfile) -> some View {
        RiskSection(icon: "building.2.fill", tint: .blue, title: L("risk.factor.building"), subtitle: L("risk.building.subtitle")) {
            Picker(L("risk.factor.building"), selection: $buildingEra) {
                ForEach(BuildingEra.allCases) { era in
                    Text(era.title).tag(era)
                }
            }
            .pickerStyle(.segmented)
            // Yönetmelik yılları ülkeye göre değişir; Türkiye dışında genel not.
            RiskFootnote(text: L(profile.isInTurkeyRegion ? "risk.building.footer" : "risk.building.footer.global"))
        }
    }

    // MARK: Öneriler ve kart

    private func adviceCard(_ profile: LocationRiskProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("risk.advice.title"), systemImage: "checkmark.shield.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.brandGreen)
            ForEach(RiskAdvice.items(for: profile), id: \.self) { key in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.brandGreen)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                    Text(L(key))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .riskCardSurface()
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(L("risk.loading"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(18)
        .riskCardSurface()
    }

    private func messageCard(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .riskCardSurface()
    }

    /// Resmî harita, konumun ülkesindeki yetkili kurumdan (Türkiye'de AFAD,
    /// ABD'de USGS…); ulusal harita yoksa GEM'in küresel haritası.
    private func disclaimer(_ authority: HazardAuthority) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("risk.disclaimer.any", authority.mapName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: authority.url) {
                Label(authority.mapName, systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
            }
            .tint(Color.appAction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

}

// MARK: - Bölüm yapı taşları

/// Risk ekranındaki her bölümün ortak kabuğu: simgeli başlık, açıklama, içerik.
struct RiskSection<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .riskCardSurface()
    }
}

struct RiskFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct RiskCountChip: View {
    let label: String
    let value: Int
    let caption: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.headline.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Risk ekranı biçimlendirmeleri (uygulama dilinin sayı ve yüzde biçimi).
enum RiskFormat {
    static func km(_ value: Double) -> String {
        value < 10
            ? value.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.currentLocale))
            : value.formatted(.number.precision(.fractionLength(0)).locale(AppLanguage.currentLocale))
    }

    static func percent(_ p: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0)).locale(AppLanguage.currentLocale)
        if p < 0.01 { return "<" + 0.01.formatted(style) }
        if p > 0.99 { return ">" + 0.99.formatted(style) }
        return p.formatted(style)
    }

    static func probabilityColor(_ p: Double) -> Color {
        switch p {
        case 0.6...: FaultRisk.high.color
        case 0.3...: FaultRisk.mediumHigh.color
        case 0.1...: FaultRisk.medium.color
        default: .brandGreen
        }
    }

    static func quakeLine(_ quake: LocationRiskProfile.HistoricQuake) -> String {
        let magnitude = quake.magnitude.formatted(.number.precision(.fractionLength(1)))
        let place = quake.place.isEmpty ? "" : " · \(quake.place)"
        return "M\(magnitude) · \(String(quake.year)) · \(String(format: L("risk.distance.away"), km(quake.distanceKm)))\(place)"
    }

    /// Adı olmayan faylar türüyle anılır ("Doğrultu atımlı fay").
    static func faultTitle(_ fault: LocationRiskProfile.NearbyFault) -> String {
        guard fault.name.isEmpty else { return fault.name }
        return fault.slipType == .unknown ? L("risk.faults.unnamed") : L("risk.faults.type.\(fault.slipType.rawValue)")
    }

    static func faultFacts(_ fault: LocationRiskProfile.NearbyFault) -> String {
        var parts = [String(format: L("risk.distance.away"), km(fault.distanceKm))]
        if fault.slipType != .unknown, !fault.name.isEmpty { parts.append(L("risk.slip.\(fault.slipType.rawValue)")) }
        if let rate = fault.slipRate, rate > 0 {
            parts.append(String(format: L("risk.faults.slipRate"),
                                rate.formatted(.number.precision(.fractionLength(rate < 10 ? 1 : 0)).locale(AppLanguage.currentLocale))))
        }
        return parts.joined(separator: " · ")
    }

    static func activityStatus(_ ratio: Double?) -> (label: String, color: Color) {
        guard let ratio else { return (L("risk.recent.rare"), .secondary) }
        switch ratio {
        case 3...: return (L("risk.recent.marked"), FaultRisk.high.color)
        case 1.5...: return (L("risk.recent.above"), FaultRisk.mediumHigh.color)
        default: return (L("risk.recent.normal"), .brandGreen)
        }
    }
}

// MARK: - Yardımcı tipler

struct RiskPlace: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Bina yapım dönemi konum başına (~1 km ızgara) saklanır: evin ve iş yerinin
/// binası farklıdır.
enum RiskBuildingEraStore {
    private static let key = "risk.buildingEra.v1"

    private static func gridKey(_ coordinate: CLLocationCoordinate2D?) -> String? {
        coordinate.map { String(format: "%.2f,%.2f", $0.latitude, $0.longitude) }
    }

    static func era(for coordinate: CLLocationCoordinate2D?) -> BuildingEra {
        guard let key = gridKey(coordinate),
              let raw = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String])?[key] else { return .unknown }
        return BuildingEra(rawValue: raw) ?? .unknown
    }

    static func set(_ era: BuildingEra, for coordinate: CLLocationCoordinate2D?) {
        guard let key = gridKey(coordinate) else { return }
        var stored = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
        stored[key] = era.rawValue
        if stored.count > 40 { stored = [key: era.rawValue] }
        UserDefaults.standard.set(stored, forKey: Self.key)
    }
}

enum RiskAdvice {
    /// Profile göre en fazla beş öneri; en önemlisi önce.
    static func items(for profile: LocationRiskProfile) -> [String] {
        var items: [String] = []
        let elevated = profile.level.rawValue >= LocationRiskProfile.Level.moderate.rawValue
        if profile.buildingEra == .before2000 || (profile.buildingEra == .unknown && elevated) {
            items.append("risk.advice.building")
        }
        if elevated || (profile.nearestFault?.distanceKm ?? .infinity) < 30 {
            items.append("risk.advice.furniture")
        }
        if (profile.recentActivityRatio ?? 0) >= 1.5 {
            // AFAD yalnızca Türkiye'de; başka yerde yerel yetkililer.
            items.append(profile.isInTurkeyRegion ? "risk.advice.recent" : "risk.advice.recent.global")
        }
        items.append("risk.advice.bag")
        // Toplanma alanları artık her ülkede (OpenStreetMap); sigorta önerisi
        // Türkiye'de zorunlu DASK, başka yerde genel konut sigortası.
        items.append("risk.advice.assembly")
        items.append(profile.isInTurkeyRegion ? "risk.advice.insurance" : "risk.advice.insurance.global")
        items.append("risk.advice.plan")
        return Array(items.prefix(5))
    }
}

extension LocationRiskProfile.Level {
    /// Fay katmanının risk renkleriyle aynı ölçek (yeşil → kırmızı).
    var color: Color {
        switch self {
        case .low: .brandGreen
        case .moderate: FaultRisk.medium.color
        case .high: FaultRisk.mediumHigh.color
        case .veryHigh: FaultRisk.high.color
        }
    }

    var title: String {
        switch self {
        case .low: L("risk.level.low")
        case .moderate: L("risk.level.moderate")
        case .high: L("risk.level.high")
        case .veryHigh: L("risk.level.veryHigh")
        }
    }

    var detail: String {
        switch self {
        case .low: L("risk.level.low.detail")
        case .moderate: L("risk.level.moderate.detail")
        case .high: L("risk.level.high.detail")
        case .veryHigh: L("risk.level.veryHigh.detail")
        }
    }
}

extension BuildingEra {
    var title: String {
        switch self {
        case .unknown: L("risk.building.unknown")
        case .before2000: L("risk.building.before2000")
        case .between2000And2018: L("risk.building.between")
        case .after2018: L("risk.building.after2018")
        }
    }
}

private extension View {
    func riskCardSurface(stroke: Color = Color.primary.opacity(0.08)) -> some View {
        background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
    }
}

/// Puan göstergesi: 0–100 arası dolan halka ve ortada puan.
struct RiskGauge: View {
    let score: Int
    let color: Color
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(100, max(0, score))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(.title, design: .rounded).weight(.heavy).monospacedDigit())
                    .foregroundStyle(color)
                Text("/100")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("risk.score"))
        .accessibilityValue("\(score)/100")
    }
}
