import AVFoundation
import Foundation
import UserNotifications

/// Uygulamaya paketlenen bildirim sesleri (Scripts/generate-notification-sounds.py
/// ile üretilir). Standart sesler olağan deprem bildiriminde, kritik sesler
/// sessiz modu aşan kritik uyarıda çalar; kullanıcı ikisini ayrı seçer.
/// Dosya adları sunucuyla sözleşmedir (functions/src/push-routes.ts).
enum NotificationSoundOption: String, CaseIterable, Identifiable {
    case sismik = "bildirim.caf"
    case pulse = "sismik_pulse.caf"
    case signal = "sismik_signal.caf"
    case deep = "sismik_deep.caf"
    case criticalAlarm = "sismik_critical_alarm.caf"
    case criticalSiren = "sismik_critical_siren.caf"
    case criticalBeacon = "sismik_critical_beacon.caf"

    static let defaultOption: Self = .sismik
    static let defaultCriticalOption: Self = .criticalAlarm

    static let standardOptions: [Self] = [.sismik, .pulse, .signal, .deep]
    static let criticalOptions: [Self] = [.criticalAlarm, .criticalSiren, .criticalBeacon]

    var isCritical: Bool { Self.criticalOptions.contains(self) }

    var id: String { rawValue }
    var fileName: String { rawValue }

    var title: String {
        switch self {
        case .sismik: L("sound.sismik")
        case .pulse:  L("sound.pulse")
        case .signal: L("sound.signal")
        case .deep:   L("sound.deep")
        case .criticalAlarm: L("sound.critical.alarm")
        case .criticalSiren: L("sound.critical.siren")
        case .criticalBeacon: L("sound.critical.beacon")
        }
    }

    var detail: String {
        switch self {
        case .sismik: L("sound.sismik.desc")
        case .pulse:  L("sound.pulse.desc")
        case .signal: L("sound.signal.desc")
        case .deep:   L("sound.deep.desc")
        case .criticalAlarm: L("sound.critical.alarm.desc")
        case .criticalSiren: L("sound.critical.siren.desc")
        case .criticalBeacon: L("sound.critical.beacon.desc")
        }
    }

    var notificationSound: UNNotificationSound {
        UNNotificationSound(named: UNNotificationSoundName(rawValue: fileName))
    }
}

/// Seçim ekranında sesi, bildirim oluşturmadan anında dinletir.
/// `playingSound`, çalmakta olan sesi yayınlar; ayarlar ekranı bu değere
/// bakarak ilgili satırda canlı bir dalga göstergesi gösterir.
@MainActor
@Observable
final class NotificationSoundPreviewPlayer {
    static let shared = NotificationSoundPreviewPlayer()

    private(set) var playingSound: NotificationSoundOption?

    @ObservationIgnored private var player: AVAudioPlayer?
    /// Çalma bitince göstergeyi kapatan iş; yeni bir ses seçilirse iptal edilir.
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    private init() {}

    func play(_ sound: NotificationSoundOption) {
        let resource = sound.fileName as NSString
        let name = resource.deletingPathExtension
        let ext = resource.pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
                ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer

            // Önceki sesin bitiş sayacı iptal edilir; aksi halde yeni ses
            // çalarken eski sayaç göstergeyi erkenden kapatabilir.
            stopTask?.cancel()
            playingSound = sound
            let duration = max(0.2, newPlayer.duration)
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.playingSound = nil
            }
        } catch {
            playingSound = nil
            AppLog.notifications.error("notification sound preview failed=\(error.localizedDescription, privacy: .public)")
        }
    }
}
