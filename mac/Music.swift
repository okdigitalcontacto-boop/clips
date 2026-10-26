// Clips · © 2026 OK Digital. Todos los derechos reservados.
import Foundation
import AVFoundation

// MARK: - Música de fondo compuesta en el momento (sin archivos ni derechos de terceros)

enum MusicMood: String, CaseIterable, Identifiable {
    case calm = "Calma", energy = "Energía"
    var id: String { rawValue }
}

/// Generador pseudoaleatorio con semilla, para que cada clip tenga su tema y se repita igual al volver a montarlo.
private struct Seeded {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}

private func midiHz(_ n: Double) -> Double { 440 * pow(2, (n - 69) / 12) }

/// Compone y escribe un .wav estéreo de `seconds` segundos.
func composeMusic(mood: MusicMood, seconds: Double, seed: UInt64, to url: URL) throws {
    let sr = 44100.0
    let n = Int((seconds + 1) * sr)
    var L = [Float](repeating: 0, count: n), R = [Float](repeating: 0, count: n)
    var rng = Seeded(seed)

    let bpm = mood == .calm ? 78.0 + Double(rng.next() % 8) : 108.0 + Double(rng.next() % 10)
    let beat = 60 / bpm, bar = beat * 4
    let root = Double(rng.pick([57, 60, 62, 65, 55]))      // La, Do, Re, Fa, Sol
    // Acordes en semitonos sobre la tónica (tonalidad mayor).
    let I = [0.0, 4, 7, 11], ii = [2.0, 5, 9, 12], IV = [5.0, 9, 12, 16], V = [7.0, 11, 14, 17], vi = [9.0, 12, 16, 19]
    let progression: [[Double]] = mood == .calm
        ? rng.pick([[I, vi, ii, V], [I, vi, IV, V], [IV, I, vi, V]])
        : rng.pick([[vi, IV, I, V], [I, V, vi, IV], [IV, V, vi, I]])

    func add(_ start: Double, _ samples: Int, pan: Double, _ f: (Double) -> Double) {
        let s0 = Int(start * sr)
        let gl = Float(min(1, 1 - pan)), gr = Float(min(1, 1 + pan))
        let tail = 0.012 * sr                                   // salida suave: sin chasquidos al acabar la nota
        for i in 0..<samples {
            let k = s0 + i
            guard k >= 0, k < n else { if k >= n { break } else { continue } }
            let v = Float(f(Double(i) / sr) * min(1, Double(samples - i) / tail))
            L[k] += v * gl; R[k] += v * gr
        }
    }
    // Instrumentos
    func keys(_ t0: Double, _ dur: Double, _ note: Double, _ vel: Double, pan: Double) {
        let f = midiHz(note), len = dur + 0.4
        add(t0, Int(len * sr), pan: pan) { t in
            let env = min(1, t / 0.008) * exp(-t / (mood == .calm ? 1.6 : 0.9)) * (t > dur ? exp(-(t - dur) / 0.12) : 1)
            let trem = 0.92 + 0.08 * sin(2 * .pi * 5 * t)
            let tone = sin(2 * .pi * f * t) + 0.22 * sin(2 * .pi * 2 * f * t) * exp(-t * 4) + 0.08 * sin(2 * .pi * 3 * f * t) * exp(-t * 7)
            return tone * env * trem * vel
        }
    }
    func pad(_ t0: Double, _ dur: Double, _ note: Double, _ vel: Double) {
        let f = midiHz(note)
        add(t0, Int((dur + 0.6) * sr), pan: 0) { t in
            let env = min(1, t / 0.45) * (t > dur ? exp(-(t - dur) / 0.3) : 1)
            return (sin(2 * .pi * f * 0.997 * t) + sin(2 * .pi * f * 1.003 * t)) * 0.5 * env * vel
        }
    }
    func bass(_ t0: Double, _ dur: Double, _ note: Double, _ vel: Double) {
        let f = midiHz(note)
        add(t0, Int((dur + 0.1) * sr), pan: 0) { t in
            let env = min(1, t / 0.01) * exp(-t / 1.2) * (t > dur ? exp(-(t - dur) / 0.05) : 1)
            let x = sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * 2 * f * t)
            return tanh(x * 1.4) * env * vel
        }
    }
    func kick(_ t0: Double, _ vel: Double) {
        add(t0, Int(0.35 * sr), pan: 0) { t in
            // Frecuencia que cae de 126 a 46 Hz: la fase es su integral.
            let phase = 46 * t + 80 * (1 - exp(-t * 32)) / 32
            return sin(2 * .pi * phase) * exp(-t * 8) * vel
        }
    }
    var noise = Seeded(seed ^ 0xABCDEF)
    func snare(_ t0: Double, _ vel: Double) {
        var last = 0.0
        add(t0, Int(0.2 * sr), pan: 0.05) { t in
            let w = noise.unit() * 2 - 1
            last = last * 0.55 + w * 0.45                    // ruido suavizado: menos áspero
            return (last * exp(-t * 20) * 0.7 + sin(2 * .pi * 185 * t) * exp(-t * 28) * 0.35) * vel
        }
    }
    func hat(_ t0: Double, _ vel: Double) {
        var prev = 0.0
        add(t0, Int(0.06 * sr), pan: 0.3) { t in
            let w = noise.unit() * 2 - 1
            let hp = w - prev; prev = w                       // agudos: solo el "tss"
            return hp * exp(-t * 70) * vel
        }
    }

    // Composición
    let bars = Int(ceil(seconds / bar)) + 1
    for b in 0..<bars {
        let t = Double(b) * bar
        let chord = progression[b % progression.count]
        // Acordes: pad en calma, teclas en energía
        for c in chord {
            if mood == .calm { pad(t, bar, root + c, 0.05) }
            keys(t, mood == .calm ? bar * 0.9 : beat * 1.5, root + c, mood == .calm ? 0.05 : 0.06, pan: -0.1)
            if mood == .energy { keys(t + beat * 2, beat * 1.5, root + c, 0.045, pan: -0.1) }
        }
        // Bajo: tónica del acorde dos octavas abajo
        let bassNote = root + chord[0] - 24
        if mood == .calm {
            bass(t, beat * 2.6, bassNote, 0.22); bass(t + beat * 2.5, beat * 1.4, bassNote, 0.16)
        } else {
            for k in 0..<4 { bass(t + Double(k) * beat, beat * 0.85, bassNote + (k == 3 ? 7 : 0), 0.2) }
        }
        // Arpegio por encima, suave, con algo de variación
        let arp = chord + [chord[1] + 12]
        let steps = mood == .calm ? 8 : 16
        for s in 0..<steps where rng.unit() > (mood == .calm ? 0.35 : 0.3) {
            let st = t + Double(s) * bar / Double(steps)
            keys(st, bar / Double(steps), root + 12 + rng.pick(arp), mood == .calm ? 0.028 : 0.022, pan: 0.25)
        }
        // Batería
        if mood == .calm {
            kick(t, 0.5); kick(t + beat * 2.5, 0.38)
            snare(t + beat, 0.16); snare(t + beat * 3, 0.16)
            for h in 0..<8 { hat(t + Double(h) * beat / 2 + (h % 2 == 1 ? beat * 0.08 : 0), h % 2 == 0 ? 0.045 : 0.028) }
        } else {
            for k in 0..<4 { kick(t + Double(k) * beat, 0.55) }
            snare(t + beat, 0.24); snare(t + beat * 3, 0.24)
            for h in 0..<8 { hat(t + Double(h) * beat / 2 + beat / 4, 0.06) }
        }
    }

    // Master: paso bajo suave (más cálido en calma), saturación ligera y normalizar a -3 dBFS.
    let cutoff = mood == .calm ? 5200.0 : 9000.0
    let a = Float(1 - exp(-2 * .pi * cutoff / sr))
    var yl: Float = 0, yr: Float = 0, peak: Float = 0.0001
    for i in 0..<n {
        yl += a * (L[i] - yl); yr += a * (R[i] - yr)
        L[i] = tanhf(yl * 1.2); R[i] = tanhf(yr * 1.2)
        peak = max(peak, abs(L[i]), abs(R[i]))
    }
    let gain = 0.7 / peak
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = L[i] * gain; buf.floatChannelData![1][i] = R[i] * gain }
    try? FileManager.default.removeItem(at: url)
    // WAV clásico de 16 bits: AVFoundation no deja montar el de coma flotante.
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                   AVLinearPCMIsNonInterleaved: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buf)
}

