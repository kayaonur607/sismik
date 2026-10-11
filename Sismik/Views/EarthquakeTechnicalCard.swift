import SwiftUI

struct EarthquakeTechnicalCard: View {
    let earthquake: Earthquake
    let impactData: SeismicImpactData?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L("detail.technicalParams"), systemImage: "info.circle.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            measurementSection
            if hasQualitySignals { qualitySection }
            sourceSection

            if let sourceURL = earthquake.sourceURL {
                Link(destination: sourceURL) {
                    Label(L("detail.openSource"), systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityHint(L("detail.openSource.hint"))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Konum & Ölçüm

    private var measurementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("Konum & Ölçüm"))
            LazyVGrid(columns: columns, spacing: 10) {
                TechnicalTile(icon: "location.fill", tint: .blue,
                              label: L("map.coordinates"),
                              value: coordinateText)
                TechnicalTile(icon: "arrow.down.forward.and.arrow.up.backward", tint: .teal,
                              label: L("detail.depthClass"), value: depthClassification)
                if let magType = earthquake.magType, !magType.isEmpty {
                    TechnicalTile(icon: "ruler", tint: .indigo,
                                  label: L("detail.magType"), value: magType.uppercased())
                }
                TechnicalTile(icon: "bolt.fill", tint: .orange,
                              label: L("detail.energyReleased"), value: energyText)
            }
        }
    }

    // MARK: - Veri Kalitesi

