import SwiftUI
import UIKit

/// Enkaz modu: enkaz altında kalan kişi için tek dokunuşla sürekli sinyal.
/// Düdük belirli aralıklarla kısa süre öter (pil ve duyulabilirlik dengesi),
/// SOS ışığı sürekli yanıp söner, ekran kapanmaz. İnternet gerekmez.
///
/// Düdük sürekli değil aralıklı: kurtarma ekipleri "sessizlik anlarında"
/// dinler, ayrıca sürekli ses pili hızla tüketir.
struct TrappedModeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private let tools = EmergencyTools.shared

    @State private var isSignaling = false
    @State private var startedAt = Date()
    @State private var cycleTask: Task<Void, Never>?
    @State private var batteryLevel: Float = UIDevice.current.batteryLevel

    /// Düdük döngüsü: `whistleSeconds` öter, `pauseSeconds` susar.
    private static let whistleSeconds: Double = 3
    private static let pauseSeconds: Double = 12

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    signalButton
                    if let url = EmergencyNumber.callURL {
                        Link(destination: url) {
                            Label(String(format: L("response.call"), EmergencyNumber.local), systemImage: "phone.fill")
                        }
                        .buttonStyle(.sismikSecondary)
                    }
                    tips
                }
                .padding(20)
                .sismikContentWidth()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L("trapped.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.close")) { dismiss() }
                        .font(.headline)
                }
            }
        }
        // SOS ekran flaşı: torch'u olmayan durumda da görünür sinyal.
        .overlay {
            if tools.screenFlashOn {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .task {
            UIDevice.current.isBatteryMonitoringEnabled = true
            UIApplication.shared.isIdleTimerDisabled = true
            batteryLevel = UIDevice.current.batteryLevel
            // Acil ekranı kaybolurken araçları durduruyor; geçiş bitince başla.
            try? await Task.sleep(for: .milliseconds(600))
            start()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onDisappear {
            stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isSignaling, !tools.isSOSOn { tools.toggleSOS() }
        }
    }

    private var statusCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isSignaling ? L("trapped.signaling") : L("trapped.paused"))
                        .font(.headline)
                        .foregroundStyle(isSignaling ? Color.brandOrange : .secondary)
                    Text(String(format: L("trapped.elapsed"), elapsedText(context.date)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if batteryLevel >= 0 {
                    Label("\(Int((batteryLevel * 100).rounded()))%", systemImage: batterySymbol)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(batteryLevel < 0.2 ? .red : .primary)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var batterySymbol: String {
        switch batteryLevel {
        case ..<0.15: "battery.0percent"
        case ..<0.4: "battery.25percent"
        case ..<0.65: "battery.50percent"
        case ..<0.9: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func elapsedText(_ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var signalButton: some View {
        Button {
            isSignaling ? stop() : start()
        } label: {
            Label(
                isSignaling ? L("trapped.stop") : L("trapped.start"),
                systemImage: isSignaling ? "pause.fill" : "dot.radiowaves.left.and.right"
            )
        }
        .buttonStyle(.sismikPrimary(height: 64, tint: isSignaling ? Color(.systemGray) : .brandOrange))
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("trapped.tips.title"))
                .font(.subheadline.weight(.semibold))
            ForEach(1...5, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index)")
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(L("trapped.tip.\(index)"))
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func start() {
        guard !isSignaling else { return }
        isSignaling = true
        startedAt = Date()
        if !tools.isSOSOn { tools.toggleSOS() }
        cycleTask = Task { @MainActor in
            while !Task.isCancelled {
                if !tools.isWhistleOn { tools.toggleWhistle() }
                try? await Task.sleep(for: .seconds(Self.whistleSeconds))
                if tools.isWhistleOn { tools.toggleWhistle() }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(Self.pauseSeconds))
            }
        }
    }

    private func stop() {
        cycleTask?.cancel()
        cycleTask = nil
        isSignaling = false
        tools.stopAll()
    }
}
