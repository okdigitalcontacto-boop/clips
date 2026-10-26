// Clips · © 2026 OK Digital. Todos los derechos reservados.
import Foundation
import AVFoundation
import AppKit
import Vision
import QuartzCore

// MARK: - Descargar solo el trozo que hace falta

/// Margen que se baja antes y después del clip, para poder retocar inicio y final sin volver a descargar.
let sectionMargin = 6.0

struct VideoSection { var file: URL; var start: Double; var end: Double }

/// `maxRes`: 1440 para vertical (el recorte 9:16 gana un 33 % de detalle), 1080 para horizontal.
func downloadSection(url: String, from a: Double, to b: Double, dir: URL, name: String, maxRes: Int = 1080,
                     onProgress: @escaping @Sendable (Double) -> Void) async throws -> VideoSection {
    let start = max(0, a), length = b - start
    let out = dir.appendingPathComponent("\(name).mp4")
    try? FileManager.default.removeItem(at: out)
    try await run("yt-dlp", ["-f", "bv*+ba/b", "-S", "res:\(maxRes),vcodec:h264,acodec:m4a",
                             "--download-sections", String(format: "*%.2f-%.2f", start, b),
                             "--merge-output-format", "mp4", "--no-playlist", "--no-warnings", "--newline",
                             "--no-part", "-o", out.path, url]) { line in
        // ffmpeg informa "time=00:00:12.34"; lo convertimos en porcentaje del trozo.
        guard let r = line.range(of: #"time=(\d+):(\d+):(\d+(\.\d+)?)"#, options: .regularExpression) else { return }
        let p = line[r].dropFirst(5).split(separator: ":").compactMap { Double($0) }
        guard p.count == 3, length > 0 else { return }
        onProgress(min(1, (p[0] * 3600 + p[1] * 60 + p[2]) / length))
    }
    guard FileManager.default.fileExists(atPath: out.path) else { throw ClipsError("No se pudo descargar este trozo del vídeo.") }
    return VideoSection(file: out, start: start, end: b)
}

/// Si AVFoundation no sabe leer el vídeo (VP9, AV1…), lo pasamos a H.264.
func ensurePlayable(_ s: VideoSection) async throws -> VideoSection {
    let asset = AVURLAsset(url: s.file)
    if let t = try? await asset.loadTracks(withMediaType: .video).first, (try? await t.load(.isPlayable)) == true { return s }
    let out = s.file.deletingPathExtension().appendingPathExtension("h264.mp4")
    let h = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize).height) ?? 1080
    // Bitrate alto: es un paso intermedio y no debe perder detalle.
    try await run("ffmpeg", ["-y", "-i", s.file.path, "-c:v", "h264_videotoolbox", "-b:v", h > 1100 ? "28M" : "12M",
                             "-c:a", "aac", "-b:a", "192k", out.path])
    return VideoSection(file: out, start: s.start, end: s.end)
}

// MARK: - Análisis del plano: a quién seguir y dónde hay cambios de plano

private func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

/// Miniatura en gris de 32×18 para comparar fotogramas y detectar cambios de plano.
private func tinyGray(_ img: CGImage) -> [UInt8] {
    let w = 32, h = 18
    var px = [UInt8](repeating: 0, count: w * h)
    px.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return px
}

private func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var s = 0
    for i in a.indices { s += abs(Int(a[i]) - Int(b[i])) }
    return Double(s) / Double(a.count)
}

/// Un instante analizado: a qué punto mirar (coordenadas 0–1, origen abajo a la izquierda) y si empieza un plano nuevo.
/// Solo hay `target` si se ve a alguien (cara o persona).
struct ShotSample { var t: Double; var target: CGPoint?; var cut: Bool; var crowd = false }

/// Cara seguida en el tiempo, para saber quién habla (la boca que más se mueve).
private struct FaceTrack { var center: CGPoint; var mouth: [(Double, Double)]; var lastSeen: Double }

