import SwiftUI
import WidgetKit

// MARK: - Ortak dil ve biçim

/// Widget metinleri uygulamada seçili dilde (App Group'tan okunur); dil hiç
/// yazılmadıysa cihaz dili, desteklenmiyorsa Türkçe.
enum WidgetText {
    static var languageCode: String {
        if let code = WidgetSharedStore.languageCode { return code }
        let device = Locale.current.language.languageCode?.identifier ?? "tr"
        return WidgetStrings.table["recent.title"]?[device] != nil ? device : "tr"
    }

    static func string(_ key: String) -> String {
        let row = WidgetStrings.table[key]
        return row?[languageCode] ?? row?["tr"] ?? key
    }

    static func string(_ key: String, _ value: Int) -> String {
        String(format: string(key), value)
    }

    static var layoutDirection: LayoutDirection { languageCode == "ar" ? .rightToLeft : .leftToRight }

    /// "az önce", "12 dk önce", "3 sa önce" — girişin anına göre.
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return string("widget.time.justnow") }
        if seconds < 3600 { return string("widget.time.min", seconds / 60) }
        if seconds < 86_400 { return string("widget.time.hour", seconds / 3600) }
        return string("widget.time.day", seconds / 86_400)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func magnitude(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// Uygulamanın büyüklük ölçeği (`MagnitudeLevel`) ile aynı eşikler ve renkler.
enum WidgetMagnitude {
    static func color(_ magnitude: Double) -> Color {
        switch magnitude {
        case ..<2.0: Color(red: 0.49, green: 0.75, blue: 0.45)
        case ..<3.0: Color(red: 0.20, green: 0.60, blue: 0.29)
        case ..<4.0: Color(red: 0.55, green: 0.68, blue: 0.11)
        case ..<5.0: Color(red: 0.97, green: 0.62, blue: 0.09)
        case ..<6.0: Color(red: 0.91, green: 0.40, blue: 0.05)
        case ..<7.0: Color(red: 0.85, green: 0.15, blue: 0.13)
        default: Color(red: 0.55, green: 0.05, blue: 0.08)
        }
    }

    /// Dolu renk üstündeki yazı: açık zeminlerde (M<2, M3–4.9) zeminle aynı
    /// tonun koyusu, diğerlerinde beyaz (uygulamadaki `foregroundOnColor`).
    static func foreground(_ magnitude: Double) -> Color {
        switch magnitude {
        case ..<2.0: Color(red: 0.08, green: 0.27, blue: 0.08)
        case 3.0..<4.0: Color(red: 0.20, green: 0.25, blue: 0.00)
        case 4.0..<5.0: Color(red: 0.36, green: 0.18, blue: 0.00)
        default: .white
        }
    }

    static func label(_ magnitude: Double) -> String {
        switch magnitude {
        case ..<2.0: WidgetText.string("magnitude.micro")
        case ..<3.0: WidgetText.string("magnitude.minor")
        case ..<4.0: WidgetText.string("magnitude.light")
        case ..<5.0: WidgetText.string("magnitude.moderate")
        case ..<6.0: WidgetText.string("magnitude.strong")
        case ..<7.0: WidgetText.string("magnitude.major")
        default: WidgetText.string("magnitude.great")
        }
    }
}

enum WidgetTheme {
    /// Logo turuncusu (#FF7A00); uygulamadaki `Color.brandOrange` ile aynı.
    static let brand = Color(red: 1.0, green: 122 / 255, blue: 0)
}

/// Sade, sisteme uyumlu zemin: açık/koyu görünümde uygulamanın kart rengi,
/// alt köşede gösterilen depremin renginden çok hafif bir ışık.
struct WidgetBackground: View {
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            RadialGradient(colors: [accent.opacity(colorScheme == .dark ? 0.30 : 0.16), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 190)
        }
    }
}