/// Canciones propias de la persona (Ajustes → Tu música). Vacío si no ha elegido carpeta.
func ownMusicFiles() -> [URL] {
    guard let p = UserDefaults.standard.string(forKey: "musicDir"), !p.isEmpty,
          let items = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: p), includingPropertiesForKeys: nil) else { return [] }
    return items.filter { ["mp3", "m4a", "wav", "aac", "aiff", "aif", "flac", "caf"].contains($0.pathExtension.lowercased()) }
}

// MARK: - Volumen final de redes

/// Deja el audio del clip a -14 LUFS (el volumen de TikTok, Reels y Shorts), midiendo primero y ajustando después.
func finishAudio(video: URL, duration: Double, out: URL) async throws {
    let measure = try await runCapture("ffmpeg", ["-hide_banner", "-i", video.path, "-vn",
                                                  "-af", "loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"])
    var filter = "loudnorm=I=-14:TP=-1.5:LRA=11"
    if let open = measure.range(of: "{", options: .backwards), let close = measure.range(of: "}", options: .backwards),
       let j = try? JSONSerialization.jsonObject(with: Data(measure[open.lowerBound...close.lowerBound].utf8)) as? [String: String],
       let i = j["input_i"], let tp = j["input_tp"], let lra = j["input_lra"], let th = j["input_thresh"], let off = j["target_offset"],
       Double(i) ?? -99 > -70 {
        filter += ":measured_I=\(i):measured_TP=\(tp):measured_LRA=\(lra):measured_thresh=\(th):offset=\(off):linear=true"
    }
    // Entrada y salida suaves del sonido para que el clip no empiece ni acabe en seco.
    let fades = String(format: ",afade=t=in:d=0.06,afade=t=out:st=%.3f:d=0.35", max(0, duration - 0.35))
    try await run("ffmpeg", ["-y", "-i", video.path, "-map", "0:v", "-map", "0:a", "-af", filter + fades + ",aresample=48000",
                             "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out.path])
}
