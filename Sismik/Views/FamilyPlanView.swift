import CoreLocation
import MessageUI
import SwiftUI

/// Aile buluşma planı: buluşma noktaları ve kişiler; tek dokunuşla hepsine
/// konumlu "Güvendeyim" SMS'i. SMS hücresel şebekeyle gider, mobil veri ya da
/// Wi-Fi gerekmez — deprem sonrasında internet çökse bile çoğu zaman ulaşır.
struct FamilyPlanView: View {
    @Environment(LocationManager.self) private var locationManager
    @State private var store = FamilyPlanStore.shared
    @State private var composer: MessageDraft?

    var body: some View {
        Form {
            Section {
                sendButton(safe: true)
                sendButton(safe: false)
            } footer: {
                Text(store.plan.smsRecipients.isEmpty ? L("family.sms.noContacts") : L("family.sms.footer"))
            }

            Section {
                TextField(L("family.meeting.nearby.placeholder"), text: $store.plan.nearbyMeetingPoint, axis: .vertical)
                TextField(L("family.meeting.outside.placeholder"), text: $store.plan.outsideMeetingPoint, axis: .vertical)
            } header: {
                Text(L("family.meeting.header"))
            } footer: {
                Text(L("family.meeting.footer"))
            }

            Section {
                TextField(L("family.contact.name"), text: $store.plan.outOfTownContact.name)
                    .textContentType(.name)
                TextField(L("family.contact.phone"), text: $store.plan.outOfTownContact.phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            } header: {
                Text(L("family.outOfTown.header"))
            } footer: {
                Text(L("family.outOfTown.footer"))
            }

            Section {
                ForEach($store.plan.contacts) { $contact in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(L("family.contact.name"), text: $contact.name)
                            .textContentType(.name)
                        TextField(L("family.contact.phone"), text: $contact.phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { store.plan.contacts.remove(atOffsets: $0) }
                if store.plan.contacts.count < 10 {
                    Button {
                        store.plan.contacts.append(.init(name: "", phone: ""))
                    } label: {
                        Label(L("family.contacts.add"), systemImage: "plus.circle.fill")
                    }
                }
            } header: {
                Text(L("family.contacts.header"))
            }

            Section {
                TextField(L("family.notes.placeholder"), text: $store.plan.notes, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text(L("family.notes.header"))
            }
        }
        .navigationTitle(L("family.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $composer) { draft in
            MessageComposer(draft: draft) { composer = nil }
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func sendButton(safe: Bool) -> some View {
        let recipients = store.plan.smsRecipients
        Button {
            composer = MessageDraft(recipients: recipients, body: messageBody(safe: safe))
        } label: {
            Label(safe ? L("family.sms.safe") : L("family.sms.help"),
                  systemImage: safe ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(safe ? Color.brandGreen : .red)
                .font(.body.weight(.semibold))
        }
        .disabled(recipients.isEmpty || !MFMessageComposeViewController.canSendText())
    }

    private func messageBody(safe: Bool) -> String {
        var text = safe
            ? L("Güvendeyim. Herhangi bir olumsuz durum yok, iyiyim.")
            : L("ACİL DURUM! Yardıma ihtiyacım var, güvende değilim!")
        let location = locationManager.location
            ?? LocationManager.cachedCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        if let location {
            // SMS'te bağlantı açılmasa da koordinat okunabilir kalsın.
            let lat = String(format: "%.5f", location.coordinate.latitude)
            let lon = String(format: "%.5f", location.coordinate.longitude)
            text += "\n\(lat), \(lon)\nhttps://maps.apple.com/?ll=\(lat),\(lon)"
        }
        if safe, !store.plan.nearbyMeetingPoint.isEmpty {
            text += "\n" + String(format: L("family.sms.meeting"), store.plan.nearbyMeetingPoint)
        }
        return text
    }
}

struct MessageDraft: Identifiable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

/// Sistem SMS düzenleyicisi. Gönderme kararı her zaman kullanıcıda.
private struct MessageComposer: UIViewControllerRepresentable {
    let draft: MessageDraft
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = draft.recipients
        controller.body = draft.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