/// Uygulamadaki büyüklük karosu: "M" + değer ve seviye adı, seviye renginde.
struct MagnitudeTile: View {
    let magnitude: Double
    var width: CGFloat = 54
    var height: CGFloat = 46
    var showsLevel = true

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                Text(verbatim: "M")
                    .font(.system(size: height * 0.19, weight: .bold))
                    .opacity(0.85)
                Text(verbatim: WidgetText.magnitude(magnitude))
                    .font(.system(size: height * 0.44, weight: .black).monospacedDigit())
            }
            if showsLevel {
                Text(WidgetMagnitude.label(magnitude))
                    .font(.system(size: 8, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 3)
            }
        }
        .foregroundStyle(renderingMode == .fullColor ? WidgetMagnitude.foreground(magnitude) : Color.primary)
        .frame(width: width, height: height)
        .background {
            RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                .fill(renderingMode == .fullColor
                      ? AnyShapeStyle(WidgetMagnitude.color(magnitude))
                      : AnyShapeStyle(Color.primary.opacity(0.14)))
        }
        .widgetAccentable()
    }
}

/// Uygulamadaki listenin filtre rozetleri ("M3+", "AFAD" / "TÜMÜ").
private struct WidgetBadges: View {
    let filter: WidgetListFilter

    var body: some View {
        HStack(spacing: 4) {
            if let magnitude = filter.magnitudeBadge {
                badge(magnitude)
            }
            badge(filter.sourceBadge ?? WidgetText.string("widget.badge.all"))
        }
    }

    private func badge(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(WidgetTheme.brand)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(WidgetTheme.brand.opacity(0.14), in: Capsule())
    }
}

private struct WidgetHeader: View {
    let icon: String
    let title: String
    let filter: WidgetListFilter

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(WidgetTheme.brand)
                .widgetAccentable()
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            WidgetBadges(filter: filter)
        }
    }
}

