import CoreLocation
import SwiftUI

// MARK: - Beni Nasıl Etkiler?
//
// Depremin kullanıcının konumunda ve takip ettiği yerlerde (ev, iş, aile)
// tahmini sarsıntısı. Sırayla: ne kadar sarsıldım → ne yapmalıyım → yerlerim
// → sarsıntı ne zaman ulaştı → teknik ayrıntılar (katlanır). Şiddet varsa
// USGS ShakeMap ızgarasından, yoksa büyüklük–derinlik–uzaklık modelinden gelir.

/// Kullanıcının etkisi hesaplanan bir noktası: konumu ya da kayıtlı yeri.
private struct ImpactPoint: Identifiable {
    let id: String
    let name: String
    let icon: PlaceIcon?
    let location: CLLocation
    let isCurrentLocation: Bool
}

/// Etki hesabı: ShakeMap varsa ölçülen ızgara, yoksa model.
private struct ImpactEstimator {
    let earthquake: Earthquake
    let impactData: SeismicImpactData?

    func distanceKm(_ location: CLLocation) -> Double {
        earthquake.clLocation.distance(from: location) / 1_000
    }

    func intensity(at location: CLLocation) -> Double {
        if let measured = impactData?.intensity(at: location.coordinate) { return measured }
        return SeismicImpactModel(earthquake: earthquake).estimatedMMI(atEpicentralDistance: distanceKm(location))
    }

    func usesShakeMap(at location: CLLocation) -> Bool {
        impactData?.intensity(at: location.coordinate) != nil
    }

    /// Takip edilen yerler (etkin olanlar). Konum yoksa "Bulunduğum yer"in
    /// son bilinen koordinatı da bir yer olarak kullanılır.
    @MainActor
    static func places(includingCurrent: Bool) -> [ImpactPoint] {
        NotificationPlacesStore.shared.activePlaces
            .filter { includingCurrent || $0.kind != .current }
            .map { place in
                let name = place.name.isEmpty
                    ? (place.kind == .current ? L("places.currentLocation") : place.icon.displayName)
                    : place.name
                return ImpactPoint(id: place.id, name: name, icon: place.icon,
                                   location: CLLocation(latitude: place.latitude, longitude: place.longitude),
                                   isCurrentLocation: place.kind == .current)
            }
    }
}

private func distanceText(_ kilometers: Double) -> String {
    kilometers < 1 ? "\(Int((kilometers * 1_000).rounded())) m" : kilometers.kmText
}

// MARK: - Detaydaki bağlantı kartı

struct PersonalImpactLinkCard: View {
    let earthquake: Earthquake
    let impactData: SeismicImpactData?
    let userLocation: CLLocation?

