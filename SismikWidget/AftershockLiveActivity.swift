import WidgetKit
import SwiftUI
import ActivityKit

// ÖNEMLİ: Bu öznitelik tanımı Sismik/Services/AftershockTracker.swift
// içindekiyle BİREBİR AYNI tutulmalıdır (iki hedef dosya paylaşmıyor).
struct AftershockActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var aftershockCount: Int
        var maxAftershockMagnitude: Double
        var lastMagnitude: Double
        var lastTitle: String
        var lastDate: Date
        var updatedAt: Date
        /// Önümüzdeki 24 saatte en az bir `forecastMagnitude`+ artçı olasılığı
        /// (0...1, `AftershockForecast`). İsteğe bağlı: eski sürümün başlattığı
        /// etkinliğin durumu bu alanlar olmadan da çözülür.
        var forecastProbability: Double?
        var forecastMagnitude: Double?
    }

    var mainshockID: String
    var regionTitle: String
    var mainshockMagnitude: Double
    var mainshockDate: Date
    var latitude: Double
    var longitude: Double
}

/// Artçı deprem takibi Canlı Etkinliği: kilit ekranı kartı + Dynamic Island.
///
/// Metinler `WidgetText` ile uygulamanın seçili dilinden okunur (14 dil);
/// eskiden bir kısmı yalnızca en/tr `.strings` dosyasındaydı ve diğer dillerde
/// ada İngilizce ya da cihaz dilinde kalıyordu.
struct AftershockLiveActivity: Widget {
    private static let brand = Color(red: 1.0, green: 122 / 255, blue: 0) // #FF7A00

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AftershockActivityAttributes.self) { context in
            // Kilit ekranı / bildirim bandı görünümü
            lockScreenView(context)
                .localizedForWidget()
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(Self.brand)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    magnitudeBadge(context.attributes.mainshockMagnitude, size: .expanded)
                        .padding(.leading, 4)
                        .localizedForWidget()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(verbatim: "\(context.state.aftershockCount)")
                            .font(.title2.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(value: Double(context.state.aftershockCount)))
                        Text(WidgetText.string("activity.aftershocks"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .padding(.trailing, 4)
                    .localizedForWidget()
                }
                DynamicIslandExpandedRegion(.center) {
                    // Bölge adı ortada tam genişlikte: dar sol bölgede tek
                    // satıra sıkışıp okunmaz hâlde kesiliyordu.
                    VStack(spacing: 1) {
                        Text(context.attributes.regionTitle)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(context.attributes.mainshockDate, style: .relative)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .localizedForWidget()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if context.isStale {
                            staleLabel
                        } else if context.state.aftershockCount > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform.path.ecg")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Self.brand)
                                Text(WidgetText.string("activity.last"))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.6))
                                Text(verbatim: Self.magnitudeText(context.state.lastMagnitude))
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                Text(context.state.lastDate, style: .relative)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if context.state.maxAftershockMagnitude > 0 {
                                    Text(verbatim: "\(WidgetText.string("activity.largest")) \(Self.magnitudeText(context.state.maxAftershockMagnitude))")
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.75))
                                        .lineLimit(1)
                                }
                            }
                        } else {
                            Text(WidgetText.string("activity.none"))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        forecastRow(context.state)
                    }
                    .padding(.horizontal, 4)
                    .localizedForWidget()
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption2.weight(.bold))
                    Text(verbatim: Self.magnitudeText(context.attributes.mainshockMagnitude, prefix: false))
                        .font(.caption2.weight(.heavy).monospacedDigit())
                }
                .foregroundStyle(Self.brand)
            } compactTrailing: {
                Text(verbatim: "\(context.state.aftershockCount)")
                    .font(.caption.weight(.heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(context.state.aftershockCount)))
            } minimal: {
                // Birden fazla etkinlik varken tek yuva: artçı varsa sayısı.
                if context.state.aftershockCount > 0 {
                    Text(verbatim: "\(min(context.state.aftershockCount, 99))")
                        .font(.caption2.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Self.brand)
                } else {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(Self.brand)
                }
            }
            .keylineTint(Self.brand)
            .widgetURL(URL(string: "sismik://quake/\(context.attributes.mainshockID)"))
        }
    }

    private enum BadgeSize { case expanded, lockScreen }

    private func magnitudeBadge(_ magnitude: Double, size: BadgeSize) -> some View {
        Text(verbatim: Self.magnitudeText(magnitude))
            .font((size == .expanded ? Font.headline : .title2).weight(.heavy).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size == .expanded ? 8 : 10)
            .padding(.vertical, size == .expanded ? 4 : 6)
            .background(Self.brand, in: RoundedRectangle(cornerRadius: size == .expanded ? 8 : 10, style: .continuous))
    }

    private var staleLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.caption2.weight(.bold))
            Text(WidgetText.string("activity.updating"))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    @ViewBuilder
    private func lockScreenView(_ context: ActivityViewContext<AftershockActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Self.brand)
                Text(WidgetText.string("activity.title"))
                    .font(.caption.weight(.heavy))
                    .tracking(0.6)
                    .foregroundStyle(Self.brand)
                    .lineLimit(1)
                Spacer()
                if context.isStale {
                    staleLabel
                } else {
                    Text(context.state.updatedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            HStack(spacing: 12) {
                magnitudeBadge(context.attributes.mainshockMagnitude, size: .lockScreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.regionTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(context.attributes.mainshockDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                statColumn(value: "\(context.state.aftershockCount)",
                           label: WidgetText.string("activity.aftershocks"))
                divider
                statColumn(value: context.state.maxAftershockMagnitude > 0
                              ? Self.magnitudeText(context.state.maxAftershockMagnitude) : "—",
                           label: WidgetText.string("activity.largest"))
                divider
                VStack(spacing: 2) {
                    if context.state.aftershockCount > 0 {
                        Text(context.state.lastDate, style: .relative)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        Text(verbatim: "—").font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                    Text(WidgetText.string("activity.last"))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
            }

            forecastRow(context.state)
        }
        .padding(14)
    }

    /// "24 sa içinde M5+ artçı olasılığı · %38" ve olasılıkla dolan ince çubuk.
    /// Eski sürümün başlattığı etkinlikte alan yoksa satır çizilmez. Her iki
    /// yüzey de koyu zeminli olduğundan renkler sabittir.
    @ViewBuilder
    private func forecastRow(_ state: AftershockActivityAttributes.ContentState) -> some View {
        if let probability = state.forecastProbability, let magnitude = state.forecastMagnitude {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Self.brand)
                    Text(String(format: WidgetText.string("activity.forecast"),
                                magnitude.formatted(.number.precision(.fractionLength(0)))))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text(Self.percentText(probability))
                        .font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Self.brand)
                }
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        // Overlay kapsülün kesin boyutunu önerir; serbest bir
                        // GeometryReader ada bölgelerinde yükseklik
                        // önerisini bozabiliyordu.
                        GeometryReader { proxy in
                            Capsule().fill(Self.brand)
                                .frame(width: max(4, proxy.size.width * min(1, probability)))
                        }
                    }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "M 6.2" — sayılar dilden bağımsız noktalı (sismolojik gösterim).
    private static func magnitudeText(_ magnitude: Double, prefix: Bool = true) -> String {
        let value = String(format: "%.1f", magnitude)
        return prefix ? "M \(value)" : value
    }

    /// Uygulama dilinin yüzde biçimi ("%38" / "38 %"); %1'in altı "<%1".
    private static func percentText(_ probability: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.Percent()
            .precision(.fractionLength(0))
            .locale(Locale(identifier: WidgetText.languageCode))
        return probability < 0.01 ? "<" + 0.01.formatted(style) : probability.formatted(style)
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 22)
    }
}

private extension View {
    /// Göreli zaman metinleri ("5 dk") ve yön uygulamanın dilini izlesin.
    func localizedForWidget() -> some View {
        environment(\.locale, Locale(identifier: WidgetText.languageCode))
            .environment(\.layoutDirection, WidgetText.layoutDirection)
    }
}
