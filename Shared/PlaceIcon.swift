import Foundation

/// Bildirim yerlerinin simge seti (10 Eylül 2026'da onaylandı).
///
/// Emoji klavyesinin yerine gelir. Ham değer sunucu ile yapılan sözleşmedir
/// (`functions/src/worker-utils.ts` → `PLACE_ICONS`); değiştirilmez, yalnızca
/// eklenir. Bu dosya hem uygulamaya hem bildirim uzantısına dahildir: uzantı,
/// push yükündeki `placeIcon` değerini buradaki simge ve renkle çizer.
enum PlaceIcon: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case house, work, family, friends, school, kids, hospital, beach
    case village, mountain, travel, city, landmark, favorite, other

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .house: "house.fill"
        case .work: "briefcase.fill"
        case .family: "heart.fill"
        case .friends: "person.2.fill"
        case .school: "graduationcap.fill"
        case .kids: "figure.and.child.holdinghands"
        case .hospital: "cross.case.fill"
        case .beach: "beach.umbrella.fill"
        case .village: "tree.fill"
        case .mountain: "mountain.2.fill"
        case .travel: "airplane"
        case .city: "building.2.fill"
        case .landmark: "building.columns.fill"
        case .favorite: "star.fill"
        case .other: "mappin"
        }
    }

    /// Simgenin zemin rengi (sRGB, 0–1). Uygulama ve uzantı kendi renk
    /// tipine buradan çevirir; iki tarafın aynı rengi göstermesi garanti.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .house: (1.0, 0.478, 0.0)         // #FF7A00
        case .work: (0.231, 0.482, 0.878)      // #3B7BE0
        case .family: (0.898, 0.282, 0.302)    // #E5484D
        case .friends: (0.557, 0.424, 0.937)   // #8E6CEF
        case .school: (0.357, 0.357, 0.839)    // #5B5BD6
        case .kids: (0.839, 0.251, 0.624)      // #D6409F
        case .hospital: (0.071, 0.647, 0.580)  // #12A594
        case .beach: (0.055, 0.647, 0.776)     // #0EA5C6
        case .village: (0.188, 0.643, 0.424)   // #30A46C
        case .mountain: (0.420, 0.482, 0.549)  // #6B7B8C
        case .travel: (0.0, 0.569, 1.0)        // #0091FF
        case .city: (0.322, 0.400, 0.478)      // #52667A
        case .landmark: (0.647, 0.467, 0.165)  // #A5772A
        case .favorite: (0.878, 0.631, 0.0)    // #E0A100
        case .other: (0.761, 0.255, 0.047)     // #C2410C
        }
    }

    /// Simge setinden önceki (emojili) kayıtları en yakın simgeye taşır.
    /// Sunucudaki `normalizePlaceIcon` ile aynı eşleme.
    init(legacyEmoji emoji: String) {
        let table: [(Set<Character>, PlaceIcon)] = [
            (["🏠", "🏡", "🏘"], .house),
            (["🏢", "💼"], .work),
            (["❤", "🧡", "💛", "💚", "💙", "💜", "🤍", "👪"], .family),
            (["👥", "🧑"], .friends),
            (["🏫", "🎓", "📚"], .school),
            (["👶", "🧒", "🧸"], .kids),
            (["🏥", "⚕"], .hospital),
            (["🏖", "⛱", "🌊", "🏝"], .beach),
            (["🌳", "🌲", "🌾", "🚜"], .village),
            (["⛰", "🏔", "🏕"], .mountain),
            (["✈", "🧳", "🛫"], .travel),
            (["🏙", "🌆", "🌃", "🏬"], .city),
            (["🏛", "🕌", "⛪", "🏰"], .landmark),
            (["⭐", "🌟"], .favorite)
        ]
        // Emoji çoğu zaman görünmez bir biçim seçiciyle (U+FE0F) gelir;
        // karşılaştırma yalnızca ilk skaler üzerinden yapılır.
        let base = emoji.unicodeScalars.first.map { Character($0) }
        self = table.first { entry in base.map(entry.0.contains) ?? false }?.1 ?? .other
    }
}