/// Decide a quién seguir en cada momento: caras (si caben juntas, el grupo; si no, quien habla) y, si no hay caras, personas.
func analyzeShots(asset: AVAsset, from a: Double, to b: Double, viewWidth: Double) async -> [ShotSample] {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 512, height: 512)
    let tol = CMTime(seconds: 0.04, preferredTimescale: 600)
    gen.requestedTimeToleranceBefore = tol; gen.requestedTimeToleranceAfter = tol
    func frame(_ t: Double) async -> CGImage? { try? await gen.image(at: cm(t)).image }

    let cutThreshold = 38.0, step = 0.25
    var samples: [ShotSample] = []
    var prevTiny: [UInt8]? = nil, prevT = a
    var tracks: [FaceTrack] = []
    var speaker: Int? = nil, speakerSince = 0.0
    var t = a
    while t < b {
        if Task.isCancelled { return [] }
        guard let img = await frame(t) else { t += step; continue }
        let tiny = tinyGray(img)
        var cutAt: Double? = nil
        if let p = prevTiny, meanDiff(p, tiny) > cutThreshold {
            // Afinar dónde está el corte entre el fotograma anterior y este (≈ 6 centésimas).
            var lo = prevT, hi = t, loTiny = p
            for _ in 0..<2 {
                let mid = (lo + hi) / 2
                guard let mi = await frame(mid) else { break }
                let mt = tinyGray(mi)
                if meanDiff(loTiny, mt) > cutThreshold { hi = mid } else { lo = mid; loTiny = mt }
            }
            cutAt = hi
            tracks = []; speaker = nil
        }
        prevTiny = tiny; prevT = t

        var target: CGPoint? = nil, crowd = false
        let handler = VNImageRequestHandler(cgImage: img)
        let faceReq = VNDetectFaceLandmarksRequest()
        try? handler.perform([faceReq])
        let faces = (faceReq.results ?? []).filter { $0.boundingBox.width > 0.025 }
        if !faces.isEmpty {
            // Emparejar cada cara con su seguimiento y apuntar cuánto abre la boca.
            var ids: [Int] = []
            for f in faces {
                let c = CGPoint(x: f.boundingBox.midX, y: f.boundingBox.midY)
                var open = 0.0
                if let lips = f.landmarks?.innerLips?.normalizedPoints, let lo = lips.map(\.y).min(), let hi = lips.map(\.y).max() { open = Double(hi - lo) }
                if let k = tracks.indices.min(by: { hypot(tracks[$0].center.x - c.x, tracks[$0].center.y - c.y) < hypot(tracks[$1].center.x - c.x, tracks[$1].center.y - c.y) }),
                   hypot(tracks[k].center.x - c.x, tracks[k].center.y - c.y) < 0.15 {
                    tracks[k].center = c; tracks[k].lastSeen = t; tracks[k].mouth.append((t, open)); ids.append(k)
                } else {
                    tracks.append(FaceTrack(center: c, mouth: [(t, open)], lastSeen: t)); ids.append(tracks.count - 1)
                }
            }
            let union = faces.map(\.boundingBox).reduce(faces[0].boundingBox) { $0.union($1) }
            crowd = faces.count >= 3 && union.width > viewWidth * 0.85
            if faces.count == 1 || union.width <= viewWidth * 0.85 {
                target = CGPoint(x: union.midX, y: faces.map { $0.boundingBox.midY }.max() ?? union.midY)
            } else {
                // Quien habla: la boca que más varía en el último segundo y medio.
                func talk(_ k: Int) -> Double {
                    let v = tracks[k].mouth.filter { $0.0 > t - 1.6 }.map(\.1)
                    guard v.count > 1 else { return 0 }
                    let m = v.reduce(0, +) / Double(v.count)
                    return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
                }
                let best = ids.max { talk($0) < talk($1) }!
                if let cur = speaker, ids.contains(cur), t - speakerSince < 1.0 || talk(best) < talk(cur) * 1.35 + 0.0002 {
                    target = tracks[cur].center
                } else {
                    if speaker != best { speakerSince = t }
                    speaker = best; target = tracks[best].center
                }
            }
        } else {
            let human = VNDetectHumanRectanglesRequest()
            try? handler.perform([human])
            if let people = human.results, !people.isEmpty {
                let union = people.map(\.boundingBox).reduce(people[0].boundingBox) { $0.union($1) }
                let box = union.width <= viewWidth * 0.85 ? union : people.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }!.boundingBox
                target = CGPoint(x: box.midX, y: box.maxY - box.height * 0.18)   // hacia la cabeza
            }
        }
        samples.append(ShotSample(t: (cutAt ?? t) - a, target: target, cut: cutAt != nil, crowd: crowd))
        t += step
    }
    return samples
}

