// Clips · © 2026 OK Digital. Todos los derechos reservados.
import SwiftUI
import AppKit
import AVFoundation

// MARK: - Estado de cada clip

enum ClipState: Equatable {
    case queued, downloading(Double), rendering, ready, failed(String)
    var isBusy: Bool {
        switch self { case .queued, .downloading, .rendering: return true; default: return false }
    }
}

struct ClipItem: Identifiable {
    let id = UUID()
    var rank: Int
    var m: Moment
    var options: RenderOptions
    var state: ClipState = .queued
    var file: URL?
    var thumb: NSImage?
    var section: VideoSection?
    /// Sube cada vez que se vuelve a montar, para recargar el reproductor.
    var version = 0
    var duration: Double { m.end - m.start }
}

enum Stage: Int, CaseIterable, Identifiable {
    case video, text, moments, clips
    var id: Int { rawValue }
    var label: String { ["Vídeo", "Texto", "Momentos", "Clips"][rawValue] }
    var symbol: String { ["play.rectangle", "text.quote", "sparkles", "scissors"][rawValue] }
}

enum StageState { case pending, active, done, failed }

// MARK: - Orquestador

enum Platform: String, CaseIterable, Identifiable {
    case youtube = "YouTube", instagram = "Instagram", tiktok = "TikTok"
    var id: String { rawValue }
    var uploadURL: URL {
        switch self {
        case .youtube: URL(string: "https://www.youtube.com/upload")!
        case .instagram: URL(string: "https://www.instagram.com/")!
        case .tiktok: URL(string: "https://www.tiktok.com/upload")!
        }
    }
    var hint: String {
        switch self {
        case .youtube: "Arrastra el clip a la página. Al ser vertical y corto, YouTube lo publica como Short."
        case .instagram: "Pulsa «+ Crear» y arrastra el clip. Los vídeos se publican como Reel."
        case .tiktok: "Arrastra el clip a la página de subida."
        }
    }
}

@MainActor
final class Model: ObservableObject {
    private let ud = UserDefaults.standard
    /// Falso en el modo prueba, para no tocar los ajustes de la persona.
    var persist = true
    @Published var url = ""
    @Published var count: Int { didSet { if persist { ud.set(count, forKey: "count") } } }
    @Published var durIdx: Int { didSet { if persist { ud.set(durIdx, forKey: "durIdx") } } }
    @Published var vertical: Bool { didSet { if persist { ud.set(vertical, forKey: "vertical") } } }
    @Published var subtitles: Bool { didSet { if persist { ud.set(subtitles, forKey: "subtitles") } } }
    @Published var focus: Focus { didSet { if persist { ud.set(focus.rawValue, forKey: "focus") } } }
    @Published var music: Bool { didSet { if persist { ud.set(music, forKey: "music") } } }
    @Published var mood: MusicMood { didSet { if persist { ud.set(mood.rawValue, forKey: "mood") } } }
    @Published var hook: Bool { didSet { if persist { ud.set(hook, forKey: "hook") } } }
    /// Anotaciones para este vídeo ("10 en orden cronológico", "uno de cada parte"…). No se guardan entre sesiones.
    @Published var notes = ""
    /// Los clips de este trabajo van en el orden del vídeo (lo pidieron las notas).
    @Published var chronological = false

    @Published var running = false
    @Published var stage: Stage?
    @Published var done: Set<Stage> = []
    @Published var detail = ""
    @Published var error: ClipsError?
    @Published var info: VideoInfo?
    @Published var curve: [Double] = []
    @Published var curveIsHeat = true
    @Published var analyzing = false
    @Published var clips: [ClipItem] = []
    @Published var outDir: URL?
    @Published var finished = false
    @Published var hovered: UUID?
    @Published var notice: String?
    @Published var updatingTools = false
    /// Solo para capturas de diseño: pinta la interfaz sin scroll ni campos de AppKit.
    var snapshot = false

