import UserNotifications
import UIKit

/// Deprem bildirimine kayıtlı yerin simgesini ekler.
///
/// Sunucu, yer eşleşmesinde yüke `placeIcon` ve `mutable-content: 1` koyar.
/// iOS bildirimi göstermeden önce bu uzantıyı çalıştırır; uzantı simgeyi
/// renkli yuvarlatılmış bir kareye çizip ek olarak iliştirir ve bildirimin
/// sağında küçük görsel olarak görünür. Sismik logosu solda kalır.
///
/// Uzantı yalnızca süslemedir: çizim başarısız olursa ya da süre dolarsa
/// bildirim olduğu gibi, eksiksiz metniyle gösterilir.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = content

        if let raw = content.userInfo["placeIcon"] as? String,
           let url = PlaceIconArtwork.writePNG(for: PlaceIcon(rawValue: raw) ?? .other),
           let attachment = try? UNNotificationAttachment(identifier: "placeIcon", url: url) {
            content.attachments = [attachment]
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }
}
