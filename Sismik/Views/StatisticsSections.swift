import Charts
import SwiftUI

// MARK: - İstatistik ekranı bölümleri
//
// Ekran "herkesin sorabileceği sorular" üzerine kurulu: kaç deprem oldu, ne
// kadar büyüktü, ne zaman yoğunlaştı, ne kadar derindi, ne kadar enerji açığa
// çıktı, en büyükleri ve en hareketli yerler. Her bölümün altında tek
// cümlelik açıklama var; sayılar yorumsuz bırakılmaz. Görsel dil liste ve
// deprem detayıyla aynı: düz kartlar, büyüklük renk ölçeği, iri rakamlar.

/// Dile uygun yüzde: "%12" (tr), "12%" (en)…
func statsPercent(_ part: Int, of total: Int) -> String {
    (Double(part) / Double(max(1, total))).formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.currentLocale))
}

/// Bölüm başlığı: soru biçiminde başlık, altında tek cümle açıklama.
struct StatsSectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Başlık alanı

/// Detay ekranındaki başlığın istatistik karşılığı: iri sayı, sade cümle ve
/// dönemin gidişatı.
struct StatsHero: View {
    let stats: GlobalStats
    let presentation: StatisticsPresentation
    let scopeTitle: String

    private var trend: (text: String, symbol: String, color: Color) {
        let change = presentation.activityChangePercent
        let percent = Int(abs(change).rounded())
        if change > 8 {
            return (String(format: L("stats.hero.trend.up"), percent), "arrow.up.right", MagnitudeLevel.major.textColor)
        }
        if change < -8 {
            return (String(format: L("stats.hero.trend.down"), percent), "arrow.down.right", MagnitudeLevel.minor.textColor)
        }
        return (L("stats.hero.trend.flat"), "equal", .secondary)
    }