    let durations = [(15, 30), (30, 60), (60, 90)]
    var words: [Word] = []
    var jobURL = ""
    var workDir: URL?
    private var job: Task<Void, Never>?
    var log: ((String) -> Void)?
    /// Solo en el modo prueba: la ventana muestra este modelo.
    static var testModel: Model?

    init() {
        count = ud.object(forKey: "count") as? Int ?? 5
        durIdx = ud.object(forKey: "durIdx") as? Int ?? 1
        vertical = ud.object(forKey: "vertical") as? Bool ?? true
        subtitles = ud.object(forKey: "subtitles") as? Bool ?? true
        focus = Focus(rawValue: ud.string(forKey: "focus") ?? "") ?? .auto
        music = ud.object(forKey: "music") as? Bool ?? true
        mood = MusicMood(rawValue: ud.string(forKey: "mood") ?? "") ?? .calm
        hook = ud.object(forKey: "hook") as? Bool ?? true
        pasteIfYouTube()
    }

    var outputBase: URL {
        if let p = ud.string(forKey: "outputDir"), !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Clips")
    }

    func pasteIfYouTube() {
        if url.isEmpty, let s = NSPasteboard.general.string(forType: .string), let link = extractYouTubeLink(s) { url = link }
    }

    /// Texto que llega pegado o arrastrado: se queda con el enlace de YouTube si lo hay.
    func receive(_ text: String) {
        guard !running else { return }
        url = extractYouTubeLink(text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        Sound.shared.play(.tick); haptic()
    }

    func state(of s: Stage) -> StageState {
        if done.contains(s) { return .done }
        if stage == s { return error != nil ? .failed : (running ? .active : .pending) }
        return .pending
    }

    var readyCount: Int { clips.filter { $0.state == .ready }.count }

    // MARK: Acciones

    func start() {
        guard !running else { return }
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let link = extractYouTubeLink(raw) else {
            fail(ClipsError("Eso no es un enlace de YouTube. Copia la dirección del vídeo (youtube.com o youtu.be) y pégala aquí."))
            return
        }
        if link != url { url = link }
        if let problem = youTubeLinkProblem(link) { fail(ClipsError(problem)); return }
        // Sin clave no merece la pena empezar a descargar nada.
        if geminiKey().isEmpty { fail(missingKeyError()); return }
        Sound.shared.play(.start); haptic(.levelChange)
        job = Task { await go(link) }
    }

    func cancel() {
        job?.cancel()
        Procs.shared.killAll()
        haptic()
    }

    func reset() {
        withAnimation(.spring(response: 0.4, dampingFraction: 1)) {
            info = nil; clips = []; error = nil; stage = nil; done = []; detail = ""
            curve = []; finished = false; outDir = nil; notice = nil
        }
    }

    func fail(_ e: ClipsError) {
        withAnimation(.spring(response: 0.35, dampingFraction: 1)) { error = e }
        Sound.shared.play(.error); haptic(.generic)
    }

    private func enter(_ s: Stage, _ text: String) {
        if let cur = stage, cur != s { done.insert(cur) }
        withAnimation(.spring(response: 0.35, dampingFraction: 1)) { stage = s; detail = text }
        log?(text)
    }

    func update(_ id: UUID, _ f: (inout ClipItem) -> Void) {
        if let i = clips.firstIndex(where: { $0.id == id }) { f(&clips[i]) }
    }

    // MARK: Proceso completo

    func go(_ link: String) async {
        jobURL = link
        running = true
        withAnimation(.spring(response: 0.4, dampingFraction: 1)) {
            error = nil; clips = []; info = nil; stage = nil; done = []; curve = []; finished = false; outDir = nil; notice = nil
            chronological = false
        }
        if let old = workDir { try? FileManager.default.removeItem(at: old) }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.okdigital.clips/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir
        let t0 = Date()
        geminiStatus = { text in Task { @MainActor in withAnimation(.ui) { self.detail = text }; self.log?("  " + text) } }
        defer {
            running = false; analyzing = false
            NSApp.dockTile.badgeLabel = nil
        }
        do {
            enter(.video, "Leyendo el vídeo…")
            let info = try await fetchInfo(link)
            withAnimation(.spring(response: 0.45, dampingFraction: 1)) { self.info = info }
            log?(String(format: "  info %.1fs · %@ · %.0fs · subtítulos: %@", Date().timeIntervalSince(t0), info.title, info.duration, info.captionLang ?? "no"))
            let (minD, maxD) = durations[durIdx]
            if info.duration > 0 && info.duration < Double(minD) {
                throw ClipsError("El vídeo dura \(Int(info.duration)) s, menos que un clip de \(minD)–\(maxD) s. Elige una duración más corta.")
            }

            enter(.text, "Leyendo lo que se dice…")
            var words = try await fetchWords(info: info, url: link, dir: dir)
            if words.isEmpty {
                enter(.text, "Este vídeo no tiene subtítulos: escuchando el audio con Gemini…")
                words = try await transcribeAudio(url: link, dir: dir)
            }
            self.words = words
            setCurve(info: info, words: words)
            log?(String(format: "  texto %.1fs · %d palabras", Date().timeIntervalSince(t0), words.count))

            // Anotaciones: se interpretan una vez y el plan manda en número, orden y partes.
            var plan = ClipPlan()
            let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                enter(.moments, "Leyendo tus anotaciones…")
                plan = try await planFromNotes(note, info: info, words: words, minD: minD)
                log?("  plan: \(plan.summary) · nº \(plan.count.map(String.init) ?? "-") · \(plan.chronological ? "cronológico" : "por calidad") · partes \(plan.parts.count)\(plan.rules.isEmpty ? "" : " · reglas: \(plan.rules)")")
                for (i, p) in plan.parts.enumerated() { log?(String(format: "    parte %d: %@–%@ %@", i, fmt(p.start), fmt(p.end), p.title)) }
            }
            let asked = plan.count ?? count
            let fits = info.duration > 0 ? max(1, Int(info.duration / Double(minD))) : asked
            let want = min(asked, fits)
            enter(.moments, !plan.summary.isEmpty ? "Entendido: \(plan.summary)"
                  : want == 1 ? "Buscando el mejor momento…" : "Buscando los \(want) mejores momentos…")
            analyzing = true

            /// Revisión y verificación; lo que falle vuelve al editor con el problema concreto (hasta 2 rondas).
            func approve(_ candidates: [Moment], need: Int) async throws -> [Moment] {
                withAnimation(.ui) { detail = "Revisando los \(candidates.count) candidatos uno a uno…" }
                var pending = try await reviewMoments(info: info, words: words, candidates: candidates, count: need,
                                                      minD: minD, maxD: maxD, plan: plan, log: log)
                var good: [Moment] = []
                for round in 0..<3 where !pending.isEmpty {
                    withAnimation(.ui) { detail = round == 0 ? "Verificando cada clip: que empiece y acabe bien y que el título sea cierto…"
                                                             : "Corrigiendo \(pending.count) clips que empezaban o acababan a medias…" }
                    let (ok, failed) = try await verifyMoments(pending, words: words, minD: minD, plan: plan, log: log)
                    good += ok
                    let enough = plan.parts.isEmpty ? good.count >= need
                        : Set(good.compactMap(\.part)).count >= Set(candidates.compactMap(\.part)).count
                    if enough || failed.isEmpty || round == 2 { break }
                    pending = try await reviewMoments(info: info, words: words, candidates: failed.map(\.0), count: need,
                                                      minD: minD, maxD: maxD, notes: failed.map(\.1), before: 70, after: 50, plan: plan, log: log)
                }
                return good
            }
            /// Sin solapes; los de más puntuación primero. Con partes, el mejor de cada una.
            func choose(_ good: [Moment]) -> [Moment] {
                var out: [Moment] = []
                for m in good.sorted(by: { $0.score > $1.score }) where !out.contains(where: { m.start < $0.end && m.end > $0.start }) {
                    if let p = m.part, out.contains(where: { $0.part == p }) { continue }
                    out.append(m)
                    if plan.parts.isEmpty && out.count == want { break }
                }
                return out
            }

            let candidates = try await pickCandidates(info: info, words: words, count: want, minD: minD, maxD: maxD, focus: focus, plan: plan)
            log?(String(format: "  candidatos %.1fs · %d", Date().timeIntervalSince(t0), candidates.count))
            var good = try await approve(candidates, need: want)
            var moments = choose(good)
            // Partes que se han quedado sin clip: una búsqueda más solo en ellas.
            var missing = plan.parts.indices.filter { p in !moments.contains { $0.part == p } }
            if !missing.isEmpty {
                withAnimation(.ui) { detail = "Buscando otra vez en \(missing.count == 1 ? "la parte que falta" : "las \(missing.count) partes que faltan")…" }
                log?("  sin clip en partes \(missing); segunda búsqueda")
                let more = try await pickCandidates(info: info, words: words, count: missing.count, minD: minD, maxD: maxD, focus: focus,
                                                    plan: plan, onlyParts: missing)
                    .filter { m in !moments.contains { m.start < $0.end && m.end > $0.start } }
                if !more.isEmpty { good += try await approve(more, need: missing.count) }
                moments = choose(good)
                missing = plan.parts.indices.filter { p in !moments.contains { $0.part == p } }
            }
            if plan.chronological { moments.sort { $0.start < $1.start } }
            chronological = plan.chronological
            analyzing = false
            log?(String(format: "  aprobados %.1fs · %d", Date().timeIntervalSince(t0), moments.count))
            if moments.isEmpty {
                throw ClipsError("Ningún momento ha pasado la revisión (empezaban o acababan a medias, no enganchaban o no cumplían tus anotaciones). Prueba con otra duración, otro enfoque u otras anotaciones.")
            }
            if !missing.isEmpty {
                notice = "Sin clip en " + missing.map { "«\(plan.parts[$0].title)»" }.joined(separator: ", ")
                    + ": no había un momento que se entendiera solo y cupiera en la duración."
            } else if moments.count < asked {
                notice = info.duration > 0 && fits < asked
                    ? "El vídeo solo da para \(moments.count) \(moments.count == 1 ? "clip" : "clips") de esta duración."
                    : "Solo \(moments.count) de los candidatos han pasado la revisión; prefiero darte menos antes que clips flojos."
            }

            // Reservar la carpeta de forma atómica: si ya existe, probar con (2), (3)…
            try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
            let base = outputBase.appendingPathComponent(safeName(info.title))
            var out = base, n = 2
            while true {
                do { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false); break }
                catch CocoaError.fileWriteFileExists { out = URL(fileURLWithPath: base.path + " (\(n))"); n += 1 }
            }
            outDir = out

            let opts = RenderOptions(vertical: vertical, subtitles: subtitles, music: music, mood: mood, hook: hook)
            for (i, mo) in moments.enumerated() {
                try await Task.sleep(nanoseconds: 70_000_000)
                withAnimation(.spring(response: 0.42, dampingFraction: 1)) {
                    clips.append(ClipItem(rank: i + 1, m: mo, options: opts))
                }
            }
            enter(.clips, "Descargando y montando \(moments.count) clips…")
            NSApp.dockTile.badgeLabel = "0/\(moments.count)"

            let ids = clips.map(\.id)
            await withTaskGroup(of: Void.self) { g in
                var it = ids.makeIterator()
                for _ in 0..<3 { if let id = it.next() { g.addTask { await self.process(id) } } }
                while await g.next() != nil { if let id = it.next() { g.addTask { await self.process(id) } } }
            }
            try Task.checkCancellation()
            let ok = readyCount
            if ok == 0 { removeOutDirIfEmpty(); throw ClipsError(failureMessage() ?? "No se pudo montar ningún clip.") }
            done.insert(.clips)
            withAnimation(.spring(response: 0.4, dampingFraction: 1)) {
                finished = true
                detail = ok == clips.count ? "\(ok) clips listos" : "\(ok) de \(clips.count) clips listos"
            }
            log?(String(format: "  total %.1fs", Date().timeIntervalSince(t0)))
            Sound.shared.play(.success); haptic(.levelChange)
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        } catch is CancellationError {
            cancelled()
        } catch {
            if Task.isCancelled { cancelled(); return }
            removeOutDirIfEmpty()
            fail(error as? ClipsError ?? ClipsError(error.localizedDescription))
            log?("ERROR: \(error.localizedDescription)")
        }
    }

    /// Si no ha salido ningún clip, no dejar una carpeta vacía en Películas.
    private func removeOutDirIfEmpty() {
        guard let d = outDir, (try? FileManager.default.contentsOfDirectory(atPath: d.path))?.isEmpty == true else { return }
        try? FileManager.default.removeItem(at: d)
        outDir = nil
    }

    private func cancelled() {
        analyzing = false
        removeOutDirIfEmpty()
        withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
            for i in clips.indices where clips[i].state.isBusy { clips[i].state = .failed("Cancelado") }
            detail = "Cancelado"
            if clips.allSatisfy({ $0.state != .ready }) { clips = [] }
        }
    }

    private func failureMessage() -> String? {
        for c in clips { if case .failed(let m) = c.state { return m } }
        return nil
    }

    private func setCurve(info: VideoInfo, words: [Word]) {
        var values: [Double]
        if !info.heatmap.isEmpty {
            values = info.heatmap.map(\.value); curveIsHeat = true
        } else {
            // Sin datos de YouTube: cuánto se habla en cada tramo.
            let bins = 80, d = max(info.duration, words.last?.end ?? 1)
            values = Array(repeating: 0, count: bins)
            for w in words where !w.isTag { values[min(bins - 1, Int(w.start / d * Double(bins)))] += 1 }
            let mx = values.max() ?? 1
            values = values.map { mx > 0 ? $0 / mx : 0 }
            curveIsHeat = false
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 1)) { curve = values }
    }

    /// Descarga el trozo de un clip y lo monta. Si falla, solo falla ese clip.
    func process(_ id: UUID) async {
        guard let c = clips.first(where: { $0.id == id }), let dir = workDir, let outDir else { return }
        let dur = info?.duration ?? 0
        // El guion de subtítulos se pide ya, en paralelo con la descarga.
        let inClip = words.filter { $0.start >= c.m.start - 0.1 && $0.start < c.m.end }
        let scriptTask: Task<[[Word]]?, Never>? = c.options.subtitles
            ? Task { await subtitleScript(words: inClip, vertical: c.options.vertical, title: c.m.title) } : nil
        defer { scriptTask?.cancel() }
        do {
            var sec: VideoSection
            if let s = c.section, s.start <= c.m.start + 0.01, s.end >= c.m.end - 0.01 { sec = s }
            else {
                update(id) { $0.state = .downloading(0) }
                let end = dur > 0 ? min(dur, c.m.end + sectionMargin) : c.m.end + sectionMargin
                sec = try await downloadSection(url: jobURL, from: c.m.start - sectionMargin, to: end, dir: dir, name: "s-\(id.uuidString)",
                                                maxRes: c.options.vertical ? 1440 : 1080) { p in
                    Task { @MainActor in self.update(id) { if case .downloading = $0.state { $0.state = .downloading(p) } } }
                }
                sec = try await ensurePlayable(sec)
                update(id) { $0.section = sec }
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { update(id) { $0.state = .rendering } }
            let file = c.file ?? outDir.appendingPathComponent(String(format: "%02d %@.mp4", c.rank, safeName(c.m.title)))
            // 1) Música de fondo: canciones propias (Ajustes) o un tema compuesto para este clip.
            var song: URL? = nil
            if c.options.music {
                let own = ownMusicFiles()
                let wav = dir.appendingPathComponent("m-\(id.uuidString).wav")
                if !own.isEmpty {
                    // Canción propia: pasarla a WAV de 16 bits (el formato que AVFoundation monta sin problemas).
                    try await run("ffmpeg", ["-y", "-i", own[(c.rank - 1) % own.count].path, "-vn", "-t", String(format: "%.2f", c.duration + 2),
                                             "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le", wav.path])
                    song = wav
                } else {
                    let seed = UInt64(c.rank) &* 7919 &+ UInt64(max(0, dur) * 10)
                    let (mood, secs) = (c.options.mood, c.duration + 2)
                    try await Task.detached { try composeMusic(mood: mood, seconds: secs, seed: seed, to: wav) }.value
                    song = wav
                }
            }
            // 2) Montaje: recorte, encuadre, subtítulos, título y música.
            let raw = dir.appendingPathComponent("r-\(id.uuidString).mp4")
            // Subtítulos revisados (palabras bien escritas y líneas por frases).
            let script = await scriptTask?.value
            if c.options.subtitles && script == nil { log?("  clip \(c.rank): subtítulos sin revisar (Gemini no devolvió un guion válido)") }
            let rendered = try await renderClip(section: sec, start: c.m.start, end: c.m.end, words: words, options: c.options,
                                                hook: c.options.hook ? c.m.title : nil, music: song, script: script, out: raw)
            // 3) Volumen de redes. Si falla (p. ej. un vídeo sin audio), el clip se queda como está.
            do {
                try await finishAudio(video: raw, duration: rendered, out: file)
                try? FileManager.default.removeItem(at: raw)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: raw, to: file)
                log?("  ajuste de volumen falló en el clip \(c.rank): \(error.localizedDescription)")
            }
            // Comprobación final antes de entregarlo: que dure lo que debe y tenga imagen y sonido.
            let made = AVURLAsset(url: file)
            let madeDur = (try? await made.load(.duration).seconds) ?? 0
            let hasVideo = !((try? await made.loadTracks(withMediaType: .video)) ?? []).isEmpty
            let hasAudio = !((try? await made.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            guard hasVideo, hasAudio, abs(madeDur - rendered) < 1.0, madeDur > 3 else {
                try? FileManager.default.removeItem(at: file)
                throw ClipsError("El clip montado no ha pasado la comprobación final (duración o pistas incorrectas).")
            }
            let th = await thumbnail(file, at: min(1.5, madeDur / 3))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                update(id) { $0.file = file; $0.thumb = th; $0.state = .ready; $0.version += 1 }
            }
            if running { NSApp.dockTile.badgeLabel = "\(readyCount)/\(clips.count)" }
            Sound.shared.play(.pop); haptic()
            log?("  clip \(c.rank) listo: \(file.lastPathComponent)")
        } catch {
            let msg = (error is CancellationError || Task.isCancelled) ? "Cancelado" : error.localizedDescription
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { update(id) { $0.state = .failed(msg) } }
            log?("  clip \(c.rank) falló: \(msg)")
        }
    }

    func retry(_ id: UUID) {
        Sound.shared.play(.tick)
        Task {
            await process(id)
            if clips.first(where: { $0.id == id })?.state != .ready { Sound.shared.play(.error) }
        }
    }

    /// Cambia inicio o final de un clip ya montado y lo vuelve a montar.
    func retrim(_ id: UUID, start: Double, end: Double) {
        guard end - start >= 1 else { return }
        update(id) { $0.m.start = max(0, start); $0.m.end = end }
        Sound.shared.play(.tick)
        Task { await process(id) }
    }

    func updateTools() {
        guard !updatingTools else { return }
        updatingTools = true
        Task {
            defer { updatingTools = false }
            do {
                try await run("brew", ["upgrade", "yt-dlp"])
                withAnimation(.ui) { error = nil; notice = "yt-dlp está al día. Vuelve a pulsar Sacar clips." }
                Sound.shared.play(.success)
            } catch {
                fail(ClipsError("No he podido actualizar yt-dlp. Abre la Terminal y escribe: brew upgrade yt-dlp"))
            }
        }
    }

    func copyCaption(_ c: ClipItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.m.caption.isEmpty ? c.m.title : "\(c.m.title)\n\n\(c.m.caption)", forType: .string)
        Sound.shared.play(.copy); haptic()
    }

    /// Subida asistida: abre la web de subida de la red, copia el texto y muestra el archivo para arrastrarlo.
    func publish(_ c: ClipItem, to p: Platform) {
        guard let f = c.file else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.m.caption.isEmpty ? c.m.title : "\(c.m.title)\n\n\(c.m.caption)", forType: .string)
        NSWorkspace.shared.open(p.uploadURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
        Sound.shared.play(.copy); haptic()
    }

    func copyAllCaptions() {
        let text = clips.filter { $0.state == .ready }.map { "\($0.rank). \($0.m.title)\n\($0.m.caption)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Sound.shared.play(.copy); haptic()
    }
}

