import CoreLocation
import MapKit
import SwiftUI

/// Son 24 saatin en büyük depremi. Solda büyük büyüklük ve seviye, sağda
/// merkez üssünü gösteren küçük harita: "nerede" sorusu metni okumadan
/// cevaplanır. Harita durağan bir önizleme; dokunuş kartın kendisine gider.
struct FeaturedQuakeCard: View {
    let earthquake: Earthquake
    /// Aktif kaynak filtresi "Tümü" mü (dünya çapında en büyük) yoksa tek bir
    /// kaynağa mı sınırlı (yalnızca o kaynağın en büyüğü) — başlık buna göre
    /// netleştirilir, aksi halde "en büyük" ibaresi yanıltıcı olabilir.
    let isWorldwide: Bool
    /// Başka bağlamda (ör. istatistik) üst satır metni.
    var caption: String? = nil
    var onTap: () -> Void

    private var isTR: Bool { AppLanguage.isTurkish }

    private var highlightTitle: String {
        if let caption { return caption }
        if isWorldwide {
            return L("Dünyada son 24 saatin en büyüğü")
        }
        return L("featured.largest.source", earthquake.sourceTag)
    }

    var body: some View {
        let color = earthquake.level.textColor
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onTap()
        }) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(highlightTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(verbatim: "M")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                            Text(earthquake.magnitudeString)
                                .font(.system(size: 42, weight: .heavy, design: .rounded).monospacedDigit())
                        }
                        .foregroundStyle(color)
                        Text(earthquake.level.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(color.opacity(0.14), in: Capsule())
                    }

                    Text(earthquake.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(["\(L("depth")) \(earthquake.depth.depthKmText)", earthquake.sourceTag, earthquake.date.relativeShort]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                FeaturedQuakeMap(coordinate: earthquake.clLocation.coordinate, color: color)
                    .frame(width: 104, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.sismikListRow)
        .accessibilityElement(children: .combine)
    }
}

/// Kart içindeki durağan harita: bölge ölçeğinde merkez üssü ve seviye
/// renginde halka.
///
/// Canlı `Map` yerine bir kez çekilen harita görüntüsü (MKMapSnapshotter):
/// etkileşimsiz küçük bir harita için canlı MapKit görünümü liste ekranında
/// beklerken sürekli ~%5 işlemci ve GPU harcıyordu (ölçüldü). Görüntü
/// deprem, boyut ve açık/koyu görünüm başına önbelleğe alınır.
private struct FeaturedQuakeMap: View {
    let coordinate: CLLocationCoordinate2D
    let color: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var snapshot: FeaturedMapSnapshot.Result?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color(.tertiarySystemGroupedBackground)
                if let snapshot {
                    Image(uiImage: snapshot.image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                    let ring = snapshot.ringRadius * 2
                    Circle()
                        .fill(color.opacity(0.22))
                        .overlay(Circle().stroke(color.opacity(0.6), lineWidth: 1))
                        .frame(width: ring, height: ring)
                        .position(snapshot.center)
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(snapshot.center)
                }
            }
            .task(id: FeaturedMapSnapshot.key(coordinate, size: size, dark: colorScheme == .dark)) {
                guard size.width > 1, size.height > 1 else { return }
                let result = await FeaturedMapSnapshot.make(
                    coordinate: coordinate, size: size, dark: colorScheme == .dark, scale: displayScale
                )
                withAnimation(.easeOut(duration: 0.2)) { snapshot = result }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Kart haritası görüntüsü ve önbelleği.
@MainActor
enum FeaturedMapSnapshot {
    struct Result {
        let image: UIImage
        /// Merkez üssünün görüntüdeki konumu (nokta).
        let center: CGPoint
        /// 60 km'lik halkanın görüntüdeki yarıçapı (nokta).
        let ringRadius: CGFloat
    }

    private static var cache: [String: Result] = [:]
    private static var order: [String] = []

    static func key(_ coordinate: CLLocationCoordinate2D, size: CGSize, dark: Bool) -> String {
        String(format: "%.3f,%.3f,%.0fx%.0f,%d", coordinate.latitude, coordinate.longitude, size.width, size.height, dark ? 1 : 0)
    }

    static func make(coordinate: CLLocationCoordinate2D, size: CGSize, dark: Bool, scale: CGFloat) async -> Result? {
        let key = key(coordinate, size: size, dark: dark)
        if let cached = cache[key] { return cached }

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))
        options.size = size
        options.scale = scale
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let center = snapshot.point(for: coordinate)
        // Halka yarıçapı: merkezden 60 km kuzeydeki noktanın görüntüdeki uzaklığı.
        let north = CLLocationCoordinate2D(latitude: coordinate.latitude + 60 / 111.32, longitude: coordinate.longitude)
        let edge = snapshot.point(for: north)
        let result = Result(image: snapshot.image, center: center, ringRadius: abs(center.y - edge.y))

        cache[key] = result
        order.append(key)
        if order.count > 12 { cache[order.removeFirst()] = nil }
        return result
    }
}

