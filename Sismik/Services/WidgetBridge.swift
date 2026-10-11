import Foundation
import WidgetKit

/// Uygulamadan widget'lara veri ve dil aktarımı (`WidgetSharedStore`).
///
/// Widget'lar uygulamanın ana listesinin aynısını gösterir ve kendileri hiç
/// ağa çıkmaz: liste burada App Group'a yazılır, ardından zaman çizelgeleri
/// yenilenir.
enum WidgetBridge {
    /// Listede görünen depremleri ve aktif filtreyi yazar (çağıran taraf
    /// sıklığı sınırlar).
    static func publish(_ list: [Earthquake], sources: Set<String>, minMagnitude: Double) {
        let quakes = list
            .sorted { $0.date > $1.date }
            .map {
                WidgetSnapshot.Quake(
                    id: $0.id,
                    provider: $0.sourceTag,
                    title: $0.displayTitle,
                    magnitude: $0.magnitude,
                    depth: $0.depth,
                    date: $0.date
                )
            }
        let snapshot = WidgetSnapshot(generatedAt: Date(), quakes: quakes,
                                      sources: sources.sorted(), minMagnitude: minMagnitude)
        // Kodlama ve disk yazımı ana iş parçacığını meşgul etmez; yenileme
        // isteği dosya yazıldıktan SONRA gider (widget eski dosyayı okumasın).
        Task.detached(priority: .utility) {
            WidgetSharedStore.write(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Arka plan yenilemesi: az önce çekilen canlı listeden, uygulamada en son
    /// görülen filtreyle (yoksa varsayılan: tüm kaynaklar, tüm büyüklükler)
    /// listenin aynısını üretip yazar.
    static func publishInBackground(_ quakes: [Earthquake]) {
        let filter = WidgetSharedStore.listFilter
        let sources = Set(filter?.sources ?? EarthquakeListViewModel.allSources)
        let minMagnitude = filter?.minMagnitude ?? 0
        let list = EarthquakeListViewModel.widgetList(from: quakes, sources: sources, minMagnitude: minMagnitude)
        publish(list, sources: sources, minMagnitude: minMagnitude)
    }

    /// Ana ekranda en az bir Sismik widget'ı var mı (arka plan yenilemesi,
    /// bildirimler kapalıyken yalnızca widget varsa ağa çıkar).
    static func hasInstalledWidgets() async -> Bool {
        let configurations = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        return !configurations.isEmpty
    }

    /// Uygulamada seçili dili widget'lara bildirir; değiştiyse widget'lar
    /// yeni dilde yeniden çizilir.
    static func syncLanguage() {
        let code = AppLanguage.currentLanguageCode
        guard WidgetSharedStore.languageCode != code else { return }
        WidgetSharedStore.languageCode = code
        WidgetCenter.shared.reloadAllTimelines()
    }
}