/// Recorrido de la cámara fotograma a fotograma: punto al que mira (0–1) y zoom (≥ 1).
/// `fit`: plano sin nadie a quien seguir (dibujos, pantallas…): se ve entero sobre fondo difuminado.
struct CameraPlan {
    let fps = 30.0
    var x: [Double], y: [Double], z: [Double], fit: [Bool]
    func at(_ t: Double) -> (x: Double, y: Double, zoom: Double, fit: Bool) {
        let i = min(x.count - 1, max(0, Int(t * fps)))
        return (x[i], y[i], z[i], fit[i])
    }
}

/// Cámara tranquila: un solo modo para todo el clip (seguir a la persona o plano entero), movimiento lento con inercia
/// y sin temblar, reencuadre suave en los cambios de plano (salto solo si el sujeto está en otro sitio) y un vaivén
/// de zoom muy lento y continuo. Nada de golpes ni saltos de zoom.
func planCamera(samples: [ShotSample], duration: Double) -> CameraPlan {
    let fps = 30.0, dt = 1 / fps
    let n = Int(duration * fps) + 2
    var xs = [Double](repeating: 0.5, count: n), ys = xs, zs = [Double](repeating: 1, count: n)
    let sorted = samples.sorted { $0.t < $1.t }
    // Modo único para todo el clip: si casi siempre se ve a alguien (y no es un grupo que no cabe), seguirle.
    let seen = sorted.filter { $0.target != nil }.count, crowd = sorted.filter(\.crowd).count
    let fit = sorted.isEmpty || Double(seen) < Double(sorted.count) * 0.6 || Double(crowd) > Double(sorted.count) * 0.4
    var tgt = sorted.first(where: { $0.target != nil })?.target ?? CGPoint(x: 0.5, y: 0.5)
    var x = Double(tgt.x), y = Double(tgt.y), vx = 0.0, vy = 0.0
    let w = 2 * Double.pi / 1.3                      // respuesta ~1,3 s: lenta, como un operador
    var k = 0
    for i in 0..<n {
        let t = Double(i) * dt
        var cut = false
        while k < sorted.count && sorted[k].t <= t {
            if let p = sorted[k].target { tgt = p }
            if sorted[k].cut { cut = true }
            k += 1
        }
        var tx = Double(tgt.x), ty = Double(tgt.y)
        // En un cambio de plano solo se salta si el sujeto está claramente en otro sitio.
        if i == 0 || (cut && hypot(tx - x, ty - y) > 0.15) { x = tx; y = ty; vx = 0; vy = 0 }
        // Zona muerta amplia: si el sujeto se mueve poco, la cámara no se mueve.
        if abs(tx - x) < 0.05 && abs(vx) < 0.02 { tx = x }
        if abs(ty - y) < 0.06 && abs(vy) < 0.02 { ty = y }
        vx += (w * w * (tx - x) - 2 * w * vx) * dt; x += vx * dt
        vy += (w * w * (ty - y) - 2 * w * vy) * dt; y += vy * dt
        xs[i] = x; ys[i] = y
        // Vaivén de zoom muy lento (1,00 → 1,05 → 1,00 cada ~16 s).
        zs[i] = 1 + 0.025 * (1 - cos(2 * .pi * t / 16))
    }
    return CameraPlan(x: xs, y: ys, z: zs, fit: [Bool](repeating: fit, count: n))
}

// MARK: - Montaje final (recorte, cámara, subtítulos, título y música) con AVFoundation + Core Image

struct RenderOptions {
    var vertical: Bool
    var subtitles: Bool
    var music = true
    var mood: MusicMood = .calm
    var hook = true
}