// MARK: - Harita Seçim Kartı

/// Haritada bir deprem işaretine dokununca açılan modern alt bilgi kartı.
/// Eski MapKit callout balonunun yerini alır: daha büyük dokunma alanı,
/// kullanıcı konumuna uzaklık ve tek dokunuşla tam detay.
struct MapQuakeCard: View {
    let earthquake: Earthquake
    let userLocation: CLLocation?
    var onDetail: () -> Void
    var onClose: () -> Void
    /// "Hissettim" raporlarının sayısı (sunucu sayaçları, CDN önbellekli).
    @State private var feltCount: Int?

    private var isTR: Bool { AppLanguage.isTurkish }

    /// Kullanıcı konumuna km cinsinden uzaklık (konum yoksa nil).
    private var distanceKm: Double? {
        guard let userLocation else { return nil }
        return userLocation.distance(from: earthquake.clLocation) / 1000.0
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Büyüklük karosu
                VStack(spacing: 1) {
                    Text(earthquake.magnitudeString)
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                    Text(earthquake.level.label)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .foregroundStyle(earthquake.level.foregroundOnColor)
                .frame(width: 54, height: 48)
                .background(earthquake.magnitudeColor,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(earthquake.displayTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(earthquake.sourceTag)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(earthquake.sourceColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(earthquake.sourceColor.opacity(0.13), in: Capsule())
                        Text(earthquake.date.relativeShort)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                }

                Spacer(minLength: 4)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.tertiarySystemFill), in: .circle)
                }
                .buttonStyle(.sismikPressable())
                .accessibilityLabel(L("done"))
            }

            // Bilgi satırı: derinlik · saat · uzaklık (varsa)
            HStack(spacing: 14) {
                cardMetric(icon: "arrow.down.to.line.compact",
                           text: earthquake.depth.depthKmText,
                           tint: .blue)
                cardMetric(icon: "clock",
                           text: earthquake.date.clockTime,
                           tint: .gray)
                if let distanceKm {
                    cardMetric(icon: "location.fill",
                               text: String(format: L("%.0f km uzakta"), distanceKm),
                               tint: .brandOrange)
                }
                if let feltCount, feltCount > 0 {
                    cardMetric(icon: "hand.raised.fill",
                               text: L("map.card.felt", feltCount),
                               tint: .appAction)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.2), value: feltCount)

