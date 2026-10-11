import SwiftUI

/// Acil durumlarda ilk yardım ve arama kurtarma ekiplerinin erişebileceği profesyonel tıbbi & kişisel bilgi kartı.
/// %100 çevrimdışı çalışır; cihaz hafızasında güvenle saklanır. Emojisiz, yüksek kontraslı profesyonel kimlik.
struct EmergencyCard: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var isPet: Bool = false
    var symbolIcon: String = "person.crop.circle.fill"
    var name: String = ""
    var relationOrBreed: String = "" // Örn: Kendim, Eşim, Çocuğum VEYA Golden Retriever, Tekir
    var birthDate: Date? = nil // Doğum Tarihi
    var personalPhone: String = "" // Kendi İletişim Telefon Numarası
    var emergencyContact: String = "" // Yakın / Veteriner Telefon Numarası
    var nationalIdOrPassport: String = "" // T.C. Kimlik / Pasaport / Sigorta No
    var bloodType: String = "A+" // A+, A-, B+, B-, AB+, AB-, 0+, 0-
    var chronicConditions: String = "" // Alerjiler, Astım, Diyabet vs.
    var medications: String = "" // Günlük kullanılan ilaçlar
    var isOrganDonor: Bool = false // Organ bağışçısı durumu
    var hasMedicalDevice: Bool = false // Kalp pili, protez, implant durumu
    var emergencyBagLocation: String = "" // Evde acil durum çantasının / tasmanın yeri
    var notes: String = "" // Tıbbi protez, çip numarası, beslenme notu vs.

    static let personSymbols = [
        "person.crop.circle.fill",
        "person.fill",
        "figure.2.and.child.holdinghands",
        "person.2.fill",
        "heart.text.square.fill"
    ]

    static let petSymbols = [
        "pawprint.fill",
        "dog.fill",
        "cat.fill",
        "bird.fill",
        "tortoise.fill"
    ]

    static let bloodTypes = ["A+", "A-", "B+", "B-", "AB+", "AB-", "0+", "0-", "Bilinmiyor"]

    var ageText: String? {
        guard let birthDate else { return nil }
        let now = Date()
        let years = Calendar.current.dateComponents([.year], from: birthDate, to: now).year ?? 0
        return String(format: L("card.years.format"), years)
    }

    var formattedBirthDate: String? {
        guard let birthDate else { return nil }
        return birthDate.formatted(
            .dateTime
                .day(.twoDigits)
                .month(.twoDigits)
                .year()
                .locale(AppLanguage.currentLocale)
        )
    }

    /// Kart aksiyonlarında önce acil yakını/veteriner, yoksa kişisel telefon kullanılır.
    var preferredContactPhone: String? {
        let raw = emergencyContact.isEmpty ? personalPhone : emergencyContact
        let normalized = raw.filter { $0.isNumber || $0 == "+" }
        return normalized.isEmpty ? nil : normalized
    }

    var callURL: URL? {
        preferredContactPhone.flatMap { URL(string: "tel:\($0)") }
    }

    func messageURL(body: String) -> URL? {
        guard let number = preferredContactPhone,
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "sms:\(number)&body=\(encodedBody)")
    }
}

@MainActor
@Observable
final class EmergencyCardStore {
    static let shared = EmergencyCardStore()

    var cards: [EmergencyCard] = []

    private let storageKey = "sismik_emergency_cards_v4"

    private init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([EmergencyCard].self, from: data) else {
            self.cards = []
            return
        }
        self.cards = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func add(_ card: EmergencyCard) {
        cards.append(card)
        save()
    }

    func update(_ card: EmergencyCard) {
        if let idx = cards.firstIndex(where: { $0.id == card.id }) {
            cards[idx] = card
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        cards.remove(atOffsets: offsets)
        save()
    }

    func delete(id: String) {
        cards.removeAll(where: { $0.id == id })
        save()
    }
}
