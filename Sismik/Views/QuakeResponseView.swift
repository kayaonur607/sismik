import CoreLocation
import SwiftUI

/// Deprem anı modu: yakında güçlü bir deprem olduktan sonra uygulama
/// açıldığında tam ekran gösterilir (bkz. `StrongQuakeMonitor`).
///
/// Sıra, o dakikalarda gerekenin sırası: güvende misin (durum paylaş / 112),
/// artçı riski, en yakın toplanma alanı, yapılacaklar. Toplanma alanı önce
/// diskteki son aramadan gelir; ağ yoksa da ekran eksiksiz çalışır.
struct QuakeResponseView: View {
    let event: StrongQuakeMonitor.Event
    let onOpenDetail: (Earthquake) -> Void
    let onClose: () -> Void

    @Environment(LocationManager.self) private var locationManager
    @State private var nearestArea: AssemblyArea?
    @State private var areaLoaded = false
    @AppStorage("response.checked") private var checkedRaw = ""

    private var quake: Earthquake { event.quake }

    private var checked: Set<String> {
        Set(checkedRaw.split(separator: ",").map(String.init))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    safetyActions
                    aftershockCard
                    assemblyCard
                    checklist
                    Button(L("response.openDetail")) { onOpenDetail(quake) }
                        .buttonStyle(.sismikSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .sismikContentWidth()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L("response.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.close"), action: onClose)
                        .font(.headline)
                }
            }
            .task { await loadNearestArea() }
        }
    }

    // MARK: Olay özeti

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(quake.magnitudeString)
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(quake.level.foregroundOnColor)
                .frame(width: 72, height: 64)
                .background(quake.magnitudeColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(quake.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(distanceText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(quake.date.relativeShort) · \(quake.date.clockTime) · \(quake.sourceTag)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var distanceText: String {
        let km = Int(event.distanceKm.rounded())
        if let name = event.placeName {
            return String(format: L("response.distance.place"), km, name)
        }
        return String(format: L("response.distance.you"), km)
    }

    // MARK: Güvende misin?

    private var safetyActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("response.safe.question"))
                .font(.title3.weight(.bold))
            HStack(spacing: 10) {
                ShareLink(item: statusText(safe: true)) {
                    Label(L("Güvendeyim"), systemImage: "checkmark.shield.fill")
                }
                .buttonStyle(.sismikPrimary(height: 52, tint: .brandGreen))

                ShareLink(item: statusText(safe: false)) {
                    Label(L("Yardım Lazım"), systemImage: "exclamationmark.shield.fill")
                }
                .buttonStyle(.sismikPrimary(height: 52, tint: .red))
            }
            if let url = EmergencyNumber.callURL {
                Link(destination: url) {
                    Label(String(format: L("response.call"), EmergencyNumber.local), systemImage: "phone.fill")
                }
                .buttonStyle(.sismikSecondary)
            }
            Text(L("response.safe.hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(safe: Bool) -> String {
        var text = safe
            ? L("Güvendeyim. Herhangi bir olumsuz durum yok, iyiyim.")
            : L("ACİL DURUM! Yardıma ihtiyacım var, güvende değilim!")
        if let loc = locationManager.location ?? LocationManager.cachedCoordinate.map({ CLLocation(latitude: $0.latitude, longitude: $0.longitude) }) {
            text += "\n" + L("Bulunduğum Konum:") + "\nhttps://maps.apple.com/?ll=\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
        }
        return text
    }

    // MARK: Artçı riski

    private var aftershockCard: some View {
        let threshold = AftershockForecast.thresholdMagnitude(forMainshock: quake.magnitude)
        let probability = AftershockForecast.probability(
            mainshockMagnitude: quake.magnitude,
            minimumMagnitude: threshold,
            elapsed: max(0, Date().timeIntervalSince(quake.date))
        )
        let percent = Int((probability * 100).rounded())
        return card {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("response.aftershock.title"), systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                Text(String(format: L("response.aftershock.value"), threshold, max(1, percent)))
                    .font(.body)
                Text(L("response.aftershock.note"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Toplanma alanı

    @ViewBuilder
    private var assemblyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("response.assembly.title"), systemImage: "figure.walk")
                    .font(.subheadline.weight(.semibold))
                if let area = nearestArea {
                    Text(area.name)
                        .font(.body.weight(.semibold))
                    if let distance = area.distance {
                        Text(distance.metersAsKmText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        OfflineDirectionsView(name: area.name, address: area.address, coordinate: area.coordinate)
                    } label: {
                        Label(L("response.assembly.directions"), systemImage: "location.north.line.fill")
                    }
                    .buttonStyle(.sismikSecondary(height: 44))
                } else {
                    Text(areaLoaded ? L("response.assembly.none") : L("response.assembly.loading"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadNearestArea() async {
        defer { areaLoaded = true }
        guard let center = locationManager.location?.coordinate ?? LocationManager.cachedCoordinate else { return }
        if let cached = await AssemblyAreaService.shared.cachedSearch(near: center, categories: [.assemblyArea]),
           let first = cached.areas.first {
            nearestArea = first
        }
        if let fresh = try? await AssemblyAreaService.shared.search(near: center, categories: [.assemblyArea]),
           let first = fresh.areas.first {
            nearestArea = first
        }
    }

    // MARK: Yapılacaklar

    private static let checklistIDs = ["exit", "gas", "power", "elevator", "shoes", "sms"]

    private var checklist: some View {
        card {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("response.checklist.title"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Self.checklistIDs, id: \.self) { id in
                    Button {
                        toggle(id)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: checked.contains(id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(checked.contains(id) ? Color.brandGreen : .secondary)
                            Text(L("response.checklist.\(id)"))
                                .foregroundStyle(checked.contains(id) ? .secondary : .primary)
                                .strikethrough(checked.contains(id))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(checked.contains(id) ? .isSelected : [])
                }
            }
        }
    }

    private func toggle(_ id: String) {
        var set = checked
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        checkedRaw = set.sorted().joined(separator: ",")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