    private var hasQualitySignals: Bool {
        earthquake.stationCount != nil || earthquake.gap != nil || earthquake.rms != nil
            || earthquake.minimumDistance != nil || earthquake.significance != nil
            || earthquake.communityIntensity != nil || earthquake.maximumIntensity != nil
            || (earthquake.feltReports ?? 0) > 0 || impactData != nil
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("Veri Kalitesi"))
            LazyVGrid(columns: columns, spacing: 10) {
                if let stationCount = earthquake.stationCount {
                    TechnicalTile(icon: "antenna.radiowaves.left.and.right", tint: .cyan,
                                  label: L("detail.stationCount"), value: stationCount.formatted())
                }
                if let gap = earthquake.gap {
                    TechnicalTile(icon: "angle", tint: .cyan,
                                  label: L("detail.azimuthalGap"),
                                  value: "\(gap.formatted(.number.precision(.fractionLength(1))))°")
                }
                if let rms = earthquake.rms {
                    TechnicalTile(icon: "waveform", tint: .cyan,
                                  label: L("detail.rms"), value: rms.formatted(.number.precision(.fractionLength(3))))
                }
                if let minimumDistance = earthquake.minimumDistance {
                    TechnicalTile(icon: "ruler.fill", tint: .cyan,
                                  label: L("detail.minimumDistance"),
                                  value: minimumDistance.formatted(.number.precision(.fractionLength(3))))
                }
                if let significance = earthquake.significance {
                    TechnicalTile(icon: "chart.bar.fill", tint: .brandOrange,
                                  label: L("detail.significance"), value: significance.formatted())
                }
                if let communityIntensity = earthquake.communityIntensity {
                    TechnicalTile(icon: "person.3.fill", tint: .brandOrange,
                                  label: L("detail.communityIntensity"),
                                  value: communityIntensity.formatted(.number.precision(.fractionLength(1))))
                }
                if let maximumIntensity = earthquake.maximumIntensity {
                    TechnicalTile(icon: "chart.bar.xaxis", tint: .brandOrange,
                                  label: L("detail.maximumIntensity"),
                                  value: maximumIntensity.formatted(.number.precision(.fractionLength(1))))
                }
                if let felt = earthquake.feltReports, felt > 0 {
                    TechnicalTile(icon: "hand.raised.fill", tint: .teal,
                                  label: L("detail.feltReports"), value: "\(felt)")
                }
                if let impactData {
                    TechnicalTile(icon: "waveform.path.ecg", tint: .brandOrange,
                                  label: L("ShakeMap durumu"),
                                  value: impactData.isReviewed
                                    ? L("detail.status.reviewed")
                                    : (L("Otomatik")))
                    if let maximumMMI = impactData.maximumMMI {
                        TechnicalTile(icon: "waveform.path.ecg.rectangle", tint: .brandOrange,
                                      label: "ShakeMap max MMI",
                                      value: maximumMMI.formatted(.number.precision(.fractionLength(1))))
                    }
                }
            }
        }
    }

    // MARK: - Kaynak & Durum

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("Kaynak & Durum"))
            LazyVGrid(columns: columns, spacing: 10) {
                TechnicalTile(icon: "antenna.radiowaves.left.and.right", tint: earthquake.sourceColor,
                              label: L("detail.dataSource"), value: earthquake.sourceTag)

                if earthquake.revised {
                    TechnicalTile(icon: "checkmark.seal.fill", tint: .green,
                                  label: L("detail.solutionStatus"), value: L("detail.status.revised"))
                } else if let status = earthquake.status {
                    TechnicalTile(icon: "checkmark.seal.fill", tint: .green,
                                  label: L("detail.solutionStatus"),
                                  value: status == "reviewed" ? L("detail.status.reviewed") : L("detail.status.automatic"))
                }
                if let network = earthquake.network, !network.isEmpty {
                    TechnicalTile(icon: "point.3.connected.trianglepath.dotted", tint: .blue,
                                  label: L("detail.network"), value: network)
                }
                if let catalog = earthquake.catalog, !catalog.isEmpty {
                    TechnicalTile(icon: "tray.full.fill", tint: .blue,
                                  label: L("detail.catalog"), value: catalog)
                }
                if let author = earthquake.author, !author.isEmpty, author != earthquake.network {
                    TechnicalTile(icon: "person.text.rectangle", tint: .blue,
                                  label: L("detail.author"), value: author)
                }
                if let eventType = earthquake.eventType, !eventType.isEmpty {
                    TechnicalTile(icon: "tag.fill", tint: .gray,
                                  label: L("detail.eventType"), value: eventType)
                }
                if let level = earthquake.impactLevel {
                    TechnicalTile(icon: "exclamationmark.triangle.fill", tint: level.color,
                                  label: L("detail.alertLevel"), value: level.name)
                }
                if let eventCode = earthquake.eventCode, !eventCode.isEmpty {
                    TechnicalTile(icon: "number", tint: .gray,
                                  label: L("detail.sourceCode"), value: eventCode)
                }
                if let updatedAt = earthquake.updatedAt {
                    TechnicalTile(icon: "clock.arrow.circlepath", tint: .gray,
                                  label: L("detail.sourceUpdated"), value: localizedDate(updatedAt))
                }
                TechnicalTile(icon: "globe", tint: .gray,
                              label: L("detail.utcTime"), value: utcDate)
                TechnicalTile(icon: "number.circle", tint: .gray,
                              label: L("detail.eventId"), value: earthquake.id)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy, HH:mm:ss 'UTC'"
        return formatter
    }()

    private static let energyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .scientific
        formatter.maximumFractionDigits = 2
        formatter.exponentSymbol = "×10^"
        return formatter
    }()

    private var isTR: Bool { AppLanguage.isTurkish }

    private func localizedDate(_ date: Date) -> String {
        date.formatted(
            .dateTime.locale(AppLanguage.currentLocale)
                .day().month(.abbreviated).year().hour().minute().second()
        )
    }

    private var coordinateText: String {
        "\(earthquake.coordinate.latitude.formatted(.number.precision(.fractionLength(3)))), " +
        "\(earthquake.coordinate.longitude.formatted(.number.precision(.fractionLength(3))))"
    }

    private var depthClassification: String {
        switch earthquake.depth {
        case ..<70: L("detail.depth.shallow")
        case ..<300: L("detail.depth.intermediate")
        default: L("detail.depth.deep")
        }
    }

    private var energyText: String {
        let joules = pow(10, 1.5 * earthquake.magnitude + 4.8)
        return (Self.energyFormatter.string(from: NSNumber(value: joules)) ?? "\(joules)") + " J"
    }

    private var utcDate: String {
        let formatter = Self.utcFormatter
        let identifier = AppLanguage.current.localeIdentifier
        if formatter.locale.identifier != identifier {
            formatter.locale = AppLanguage.locale(for: identifier)
        }
        return formatter.string(from: earthquake.date)
    }
}

/// Teknik parametre kartındaki eşit boyutlu bento hücresi — StatisticsKPITile
/// ile aynı görsel dili paylaşır (ikon rozeti + değer + etiket).
private struct TechnicalTile: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}
