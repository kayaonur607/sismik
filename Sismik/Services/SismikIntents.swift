import AppIntents
import Foundation

// MARK: - Siri ve Kestirmeler
//
// Uygulamayı açmadan "Sismik'te son deprem ne?" sorusunu yanıtlar ve acil
// durum ekranını tek komutla açar. Deprem verisi önce diskteki son anlık
// görüntüden okunur (ağ yoksa da cevap verir), eskiyse sunucudan tazelenir.

/// Son deprem(ler)i sesli/yazılı özetler.
struct LatestEarthquakeIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("intent.latest.title", table: "Intents")
    static let description = IntentDescription(LocalizedStringResource("intent.latest.description", table: "Intents"))

    @Parameter(title: LocalizedStringResource("intent.latest.minMagnitude", table: "Intents"), default: 3.0, inclusiveRange: (0, 9))
    var minimumMagnitude: Double

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var quakes = await QuakeCache.shared.load()
        // Önbellek 10 dakikadan eskiyse (ya da boşsa) sunucudan tazele.
        let newest = quakes.map(\.date).max() ?? .distantPast
        if Date().timeIntervalSince(newest) > 600 {
            let live = await EarthquakeService.shared.liveSnapshot(minMagnitude: 0).quakes
            if !live.isEmpty { quakes = live }
        }
        let threshold = minimumMagnitude
        let dayAgo = Date().addingTimeInterval(-86_400)
        let matches = quakes
            .filter { $0.magnitude >= threshold && $0.date >= dayAgo }
            .sorted { $0.date > $1.date }

        guard let latest = matches.first else {
            return .result(dialog: IntentDialog(stringLiteral: L("intent.latest.none", threshold)))
        }
        let largest = matches.max { $0.magnitude < $1.magnitude } ?? latest
        var text = L("intent.latest.answer", latest.magnitudeString, latest.displayTitle, latest.date.relativeShort)
        if largest.id != latest.id {
            text += " " + L("intent.latest.largest", largest.magnitudeString, largest.displayTitle)
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Uygulamayı Acil Durum ekranında açar (112, düdük, fener, konum paylaşımı).
struct OpenEmergencyIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("intent.emergency.title", table: "Intents")
    static let description = IntentDescription(LocalizedStringResource("intent.emergency.description", table: "Intents"))
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = URL(string: "sismik://emergency") {
            QuickActionRouter.shared.pendingURL = url
        }
        return .result()
    }
}

/// Uygulamayı deprem haritasında açar.
struct OpenQuakeMapIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("intent.map.title", table: "Intents")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = URL(string: "sismik://map") {
            QuickActionRouter.shared.pendingURL = url
        }
        return .result()
    }
}

struct SismikShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LatestEarthquakeIntent(),
            phrases: [
                "Latest earthquake in \(.applicationName)",
                "What was the last earthquake on \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("intent.latest.short", table: "Intents"),
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: OpenEmergencyIntent(),
            phrases: [
                "Open emergency in \(.applicationName)",
                "\(.applicationName) emergency"
            ],
            shortTitle: LocalizedStringResource("intent.emergency.short", table: "Intents"),
            systemImageName: "cross.case"
        )
        AppShortcut(
            intent: OpenQuakeMapIntent(),
            phrases: ["Show earthquake map in \(.applicationName)"],
            shortTitle: LocalizedStringResource("intent.map.short", table: "Intents"),
            systemImageName: "map"
        )
    }
}