            Button(action: onDetail) {
                HStack(spacing: 8) {
                    Text(L("Detayları Gör"))
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.sismikPrimary)
        }
        .padding(14)
        .background { MapOverlayCardBackground() }
        .frame(maxWidth: 440)
        .task(id: earthquake.id) {
            feltCount = nil
            // Yalnızca son 3 günün depremleri için sorulur: sayaçlar deprem
            // sonrası dolar, eski kayıtlarda boş istek atılmaz.
            guard Date().timeIntervalSince(earthquake.date) < 3 * 86_400 else { return }
            feltCount = await FeltReportService.summary(for: earthquake.id)?.count
        }
    }

    private func cardMetric(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Harita kartlarının zemini

/// Haritanın üstündeki kartların ortak zemini. Gölge yalnızca şekle
/// uygulanır: bütün karta uygulanan gölge, bulanık malzemeyle birlikte
/// alttan kayma animasyonunun her karesinde canlı haritanın üstünde ayrı bir
/// çizim geçişi istiyor ve panel kasıntılı açılıyordu.
struct MapOverlayCardBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
        shape
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
            .overlay(shape.strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Kompakt Harita Filtre Paneli

/// Haritanın kendi kaynak/büyüklük/zaman filtresi — liste filtresinden tamamen
/// bağımsız. Sheet yerine dock'un hemen üzerinde duran kompakt kart: harita
/// görünür kalır, seçim anında haritaya yansır.
struct MapFilterPanel: View {
    @Bindable var viewModel: EarthquakeListViewModel
    var onClose: () -> Void
    var onPaywall: () -> Void

    private let premium = PremiumStore.shared
    private let magnitudeOptions: [Double] = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
    private var isTR: Bool { AppLanguage.isTurkish }

    var body: some View {
        VStack(spacing: 10) {
            header

            // Kaynak seçici kaldırıldı: harita artık tüm kaynakları aynı
            // fiziksel deprem için tek noktaya indiren tekilleştirme ile
            // gösteriyor; tek bir kaynağa filtrelemek bu tekilleştirmeyle
            // tutarsız sonuçlara yol açar (bkz. mapSource — hep "all").
            filterRow(icon: "bolt.fill") {
                ForEach(magnitudeOptions, id: \.self) { value in
                    chip(
                        title: value == 0
                            ? (L("Tümü"))
                            : "M\(value.formatted(.number.precision(.fractionLength(0))))+",
                        isSelected: viewModel.mapMinMagnitude == value
                    ) {
                        viewModel.mapMinMagnitude = value
                    }
                }
            }

            filterRow(icon: "clock.fill") {
                // 60/90 gün haritadan kaldırıldı: uzun dönem zaten İstatistik
                // sekmesinde görülebiliyor; harita en fazla 30 gün gösterir.
                ForEach(EarthquakeListViewModel.mapTimeRanges) { range in
                    let locked = range.isPremium && !premium.isPremium
                    chip(
                        title: range.shortTitle,
                        locked: locked,
                        isSelected: viewModel.mapTimeRange == range
                    ) {
                        viewModel.mapTimeRange = range
                    }
                }
            }
        }
        .padding(12)
        .background { MapOverlayCardBackground() }
        .frame(maxWidth: 440)
    }

    /// Başlık: canlı sonuç sayısı + sıfırla + kapat.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.appAction)
            Text(isTR
                 ? "\(viewModel.mapFiltered.count.formatted()) deprem"
                 : "\(viewModel.mapFiltered.count.formatted()) earthquakes")
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: viewModel.mapFiltered.count)

            Spacer(minLength: 4)

            if viewModel.mapActiveFilterCount > 0 {
                Button {
                    // Varsayılanlar VM ile aynı olmalı (tüm kaynaklar/tüm büyüklükler/24 sa) —
                    // aksi halde sıfırlamadan sonra rozet 1 gösterir.
                    withAnimation(.snappy(duration: 0.25)) {
                        viewModel.mapSource = "all"
                        viewModel.mapMinMagnitude = 0
                        viewModel.mapTimeRange = .day
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(L("reset"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appAction)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.appAction)
                    .frame(width: 28, height: 28)
                    .background(Color.appAction.opacity(0.12), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("done"))
        }
    }

    /// Tek satırlık filtre şeridi: ikon + yatay kaydırılabilir chip'ler.
    private func filterRow<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appAction)
                .frame(width: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content() }
            }
        }
    }

    private func chip(title: String, locked: Bool = false, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if locked {
                onPaywall()
            } else {
                withAnimation(.snappy(duration: 0.22)) { action() }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : (locked ? .secondary : .primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(Color.appAction) : AnyShapeStyle(Color(.tertiarySystemFill)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

