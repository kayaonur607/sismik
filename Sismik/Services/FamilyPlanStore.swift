import Foundation
import Observation

/// Aile afet planı: buluşma noktaları ve haber verilecek kişiler. Yalnızca
/// cihazda (UserDefaults) tutulur; sunucuya gönderilmez, internetsiz okunur.
struct FamilyPlan: Codable, Equatable {
    struct Contact: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var phone: String
    }

    /// Evin yakınında, binalardan uzak açık alan.
    var nearbyMeetingPoint = ""
    /// Mahalleye ulaşılamıyorsa buluşulacak ikinci yer.
    var outsideMeetingPoint = ""
    /// Şehir dışındaki kişi: yerel hatlar kilitlenince uzak hatlar çoğu zaman açıktır.
    var outOfTownContact = Contact(name: "", phone: "")
    var contacts: [Contact] = []
    var notes = ""

    /// SMS alıcıları: boş olmayan, tekrarsız numaralar.
    var smsRecipients: [String] {
        var seen = Set<String>()
        return ([outOfTownContact] + contacts)
            .map { $0.phone.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var isEmpty: Bool {
        nearbyMeetingPoint.isEmpty && outsideMeetingPoint.isEmpty && smsRecipients.isEmpty
    }
}

@MainActor
@Observable
final class FamilyPlanStore {
    static let shared = FamilyPlanStore()
    private static let key = "familyPlan.v1"

    var plan: FamilyPlan {
        didSet {
            guard plan != oldValue, let data = try? JSONEncoder().encode(plan) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(FamilyPlan.self, from: data) {
            plan = stored
        } else {
            plan = FamilyPlan()
        }
    }
}