    private var paceText: String? {
        guard stats.total7d > 0 else { return nil }
        let perDay = presentation.dailyAverage
        let perDayText = perDay.formatted(.number.precision(.fractionLength(perDay < 10 ? 1 : 0)).locale(AppLanguage.currentLocale))
        guard let minutes = presentation.averageIntervalMinutes else {
            return String(format: L("stats.hero.pace.day"), perDayText)
        }
        let interval = minutes < 60
            ? String(format: L("stats.hero.interval.min"), max(1, Int(minutes.rounded())))
            : String(format: L("stats.hero.interval.hour"), (minutes / 60).formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.currentLocale)))
        return String(format: L("stats.hero.pace"), perDayText, interval)
    }

    var body: some View {
        let trend = self.trend
        VStack(alignment: .leading, spacing: 8) {
            Text(scopeTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stats.total7d.formatted())
                    .font(.system(size: 54, weight: .heavy, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(stats.total7d)))
                Text(L("stats.hero.unit"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let paceText {
                Text(paceText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(trend.text, systemImage: trend.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(trend.color)
            if stats.m45plus > 0 {
                Text(String(format: L("stats.hero.significant"), stats.m45plus))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Ne kadar büyüktü?

struct StatsMagnitudeBreakdown: View {
    let stats: GlobalStats

    private struct Band: Identifiable {
        let id: String
        let range: String
        let meaning: String
        let count: Int
        let level: MagnitudeLevel
    }

    private var bands: [Band] {
        [
            Band(id: "micro", range: "M < 3", meaning: L("stats.mag.band.micro"), count: stats.magDist.micro, level: .minor),
            Band(id: "light", range: "M 3–4.4", meaning: L("stats.mag.band.light"), count: stats.magDist.light, level: .light),
            Band(id: "moderate", range: "M 4.5–5.9", meaning: L("stats.mag.band.moderate"), count: stats.magDist.moderate, level: .strong),
            Band(id: "strong", range: "M 6+", meaning: L("stats.mag.band.strong"), count: stats.magDist.strong + stats.magDist.major, level: .major)
        ]
    }

    var body: some View {
        let bands = self.bands
        let total = max(1, bands.reduce(0) { $0 + $1.count })
        VStack(alignment: .leading, spacing: 14) {
            StatsSectionTitle(title: L("stats.mag.title"), subtitle: L("stats.mag.subtitle"))

            // Tek şerit: payların görsel özeti.
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(bands.filter { $0.count > 0 }) { band in
                        Rectangle()
                            .fill(band.level.color)
                            .frame(width: max(4, (proxy.size.width - 6) * CGFloat(band.count) / CGFloat(total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                ForEach(bands) { band in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(band.level.color)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(band.range)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Text(band.meaning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(band.count.formatted())
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .contentTransition(.numericText(value: Double(band.count)))
                            Text(statsPercent(band.count, of: total))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .bentoCardStyle()
    }
}

// MARK: Zaman içinde

struct StatsTimelineCard: View {
    let stats: GlobalStats
    let buckets: [StatisticsTrendBucket]
    let peak: StatisticsTrendBucket?

    @State private var selectedDate: Date?
    private var isHourly: Bool { stats.rangeHours <= 24 }
    private var unit: Calendar.Component { isHourly ? .hour : .day }

    private var selected: StatisticsTrendBucket? {
        selectedDate.flatMap { date in
            buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
        }
    }

    private func label(for bucket: StatisticsTrendBucket) -> String {
        isHourly
            ? bucket.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.currentLocale))
            : bucket.start.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.currentLocale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatsSectionTitle(
                title: L(isHourly ? "stats.time.title.hourly" : "stats.time.title.daily"),
                subtitle: L("stats.time.subtitle")
            )

            Group {
                if let bucket = selected ?? peak {
                    HStack(spacing: 6) {
                        Text(selected == nil ? L("stats.time.peak") : label(for: bucket))
                            .fontWeight(.semibold)
                        Text(selected == nil ? "\(label(for: bucket)) · " + String(format: L("stats.trend.selectedCount"), bucket.count)
                                             : String(format: L("stats.trend.selectedCount"), bucket.count))
                        if bucket.maximumMagnitude > 0 {
                            Text("· M\(bucket.maximumMagnitude.formatted(.number.precision(.fractionLength(1))))")
                                .fontWeight(.semibold)
                                .foregroundStyle(MagnitudeLevel(magnitude: bucket.maximumMagnitude).textColor)
                        }
                    }
                    .font(.footnote.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
            .frame(height: 18, alignment: .leading)

            Chart(buckets) { bucket in
                BarMark(
                    x: .value(isHourly ? "Saat" : "Gün", bucket.start, unit: unit),
                    y: .value("Sayı", bucket.count)
                )
                // Çubuğun rengi o dilimdeki en büyük depremin rengi.
                .foregroundStyle(MagnitudeLevel(magnitude: bucket.maximumMagnitude).color)
                .opacity(selected == nil || selected?.id == bucket.id ? 1 : 0.35)
                .clipShape(.rect(cornerRadius: 3))
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 170)
        }
        .bentoCardStyle()
        .onChange(of: buckets.first?.id) { _, _ in selectedDate = nil }
    }
}

// MARK: Ne kadar derindi?

struct StatsDepthCard: View {
    let stats: GlobalStats

    private static let colors: [Color] = [
        Color(red: 0.86, green: 0.52, blue: 0.22),
        Color(red: 0.62, green: 0.45, blue: 0.33),
        Color(red: 0.42, green: 0.38, blue: 0.38)
    ]

    var body: some View {
        let parts: [(title: String, range: String, meaning: String, count: Int)] = [
            (L("Sığ"), "0–70 km", L("stats.depth.shallow"), stats.depthDist.shallow),
            (L("Orta"), "70–300 km", L("stats.depth.intermediate"), stats.depthDist.intermediate),
            (L("Derin"), "300+ km", L("stats.depth.deep"), stats.depthDist.deep)
        ]
        let total = max(1, parts.reduce(0) { $0 + $1.count })
        VStack(alignment: .leading, spacing: 14) {
            StatsSectionTitle(title: L("stats.depth.title"), subtitle: stats.avgDepth > 0
                              ? String(format: L("stats.depth.subtitle"), stats.avgDepth.depthKmText)
                              : nil)
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statsPercent(part.count, of: total))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(Self.colors[index])
                        Text("\(part.title) · \(part.range)")
                            .font(.caption.weight(.semibold))
                        Text(part.meaning)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .bentoCardStyle()
    }
}

// MARK: Açığa çıkan enerji

/// Toplam sismik enerjiyi günlük karşılıklara çevirir: eşdeğer tek deprem
/// büyüklüğü ve TNT karşılığı. Büyüklük ölçeğinin logaritmik olduğunu
/// sezdirmenin en anlaşılır yolu.
struct StatsEnergyCard: View {
    let joules: Double

    /// Gutenberg–Richter enerji bağıntısı: log10 E = 1,5 M + 4,8 (joule).
    private var equivalentMagnitude: Double { (log10(joules) - 4.8) / 1.5 }

    private var tntText: String {
        let tons = joules / 4.184e9
        if tons >= 1_000_000 { return String(format: L("stats.energy.tnt.mt"), (tons / 1_000_000).formatted(.number.precision(.fractionLength(1)))) }
        if tons >= 1_000 { return String(format: L("stats.energy.tnt.kt"), (tons / 1_000).formatted(.number.precision(.fractionLength(1)))) }
        return String(format: L("stats.energy.tnt.t"), tons.formatted(.number.precision(.fractionLength(0))))
    }

    var body: some View {
        let magnitude = equivalentMagnitude
        let level = MagnitudeLevel(magnitude: magnitude)
        VStack(alignment: .leading, spacing: 12) {
            StatsSectionTitle(title: L("stats.energy.title"), subtitle: L("stats.energy.subtitle"))
            HStack(alignment: .center, spacing: 14) {
                Text(magnitude.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(level.foregroundOnColor)
                    .frame(width: 72, height: 58)
                    .background(level.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: L("stats.energy.equivalent"), magnitude.formatted(.number.precision(.fractionLength(1)))))
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tntText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text(L("stats.energy.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .bentoCardStyle()
        .accessibilityElement(children: .combine)
    }
}

// MARK: En hareketli bölgeler

struct StatsRegionsCard: View {
    let regions: [GlobalStats.Region]

    var body: some View {
        let maximum = max(1, regions.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            StatsSectionTitle(title: L("stats.regions.title"), subtitle: L("stats.regions.subtitle"))
            ForEach(Array(regions.enumerated()), id: \.offset) { index, region in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(region.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(region.count.formatted())
                                .font(.subheadline.weight(.bold).monospacedDigit())
                        }
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.primary.opacity(0.07))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.brandOrange)
                                        .frame(width: proxy.size.width * CGFloat(region.count) / CGFloat(maximum))
                                }
                        }
                        .frame(height: 5)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .bentoCardStyle()
    }
}