// MARK: - App

@main
struct ClipsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Modo prueba sin ventana: Clips --test URL [nº de clips] [--horizontal] [--sin-subtitulos] [--dur 0|1|2]
        let a = CommandLine.arguments
        if a.count >= 2, a[1] == "--detail-test" { detailTest(); return }
        if a.count >= 3, a[1] == "--snapshot" { snapshot(a[2], running: a.contains("--running"), dark: a.contains("--dark")); return }
        guard a.count >= 3, a[1] == "--test" else { return }
        // La prueba usa el mismo modelo que la ventana, para que la interfaz se anime igual que al usarla.
        let shared = Model()
        shared.persist = false
        Model.testModel = shared
        Task { @MainActor in
            let m = shared
            m.url = a[2]
            m.count = Int(a.count > 3 ? a[3] : "") ?? 3
            m.vertical = !a.contains("--horizontal")
            m.subtitles = !a.contains("--sin-subtitulos")
            if let i = a.firstIndex(of: "--dur"), i + 1 < a.count, let d = Int(a[i + 1]) { m.durIdx = d }
            if let i = a.firstIndex(of: "--notas"), i + 1 < a.count { m.notes = a[i + 1] }
            m.log = { print($0); fflush(stdout) }
            if a.contains("--cancelar") {
                // Prueba de cancelar: en cuanto un clip empiece a descargarse, cancelar y medir.
                Task { @MainActor in
                    while !m.clips.contains(where: { if case .downloading = $0.state { return true }; return false }) {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let t = Date(); m.cancel()
                    while m.running { try? await Task.sleep(nanoseconds: 50_000_000) }
                    print(String(format: "CANCELADO en %.2f s · clips: %@ · carpeta: %@", Date().timeIntervalSince(t),
                                 m.clips.map { "\($0.state)" }.joined(separator: ","), m.outDir?.lastPathComponent ?? "borrada"))
                    exit(0)
                }
            }
            // Mismo camino que el botón "Sacar clips".
            m.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            while m.running { try? await Task.sleep(nanoseconds: 200_000_000) }
            if let e = m.error { print("ERROR: \(e.message)"); exit(1) }
            for c in m.clips {
                print(String(format: "#%d [%d] %@–%@ (%.1fs) | %@ | %@ | %@", c.rank, c.m.score, fmt(c.m.start, tenths: true), fmt(c.m.end, tenths: true),
                             c.duration, c.m.title, c.m.reason, c.file?.path ?? "\(c.state)"))
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("Clips", id: "main") {
            RootView()
                .tint(Palette.cue)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 940, height: 840)
        Settings { SettingsView().tint(Palette.cue) }
    }
}

/// Captura de la interfaz con datos de muestra, para revisar el diseño sin abrir la ventana.
@MainActor func snapshot(_ path: String, running: Bool, dark: Bool) {
    Task { @MainActor in
        let m = Model()
        m.persist = false
        m.url = "https://www.youtube.com/watch?v=iG9CE55wbtY"
        m.info = VideoInfo(id: "x", title: "Do schools kill creativity? | Sir Ken Robinson | TED", channel: "TED", duration: 1203,
                           heatmap: [], chapters: [], thumbnail: nil, captionURL: nil, captionLang: "en", hasWordTiming: true)
        var curve: [Double] = []
        for i in 0..<100 {
            var v: Double = 0.25 + 0.2 * sin(Double(i) / 6)
            if i > 28 && i < 33 { v += 0.45 }
            if i > 70 && i < 74 { v += 0.35 }
            curve.append(v)
        }
        m.curve = curve
        m.done = running ? [.video, .text, .moments] : [.video, .text, .moments, .clips]
        m.stage = .clips
        m.running = running
        m.finished = !running
        m.detail = running ? "Descargando y montando 4 clips…" : "4 clips listos"
        let files = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Clips"), includingPropertiesForKeys: nil))?
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter { $0.pathExtension == "mp4" } ?? []
        let moments = [
            Moment(start: 350.5, end: 391.7, title: "We Get Educated Out of Creativity", reason: "La tesis central de la charla, rematada con la cita de Picasso sobre el miedo a equivocarse.", caption: "", score: 98),
            Moment(start: 1005.2, end: 1064.6, title: "She Wasn't Sick, She Was a Dancer", reason: "La historia de Gillian Lynne: casi la mediquen y acabó siendo una gran coreógrafa.", caption: "", score: 95),
            Moment(start: 740.3, end: 786.8, title: "The Trap of Academic Inflation", reason: "Explica con humor por qué los títulos ya no garantizan trabajo.", caption: "", score: 91),
            Moment(start: 520.6, end: 576.1, title: "Why Schools Don't Teach Dance", reason: "La jerarquía de asignaturas, con el chiste de educar de cintura para arriba.", caption: "", score: 88)]
        for (i, mo) in moments.enumerated() {
            var c = ClipItem(rank: i + 1, m: mo, options: RenderOptions(vertical: true, subtitles: true))
            if !running || i < 2 {
                c.state = .ready
                if i < files.count { c.file = files[i]; c.thumb = await thumbnail(files[i], at: 3) }
            } else { c.state = i == 2 ? .downloading(0.42) : .queued }
            m.clips.append(c)
        }
        m.snapshot = true
        let view = RootView(model: m)
            .frame(width: 940, height: 1180)
            .background(dark ? Color(white: 0.12) : Color(white: 0.955))
            .environment(\.colorScheme, dark ? .dark : .light)
            .tint(Palette.cue)
        let r = ImageRenderer(content: view)
        r.scale = 1.5
        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}

/// Prueba: abre el detalle de un clip en una ventana real y cierra a los 3 s (si no se ha caído antes).
@MainActor func detailTest() {
    Task { @MainActor in
        let m = Model()
        m.persist = false
        let file = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Clips"), includingPropertiesForKeys: nil))?
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.first { $0.pathExtension == "mp4" }
        var c = ClipItem(rank: 1, m: Moment(start: 350.5, end: 391.7, title: "Prueba", reason: "Detalle", caption: "Texto #prueba", score: 90),
                         options: RenderOptions(vertical: true, subtitles: true))
        c.state = .ready; c.file = file
        m.clips = [c]
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: ClipDetail(m: m, id: c.id).tint(Palette.cue))
        w.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        print("detalle OK"); exit(0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        Procs.shared.killAll()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.okdigital.clips")
        try? FileManager.default.removeItem(at: cache)
    }
}