/// Imagen fija que aparece encima del vídeo entre `from` y `to`; con `pop`, entra con un pequeño salto.
struct Overlay { var from: Double; var to: Double; var image: CIImage; var pop: Bool; var fade: Bool }

/// `script`: líneas de subtítulos ya corregidas (si no, se agrupan solas). Devuelve la duración real del clip montado.
@discardableResult
func renderClip(section: VideoSection, start startIn: Double, end endIn: Double, words: [Word], options: RenderOptions,
                hook: String?, music: URL?, script: [[Word]]? = nil, out: URL) async throws -> Double {
    let asset = AVURLAsset(url: section.file)
    guard let vSrc = try await asset.loadTracks(withMediaType: .video).first else { throw ClipsError("El trozo descargado no tiene imagen.") }
    let aSrc = try await asset.loadTracks(withMediaType: .audio).first
    let assetDur = try await asset.load(.duration).seconds
    let natural = try await vSrc.load(.naturalSize)
    let pt = try await vSrc.load(.preferredTransform)
    let fps = try await vSrc.load(.nominalFrameRate)
    let r = CGRect(origin: .zero, size: natural).applying(pt)
    let src = CGSize(width: abs(r.width), height: abs(r.height))

    var localStart = max(0, startIn - section.start)
    var localEnd = min(assetDur, endIn - section.start)
    guard localEnd - localStart > 0.5 else { throw ClipsError("El trozo descargado es demasiado corto.") }

    // Planos y a quién seguir. Si hay un cambio de plano pegado al inicio o al final, cortar ahí
    // (sin perder palabras) para no empezar ni acabar con un fogonazo de otro plano.
    // Ancho visible del original en vertical 9:16 (0,32 para un vídeo 16:9).
    let viewWidth = options.vertical ? min(1, Double(src.height / src.width) * 9 / 16) : 1
    var shots = await analyzeShots(asset: asset, from: localStart, to: localEnd, viewWidth: viewWidth)
    try Task.checkCancellation()
    let spoken = words.filter { !$0.isTag }
    let firstWord = spoken.first { $0.end > startIn }?.start ?? startIn
    let lastWord = spoken.last { $0.start < endIn }?.end ?? endIn
    if let c = shots.first(where: { $0.cut && $0.t > 0 && $0.t <= 0.4 }), section.start + localStart + c.t <= firstWord + 0.04 {
        localStart += c.t
        shots = shots.compactMap { $0.t >= c.t ? ShotSample(t: $0.t - c.t, target: $0.target, cut: $0.t == c.t ? false : $0.cut, crowd: $0.crowd) : nil }
    }
    let span = localEnd - localStart
    if let c = shots.last(where: { $0.cut && $0.t >= span - 0.4 && $0.t < span }), section.start + localStart + c.t >= lastWord - 0.04 {
        localEnd = localStart + c.t
        shots = shots.filter { $0.t < c.t }
    }
    let start = section.start + localStart, end = section.start + localEnd
    let dur = localEnd - localStart
    let range = CMTimeRange(start: cm(localStart), duration: cm(dur))

    let comp = AVMutableComposition()
    guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ClipsError("No pude preparar el montaje.") }
    try cv.insertTimeRange(range, of: vSrc, at: .zero)
    // El audio puede ser un poco más corto que la imagen; se recorta a lo que haya.
    if let aSrc, let aEnd = try? await aSrc.load(.timeRange).end.seconds,
       let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        let aDur = min(dur, aEnd - localStart)
        if aDur > 0.05 { try? ca.insertTimeRange(CMTimeRange(start: cm(localStart), duration: cm(aDur)), of: aSrc, at: .zero) }
    }

    // Música de fondo: baja cuando se habla y sube un poco en las pausas (se sabe por los tiempos de las palabras).
    var audioMix: AVMutableAudioMix?
    let musicAsset = music.map { AVURLAsset(url: $0, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }
    if let musicAsset, let mTrack = try? await musicAsset.loadTracks(withMediaType: .audio).first,
       let mDur = try? await mTrack.load(.timeRange).duration.seconds, mDur > 1,
       let cm2 = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        var at = 0.0
        while at < dur {   // repetir la canción si es más corta que el clip
            let piece = min(mDur, dur - at)
            do { try cm2.insertTimeRange(CMTimeRange(start: .zero, duration: cm(piece)), of: mTrack, at: cm(at)) }
            catch { break }
            at += piece
        }
        let speech = words.filter { !$0.isTag && $0.end > start && $0.start < end }.map { ($0.start - start, $0.end - start) }
        // Pausas largas (más de 2,5 s sin hablar): ahí la música puede subir un poco, despacio.
        var gaps: [(Double, Double)] = []
        var last = 0.0
        for (a, b) in speech.sorted(by: { $0.0 < $1.0 }) { if a - last > 2.5 { gaps.append((last + 0.6, a - 0.6)) }; last = max(last, b) }
        if dur - last > 2.5 { gaps.append((last + 0.6, dur)) }
        func level(_ t: Double) -> Float {
            let fade = min(1, t / 1.2) * min(1, max(0, dur - t) / 1.5)
            // Medido: ~13 dB por debajo de la voz; en pausas largas sube hasta ~9 dB, con rampas de 0,8 s.
            var lift = 0.0
            for (a, b) in gaps where b > a { lift = max(lift, min(1, max(0, t - a) / 0.8, max(0, b - t) / 0.8)) }
            return Float(fade * (0.20 + 0.11 * lift))
        }
        let p = AVMutableAudioMixInputParameters(track: cm2)
        let step = 0.1
        var t = 0.0, prev = level(0)
        p.setVolume(prev, at: .zero)
        while t < dur {
            let nt = min(dur, t + step), v = level(nt)
            if v != prev { p.setVolumeRamp(fromStartVolume: prev, toEndVolume: v, timeRange: CMTimeRange(start: cm(t), duration: cm(nt - t))) }
            prev = v; t = nt
        }
        if ProcessInfo.processInfo.environment["CLIPS_DEBUG"] != nil {
            FileHandle.standardError.write("música: \(mDur) s, pistas de audio en el montaje: \(comp.tracks(withMediaType: .audio).count), segmentos: \(cm2.segments.count)\n".data(using: .utf8)!)
        }
        if cm2.segments.isEmpty { comp.removeTrack(cm2) }
        else { let mix = AVMutableAudioMix(); mix.inputParameters = [p]; audioMix = mix }
    }

    // Tamaño de salida: vertical 1080×1920; horizontal, el del original hasta 1920 de ancho.
    let renderSize: CGSize
    if options.vertical { renderSize = CGSize(width: 1080, height: 1920) }
    else {
        let k = min(1, 1920 / max(src.width, src.height))
        renderSize = CGSize(width: (src.width * k / 2).rounded() * 2, height: (src.height * k / 2).rounded() * 2)
    }
    let baseScale = max(renderSize.width / src.width, renderSize.height / src.height)
    let plan = planCamera(samples: shots, duration: dur)

    // Capas de texto, ya dibujadas como imágenes.
    var overlays: [Overlay] = []
    var subs: [SubChunk] = []
    if options.subtitles {
        let clipWords = words.filter { !$0.isTag && $0.start >= start - 0.1 && $0.start < end - 0.08 }
            .map { Word(start: max(0, $0.start - start), end: min(dur, $0.end - start), text: $0.text) }
        let lines = script?.map { $0.filter { $0.start >= start - 0.1 && $0.start < end - 0.08 }
            .map { Word(start: max(0, $0.start - start), end: min(dur, $0.end - start), text: $0.text) } }.filter { !$0.isEmpty }
        subs = subtitleChunks(clipWords, lines: (lines?.isEmpty ?? true) ? nil : lines, size: renderSize, vertical: options.vertical, duration: dur)
    }
    if let hook, !hook.isEmpty, dur > 5, let h = hookOverlay(hook, size: renderSize, vertical: options.vertical) { overlays.append(h) }
    if ProcessInfo.processInfo.environment["CLIPS_DEBUG"] != nil {
        FileHandle.standardError.write("subtítulos: \(subs.count) bloques (\(script == nil ? "automáticos" : "revisados")), cortes: \(shots.filter(\.cut).count), modo: \(plan.fit.first == true ? "plano entero" : "seguir")\n".data(using: .utf8)!)
    }

    let R = renderSize
    let canFit = R.height > R.width * 1.2 && src.width > src.height    // vídeo apaisado en salida vertical
    let vc = AVMutableVideoComposition(asset: comp) { request in
        let t = request.compositionTime.seconds
        let source = request.sourceImage
        let e = source.extent
        let cam = plan.at(t)
        var img: CIImage
        if cam.fit && canFit {
            // Plano entero en el centro (con un zoom suave) sobre el mismo plano ampliado y difuminado.
            let bs = max(R.width / e.width, R.height / e.height) * 1.08
            let bg = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: bs, y: bs)))
            let bgc = bg.transformed(by: CGAffineTransform(translationX: (R.width - e.width * bs) / 2, y: (R.height - e.height * bs) / 2))
                .clampedToExtent().applyingGaussianBlur(sigma: 38)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.1])
                .cropped(to: CGRect(origin: .zero, size: R))
            let fs = R.width / e.width * CGFloat(1 + (cam.zoom - 1) * 0.6)
            let fg = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: fs, kCIInputAspectRatioKey: 1])
            let fx = (R.width - e.width * fs) / 2, fy = (R.height - e.height * fs) / 2 + R.height * 0.04
            img = fg.transformed(by: CGAffineTransform(translationX: fx, y: fy)).cropped(to: CGRect(origin: .zero, size: R)).composited(over: bgc)
        } else {
            let s = baseScale * CGFloat(cam.zoom)
            let w = R.width / s, h = R.height / s
            // El sujeto queda un poco por encima del centro (aire para los subtítulos).
            var X = e.minX + CGFloat(cam.x) * e.width
            var Y = e.minY + CGFloat(cam.y) * e.height - h * 0.08
            X = min(max(X, e.minX + w / 2), e.maxX - w / 2)
            Y = min(max(Y, e.minY + h / 2), e.maxY - h / 2)
            // Escalado Lanczos (más nítido que el lineal al ampliar el recorte).
            img = source.transformed(by: CGAffineTransform(translationX: -(X - w / 2), y: -(Y - h / 2)))
                .cropped(to: CGRect(x: -2, y: -2, width: w + 4, height: h + 4))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        }
        // Enfoque suave para compensar la ampliación.
        img = img.cropped(to: CGRect(origin: .zero, size: R)).applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35, kCIInputRadiusKey: 1.4])
        if let c = subs.first(where: { t >= $0.from && t < $0.to }) { img = drawSubtitle(c, at: t).composited(over: img) }
        for o in overlays where t >= o.from && t < o.to {
            var layer = o.image
            let local = t - o.from
            if o.pop && local < 0.22 {
                let u = local / 0.22
                let k = u < 0.6 ? 0.82 + (1.06 - 0.82) * (u / 0.6) : 1.06 - 0.06 * ((u - 0.6) / 0.4)
                let c = CGPoint(x: layer.extent.midX, y: layer.extent.midY)
                layer = layer.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                    .concatenating(CGAffineTransform(scaleX: k, y: k)).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            }
            if o.fade {
                let a = CGFloat(min(1, local / 0.15, (o.to - t) / 0.4))
                layer = layer.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
            }
            img = layer.composited(over: img)
        }
        request.finish(with: img.cropped(to: CGRect(origin: .zero, size: R)), context: nil)
    }
    vc.renderSize = R
    vc.frameDuration = CMTime(value: 1, timescale: Int32(min(60, max(24, fps.rounded()))))

    try? FileManager.default.removeItem(at: out)
    guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw ClipsError("No pude exportar el clip.") }
    ex.outputURL = out
    ex.outputFileType = .mp4
    ex.videoComposition = vc
    if let audioMix { ex.audioMix = audioMix }
    ex.shouldOptimizeForNetworkUse = true
    nonisolated(unsafe) let session = ex
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed: c.resume()
                case .cancelled: c.resume(throwing: CancellationError())
                default: c.resume(throwing: ClipsError("Falló el montaje del clip: \(session.error?.localizedDescription ?? "error desconocido")."))
                }
            }
        }
    } onCancel: { session.cancelExport() }
    return dur
}

