import Foundation

/// Bir ekranın veri yaşam döngüsünü tek bir kaynaktan ifade eder.
///
/// Önbellekte veri varken arka plan yenilemesi `loaded` durumunu korur;
/// böylece arayüz skeleton'a geri dönmez ve içerik sıçramaz.
enum ViewState<Value> {
    case idle
    case loading
    case loaded(Value)
    case error(any Error)

    var value: Value? {
        guard case let .loaded(value) = self else { return nil }
        return value
    }

    var isInitialLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var failure: (any Error)? {
        guard case let .error(error) = self else { return nil }
        return error
    }
}

/// `@Observable` ayarlayıcısının gereksiz geçersizleştirmeyi atlayabilmesi için.
///
/// SWR yenilemesi ekrandaki veriyi korumak adına bilerek aynı değeri yeniden
/// atıyor (`viewState = .loaded(earthquakes)`). Tip karşılaştırılabilir
/// olmadığı sürece makro bunu ayırt edemiyor ve içerik bayt bayt aynı olsa da
/// `viewState` okuyan her görünüm her yoklamada yeniden çiziliyordu.
///
/// `Value` karşılaştırılamadığında (ör. `FaultSegment`) koşullu uyum devreye
/// girmez ve davranış aynı kalır.
extension ViewState: Equatable where Value: Equatable {
    static func == (lhs: ViewState, rhs: ViewState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            true
        case let (.loaded(lhsValue), .loaded(rhsValue)):
            lhsValue == rhsValue
        // `any Error` karşılaştırılamaz; hata durumu her zaman değişmiş
        // sayılır, yani bugünkü davranış korunur.
        default:
            false
        }
    }
}

/// Servis hatalarını kullanıcıya gösterilebilir ve test edilebilir bir tipe çevirir.
struct ViewStateError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
