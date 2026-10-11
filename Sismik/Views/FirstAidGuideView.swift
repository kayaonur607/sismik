import AudioToolbox
import SwiftUI
import UIKit

/// Çevrimdışı ilk yardım rehberi: deprem sonrasında en sık gereken yedi
/// durum, her biri dört adım. Metinler uygulamanın içinde; internet gerekmez.
/// Kalp masajı sayfasında dakikada 110 vuruşluk ritim tutucu var.
struct FirstAidGuideView: View {
    enum Topic: String, CaseIterable, Identifiable {
        case bleeding, unconscious, cpr, fracture, crush, burn, shock

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .bleeding: "drop.fill"
            case .unconscious: "person.fill.questionmark"
            case .cpr: "heart.fill"
            case .fracture: "bandage.fill"
            case .crush: "square.stack.3d.down.forward.fill"
            case .burn: "flame.fill"
            case .shock: "thermometer.snowflake"
            }
        }

        var title: String { L("firstaid.\(rawValue).title") }
        var summary: String { L("firstaid.\(rawValue).summary") }
        var steps: [String] { (1...4).map { L("firstaid.\(rawValue).step\($0)") } }
    }

    var body: some View {
        List {
            Section {
                Label(L("firstaid.disclaimer"), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Topic.allCases) { topic in
                    NavigationLink {
                        FirstAidTopicView(topic: topic)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: topic.icon)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.red)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title).font(.body.weight(.semibold))
                                Text(topic.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(L("firstaid.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FirstAidTopicView: View {
    let topic: FirstAidGuideView.Topic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(topic.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.red, in: Circle())
                        Text(step)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if topic == .cpr {
                    CPRMetronome()
                        .padding(.top, 8)
                }
                if let url = EmergencyNumber.callURL {
                    Link(destination: url) {
                        Label(String(format: L("response.call"), EmergencyNumber.local), systemImage: "phone.fill")
                    }
                    .buttonStyle(.sismikPrimary(tint: .red))
                    .padding(.top, 8)
                }
            }
            .padding(20)
            .sismikContentWidth()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Kalp masajı ritim tutucu: dakikada 110 vuruş (önerilen aralık 100–120).
/// Ses, titreşim ve büyüyüp küçülen daire aynı anda; sessiz modda da
/// titreşim ve görsel ritim sürer. Açıkken ekran kapanmaz.
private struct CPRMetronome: View {
    private static let beatsPerMinute = 110.0

    @State private var isRunning = false
    @State private var beat = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(Color.red.opacity(isRunning ? 0.9 : 0.25))
                .frame(width: 96, height: 96)
                .scaleEffect(isRunning && beat % 2 == 0 ? 1.0 : 0.82)
                .animation(.easeOut(duration: 0.12), value: beat)
                .overlay {
                    Text(isRunning ? "\(beat % 30 + 1)" : "110")
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            Text(L("firstaid.cpr.metronome.caption"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                isRunning ? stop() : start()
            } label: {
                Label(isRunning ? L("firstaid.cpr.metronome.stop") : L("firstaid.cpr.metronome.start"),
                      systemImage: isRunning ? "stop.fill" : "metronome.fill")
            }
            .buttonStyle(.sismikSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDisappear { stop() }
    }

    private func start() {
        isRunning = true
        beat = 0
        UIApplication.shared.isIdleTimerDisabled = true
        let interval = 60.0 / Self.beatsPerMinute
        let haptic = UIImpactFeedbackGenerator(style: .rigid)
        task = Task { @MainActor in
            var next = ContinuousClock.now
            while !Task.isCancelled {
                // 1104: sistem tık sesi; sessiz modda çalmaz, titreşim sürer.
                AudioServicesPlaySystemSound(1104)
                haptic.impactOccurred()
                beat += 1
                next += .seconds(interval)
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
