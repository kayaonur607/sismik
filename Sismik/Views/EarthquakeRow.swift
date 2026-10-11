import SwiftUI
import CoreLocation

/// Son depremler listesindeki satır.
struct EarthquakeRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let earthquake: Earthquake
    var isNew: Bool = false
    var showsTsunami: Bool = false
    /// `NavigationLink` içinde kullanıldığında sistem kendi açıklama okunu
    /// çizer; ikinci bir ok göstermemek için kapatılır.
    var showsChevron: Bool = true

    /// `relativeShort` ve `clockTime` biçimlendirici çağrısıdır; satır
    /// gövdesinde ve VoiceOver etiketinde ayrı ayrı okununca her satır
    /// çiziminde dört formatlama yapılıyordu. Bir kez hesaplanıp paylaşılır.
    private var relativeText: String { earthquake.date.relativeShort }
    private var clockText: String { earthquake.date.clockTime }

    var body: some View {
        let relativeText = self.relativeText
        let clockText = self.clockText
        // Meta metni ve derinlik eskiden hem gövdede hem de VoiceOver
        // etiketinde ayrı ayrı üretiliyordu; her ikisi de sayı biçimlendirme
        // yapıyor ve satır başına aynı iş iki kez tekrarlanıyordu.
        let metaText = self.metaText
        let depthText = earthquake.depth.depthKmText
        return HStack(spacing: 12) {
            magnitudeTile

            VStack(alignment: .leading, spacing: 3) {
                // Başlık iki satıra kadar: uzun deniz/bölge adları ("Ege
                // Denizi - Çanakkale") artık kesilmiyor.
                (Text(earthquake.flag).font(.subheadline) + Text(" ") + Text(listTitle))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Tek satır, tek stil: uzaklık · derinlik · kaynak. Simgeli
                // parçalar ve renkli rozetler satırı kalabalıklaştırıyordu.
                HStack(spacing: 6) {
                    Text(metaLine(meta: metaText, depth: depthText))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if showsTsunami {
                        tsunamiBadge
                    }
                    // Turuncu/kırmızı etki seviyesi (GDACS, USGS PAGER) satırda da görünür.
                    if let impact = earthquake.impactLevel, impact.isSignificant {
                        ImpactLevelBadge(level: impact, compact: true)
                    }
                }
            }
            // Satır ayırıcısı büyüklük karosunun değil, metnin hizasından başlar.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                // Yeni gelen kayıt: rozet yerine zamanın yanında tek nokta.
                HStack(spacing: 4) {
                    if isNew {
                        Circle()
                            .fill(Color.appAction)
                            .frame(width: 6, height: 6)
                            .phaseAnimator([1.0, 0.35]) { dot, phase in
                                dot.opacity(reduceMotion ? 1 : phase)
                            } animation: { _ in .easeInOut(duration: 0.8) }
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(relativeText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(isNew ? Color.appAction : .primary)
                }

                Text(clockText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
        .contentShape(.rect)
        .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: isNew)
        // Satır VoiceOver'da tek bir öğe olarak okunur. Aksi hâlde büyüklük
        // karosu ("M", "4.2", seviye), meta satırı, kaynak rozeti ve saat ayrı
        // ayrı odaklanılan parçalar olarak okunuyor ve listede gezinmek
        // deprem başına beş altı kaydırma gerektiriyordu.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityDescription(
                relative: relativeText,
                clock: clockText,
                meta: metaText,
                depth: depthText
            )
        )
    }

    /// Derinlik başta: satır daralınca kesilen kısım il/kaynak olur, derinlik
    /// her zaman görünür.
    private func metaLine(meta: String?, depth: String) -> String {
        ["\(L("depth")) \(depth)", meta, earthquake.sourceTag]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Satırın görsel hiyerarşisini konuşma sırasına çevirir: büyüklük ve
    /// seviye, yer, uzaklık/derinlik, kaynak ve zaman.
    private func accessibilityDescription(
        relative: String,
        clock: String,
        meta: String?,
        depth: String
    ) -> String {
        var parts: [String] = [
            "M \(earthquake.magnitudeString)",
            earthquake.level.label,
            earthquake.displayTitle,
            meta ?? "",
            "\(L("depth")) \(depth)",
            earthquake.sourceTag,
            "\(relative) · \(clock)"
        ]
        if isNew { parts.insert(L("badge.live"), at: 0) }
        if showsTsunami { parts.append(L("badge.tsunami")) }
        if let impact = earthquake.impactLevel, impact.isSignificant {
            parts.append("\(L("impact.title")): \(impact.name)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Büyüklük karosu. M4 altı: seviye renginin açık tonu üstünde renkli
    /// rakam (liste sakin kalır); M4 ve üstü: dolu renk üstünde beyaz rakam
    /// (hissedilir depremler ilk bakışta öne çıkar).
    private var magnitudeTile: some View {
        let color = earthquake.magnitudeColor
        let prominent = earthquake.magnitude >= 4
        return Text(earthquake.magnitudeString)
            .font(.system(size: 20, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundStyle(prominent ? earthquake.level.foregroundOnColor : earthquake.level.textColor)
            .frame(width: 50, height: 40)
            .background(
                prominent ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.15)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            // Canlı akışa yeni giren deprem: karonun çevresinden dalga yayılır.
            .overlay {
                if isNew && !reduceMotion {
                    NewQuakeRipple(color: color)
                        .transition(.opacity)
                }
            }
    }


    /// Listede kısaltılmış başlık. AFAD "Doğanşehir (Malatya)" yazar ve il
    /// alt satırda zaten görünür; tekrar başlığı kesiyordu. Deniz kayıtlarındaki
    /// "[40.32 km]" gibi ara mesafeler de satırda anlam taşımıyor.
    private var listTitle: String {
        guard earthquake.sourceTag == "AFAD" else { return earthquake.displayTitle }
        let city = earthquake.locationProperties.closestCity?.name
        // Kaydırırken her satır çiziminde düzenli ifade çalışıyordu; sonuç
        // başlık + il çiftine göre önbellekte tutulur.
        let key = "\(earthquake.displayTitle)|\(city ?? "")" as NSString
        if let cached = Self.listTitleCache.object(forKey: key) { return cached as String }
        let title = Self.trimmedAFADTitle(earthquake.displayTitle, city: city)
        Self.listTitleCache.setObject(title as NSString, forKey: key)
        return title
    }

    private static let listTitleCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2_000
        return cache
    }()
    private static let turkishLocale = Locale(identifier: "tr_TR")

    static func trimmedAFADTitle(_ displayTitle: String, city: String?) -> String {
        var title = displayTitle
        if title.contains("[") {
            title = title.replacingOccurrences(of: #"\s*\[[^\]]*\]\s*"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        if let city, let open = title.lastIndex(of: "("), title.hasSuffix(")") {
            let inner = title[title.index(after: open)..<title.index(before: title.endIndex)]
            if inner.compare(city, options: [.caseInsensitive, .diacriticInsensitive], locale: turkishLocale) == .orderedSame {
                title = String(title[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    /// Kaynağın verdiği en yakın yerleşim (AFAD: il).
    private var metaText: String? {
        if let city = earthquake.locationProperties.closestCity {
            if let d = city.distance { return "\(city.name) \(d.metersAsKmText)" }
            return city.name
        }
        return nil
    }

    private var tsunamiBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "water.waves")
                .font(.system(size: 8, weight: .bold))
            Text(L("badge.tsunami"))
                .font(.system(size: 8, weight: .black))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.cyan, in: Capsule())
    }
}

/// Yeni depremin büyüklük karosundan yayılan dalga: sismik dalga gibi dışa
/// doğru büyüyüp söner, `isNew` süresince (8 sn) tekrarlar.
private struct NewQuakeRipple: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(color, lineWidth: 2)
            .phaseAnimator([false, true]) { shape, expanded in
                shape
                    .scaleEffect(expanded ? 1.35 : 1)
                    .opacity(expanded ? 0 : 0.85)
            } animation: { expanded in
                expanded ? .easeOut(duration: 1.3) : .linear(duration: 0.01)
            }
            .allowsHitTesting(false)
    }
}