    var body: some View {
        let estimator = ImpactEstimator(earthquake: earthquake, impactData: impactData)
        let point = primaryPoint
        let value = point.map { estimator.intensity(at: $0.location) } ?? 0
        let descriptor = SeismicIntensityDescriptor(value: value)
        NavigationLink {
            PersonalImpactView(earthquake: earthquake, impactData: impactData)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "location.viewfinder")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(point == nil ? Color.appAction : descriptor.color)
                    .frame(width: 48, height: 48)
                    .background((point == nil ? Color.appAction : descriptor.color).opacity(0.14), in: .rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L("onboarding.shakemap.badge"))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                        if point != nil {
                            Text("MMI \(descriptor.roman)")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(descriptor.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(descriptor.color.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(point.map { summary(for: $0, value: value, estimator: estimator) } ?? L("pi.link.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(.rect)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                    .stroke((point == nil ? Color.appAction : descriptor.color).opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.sismikPressable)
        .accessibilityHint(L("pi.link.hint"))
    }

    /// Konum varsa konum; yoksa en güçlü sarsılan takip edilen yer.
    private var primaryPoint: ImpactPoint? {
        if let userLocation {
            return ImpactPoint(id: "me", name: L("places.currentLocation"), icon: nil, location: userLocation, isCurrentLocation: true)
        }
        let estimator = ImpactEstimator(earthquake: earthquake, impactData: impactData)
        return ImpactEstimator.places(includingCurrent: true)
            .max { estimator.intensity(at: $0.location) < estimator.intensity(at: $1.location) }
    }

    private func summary(for point: ImpactPoint, value: Double, estimator: ImpactEstimator) -> String {
        let distance = distanceText(estimator.distanceKm(point.location))
        let descriptor = SeismicIntensityDescriptor(value: value)
        let prefix = userLocation == nil ? "\(point.name) · " : ""
        if value < 1 { return prefix + L("pi.summary.notFelt", distance) }
        return prefix + L("pi.summary", distance, descriptor.title())
    }
}

// MARK: - Ekran

struct PersonalImpactView: View {
    let earthquake: Earthquake
    let impactData: SeismicImpactData?

    @Environment(LocationManager.self) private var locationManager
    @State private var safetyEvent: StrongQuakeMonitor.Event?
    @State private var showsTechnical = false

    private var estimator: ImpactEstimator { ImpactEstimator(earthquake: earthquake, impactData: impactData) }

    var body: some View {
        let location = locationManager.location
        let places = ImpactEstimator.places(includingCurrent: location == nil)
        // Ana nokta: konum; yoksa en güçlü sarsılan yer.
        let primary: ImpactPoint? = location.map {
            ImpactPoint(id: "me", name: L("places.currentLocation"), icon: nil, location: $0, isCurrentLocation: true)
        } ?? places.max { estimator.intensity(at: $0.location) < estimator.intensity(at: $1.location) }

        ScrollView {
            VStack(spacing: 16) {
                if let primary {
                    intensityHero(primary)
                    actionCard(primary)
                } else {
                    locationRequiredCard
                }

                let others = places.filter { $0.id != primary?.id }
                if !others.isEmpty {
                    placesCard(others)
                }

                if let primary {
                    metricsCard(primary.location)
                    timingCard(primary.location)
                    technicalSection(primary.location)
                }

                limitationCard
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("onboarding.shakemap.badge"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if locationManager.location == nil {
                locationManager.requestLocation()
            }
        }
        .fullScreenCover(item: $safetyEvent) { event in
            QuakeResponseView(
                event: event,
                onOpenDetail: { _ in safetyEvent = nil },
                onClose: { safetyEvent = nil }
            )
        }
    }

    // MARK: Şiddet

    private func intensityHero(_ point: ImpactPoint) -> some View {
        let value = estimator.intensity(at: point.location)
        let descriptor = SeismicIntensityDescriptor(value: value)
        let measured = estimator.usesShakeMap(at: point.location)
        return VStack(spacing: 12) {
            Text(point.isCurrentLocation && point.id == "me" ? L("pi.hero.title") : L("pi.hero.titlePlace", point.name))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("MMI")
                    .font(.headline.weight(.bold))
                Text(value.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(.largeTitle, design: .rounded, weight: .black).monospacedDigit())
            }
            .foregroundStyle(descriptor.color)

            Text("\(descriptor.roman) · \(descriptor.title())")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            Text(descriptor.description())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            IntensityScaleBar(value: value)
                .padding(.top, 4)

            HStack(spacing: 5) {
                Image(systemName: measured ? "checkmark.seal.fill" : "function")
                Text(L(measured ? "pi.source.shakemap" : "pi.source.model"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(measured ? Color.brandGreen : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(descriptor.color.opacity(0.10), in: .rect(cornerRadius: SismikDesign.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                .stroke(descriptor.color.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Ne yapmalısın?

    private func actionCard(_ point: ImpactPoint) -> some View {
        let value = estimator.intensity(at: point.location)
        let key: String
        let icon: String
        let tint: Color
        switch value {
        case ..<2.5: (key, icon, tint) = ("pi.action.none", "checkmark.circle.fill", .brandGreen)
        case ..<4.5: (key, icon, tint) = ("pi.action.light", "hand.raised.fill", .teal)
        case ..<6: (key, icon, tint) = ("pi.action.moderate", "exclamationmark.circle.fill", .orange)
        default: (key, icon, tint) = ("pi.action.strong", "exclamationmark.triangle.fill", .red)
        }
        let showsSteps = value >= 4.5
        return VStack(alignment: .leading, spacing: 12) {
            Label(L("pi.action.title"), systemImage: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
            Text(L(key))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if showsSteps {
                Button {
                    safetyEvent = StrongQuakeMonitor.Event(
                        quake: earthquake,
                        distanceKm: estimator.distanceKm(point.location),
                        placeName: point.id == "me" ? nil : point.name
                    )
                } label: {
                    Label(L("pi.action.steps"), systemImage: "list.bullet.clipboard.fill")
                }
                .buttonStyle(.sismikPrimary(height: 46, tint: tint))

                Label(L("pi.action.authorities"), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }

    // MARK: Yerlerin

    private func placesCard(_ places: [ImpactPoint]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("pi.places.title"), systemImage: "mappin.and.ellipse")
                .font(.headline.weight(.bold))

            VStack(spacing: 0) {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    if index > 0 { Divider().padding(.leading, 44) }
                    placeRow(place)
                }
            }

            Text(L("pi.places.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }

    private func placeRow(_ place: ImpactPoint) -> some View {
        let value = estimator.intensity(at: place.location)
        let descriptor = SeismicIntensityDescriptor(value: value)
        return HStack(spacing: 12) {
            if let icon = place.icon {
                PlaceIconBadge(icon: icon, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(distanceText(estimator.distanceKm(place.location)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value < 1 ? "—" : "MMI \(descriptor.roman)")
                    .font(.subheadline.weight(.black).monospacedDigit())
                    .foregroundStyle(descriptor.color)
                Text(descriptor.title())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: Uzaklık

    private func metricsCard(_ location: CLLocation) -> some View {
        let epicentral = estimator.distanceKm(location)
        let hypocentral = hypot(epicentral, max(0, earthquake.depth))
        return HStack(spacing: 0) {
            metric(title: L("pi.metrics.epicenter"), value: distanceText(epicentral), icon: "location.fill", color: .brandOrange)
            Divider().frame(height: 56)
            metric(title: L("pi.metrics.hypocenter"), value: distanceText(hypocentral), icon: "arrow.down.forward", color: .blue)
            Divider().frame(height: 56)
            metric(title: L("pi.metrics.depth"), value: distanceText(earthquake.depth), icon: "arrow.down.to.line.compact", color: .teal)
        }
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }

    private func metric(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body.weight(.bold))
                .foregroundStyle(color)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Dalgalar

    /// Saat yerine "depremden kaç saniye sonra": kullanıcı için anlamlı olan
    /// fark. İlk titreşim (P) ile ana sarsıntı (S) arasındaki süre, erken
    /// uyarının neden mümkün olduğunu da anlatır.
    private func timingCard(_ location: CLLocation) -> some View {
        let arrivals = SeismicImpactModel(earthquake: earthquake).waveArrivals(atEpicentralDistance: estimator.distanceKm(location))
        let gap = max(0, arrivals.sWave.travelSeconds - arrivals.pWave.travelSeconds)
        return VStack(alignment: .leading, spacing: 12) {
            Label(L("pi.timing.title"), systemImage: "timer")
                .font(.headline.weight(.bold))

            HStack(spacing: 8) {
                waveMetric(name: L("pi.timing.p"), seconds: arrivals.pWave.travelSeconds, date: arrivals.pWave.arrivalDate, color: .blue)
                waveMetric(name: L("pi.timing.s"), seconds: arrivals.sWave.travelSeconds, date: arrivals.sWave.arrivalDate, color: .brandOrange)
                waveMetric(name: L("pi.timing.surface"), seconds: arrivals.surfaceWave.travelSeconds, date: arrivals.surfaceWave.arrivalDate, color: .purple)
            }

            Text(L("pi.timing.gap", gap.formatted(.number.precision(.fractionLength(0)))))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }

    private func waveMetric(name: String, seconds: Double, date: Date, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(L("pi.timing.after", seconds.formatted(.number.precision(.fractionLength(0)))))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(date.formatted(.dateTime.hour().minute().second().locale(AppLanguage.currentLocale)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.10), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    // MARK: Teknik ayrıntılar (katlanır)

    private func technicalSection(_ location: CLLocation) -> some View {
        let model = SeismicImpactModel(earthquake: earthquake)
        let distance = estimator.distanceKm(location)
        let pga = model.pgaG(atEpicentralDistance: distance) * 100
        let pgv = model.pgvCmPerSec(atEpicentralDistance: distance)
        let velocity = model.waveArrivals(atEpicentralDistance: distance).velocityModel
        let measured = estimator.usesShakeMap(at: location)
        return DisclosureGroup(isExpanded: $showsTechnical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    technicalValue(title: L("pi.gm.pga"), value: String(format: "%%%.2fg", pga), color: .brandOrange)
                    technicalValue(title: L("pi.gm.pgv"), value: String(format: "%.1f cm/s", pgv), color: .blue)
                }
                Text(L("pi.gm.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text(L("pi.velocity.note", velocity.sourceName,
                       velocity.vpCrust.formatted(.number.precision(.fractionLength(2))),
                       velocity.vsCrust.formatted(.number.precision(.fractionLength(2)))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack {
                    Label(L("pi.confidence.title"), systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text(L(measured ? "pi.confidence.high" : "pi.confidence.limited"))
                        .font(.caption.weight(.black))
                        .foregroundStyle(measured ? Color.brandGreen : .orange)
                }
                Text(L(measured ? "pi.confidence.high.body" : "pi.confidence.limited.body"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        } label: {
            Label(L("pi.tech.title"), systemImage: "waveform.path.ecg")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
        }
        .tint(.secondary)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }

    private func technicalValue(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    // MARK: Konum yok

    private var locationRequiredCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L("pi.location.title"))
                .font(.title3.weight(.bold))
            Text(L("pi.location.body"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                locationManager.requestPermission()
                locationManager.requestLocation()
            } label: {
                Label(L("pi.location.button"), systemImage: "location.fill")
            }
            .buttonStyle(.sismikPrimary)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: SismikDesign.Radius.card))
    }

    private var limitationCard: some View {
        Label(L("pi.limitation"), systemImage: "info.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08), in: .rect(cornerRadius: 16))
    }
}

/// I–X şiddet ölçeği; kullanıcının değeri üzerinde işaretli. Rengin ne
/// söylediği ve değerin ölçekteki yeri tek bakışta görülür.
private struct IntensityScaleBar: View {
    let value: Double

    private let levels = Array(1...10)

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let clamped = min(10, max(1, value))
                let x = (clamped - 0.5) / 10 * width
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 2) {
                        ForEach(levels, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(SeismicIntensityDescriptor(value: Double(level)).color.opacity(Double(level) <= value.rounded() ? 0.95 : 0.35))
                        }
                    }
                    .frame(height: 10)
                    .padding(.top, 8)

                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.primary)
                        .position(x: x, y: 3)
                        .opacity(value >= 1 ? 1 : 0)
                }
            }
            .frame(height: 18)

            HStack {
                Text("I")
                Spacer()
                Text("V")
                Spacer()
                Text("X")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}
