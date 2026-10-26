// Clips · © 2026 OK Digital. Todos los derechos reservados.
import AVFoundation
import AppKit

/// Sonidos cortos sintetizados al arrancar (sin archivos). Suaves y solo en momentos con significado.
@MainActor
final class Sound {
    static let shared = Sound()
    enum Kind: CaseIterable { case tick, start, pop, success, error, copy }

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [Kind: AVAudioPCMBuffer] = [:]
    private var next = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

    var enabled: Bool { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }

    private init() {
        for _ in 0..<6 {
            let p = AVAudioPlayerNode()
            engine.attach(p); engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        engine.mainMixerNode.outputVolume = 0.55
        // Al cambiar la salida de audio (auriculares, AirPods) el motor se para: volver a arrancarlo.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.engine.start() }
        }
        // Clic seco y corto para controles.
        buffers[.tick] = synth(0.035) { t in Self.tone(t, 1900, 1500, 0.035) * Self.env(t, 0.001, 0.007) * 0.22 }
        // "Tin" brillante al copiar.
        buffers[.copy] = synth(0.16) { t in
            (Self.tone(t, 2637, 2637, 0.16) + 0.35 * Self.tone(t, 3951, 3951, 0.16)) * Self.env(t, 0.002, 0.04) * 0.18 }
        // Burbuja que sube cuando aparece un clip.
        buffers[.pop] = synth(0.14) { t in Self.tone(t, 420, 980, 0.07) * Self.env(t, 0.003, 0.035) * 0.34 }
        // Arranque: barrido de aire que sube.
        buffers[.start] = synth(0.32) { t in
            let n = Double.random(in: -1...1) * 0.25 * Self.env(t, 0.12, 0.08)
            return (Self.tone(t, 280, 620, 0.3) * 0.5 + n) * Self.env(t, 0.06, 0.12) * 0.3 }
        // Éxito: arpegio do–mi–sol.
        buffers[.success] = synth(0.75) { t in
            [(0.0, 1046.5), (0.08, 1318.5), (0.16, 1568.0)].reduce(0.0) { acc, n in
                let u = t - n.0
                return u < 0 ? acc : acc + (Self.tone(u, n.1, n.1, 1) + 0.2 * Self.tone(u, n.1 * 2, n.1 * 2, 1)) * Self.env(u, 0.004, 0.22) * 0.16
            } }
        // Error: dos notas graves y suaves, bajando.
        buffers[.error] = synth(0.34) { t in
            let u = t < 0.14 ? t : t - 0.14
            let f = t < 0.14 ? 392.0 : 293.7
            return Self.tone(u, f, f, 1) * Self.env(u, 0.004, 0.07) * 0.28 }
    }

    func play(_ k: Kind) {
        guard enabled, let b = buffers[k] else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        let p = players[next]; next = (next + 1) % players.count
        p.stop()
        p.scheduleBuffer(b, at: nil)
        p.play()
    }

    private func synth(_ seconds: Double, _ f: (Double) -> Double) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(seconds * format.sampleRate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        let ch = b.floatChannelData![0]
        for i in 0..<Int(n) { ch[i] = Float(f(Double(i) / format.sampleRate)) }
        return b
    }
    /// Seno con barrido de frecuencia (f0 → f1 durante `sweep` segundos), con fase integrada.
    private static func tone(_ t: Double, _ f0: Double, _ f1: Double, _ sweep: Double) -> Double {
        let k = (f1 - f0) / max(sweep, 0.0001)
        let phase = t < sweep ? f0 * t + 0.5 * k * t * t : f0 * sweep + 0.5 * k * sweep * sweep + f1 * (t - sweep)
        return sin(2 * .pi * phase)
    }
    private static func env(_ t: Double, _ attack: Double, _ decay: Double) -> Double {
        min(1, t / attack) * exp(-max(0, t - attack) / decay)
    }
}

/// Toque háptico en el trackpad, a la vez que el sonido.
func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
    NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
}
