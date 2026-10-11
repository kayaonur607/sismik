import CoreLocation
import SwiftUI

/// Liste başındaki deprem kartı (`FeltEventCenter`): büyük olay, yakınında
/// olan ya da uzakta olup hissedilmiş olabilecek deprem. Büyüklük, yer ve
/// saat olayın GÜNCEL resmî kaydından gelir; kullanıcı kartı kapatabilir.
/// Eylemler: ayrıntılar, "Hissettim" (bildirir ve güvenlik adımlarını açar)
/// ve büyük olayda kilit ekranında canlı takip.
struct MajorEventCard: View {
    let card: FeltEventCenter.Card
    let aftershockCount: Int
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var feltCount: Int?
    @State private var hasReportedFelt = false
    /// "Hissettim"den sonra açılan güvenlik adımları (deprem anı ekranı).
    @State private var safetyEvent: StrongQuakeMonitor.Event?
    private var tracker: AftershockTracker { AftershockTracker.shared }
    private var quake: Earthquake { card.quake }

    var body: some View {
        let level = MagnitudeLevel(magnitude: quake.magnitude)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(headline, systemImage: headlineSymbol)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(level.textColor)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("feltcard.dismiss"))
            }

            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 14) {
                    Text(quake.magnitudeString)
                        .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(level.foregroundOnColor)
                        .contentTransition(.numericText())
                        .frame(width: 84, height: 72)
                        .background(level.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(quake.displayTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(quake.date.relativeShort) · \(L("depth")) \(quake.depth.depthKmText) · \(quake.sourceTag)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        // GDACS / USGS PAGER beklenen etki seviyesi.
                        if let impact = quake.impactLevel {
                            ImpactLevelBadge(level: impact)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                switch card.kind {
                case .major:
                    stat(value: "\(aftershockCount)", label: L("major.aftershocks"))
                case .nearby(let distanceKm), .felt(let distanceKm, _):
                    stat(value: "\(Int(distanceKm.rounded())) km", label: L(card.placeName == nil ? "feltcard.distance.you" : "feltcard.distance.place"))
                }
                Divider().frame(height: 30)
                stat(value: feltCount.map { $0.formatted() } ?? "—", label: L("major.felt"))
            }
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Button(action: onOpen) {
                    Text(L("major.open"))
                }
                .buttonStyle(.sismikPrimary(height: 46, tint: level.color))

                Button(action: reportFelt) {
                    Label(L(hasReportedFelt ? "feltcard.felt.done" : "feltcard.felt.button"),
                          systemImage: hasReportedFelt ? "checkmark.circle.fill" : "hand.raised.fill")
                }
                .buttonStyle(.sismikPrimary(height: 46, tint: .teal))
                .accessibilityHint(L("feltcard.felt.hint"))
            }

            if let event = card.majorEvent, let channelID = event.liveChannelID, tracker.activitiesEnabled {
                liveTrackingButton(event: event, channelID: channelID, tint: level.color)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(level.color.opacity(0.55), lineWidth: 1.5)
        }
        .animation(.snappy, value: quake.magnitude)
        .task(id: quake.id) {
            hasReportedFelt = FeltReportService.hasReported(feltReportID)
            feltCount = await FeltReportService.summary(for: feltReportID)?.count
        }
        .fullScreenCover(item: $safetyEvent) { event in
            QuakeResponseView(
                event: event,
                onOpenDetail: { _ in
                    safetyEvent = nil
                    onOpen()
                },
                onClose: { safetyEvent = nil }
            )
        }
    }

    /// Hissettim bildirimi olayın kimliğine yazılır (büyük olayda sunucudaki
    /// olay kimliği: tüm kullanıcılar aynı sayacı artırır).
    private var feltReportID: String { card.majorEvent?.id ?? quake.id }

    /// Hissettim: bildirim bir kez gönderilir, ardından uygulamanın güvenlik
    /// adımları (112, toplanma alanı, yapılacaklar) açılır. Tekrar dokununca
    /// adımlar yeniden açılır.
    private func reportFelt() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let distanceKm: Double
        switch card.kind {
        case .nearby(let km), .felt(let km, _): distanceKm = km
        case .major:
            distanceKm = LocationManager.cachedCoordinate
                .map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: quake.clLocation) / 1_000 } ?? 0
        }
        safetyEvent = StrongQuakeMonitor.Event(quake: quake, distanceKm: distanceKm, placeName: card.placeName)
        guard !hasReportedFelt else { return }
        hasReportedFelt = true
        feltCount = (feltCount ?? 0) + 1
        let id = feltReportID
        Task { _ = await FeltReportService.report(id, felt: true) }
    }

    private var headline: String {
        switch card.kind {
        case .major:
            return L(card.majorEvent?.region == "turkiye" ? "major.title.turkiye" : "major.title.world")
        case .nearby:
            return card.placeName.map { L("feltcard.nearby.place", $0) } ?? L("feltcard.nearby.you")
        case .felt(_, let mmi):
            return L("feltcard.felt.title", Self.roman(mmi))
        }
    }

    private var headlineSymbol: String {
        switch card.kind {
        case .major: "exclamationmark.triangle.fill"
        case .nearby: "location.fill"
        case .felt: "waveform.path.ecg"
        }
    }

    /// Tahmini şiddet (MMI) Roma rakamıyla: III, IV, V…
    private static func roman(_ mmi: Double) -> String {
        let numerals = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        let index = min(numerals.count, max(1, Int(mmi.rounded()))) - 1
        return numerals[index]
    }

    /// Kilit ekranı ve Dynamic Island'da canlı takip. Büyük olayda herkese
    /// açık; artçılar sunucunun yayın kanalından gelir, uygulama kapalıyken de.
    private func liveTrackingButton(event: MajorEventCenter.Event, channelID: String, tint: Color) -> some View {
        let tracking = tracker.isTracking(event.id)
        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task {
                if tracking {
                    await tracker.stop()
                } else {
                    await tracker.start(for: event.earthquake, channelID: channelID, expiresAt: event.expiryDate)
                }
            }
        } label: {
            Label(L(tracking ? "major.live.stop" : "major.live.start"),
                  systemImage: tracking ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(tint)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(L("major.live.hint"))
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