// MARK: - Subtítulos y título

/// Dibuja un texto en una imagen ajustada a su tamaño (más fiable que CATextLayer al exportar).
func textImage(_ text: NSAttributedString, maxWidth: CGFloat, pad: CGFloat) -> CGImage? {
    let bounds = text.boundingRect(with: NSSize(width: maxWidth, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let w = Int(ceil(min(maxWidth, bounds.width) + pad * 2)), h = Int(ceil(bounds.height + pad * 2))
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(with: NSRect(x: pad, y: pad, width: CGFloat(w) - pad * 2, height: bounds.height),
              options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

/// Un bloque de subtítulos: el texto en una línea y dónde está cada palabra (para la pastilla que la resalta).
struct SubChunk {
    var from: Double, to: Double
    var text: CIImage
    var words: [(from: Double, rect: CGRect)]
    var radius: CGFloat
}

/// Quita la puntuación suelta del final (".", ",", ";", ":") y deja "?" y "!".
private func cleanWord(_ w: String) -> String {
    var s = w
    while let c = s.last, ".,;:…".contains(c), s.count > 1 { s.removeLast() }
    return s
}

/// Subtítulos limpios: SF Pro en blanco con sombra suave, en una línea; la palabra que se dice va en una pastilla coral.
func subtitleChunks(_ words: [Word], lines: [[Word]]? = nil, size: CGSize, vertical: Bool, duration: Double) -> [SubChunk] {
    let chunks = lines ?? groupLines(words, maxWords: vertical ? 3 : 5, maxChars: vertical ? 18 : 32)

    let baseSize: CGFloat = vertical ? 86 : max(46, size.height * 0.064)
    let maxWidth = size.width * (vertical ? 0.84 : 0.78)
    let centerY = vertical ? size.height * 0.27 : size.height * 0.12
    var out: [SubChunk] = []
    for (ci, chunk) in chunks.enumerated() {
        var texts = chunk.map { cleanWord($0.text) }
        if lines == nil, let f = texts.first?.first, f.isLowercase { texts[0] = f.uppercased() + texts[0].dropFirst() }
        // Si la línea no cabe, se reduce la letra (nunca dos líneas).
        var fs = baseSize
        func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55); shadow.shadowBlurRadius = size * 0.18
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.05)
            return [.font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: NSColor.white, .shadow: shadow,
                    .kern: -size * 0.01]
        }
        // Cada palabra se dibuja por separado, con aire entre ellas para que la pastilla no pise a las vecinas.
        func widths(_ size: CGFloat) -> [CGFloat] { texts.map { NSAttributedString(string: $0, attributes: attrs(size)).size().width } }
        let gapK: CGFloat = 0.42
        let full = widths(fs).reduce(0, +) + fs * gapK * CGFloat(texts.count - 1)
        if full > maxWidth { fs *= maxWidth / full }
        let at = attrs(fs), font = at[.font] as! NSFont
        let ws = widths(fs), gap = fs * gapK
        let lineW = ws.reduce(0, +) + gap * CGFloat(texts.count - 1)
        let lineH = font.ascender - font.descender
        let pad = fs * 0.45
        let W = Int(ceil(lineW + pad * 2)), H = Int(ceil(lineH + pad * 2))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var dx = pad
        for (k, t) in texts.enumerated() {
            NSAttributedString(string: t, attributes: at).draw(at: NSPoint(x: dx, y: pad))
            dx += ws[k] + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { continue }
        let ox = (size.width - CGFloat(W)) / 2, oy = centerY - CGFloat(H) / 2
        // Pastilla de cada palabra: centrada en la altura de las mayúsculas, con margen.
        let baseline = oy + pad - font.descender
        var x = ox + pad
        var rects: [(Double, CGRect)] = []
        for (k, _) in texts.enumerated() {
            let r = CGRect(x: x - fs * 0.2, y: baseline - fs * 0.2, width: ws[k] + fs * 0.4, height: font.capHeight + fs * 0.4)
            rects.append((chunk[k].start, r))
            x += ws[k] + gap
        }
        let nextStart = ci + 1 < chunks.count ? chunks[ci + 1][0].start : duration
        out.append(SubChunk(from: chunk[0].start, to: min(chunk.last!.end + 0.3, nextStart), text: CIImage(cgImage: img).transformed(by: CGAffineTransform(translationX: ox, y: oy)),
                            words: rects.map { (from: $0.0, rect: $0.1) }, radius: fs * 0.22))
    }
    return out
}

private let subtitleAccent = CIColor(red: 1.0, green: 0.36, blue: 0.22, alpha: 0.96)

/// Pinta un bloque en el instante `t`: entra subiendo y apareciendo (0,16 s) y la pastilla se desliza de palabra en palabra.
func drawSubtitle(_ c: SubChunk, at t: Double) -> CIImage {
    let local = t - c.from
    let u = min(1, local / 0.16), ease = 1 - pow(1 - u, 3)
    var i = 0
    for (k, w) in c.words.enumerated() where w.from <= t { i = k }
    var r = c.words[i].rect
    let since = t - c.words[i].from
    if i > 0 && since < 0.1 {
        let v = since / 0.1, e = CGFloat(v * v * (3 - 2 * v))
        let p = c.words[i - 1].rect
        r = CGRect(x: p.minX + (r.minX - p.minX) * e, y: r.minY, width: p.width + (r.width - p.width) * e, height: r.height)
    }
    let pill = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
        "inputExtent": CIVector(cgRect: r), "inputRadius": c.radius, "inputColor": subtitleAccent])?.outputImage ?? CIImage.empty()
    var layer = c.text.composited(over: pill)
    layer = layer.transformed(by: CGAffineTransform(translationX: 0, y: -14 * (1 - ease)))
    if u < 1 {
        let a = CGFloat(ease)
        layer = layer.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }
    return layer
}