private struct WidgetEmptyState: View {
    let entry: QuakeEntry

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.hasData ? "line.3.horizontal.decrease.circle" : "iphone.and.arrow.forward")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(WidgetText.string(entry.hasData ? "widget.emptyFiltered" : "widget.empty"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func quakeURL(_ quake: WidgetQuake?) -> URL {
    if let quake, let url = URL(string: "sismik://quake/\(quake.id)") { return url }
    return URL(string: "sismik://recent")!
}

// MARK: - Son Depremler

struct SismikWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuakeEntry

    var body: some View {
        content
            .environment(\.layoutDirection, WidgetText.layoutDirection)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemSmall: small
        case .systemMedium: medium
        default: large
        }
    }

    // Küçük: en son deprem, büyük ve net.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(icon: "waveform.path.ecg", title: WidgetText.string("recent.title"),
                         filter: entry.filter)
            if let quake = entry.latest {
                Spacer(minLength: 4)
                featured(quake, magnitudeSize: 40)
            } else {
                WidgetEmptyState(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(quakeURL(entry.latest))
    }

    // Orta: solda en son deprem, sağda sıradaki üç deprem.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(icon: "waveform.path.ecg", title: WidgetText.string("recent.title"),
                         filter: entry.filter)
            if let quake = entry.latest {
                HStack(alignment: .top, spacing: 12) {
                    Link(destination: quakeURL(quake)) {
                        featured(quake, magnitudeSize: 34)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(entry.quakes.dropFirst().prefix(3).enumerated()), id: \.element.id) { index, quake in
                            if index > 0 { Divider().opacity(0.5) }
                            compactRow(quake)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                WidgetEmptyState(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Büyük: öne çıkan deprem kartı ve altında altı satırlık liste.
    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(icon: "waveform.path.ecg", title: WidgetText.string("recent.title"),
                         filter: entry.filter)
            if let quake = entry.latest {
                Link(destination: quakeURL(quake)) {
                    HStack(spacing: 12) {
                        MagnitudeTile(magnitude: quake.magnitude, width: 62, height: 54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: quake.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(verbatim: metaLine(quake))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 16, style: .continuous))
                }
                VStack(spacing: 0) {
                    ForEach(Array(entry.quakes.dropFirst().prefix(5).enumerated()), id: \.element.id) { index, quake in
                        if index > 0 { Divider().opacity(0.5) }
                        listRow(quake)
                    }
                }
                Spacer(minLength: 0)
            } else {
                WidgetEmptyState(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func featured(_ quake: WidgetQuake, magnitudeSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: "M")
                    .font(.system(size: magnitudeSize * 0.36, weight: .heavy, design: .rounded))
                Text(verbatim: WidgetText.magnitude(quake.magnitude))
                    .font(.system(size: magnitudeSize, weight: .black, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(WidgetMagnitude.color(quake.magnitude))
            .widgetAccentable()
            .minimumScaleFactor(0.8)
            Text(WidgetMagnitude.label(quake.magnitude))
                .font(.system(size: 9, weight: .heavy))
                .textCase(.uppercase)
                .foregroundStyle(WidgetMagnitude.color(quake.magnitude))
            Text(verbatim: quake.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.top, 2)
            Text(verbatim: "\(WidgetText.relative(quake.date, now: entry.date)) · \(WidgetText.clock(quake.date))")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Orta boyuttaki sağ sütun satırı.
    private func compactRow(_ quake: WidgetQuake) -> some View {
        Link(destination: quakeURL(quake)) {
            HStack(spacing: 8) {
                MagnitudeTile(magnitude: quake.magnitude, width: 36, height: 28, showsLevel: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: quake.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(WidgetText.relative(quake.date, now: entry.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    /// Büyük boyuttaki liste satırı (uygulamadaki deprem satırının sade hâli).
    private func listRow(_ quake: WidgetQuake) -> some View {
        Link(destination: quakeURL(quake)) {
            HStack(spacing: 10) {
                MagnitudeTile(magnitude: quake.magnitude, width: 44, height: 34, showsLevel: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: quake.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(verbatim: metaLine(quake))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(WidgetText.relative(quake.date, now: entry.date))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 5)
        }
    }

    private func metaLine(_ quake: WidgetQuake) -> String {
        var parts = [WidgetText.clock(quake.date)]
        if let depth = quake.depth {
            parts.append("\(WidgetText.string("depth")) \(String(format: "%.0f", depth)) km")
        }
        parts.append(quake.provider)
        return parts.joined(separator: " · ")
    }

    // Kilit ekranı

    private var circular: some View {
        Group {
            if let quake = entry.latest {
                Gauge(value: min(quake.magnitude, 8), in: 0...8) {
                    Text(verbatim: "M")
                } currentValueLabel: {
                    Text(verbatim: WidgetText.magnitude(quake.magnitude))
                        .font(.system(.body, design: .rounded).weight(.bold))
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                Image(systemName: "waveform.path.ecg")
                    .font(.title3.weight(.semibold))
            }
        }
        .widgetURL(quakeURL(entry.latest))
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let quake = entry.latest {
                HStack(spacing: 4) {
                    Text(verbatim: "M\(WidgetText.magnitude(quake.magnitude))")
                        .font(.system(.headline, design: .rounded).weight(.black))
                        .widgetAccentable()
                    Text(verbatim: "· \(WidgetMagnitude.label(quake.magnitude))")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                }
                Text(verbatim: quake.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: "\(WidgetText.relative(quake.date, now: entry.date)) · \(quake.provider)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(WidgetText.string(entry.hasData ? "widget.emptyFiltered" : "widget.empty"))
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(quakeURL(entry.latest))
        .containerBackground(.clear, for: .widget)
    }

    private var inline: some View {
        Group {
            if let quake = entry.latest {
                Text(verbatim: "M\(WidgetText.magnitude(quake.magnitude)) · \(quake.title)")
            } else {
                Text(verbatim: "Sismik")
            }
        }
        .widgetURL(quakeURL(entry.latest))
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Deprem İstatistikleri (son 24 saat)

struct SismikStatsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuakeEntry

    private var digest: QuakeDigest { QuakeDigest(quakes: entry.quakes, now: entry.date) }

    var body: some View {
        let digest = digest
        Group {
            if family == .systemSmall {
                small(digest)
            } else {
                medium(digest)
            }
        }
        .environment(\.layoutDirection, WidgetText.layoutDirection)
        .widgetURL(URL(string: "sismik://stats"))
    }

    private func small(_ digest: QuakeDigest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(icon: "chart.bar.fill", title: WidgetText.string("widget.stats.last24h"),
                         filter: entry.filter)
            Spacer(minLength: 4)
            Text(digest.count, format: .number)
                .font(.system(size: 38, weight: .black, design: .rounded).monospacedDigit())
                .widgetAccentable()
                .minimumScaleFactor(0.7)
            Text(WidgetText.string("widget.stats.totalCount"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HourlyBars(counts: digest.hourlyCounts, maxima: digest.hourlyMaxMagnitudes)
                .frame(height: 20)
                .padding(.top, 6)
            if let largest = digest.largest {
                HStack(spacing: 4) {
                    Circle()
                        .fill(WidgetMagnitude.color(largest.magnitude))
                        .frame(width: 6, height: 6)
                    Text(verbatim: "\(WidgetText.string("widget.stats.maxQuake")) M\(WidgetText.magnitude(largest.magnitude))")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ digest: QuakeDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(icon: "chart.bar.fill", title: WidgetText.string("widget.stats.last24h"),
                         filter: entry.filter)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(digest.count, format: .number)
                        .font(.system(size: 36, weight: .black, design: .rounded).monospacedDigit())
                        .widgetAccentable()
                        .minimumScaleFactor(0.7)
                    Text(WidgetText.string("widget.stats.totalCount"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HourlyBars(counts: digest.hourlyCounts, maxima: digest.hourlyMaxMagnitudes)
                        .frame(height: 26)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    metric(icon: "bolt.fill",
                           color: digest.largest.map { WidgetMagnitude.color($0.magnitude) } ?? .secondary,
                           label: WidgetText.string("widget.stats.maxQuake"),
                           value: digest.largest.map { "M\(WidgetText.magnitude($0.magnitude))" } ?? "—")
                    metric(icon: "waveform.path.ecg", color: .orange,
                           label: WidgetText.string("widget.stats.feltCount"),
                           value: "\(digest.feltCount)")
                    metric(icon: "mappin.and.ellipse", color: WidgetTheme.brand,
                           label: WidgetText.string("widget.stats.activeRegion"),
                           value: digest.busiestRegion ?? "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metric(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.15), in: .rect(cornerRadius: 7, style: .continuous))
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: value)
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

/// Son 24 saatin saatlik yoğunluğu: çubuk boyu deprem sayısı, rengi o saatin
/// en büyük depremi (uygulamadaki oynatım histogramıyla aynı dil).
private struct HourlyBars: View {
    let counts: [Int]
    let maxima: [Double]

    var body: some View {
        Canvas { context, size in
            let peak = max(1, counts.max() ?? 1)
            let spacing: CGFloat = 1.5
            let width = max(1, (size.width - spacing * CGFloat(counts.count - 1)) / CGFloat(counts.count))
            for (index, count) in counts.enumerated() {
                let height = count == 0 ? 2 : max(3, CGFloat(count) / CGFloat(peak) * size.height)
                let rect = CGRect(x: CGFloat(index) * (width + spacing), y: size.height - height,
                                  width: width, height: height)
                let color = count == 0 ? Color.primary.opacity(0.12) : WidgetMagnitude.color(maxima[index])
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, width / 2)), with: .color(color))
            }
        }
        .widgetAccentable()
    }
}
