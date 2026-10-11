import AVFoundation
import Observation

/// Acil durumda işe yarayan donanım araçları: el feneri, siren, düdük ve SOS (mors) sinyali.
/// El feneri/SOS torch'u kullanır (simülatörde torch yoktur — sessizce yok sayılır,
/// SOS ayrıca ekran flaşı verir). Siren ve düdük sentezlenir; ses dosyası gerektirmez ve
/// sessiz modda bile duyulur (playback kategorisi).
@MainActor
@Observable
final class EmergencyTools {
    static let shared = EmergencyTools()

    var isTorchOn = false
    var isSirenOn = false
    var isWhistleOn = false
    var isSOSOn = false
    /// SOS sırasında ekranı yakıp söndürmek için (torch'u olmayan cihaz/simülatörde de görünür).
    var screenFlashOn = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var sirenBuffer: AVAudioPCMBuffer?
    private var whistleBuffer: AVAudioPCMBuffer?
    private var sosTask: Task<Void, Never>?

    init() {
        // Tamponlar ilk kullanımda (startSiren/startWhistle çağrısında) on-demand oluşturulur.
        // Böylece açılışta gereksiz thread açılmaz ve non-Sendable AVAudioPCMBuffer nesneleri sınır geçişine zorlanmaz.
    }

    // MARK: El feneri

    func toggleTorch() {
        if isSOSOn { stopSOS() }
        setTorch(!isTorchOn)
    }

    private func setTorch(_ on: Bool) {
        writeTorch(on)
        isTorchOn = on
    }

    /// Donanıma doğrudan yazar (UI durumunu değiştirmez — SOS bunu kullanır).
    private func writeTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if on { try device.setTorchModeOn(level: 1.0) } else { device.torchMode = .off }
            device.unlockForConfiguration()
        } catch { /* torch meşgul/erişilemez — yok say */ }
    }

    // MARK: Siren

    func toggleSiren() {
        if isWhistleOn { stopWhistle() }
        isSirenOn ? stopSiren() : startSiren()
    }

    private func startSiren() {
        configureAudioSession()
        if sirenBuffer == nil { sirenBuffer = Self.makeSirenBuffer() }
        guard let buffer = sirenBuffer else { return }
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        }
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isSirenOn = true
        } catch { isSirenOn = false }
    }

    private func stopSiren() {
        player.stop()
        engine.stop()
        isSirenOn = false
        deactivateAudioSession()
    }

    // MARK: Düdük (Yeni Özellik)

    func toggleWhistle() {
        if isSirenOn { stopSiren() }
        isWhistleOn ? stopWhistle() : startWhistle()
    }

    private func startWhistle() {
        configureAudioSession()
        if whistleBuffer == nil { whistleBuffer = Self.makeWhistleBuffer() }
        guard let buffer = whistleBuffer else { return }
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        }
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isWhistleOn = true
        } catch { isWhistleOn = false }
    }

    private func stopWhistle() {
        player.stop()
        engine.stop()
        isWhistleOn = false
        deactivateAudioSession()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
            try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// İki tonlu (yükselen-alçalan) siren tamponu; faz sürekliliğiyle tıkırtısız.
    nonisolated private static func makeSirenBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        let duration = 1.2
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            // İlk yarı 950 Hz, ikinci yarı 700 Hz (klasik acil siren hissi).
            let freq = t.truncatingRemainder(dividingBy: duration) < duration / 2 ? 950.0 : 700.0
            phase += 2 * .pi * freq / sampleRate
            samples[i] = 0.9 * Float(sin(phase))
        }
        return buffer
    }

    /// Yüksek perdeli kesik düdük sesi tamponu (göçük altı aramaları için optimize edilmiş frekans: 2600 Hz)
    nonisolated private static func makeWhistleBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        let duration = 0.8
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            // Arama ekiplerinin ve köpeklerin en duyarlı olduğu 2600 Hz tiz frekansı
            let freq = 2600.0
            phase += 2 * .pi * freq / sampleRate
            
            // Düdük üfleme ritmi (0.45 sn sesli, 0.35 sn sessiz)
            let cycleTime = t.truncatingRemainder(dividingBy: duration)
            let amplitude: Float = cycleTime < 0.45 ? 0.85 : 0.0
            
            samples[i] = amplitude * Float(sin(phase))
        }
        return buffer
    }

    // MARK: SOS (mors) — torch + ekran flaşı

    func toggleSOS() { isSOSOn ? stopSOS() : startSOS() }

    private func startSOS() {
        if isTorchOn { setTorch(false) }
        isSOSOn = true
        sosTask = Task { @MainActor [weak self] in
            let unit: UInt64 = 220_000_000 // ~0.22 sn (mors nokta süresi)
            // S O S = · · ·  – – –  · · ·  (uzunluklar nokta cinsinden)
            let pattern = [1, 1, 1, 3, 3, 3, 1, 1, 1]
            while !Task.isCancelled {
                for length in pattern {
                    guard !Task.isCancelled else { break }
                    self?.flash(true)
                    if (try? await Task.sleep(nanoseconds: unit * UInt64(length))) == nil {
                        self?.flash(false)
                        return
                    }
                    self?.flash(false)
                    if (try? await Task.sleep(nanoseconds: unit)) == nil {
                        return
                    }
                }
                if (try? await Task.sleep(nanoseconds: unit * 5)) == nil {
                    return
                }
            }
            self?.flash(false)
        }
    }

    private func flash(_ on: Bool) {
        writeTorch(on)
        screenFlashOn = on
    }

    func stopSOS() {
        sosTask?.cancel()
        sosTask = nil
        isSOSOn = false
        screenFlashOn = false
        writeTorch(false)
    }

    /// Ekran kapanırken/araç bırakılırken her şeyi durdur.
    func stopAll() {
        stopSOS()
        if isSirenOn { stopSiren() }
        if isWhistleOn { stopWhistle() }
        setTorch(false)
    }
}