/// El título del clip en una tarjeta blanca arriba durante los primeros 3 s.
func hookOverlay(_ title: String, size: CGSize, vertical: Bool) -> Overlay? {
    let text = String(title.prefix(70))
    let fontSize: CGFloat = vertical ? 74 : max(40, size.height * 0.058)
    let base = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
    let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byWordWrapping
    para.lineHeightMultiple = 0.92
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.07, alpha: 1), .paragraphStyle: para])
    guard let label = textImage(attr, maxWidth: size.width * (vertical ? 0.74 : 0.56), pad: 0) else { return nil }
    let padX = fontSize * 0.55, padY = fontSize * 0.36, shadowPad = fontSize * 0.6
    let cw = CGFloat(label.width) + padX * 2, ch = CGFloat(label.height) + padY * 2
    let W = Int(ceil(cw + shadowPad * 2)), H = Int(ceil(ch + shadowPad * 2))
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let card = CGRect(x: shadowPad, y: shadowPad, width: cw, height: ch)
    ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.08), blur: fontSize * 0.35, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: fontSize * 0.42, cornerHeight: fontSize * 0.42, transform: nil))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.draw(label, in: CGRect(x: card.minX + padX, y: card.minY + padY, width: CGFloat(label.width), height: CGFloat(label.height)))
    guard let img = ctx.makeImage() else { return nil }
    let centerY = size.height * (vertical ? 0.79 : 0.83)
    let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(translationX: (size.width - CGFloat(W)) / 2, y: centerY - CGFloat(H) / 2))
    return Overlay(from: 0, to: 3.2, image: ci, pop: true, fade: true)
}

// MARK: - Miniaturas

func thumbnail(_ file: URL, at s: Double = 1.0) async -> NSImage? {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: file))
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 720, height: 720)
    guard let img = try? await gen.image(at: CMTime(seconds: s, preferredTimescale: 600)).image else { return nil }
    return NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
}
