import SwiftUI

/// Deprem detayında ORFEUS RRSM'in istasyonlarda ölçtüğü sarsıntı.
///
/// Yalnızca ölçüm yayımlanmış depremde görünür (RRSM: Avrupa–Akdeniz, M3.5
/// civarı ve üstü). Veri yoksa ya da henüz gelmediyse kart hiç yer tutmaz;
/// detay ekranı `RRSMCard.watch` ile arka planda sorar, ölçüm gelince kart
/// yumuşak geçişle eklenir. Herkese açık.
struct RRSMCard: View {
    let earthquake: Earthquake
    let result: RRSMService.Result

    private static let tint = Color.indigo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            measured(result)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RRSMSurface())
    }

    // MARK: Yükleme

    /// Ölçümü arar ve bulunca bildirir. Yeni depremde veri birkaç dakika
    /// içinde yayımlanır: ekran açıkken dakikada bir yeniden sorulur. Ağ
    /// hatasında bir kez daha denenir. Kapsam dışı depremde istek atılmaz.
    static func watch(_ earthquake: Earthquake, onResult: @MainActor (RRSMService.Result) -> Void) async {
        guard RRSMService.isInScope(earthquake) else { return }
        var networkRetries = 1
        while !Task.isCancelled {
            switch await RRSMService.availability(for: earthquake) {
            case .available(let result):
                onResult(result)
                return
            case .pending where Date().timeIntervalSince(earthquake.date) < RRSMService.pendingWindow:
                try? await Task.sleep(for: .seconds(60))
            case .unreachable where networkRetries > 0:
                networkRetries -= 1
                try? await Task.sleep(for: .seconds(20))
            default:
                return
            }
        }
    }

    // MARK: Parçalar

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.headline.weight(.bold))
                .foregroundStyle(Self.tint)
                .frame(width: 40, height: 40)
                .background(Self.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(L("rrsm.title"))
                    .font(.subheadline.weight(.bold))
                Text(L("rrsm.subtitle"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func measured(_ result: RRSMService.Result) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let peak = result.peak {
                peakSummary(peak)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("rrsm.stations.top"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(result.stations.prefix(3)) { station in
                    RRSMStationRow(station: station, maxPGA: result.peak?.pga ?? station.pga)
                }
            }

            NavigationLink {
                RRSMStationsView(result: result, title: earthquake.displayTitle)
            } label: {
                HStack {
                    Text(String(format: L("rrsm.stations.all"), result.stations.count))
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Color.appAction)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            attribution(result)
        }
    }

    /// En yüksek ivmenin ölçüldüğü istasyon: ivme, yerçekimine oranı, hız ve
    /// nerede ölçüldüğü. Yalnızca ölçülen değerler; şiddet tahmini yapılmaz.
    private func peakSummary(_ peak: RRSMService.Station) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("rrsm.peak"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(RRSMFormat.pga(peak.pga))
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.brandOrange)
            Text(String(format: L("rrsm.peak.detail"), RRSMFormat.percentOfGravity(peak.pgaPercentG), RRSMFormat.pgv(peak.pgv)))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: L("rrsm.peak.where"), peak.id, RRSMFormat.number(peak.distanceKm), RRSMFormat.direction(peak.directionIndex, long: true)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func attribution(_ result: RRSMService.Result) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("rrsm.disclaimer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = result.eventURL {
                    Link(L("rrsm.source"), destination: url)
                        .font(.caption2.weight(.semibold))
                        .tint(Color.appAction)
                }
            }
        }
    }
}

/// İstasyon satırı: kod, uzaklık ve yön, ölçülen ivme ve en yüksek ölçüme
/// göre dolan çubuk.
struct RRSMStationRow: View {
    let station: RRSMService.Station
    let maxPGA: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(station.id)
                    .font(.footnote.weight(.semibold).monospaced())
                Text("\(RRSMFormat.number(station.distanceKm)) km · \(RRSMFormat.direction(station.directionIndex, long: false))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(RRSMFormat.pga(station.pga))
                    .font(.caption.weight(.bold).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(Color.brandOrange)
                        .frame(width: max(4, proxy.size.width * min(1, station.pga / max(maxPGA, 0.001))))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tüm istasyonlar: sade bir açıklama, sonra en çok sarsılandan başlayan liste.
struct RRSMStationsView: View {
    let result: RRSMService.Result
    let title: String

    var body: some View {
        List {
            Section {
                Text(L("rrsm.list.intro"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(result.stations) { station in
                    VStack(alignment: .leading, spacing: 6) {
                        RRSMStationRow(station: station, maxPGA: result.peak?.pga ?? station.pga)
                        HStack(spacing: 12) {
                            Text(String(format: L("rrsm.list.accel"), RRSMFormat.pga(station.pga), RRSMFormat.percentOfGravity(station.pgaPercentG)))
                            Spacer()
                            Text(String(format: L("rrsm.list.velocity"), RRSMFormat.pgv(station.pgv)))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(title)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("rrsm.list.footer"))
                    if let url = result.eventURL {
                        Link(L("rrsm.source"), destination: url).tint(Color.appAction)
                    }
                }
            }
        }
        .navigationTitle(L("rrsm.list.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum RRSMFormat {
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(AppLanguage.currentLocale))
    }

    /// İvme cm/s² cinsinden; küçük değerlerde iki ondalık.
    static func pga(_ value: Double) -> String {
        let digits = value < 10 ? 2 : (value < 100 ? 1 : 0)
        return "\(value.formatted(.number.precision(.fractionLength(digits)).locale(AppLanguage.currentLocale))) cm/s²"
    }

    static func pgv(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(value < 1 ? 3 : 2)).locale(AppLanguage.currentLocale))) cm/s"
    }

    /// Yerçekimi ivmesinin yüzdesi, uygulama dilinin yüzde biçimiyle ("%0,87").
    static func percentOfGravity(_ value: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.Percent()
            .precision(.fractionLength(value < 1 ? 2 : 1))
            .locale(AppLanguage.currentLocale)
        return (value / 100).formatted(style)
    }

    /// Sekiz ana yön: kısa ("K", "N") ya da cümle içi uzun biçim.
    static func direction(_ index: Int, long: Bool) -> String {
        L("rrsm.dir\(long ? "Long" : "Short").\(max(0, min(7, index)))")
    }
}

private struct RRSMSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}
