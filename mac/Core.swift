// Clips · © 2026 OK Digital. Todos los derechos reservados.
import Foundation

// MARK: - Errores

struct ClipsError: LocalizedError {
    let message: String
    var canUpdateTools = false
    /// No tiene sentido probar con otro modelo (clave mala, sin internet).
    var fatal = false
    /// El error se arregla en Ajustes (falta la clave o no vale).
    var opensSettings = false
    init(_ m: String, canUpdateTools: Bool = false) { message = m; self.canUpdateTools = canUpdateTools }
    var errorDescription: String? { message }
}

func fmt(_ s: Double, tenths: Bool = false) -> String {
    let t = max(0, s)
    let whole = Int(t)
    let h = whole / 3600, m = (whole % 3600) / 60, sec = whole % 60
    var r = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    if tenths { r += String(format: ".%d", Int((t - Double(whole)) * 10)) }
    return r
}

// MARK: - Procesos externos (yt-dlp, ffmpeg)

func toolPath(_ name: String) -> String {
    for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        let p = d + "/" + name
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return name
}

final class Buf: @unchecked Sendable {
    private var d = Data(); private let l = NSLock()
    func add(_ x: Data) { l.lock(); d.append(x); l.unlock() }
    var data: Data { l.lock(); defer { l.unlock() }; return d }
}

/// Hijos y nietos de un proceso (yt-dlp lanza ffmpeg, que si no se mata sigue descargando).
func descendants(of pid: Int32) -> [Int32] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-P", String(pid)]
    let out = Pipe()
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let kids = String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
    return kids + kids.flatMap { descendants(of: $0) }
}

/// Procesos en marcha, para poder cancelarlos todos de golpe (con sus hijos).
final class Procs: @unchecked Sendable {
    static let shared = Procs()
    private var running: [ObjectIdentifier: Process] = [:]
    private let l = NSLock()
    func add(_ p: Process) { l.lock(); running[ObjectIdentifier(p)] = p; l.unlock() }
    func remove(_ p: Process) { l.lock(); running[ObjectIdentifier(p)] = nil; l.unlock() }
    func killAll() {
        l.lock(); let ps = Array(running.values); l.unlock()
        for p in ps where p.isRunning {
            let kids = descendants(of: p.processIdentifier)
            p.terminate()
            for k in kids.reversed() { kill(k, SIGTERM) }
        }
    }
}

/// Lee una tubería y entrega cada línea (separada por \n o \r) al callback.
private func pump(_ h: FileHandle, into buf: Buf, onLine: (@Sendable (String) -> Void)?) {
    var pending = Data()
    while true {
        let x = h.availableData
        if x.isEmpty { break }
        buf.add(x)
        guard let onLine else { continue }
        pending.append(x)
        while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...i)
            if !line.isEmpty { onLine(line) }
        }
    }
}

func runSync(_ exe: String, _ args: [String], onLine: (@Sendable (String) -> Void)?) throws -> (Int32, Data, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: toolPath(exe))
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { throw ClipsError("No encuentro \(exe). Instálalo con Homebrew: brew install \(exe)") }
    Procs.shared.add(p)
    defer { Procs.shared.remove(p) }
    let outBuf = Buf(), errBuf = Buf()
    let g = DispatchGroup()
    for (h, b) in [(out.fileHandleForReading, outBuf), (err.fileHandleForReading, errBuf)] {
        g.enter()
        DispatchQueue.global().async { pump(h, into: b, onLine: onLine); g.leave() }
    }
    p.waitUntilExit()
    // Si un proceso hijo se quedó con la tubería abierta, no esperarlo para siempre.
    _ = g.wait(timeout: .now() + 3)
    return (p.terminationStatus, outBuf.data, String(decoding: errBuf.data, as: UTF8.self))
}

/// Traduce los fallos típicos de yt-dlp a algo que se entienda.
func explainToolError(_ exe: String, _ err: String) -> ClipsError {
    let e = err.lowercased()
    if exe == "yt-dlp" {
        if e.contains("private video") || e.contains("video unavailable") || e.contains("has been removed") {
            return ClipsError("El vídeo no está disponible: es privado, se ha borrado o está bloqueado.")
        }
        if e.contains("sign in to confirm your age") || e.contains("age-restricted") {
            return ClipsError("El vídeo tiene restricción de edad y YouTube no deja descargarlo sin iniciar sesión.")
        }
        if e.contains("unsupported url") || e.contains("is not a valid url") {
            return ClipsError("Ese enlace no es de un vídeo de YouTube.")
        }
        if e.contains("unable to resolve host") || e.contains("nodename nor servname") || e.contains("network is unreachable") {
            return ClipsError("No hay conexión a internet.")
        }
        if e.contains("not a bot") {
            return ClipsError("YouTube está frenando las descargas desde tu conexión (pide confirmar que no eres un robot). Actualiza yt-dlp o espera un rato y vuelve a probar.", canUpdateTools: true)
        }
        if e.contains("sign in to confirm") || e.contains("unable to extract") || e.contains("http error 403")
            || e.contains("nsig") || e.contains("requested format is not available") {
            return ClipsError("YouTube ha cambiado algo y hay que actualizar yt-dlp.", canUpdateTools: true)
        }
    }
    let tail = err.split(separator: "\n").filter { !$0.contains("WARNING") }.suffix(2).joined(separator: "\n")
    return ClipsError("\(exe) falló. \(tail)", canUpdateTools: exe == "yt-dlp")
}

/// Como `run`, pero devuelve lo que el programa escribe en stderr (ffmpeg informa ahí de sus mediciones).
func runCapture(_ exe: String, _ args: [String]) async throws -> String {
    let (code, _, err) = try await Task.detached { try runSync(exe, args, onLine: nil) }.value
    try Task.checkCancellation()
    if code != 0 { throw explainToolError(exe, err) }
    return err
}

@discardableResult
func run(_ exe: String, _ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> Data {
    let (code, data, err) = try await Task.detached { try runSync(exe, args, onLine: onLine) }.value
    try Task.checkCancellation()
    if code != 0 { throw explainToolError(exe, err) }
    return data
}

// MARK: - Datos del vídeo

struct Word {
    var start: Double
    var end: Double
    var text: String
    /// Marcas como [Música] o [Risas]: sirven de pista a la IA pero no van en los subtítulos.
    var isTag: Bool { text.hasPrefix("[") || text.hasPrefix("(") }
}

struct VideoInfo {
    var id: String
    var title: String
    var channel: String
    var duration: Double
    var heatmap: [(start: Double, end: Double, value: Double)]
    var chapters: [(start: Double, title: String)]
    var thumbnail: URL?
    var captionURL: URL?
    var captionLang: String?
    var hasWordTiming: Bool
}

func isYouTubeLink(_ s: String) -> Bool {
    guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let h = u.host?.lowercased() else { return false }
    return h == "youtu.be" || h == "youtube.com" || h.hasSuffix(".youtube.com")
}

/// Saca el enlace de YouTube de un texto pegado, aunque venga con más texto alrededor o sin "https://".
func extractYouTubeLink(_ s: String) -> String? {
    let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if isYouTubeLink(text) { return text }
    for token in text.split(whereSeparator: { $0.isWhitespace || "<>\"'()".contains($0) }) {
        var t = String(token)
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        if isYouTubeLink(t) { return t }
    }
    return nil
}

/// Enlaces de YouTube que no son de un vídeo (listas, canales, portada).
func youTubeLinkProblem(_ s: String) -> String? {
    guard let u = URL(string: s), let host = u.host?.lowercased() else { return nil }
    let path = u.path.lowercased()
    if host == "youtu.be" { return path.count > 1 ? nil : "Ese enlace no lleva a ningún vídeo." }
    let hasVideo = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } ?? false
    if hasVideo || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") || path.hasPrefix("/embed/") || path.hasPrefix("/v/") { return nil }
    if path.hasPrefix("/playlist") { return "Es una lista de reproducción. Abre el vídeo que quieras y copia su enlace." }
    if path.hasPrefix("/@") || path.hasPrefix("/channel") || path.hasPrefix("/c/") || path.hasPrefix("/user") {
        return "Es el enlace de un canal. Abre uno de sus vídeos y copia su enlace."
    }
    return "Ese enlace no lleva a ningún vídeo. Abre el vídeo en YouTube y copia su enlace."
}

func fetchInfo(_ url: String) async throws -> VideoInfo {
    let d = try await run("yt-dlp", ["-J", "--no-playlist", "--no-warnings", url])
    guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw ClipsError("No pude leer los datos del vídeo.") }
    if (j["_type"] as? String) == "playlist" { throw ClipsError("Es una lista de reproducción. Abre el vídeo que quieras y copia su enlace.") }
    if (j["is_live"] as? Bool) == true { throw ClipsError("Es un directo en curso. Espera a que termine y vuelve a probar.") }
    let subs = (j["subtitles"] as? [String: [[String: Any]]] ?? [:]).filter { $0.key != "live_chat" }
    let autos = j["automatic_captions"] as? [String: [[String: Any]]] ?? [:]
    // Idioma original: el que dice YouTube o, si no, el del audio marcado como original
    // (los vídeos con doblaje automático traen varias pistas de audio y de subtítulos).
    let formats = j["formats"] as? [[String: Any]] ?? []
    let originalAudio = formats
        .filter { ($0["acodec"] as? String ?? "none") != "none" && $0["language"] is String }
        .max { ($0["language_preference"] as? Int ?? -1) < ($1["language_preference"] as? Int ?? -1) }?["language"] as? String
    let lang = (j["language"] as? String) ?? originalAudio
    func base(_ s: String) -> String { String(s.lowercased().split(separator: "-").first ?? "") }

    func json3(_ list: [[String: Any]]?) -> URL? {
        (list?.first { $0["ext"] as? String == "json3" }?["url"] as? String).flatMap(URL.init(string:))
    }
    // Preferencia: subtítulos automáticos en el idioma original (traen el tiempo de cada palabra),
    // luego los subidos por el autor, luego automáticos en el idioma del vídeo.
    var cap: (URL, String, Bool)?
    let origs = autos.keys.filter { $0.hasSuffix("-orig") }.sorted()
    let orig = origs.first { k in lang.map { base(k) == base($0) } ?? false } ?? (lang == nil ? origs.first : nil)
    if let k = orig, let u = json3(autos[k]) { cap = (u, k, true) }
    else if let k = (lang.flatMap { l in subs.keys.first { base($0) == base(l) } }
                     ?? subs.keys.first { $0.hasPrefix("es") } ?? subs.keys.first { $0.hasPrefix("en") } ?? subs.keys.sorted().first),
            let u = json3(subs[k]) { cap = (u, k, false) }
    else if let l = lang, let k = autos[l] != nil ? l : autos.keys.first(where: { $0 == base(l) }), let u = json3(autos[k]) { cap = (u, k, true) }

    let heat = (j["heatmap"] as? [[String: Any]] ?? []).compactMap { e -> (Double, Double, Double)? in
        guard let s = e["start_time"] as? Double, let en = e["end_time"] as? Double, let v = e["value"] as? Double else { return nil }
        return (s, en, v)
    }
    let chapters = (j["chapters"] as? [[String: Any]] ?? []).compactMap { c -> (Double, String)? in
        guard let s = c["start_time"] as? Double, let t = c["title"] as? String else { return nil }
        return (s, t)
    }
    return VideoInfo(id: j["id"] as? String ?? UUID().uuidString,
                     title: j["title"] as? String ?? "Vídeo",
                     channel: j["channel"] as? String ?? j["uploader"] as? String ?? "",
                     duration: j["duration"] as? Double ?? 0,
                     heatmap: heat.map { (start: $0.0, end: $0.1, value: $0.2) },
                     chapters: chapters.map { (start: $0.0, title: $0.1) },
                     thumbnail: (j["thumbnail"] as? String).flatMap(URL.init(string:)),
                     captionURL: cap?.0, captionLang: cap?.1, hasWordTiming: cap?.2 ?? false)
}

// MARK: - Transcripción

/// Convierte subtítulos json3 de YouTube en palabras con tiempo.
func parseJSON3(_ data: Data) -> [Word] {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let events = j["events"] as? [[String: Any]] else { return [] }
    var words: [Word] = []
    for e in events {
        guard let segs = e["segs"] as? [[String: Any]], let t0 = e["tStartMs"] as? Double else { continue }
        let dur = (e["dDurationMs"] as? Double ?? 0) / 1000
        let start = t0 / 1000
        let items = segs.compactMap { s -> (Double, String)? in
            let t = (s["utf8"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : (start + (s["tOffsetMs"] as? Double ?? 0) / 1000, t)
        }
        if items.isEmpty { continue }
        if items.count == 1 && items[0].1.contains(" ") {
            // Subtítulos manuales: una frase entera en un bloque; repartimos el tiempo entre sus palabras.
            words += spread(items[0].1, from: start, to: start + max(dur, 0.3))
        } else {
            for (t, w) in items { words.append(Word(start: t, end: t, text: w)) }
        }
    }
    words.sort { $0.start < $1.start }
    for i in words.indices where words[i].end <= words[i].start {
        let next = i + 1 < words.count ? words[i + 1].start : words[i].start + 0.6
        words[i].end = min(next, words[i].start + 0.9)
    }
    // A veces un bloque trae dos palabras juntas ("of it"): se separan para poder buscarlas y subtitularlas.
    return words.flatMap { w in w.text.contains(" ") && !w.isTag ? spread(w.text, from: w.start, to: w.end) : [w] }
}

/// Reparte una frase en palabras con el tiempo proporcional a su longitud.
func spread(_ text: String, from a: Double, to b: Double) -> [Word] {
    let parts = text.split(whereSeparator: { $0 == " " }).map(String.init)
    let total = Double(parts.reduce(0) { $0 + $1.count + 1 })
    guard total > 0 else { return [] }
    var t = a, out: [Word] = []
    for p in parts {
        let d = (b - a) * Double(p.count + 1) / total
        out.append(Word(start: t, end: t + d, text: p)); t += d
    }
    return out
}

/// Texto para la IA: una línea por frase o pausa, con el segundo exacto delante.
func transcriptLines(_ words: [Word]) -> String {
    var lines: [String] = [], cur: [String] = [], curStart = 0.0, lastEnd = 0.0
    for w in words {
        if !cur.isEmpty && (w.start - lastEnd > 0.8 || w.start - curStart > 10) {
            lines.append(String(format: "[%.1f] ", curStart) + cur.joined(separator: " ")); cur = []
        }
        if cur.isEmpty { curStart = w.start }
        cur.append(w.text); lastEnd = w.end
    }
    if !cur.isEmpty { lines.append(String(format: "[%.1f] ", curStart) + cur.joined(separator: " ")) }
    return lines.joined(separator: "\n")
}

func fetchWords(info: VideoInfo, url: String, dir: URL) async throws -> [Word] {
    if let u = info.captionURL, let (d, r) = try? await URLSession.shared.data(from: u),
       (r as? HTTPURLResponse)?.statusCode == 200 {
        let w = parseJSON3(d)
        if !w.isEmpty { return w }
    }
    // Plan B: que yt-dlp baje los subtítulos (a veces YouTube no deja leerlos directamente).
    if let lang = info.captionLang {
        _ = try? await run("yt-dlp", ["--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", lang,
                                      "--sub-format", "json3", "--no-playlist", "--no-warnings",
                                      "-o", dir.appendingPathComponent("sub").path, url])
        if let f = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "json3" }),
           let d = try? Data(contentsOf: f) {
            let w = parseJSON3(d)
            if !w.isEmpty { return w }
        }
    }
    return []
}

// MARK: - Gemini

/// Del mejor al más disponible. Si uno está saturado o tarda, entra el siguiente.
let geminiModels = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite"]

/// Para avisar en pantalla cuando Gemini va saturado y se está reintentando.
nonisolated(unsafe) var geminiStatus: (@Sendable (String) -> Void)?
let geminiModel = geminiModels[0]

func missingKeyError() -> ClipsError {
    var e = ClipsError("Falta la clave de Gemini. Es gratis: ábrela en Ajustes y sigue los 3 pasos.")
    e.fatal = true; e.opensSettings = true
    return e
}

func geminiKey() -> String {
    let k = (UserDefaults.standard.string(forKey: "geminiKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return k.isEmpty ? (ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? "") : k
}

private func geminiFailure(_ status: Int, _ data: Data) -> ClipsError {
    let msg = String(decoding: data, as: UTF8.self).lowercased()
    switch status {
    case 429: return ClipsError("Gemini ha llegado a su límite gratuito por ahora. Espera un minuto y vuelve a probar.")
    case 400 where msg.contains("api key"), 401, 403:
        var e = ClipsError("Gemini no acepta la clave. Revísala en Ajustes."); e.fatal = true; e.opensSettings = true; return e
    case 404: return ClipsError("Los modelos de Gemini que usa Clips ya no están disponibles; hay que actualizar la app.")
    case 503: return ClipsError("Gemini está saturado ahora mismo. Vuelve a probar en un par de minutos.")
    default: return ClipsError("Gemini respondió con un error (\(status)). Vuelve a probar en un momento.")
    }
}

/// Traduce los fallos de red a mensajes claros. La cancelación sigue siendo cancelación.
func networkError(_ e: URLError, who: String) -> Error {
    switch e.code {
    case .cancelled: return CancellationError()
    case .notConnectedToInternet:
        var c = ClipsError("No hay conexión a internet."); c.fatal = true; return c
    case .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
        return ClipsError("Se ha cortado la conexión con \(who). Comprueba internet y vuelve a probar.")
    case .timedOut: return ClipsError("\(who) ha tardado demasiado en responder. Vuelve a probar.")
    default: return ClipsError("No he podido hablar con \(who) (error \(e.code.rawValue)). Vuelve a probar.")
    }
}

/// Una llamada a un modelo concreto.
private func geminiOnce(model: String, body: Data, key: String, timeout: Double) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
    req.httpMethod = "POST"; req.timeoutInterval = timeout
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    req.httpBody = body
    let data: Data, resp: URLResponse
    do { (data, resp) = try await URLSession.shared.data(for: req) }
    catch let e as URLError { throw networkError(e, who: "Gemini") }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw geminiFailure(status, data) }
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cand = (j["candidates"] as? [[String: Any]])?.first,
          let ps = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]],
          let text = ps.compactMap({ $0["text"] as? String }).last,
          let r = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { throw ClipsError("Gemini devolvió una respuesta que no entiendo. Vuelve a probar.") }
    return r
}

/// Llama a Gemini pidiendo JSON con un esquema fijo. Empieza con el mejor modelo; si falla,
/// o si a los `headStart` segundos aún no ha contestado, lanza el siguiente a la vez y gana el primero que responda bien.
func gemini(parts: [[String: Any]], schema: [String: Any], timeout: Double = 240, headStart: Double = 40) async throws -> [String: Any] {
    // Hasta 3 rondas: si todos los modelos están saturados, esperar un poco y volver a intentarlo.
    var lastError: Error = ClipsError("Gemini no responde ahora mismo. Vuelve a probar en un momento.")
    for round in 0..<3 {
        do { return try await geminiRound(parts: parts, schema: schema, timeout: timeout, headStart: headStart) }
        catch let e as ClipsError where !e.fatal {
            lastError = e
            if round < 2 {
                geminiStatus?("Gemini va saturado; vuelvo a intentarlo en unos segundos…")
                try await Task.sleep(nanoseconds: UInt64(6 + round * 8) * 1_000_000_000)
            }
        }
    }
    throw lastError
}

private func geminiRound(parts: [[String: Any]], schema: [String: Any], timeout: Double, headStart: Double) async throws -> [String: Any] {
    let key = geminiKey()
    if key.isEmpty { throw missingKeyError() }
    let body = try JSONSerialization.data(withJSONObject: [
        "contents": [["parts": parts]],
        "generationConfig": ["responseMimeType": "application/json", "responseSchema": schema, "temperature": 0.4]] as [String: Any])
    let models = geminiModels
    return try await withThrowingTaskGroup(of: (Int, Result<[String: Any], Error>).self) { g in
        var launched = 0, failed = 0
        var lastError: Error = ClipsError("Gemini no responde ahora mismo. Vuelve a probar en un momento.")
        func launch() {
            let i = launched; launched += 1
            g.addTask {
                do { return (i, .success(try await geminiOnce(model: models[i], body: body, key: key, timeout: timeout))) }
                catch { return (i, .failure(error)) }
            }
            if launched < models.count {
                // Temporizador: lleva la cuenta de modelos lanzados al crearse (en negativo).
                let tag = -launched
                g.addTask { try await Task.sleep(nanoseconds: UInt64(headStart * 1e9)); return (tag, .failure(CancellationError())) }
            }
        }
        launch()
        while let (i, r) = try await g.next() {
            switch r {
            case .success(let v):
                g.cancelAll(); return v
            case .failure(let e):
                if i < 0 { if launched == -i && launched < models.count { launch() }; continue }
                if let c = e as? ClipsError, c.fatal { g.cancelAll(); throw c }
                if e is CancellationError || Task.isCancelled { g.cancelAll(); throw CancellationError() }
                failed += 1; lastError = e
                if launched < models.count { launch() }
                else if failed >= launched { g.cancelAll(); throw lastError }
            }
        }
        throw lastError
    }
}

/// Comprueba la clave sin gastar cuota de generación (no depende de que exista un modelo concreto).
func testGeminiKey(_ key: String) async -> Bool {
    var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!)
    req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    guard let (_, r) = try? await URLSession.shared.data(for: req) else { return false }
    return (r as? HTTPURLResponse)?.statusCode == 200
}

/// Sube un archivo a la Files API de Gemini y devuelve su URI.
func geminiUpload(_ file: URL, mime: String) async throws -> String {
    let key = geminiKey()
    if key.isEmpty { throw missingKeyError() }
    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    var start = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!)
    start.httpMethod = "POST"
    start.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
    start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
    start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
    start.setValue(mime, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
    start.setValue("application/json", forHTTPHeaderField: "Content-Type")
    start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": "clips-audio"]])
    let d0: Data, r0: URLResponse
    do { (d0, r0) = try await URLSession.shared.data(for: start) } catch let e as URLError { throw networkError(e, who: "Gemini") }
    guard let h = r0 as? HTTPURLResponse, h.statusCode == 200,
          let up = h.value(forHTTPHeaderField: "x-goog-upload-url"), let upURL = URL(string: up)
    else { throw geminiFailure((r0 as? HTTPURLResponse)?.statusCode ?? 0, d0) }
    var put = URLRequest(url: upURL)
    put.httpMethod = "POST"; put.timeoutInterval = 600
    put.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
    put.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
    let d1: Data, r1: URLResponse
    do { (d1, r1) = try await URLSession.shared.upload(for: put, fromFile: file) } catch let e as URLError { throw networkError(e, who: "Gemini") }
    guard (r1 as? HTTPURLResponse)?.statusCode == 200,
          let j = try JSONSerialization.jsonObject(with: d1) as? [String: Any],
          let f = j["file"] as? [String: Any], let uri = f["uri"] as? String, let name = f["name"] as? String
    else { throw ClipsError("No pude subir el audio a Gemini.") }
    // Esperar a que Gemini termine de procesar el archivo.
    for _ in 0..<60 {
        var g = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)")!)
        g.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        if let (d, _) = try? await URLSession.shared.data(for: g),
           let s = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["state"] as? String {
            if s == "ACTIVE" { return uri }
            if s == "FAILED" { break }
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    throw ClipsError("Gemini no pudo procesar el audio del vídeo.")
}

/// Plan B para vídeos sin subtítulos: bajar el audio y que Gemini lo transcriba con tiempos.
func transcribeAudio(url: String, dir: URL) async throws -> [Word] {
    try await run("yt-dlp", ["-f", "ba[abr<=96]/ba/b", "--no-playlist", "--no-warnings",
                             "-o", dir.appendingPathComponent("audio.%(ext)s").path, url])
    guard let src = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
        .first(where: { $0.lastPathComponent.hasPrefix("audio.") }) else { throw ClipsError("No pude bajar el audio del vídeo.") }
    let mp3 = dir.appendingPathComponent("voz.mp3")
    try await run("ffmpeg", ["-y", "-i", src.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "libmp3lame", "-b:a", "32k", mp3.path])
    let uri = try await geminiUpload(mp3, mime: "audio/mpeg")
    let schema: [String: Any] = ["type": "OBJECT", "properties": ["segments": ["type": "ARRAY", "items": [
        "type": "OBJECT", "properties": ["start": ["type": "NUMBER"], "end": ["type": "NUMBER"], "text": ["type": "STRING"]],
        "required": ["start", "end", "text"]]]], "required": ["segments"]]
    let r = try await gemini(parts: [
        ["file_data": ["mime_type": "audio/mpeg", "file_uri": uri]],
        ["text": """
        Transcribe este audio palabra por palabra, en su idioma original, en frases cortas de 2 a 8 segundos.
        "start" y "end" en segundos exactos desde el inicio del audio. Marca risas, aplausos o música entre corchetes, como [Risas].
        """]], schema: schema, timeout: 600)
    let segs = r["segments"] as? [[String: Any]] ?? []
    var words: [Word] = []
    for s in segs {
        guard let a = s["start"] as? Double, let b = s["end"] as? Double, let t = s["text"] as? String, b > a else { continue }
        words += spread(t, from: a, to: b)
    }
    if words.isEmpty { throw ClipsError("No he podido sacar el texto de este vídeo.") }
    return words.sorted { $0.start < $1.start }
}

// MARK: - Elegir momentos

struct Moment {
    var start: Double, end: Double
    var title: String, reason: String, caption: String
    var score: Int
    /// Lo que comprobó la revisión (para el registro y el detalle del clip).
    var check = ""
    /// Parte del vídeo a la que pertenece, si se pidió un clip por parte.
    var part: Int? = nil
}

/// Lo que la persona pide en las anotaciones, ya interpretado. El código hace cumplir número, orden y partes;
/// el resto de instrucciones va a cada pasada de Gemini y la verificación final comprueba que se cumplen.
struct ClipPlan {
    struct Part { var start: Double, end: Double, title: String }
    var count: Int? = nil
    var chronological = false
    var parts: [Part] = []
    var rules = ""
    var summary = ""

    var isEmpty: Bool { count == nil && !chronological && parts.isEmpty && rules.isEmpty }
    /// Bloque para los prompts.
    var prompt: String {
        var s = ""
        if !rules.isEmpty { s += "INSTRUCCIONES DE LA PERSONA (mandan sobre los criterios generales, salvo empezar y acabar en frases completas y no inventar nada): \(rules)\n" }
        if !parts.isEmpty {
            s += "El vídeo se divide en estas partes y se quiere UN clip de cada una, que trate de lo que pasa en esa parte y quede entero dentro de ella:\n"
            s += parts.enumerated().map { String(format: "  Parte %d: %.0f–%.0f s · %@", $0.offset, $0.element.start, $0.element.end, $0.element.title) }.joined(separator: "\n") + "\n"
        }
        return s
    }
    /// Cuánto del clip cae dentro de la parte `p` (0–1).
    func inside(_ m: Moment, _ p: Int) -> Double {
        guard parts.indices.contains(p), m.end > m.start else { return 0 }
        return max(0, min(m.end, parts[p].end) - max(m.start, parts[p].start)) / (m.end - m.start)
    }
    /// La parte que contiene al menos el 80 % del clip.
    func part(of m: Moment) -> Int? { parts.indices.first { inside(m, $0) >= 0.8 } }
}

/// Interpreta las anotaciones ("10 en orden cronológico", "uno de cada parte"…) en un plan concreto.
func planFromNotes(_ notes: String, info: VideoInfo, words: [Word], minD: Int) async throws -> ClipPlan {
    let chapters = info.chapters.map { String(format: "%.0f s: %@", $0.start, $0.title) }.joined(separator: "; ")
    let prompt = """
    Una persona va a sacar clips cortos de este vídeo y ha dejado estas anotaciones:
    «\(notes)»

    Tradúcelas a un plan:
    - "count": número de clips que pide expresamente (0 si no dice ninguno).
    - "order": "chronological" si quiere los clips en el orden en que pasan en el vídeo (también si habla de "en orden", "por orden", "cronológico" o de seguir la historia); si no, "best".
    - "one_per_part": true si quiere un clip de cada parte, bloque, sección, capítulo, punto o tema del vídeo.
    - "parts": solo si one_per_part es true. Las partes REALES del vídeo, en orden, sin solaparse y cubriendo de principio a fin lo que interesa. Si dice cuántas partes hay ("está estructurado en 5"), devuelve exactamente esas, buscando dónde cambia de verdad de tema en la transcripción. Usa los capítulos si existen y encajan. Cada parte: "start" y "end" en segundos (tomados de las marcas [segundo]) y un "title" corto que diga de qué trata. Ninguna parte de menos de \(minD) s.
    - "rules": cualquier OTRA instrucción para elegir o recortar los clips (de qué temas, qué evitar, quién debe salir…), escrita en claro y en español. No repitas aquí el número, el orden ni lo de una por parte: eso ya va en los otros campos. Vacío si no hay más.
    - "summary": en una frase en español, qué has entendido (por ejemplo: "10 clips en orden cronológico" o "5 clips, uno de cada parte: …").
    No inventes peticiones que no estén en las anotaciones.

    Vídeo: "\(info.title)", \(Int(info.duration)) segundos.
    \(chapters.isEmpty ? "" : "Capítulos: \(chapters)\n")
    TRANSCRIPCIÓN:
    \(transcriptLines(words))
    """
    let part: [String: Any] = ["type": "OBJECT", "properties": ["start": ["type": "NUMBER"], "end": ["type": "NUMBER"], "title": ["type": "STRING"]],
                               "required": ["start", "end", "title"]]
    let schema: [String: Any] = ["type": "OBJECT", "properties": [
        "count": ["type": "INTEGER"], "order": ["type": "STRING", "enum": ["best", "chronological"]],
        "one_per_part": ["type": "BOOLEAN"], "parts": ["type": "ARRAY", "items": part],
        "rules": ["type": "STRING"], "summary": ["type": "STRING"]],
        "required": ["count", "order", "one_per_part", "parts", "rules", "summary"]]
    let r = try await gemini(parts: [["text": prompt]], schema: schema)
    var plan = ClipPlan()
    if let c = num(r["count"]).map(Int.init), c > 0 { plan.count = min(c, 20) }
    plan.chronological = (r["order"] as? String) == "chronological"
    plan.rules = (r["rules"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    plan.summary = (r["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if (r["one_per_part"] as? Bool) == true {
        // Partes en orden, dentro del vídeo y sin solaparse; las demasiado cortas se unen a la anterior.
        let dur = info.duration > 0 ? info.duration : (words.last?.end ?? 0)
        var parts: [ClipPlan.Part] = []
        for p in (r["parts"] as? [[String: Any]] ?? []).compactMap({ d -> ClipPlan.Part? in
            guard let a = num(d["start"]), let b = num(d["end"]), b > a else { return nil }
            return ClipPlan.Part(start: max(0, a), end: min(dur, b), title: d["title"] as? String ?? "")
        }).sorted(by: { $0.start < $1.start }) {
            var p = p
            if let last = parts.last { p.start = max(p.start, last.end) }
            if p.end - p.start >= Double(minD) { parts.append(p) }
            else if !parts.isEmpty { parts[parts.count - 1].end = max(parts[parts.count - 1].end, p.end) }
        }
        plan.parts = parts
        if !parts.isEmpty { plan.chronological = true; plan.count = parts.count }
    }
    return plan
}

enum Focus: String, CaseIterable, Identifiable {
    case auto = "Automático", tension = "Tensión", humor = "Humor", learn = "Aprendizaje", emotion = "Emoción", debate = "Polémica"
    var id: String { rawValue }
    var hint: String {
        switch self {
        case .auto: return "Lo que mejor funcione: tensión, giros, humor, revelaciones o frases potentes."
        case .tension: return "Prioriza momentos de tensión, conflicto, suspense, discusiones y giros."
        case .humor: return "Prioriza los momentos más graciosos: chistes, reacciones, situaciones absurdas, risas."
        case .learn: return "Prioriza explicaciones claras, consejos útiles y datos sorprendentes que se entiendan solos."
        case .emotion: return "Prioriza momentos emotivos, inspiradores o personales que conmuevan."
        case .debate: return "Prioriza opiniones fuertes, afirmaciones polémicas y desacuerdos que generen comentarios."
        }
    }
}

/// Primera pasada: candidatos (más de los que se piden; la revisión decide cuáles valen).
/// Con `onlyParts`, solo busca en esas partes del plan (para rellenar las que se quedaron sin clip).
func pickCandidates(info: VideoInfo, words: [Word], count: Int, minD: Int, maxD: Int, focus: Focus,
                    plan: ClipPlan = ClipPlan(), onlyParts: [Int]? = nil) async throws -> [Moment] {
    let peaks = info.heatmap.sorted { $0.value > $1.value }.prefix(10)
        .map { String(format: "%.0f–%.0f s (%.2f)", $0.start, $0.end, $0.value) }.joined(separator: ", ")
    let chapters = info.chapters.map { String(format: "%.0f s: %@", $0.start, $0.title) }.joined(separator: "; ")
    let wanted = onlyParts ?? Array(plan.parts.indices)
    let ask = plan.parts.isEmpty ? count + 5 : wanted.count * 3
    let perPart = plan.parts.isEmpty ? "" : """

    Devuelve 3 candidatos de CADA una de estas partes: \(wanted.map { "Parte \($0)" }.joined(separator: ", ")). "part" es el número de la parte; el clip entero debe caer dentro de ella y tratar de lo que pasa en ella.
    """
    let prompt = """
    Eres editor jefe de un canal que vive de los clips cortos (TikTok, Reels, Shorts). Tu trabajo: encontrar en este vídeo los momentos que, recortados, la gente vería hasta el final y compartiría.

    Vídeo: "\(info.title)"\(info.channel.isEmpty ? "" : " de \(info.channel)"), \(Int(info.duration)) segundos.
    \(chapters.isEmpty ? "" : "Capítulos: \(chapters)\n")Momentos que más repiten los espectadores (rango e intensidad 0–1; buena pista, no obligatoria): \(peaks.isEmpty ? "sin datos" : peaks)

    Qué buscar: \(focus.hint)
    \(plan.prompt)
    Devuelve \(ask) candidatos, del mejor al peor.\(perPart) Cada uno:
    - Dura entre \(minD) y \(maxD) segundos.
    - Se entiende solo, sin haber visto el resto del vídeo, y se cuenta COMPLETO en esa duración: un chiste con su remate, una reacción, una opinión contundente, una pregunta con su respuesta, una situación con su desenlace. Una anécdota larga solo si su planteamiento y su final caben.
    - Empieza justo donde empieza una frase con gancho (nada de "y entonces", "bueno, pues…" ni frases a medias) y termina cuando la idea se cierra: remate, conclusión o reacción. Nunca a mitad de frase.
    - No se solapa con otro candidato.
    - "start" y "end": segundos del vídeo, tomados de las marcas [segundo] de la transcripción (puedes usar un punto intermedio de una línea si la frase empieza ahí).
    - "first_words": las 4 primeras palabras del clip, copiadas tal cual de la transcripción. "last_words": las 4 últimas, tal cual. Comprueba que la última palabra cierra la frase (si la frase sigue en la línea siguiente, inclúyela hasta el final).
    - "title": título corto y potente para el clip, en el idioma del vídeo, sin comillas.
    - "reason": por qué funciona, en una frase en español, concreta (qué pasa en ese momento).
    - "caption": texto para publicarlo en redes, en el idioma del vídeo, 1–2 frases y 3–5 hashtags.
    - "score": de 0 a 100, cuánto potencial viral tiene de verdad. Sé exigente.

    TRANSCRIPCIÓN (cada línea empieza con el segundo en que se dice; entre corchetes, sonidos como [Risas] o [Música]):
    \(transcriptLines(words))
    """
    let item: [String: Any] = ["type": "OBJECT", "properties": [
        "start": ["type": "NUMBER"], "end": ["type": "NUMBER"], "title": ["type": "STRING"],
        "reason": ["type": "STRING"], "caption": ["type": "STRING"], "score": ["type": "INTEGER"],
        "first_words": ["type": "STRING"], "last_words": ["type": "STRING"], "part": ["type": "INTEGER"]],
        "required": ["start", "end", "first_words", "last_words", "title", "reason", "caption", "score"]]
    let r = try await gemini(parts: [["text": prompt]],
                             schema: ["type": "OBJECT", "properties": ["clips": ["type": "ARRAY", "items": item]], "required": ["clips"]])
    let raw = r["clips"] as? [[String: Any]] ?? []
    let speech = words.filter { !$0.isTag }
    var out: [Moment] = []
    for c in raw {
        guard let s0 = num(c["start"]), let e0 = num(c["end"]), e0 > s0 else { continue }
        var (s, e) = anchor(s0, e0, first: c["first_words"] as? String ?? "", last: c["last_words"] as? String ?? "",
                            words: speech, duration: info.duration)
        if e - s > Double(maxD) + 6 { e = snap(s, s + Double(maxD), words: speech, duration: info.duration).1 }
        // Si se ha quedado corto (la IA no siempre respeta la duración), alargar hasta una pausa natural.
        if e - s < Double(minD) * 0.9 {
            let target = s + Double(minD) + Double(maxD - minD) * 0.3
            e = max(e, snap(s, target, words: speech, duration: info.duration).1)
        }
        if e - s < Double(minD) * 0.6 { continue }
        if out.contains(where: { s < $0.end && e > $0.start }) { continue }
        var m = Moment(start: s, end: e,
                       title: (c["title"] as? String ?? "Clip").trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ")),
                       reason: c["reason"] as? String ?? "", caption: c["caption"] as? String ?? "",
                       score: max(0, min(100, Int(num(c["score"]) ?? 50))))
        if !plan.parts.isEmpty {
            // La parte la decide el código por dónde cae el clip, no lo que diga la IA; si cruza de una parte a otra, fuera.
            guard let p = plan.part(of: m), wanted.contains(p) else { continue }
            m.part = p
        }
        out.append(m)
    }
    out = out.sorted { $0.score > $1.score }
    if out.isEmpty { throw ClipsError("No he encontrado momentos que se sostengan solos. Prueba con otra duración o con otro enfoque.") }
    return out
}

/// Tiempos de corte para un clip que va de la palabra `i` a la `j`: justo antes de la primera y justo después de la última.
func boundaryTimes(_ i: Int, _ j: Int, words: [Word], duration: Double) -> (Double, Double) {
    let dur = duration > 0 ? duration : words[j].end + 1
    let prevEnd = i > 0 ? words[i - 1].end : 0
    let nextStart = j + 1 < words.count ? words[j + 1].start : dur
    let a = min(words[i].start - 0.03, max(prevEnd + 0.02, words[i].start - 0.15))
    let b = min(words[j].end + 0.45, max(words[j].end - 0.02, nextStart - 0.05))
    return (max(0, a), min(dur, b))
}

/// Segunda pasada: un editor exigente revisa cada candidato con su contexto, corrige inicio y final palabra a palabra,
/// comprueba que título y texto solo cuentan lo que pasa, y descarta lo que no se sostenga.
func reviewMoments(info: VideoInfo, words: [Word], candidates: [Moment], count: Int, minD: Int, maxD: Int,
                   notes: [String]? = nil, before: Double = 45, after: Double = 30, plan: ClipPlan = ClipPlan(),
                   log: ((String) -> Void)? = nil) async throws -> [Moment] {
    let speech = words.filter { !$0.isTag }
    guard !speech.isEmpty else { return [] }
    func idx(startAt t: Double) -> Int { speech.firstIndex { $0.start >= t - 0.05 } ?? 0 }
    func idx(endAt t: Double) -> Int { speech.lastIndex { $0.end <= t + 0.05 } ?? speech.count - 1 }
    var blocks: [String] = []
    var windows: [ClosedRange<Int>] = []
    for (k, c) in candidates.enumerated() {
        let i = idx(startAt: c.start), j = max(i, idx(endAt: c.end))
        let lo = idx(startAt: speech[i].start - before), hi = idx(endAt: speech[j].end + after)
        windows.append(lo...max(lo, hi))
        var lines: [String] = [], cur: [String] = [], lineStart = speech[lo].start
        for n in lo...max(lo, hi) {
            if cur.isEmpty { lineStart = speech[n].start }
            cur.append("\(n):\(speech[n].text)")
            if cur.count >= 12 { lines.append(String(format: "[%@] ", fmt(lineStart)) + cur.joined(separator: " ")); cur = [] }
        }
        if !cur.isEmpty { lines.append(String(format: "[%@] ", fmt(lineStart)) + cur.joined(separator: " ")) }
        blocks.append("""
        ### Candidato \(k)
        Propuesta: palabras \(i)–\(j) (\(String(format: "%.0f", speech[j].end - speech[i].start)) s). Título propuesto: \(c.title)\(c.part.map { p in String(format: "\nDebe quedarse dentro de la Parte %d (%.0f–%.0f s · %@).", p, plan.parts[p].start, plan.parts[p].end, plan.parts[p].title) } ?? "")\(notes.map { "\nPROBLEMA DETECTADO, corrígelo moviendo inicio y/o final (o descarta si no tiene arreglo): \($0[k])" } ?? "")
        Texto con contexto (índice:palabra; puedes elegir cualquier índice de este tramo):
        \(lines.joined(separator: "\n"))
        """)
    }
    let prompt = """
    Eres el editor más exigente de un equipo de clips cortos (TikTok, Reels, Shorts). Revisa uno a uno estos candidatos del vídeo "\(info.title)". Para cada uno, razona en "check" (2–4 frases, en español) y decide.

    Comprueba, con el texto exacto:
    1. INICIO: la primera palabra empieza una idea que se entiende sin nada de lo anterior (no hace falta explicar el programa, el juego ni quiénes son). Si depende de algo dicho antes ("eso", "él", "entonces", una pregunta que se responde…), mueve "start_word" atrás hasta donde empieza esa idea. Si para entenderlo haría falta demasiado, descártalo.
    2. FINAL: la última palabra cierra la idea, el remate o la reacción. Si se corta, mueve "end_word" hasta el cierre. Nunca termines a mitad de frase.
    3. UNA SOLA SITUACIÓN: el clip cuenta una única situación de principio a fin (un premio, una anécdota, una discusión, una idea). Si dentro del tramo empieza otra situación distinta (otro premio, otra ronda, otro tema), corta "end_word" justo antes de que empiece. Nunca pegues dos situaciones para alcanzar la duración.
    4. DURACIÓN: idealmente entre \(minD) y \(maxD) segundos (mira las marcas de tiempo). Si la situación completa dura menos, se acepta hasta \(Int(Double(minD) * 0.7)) s; si hace falta, añade el planteamiento de antes, nunca otra situación de después.
    5. COHERENCIA: "title" y "caption" solo pueden contar lo que de verdad se dice o pasa en ese tramo. Compruébalo frase a frase: si el título dice algo que no ocurre (por ejemplo "les roban" cuando lo que pasa es que lo ganan), corrígelo. Nada inventado ni exagerado. En el idioma del vídeo. "reason": qué pasa y por qué engancha, en una frase en español.
    6. COMPLETO: tiene planteamiento y desenlace. Si es una anécdota o historia, el clip incluye cómo empieza y su remate. Si el remate o la respuesta llegan después del final, alarga; si la historia entera no cabe en \(Int(Double(maxD) * 1.3)) s, descártala.
    7. CALIDAD: descarta (keep=false) si es relleno, presentación, despedida, publicidad, o si no engancharía a alguien que no conoce el vídeo.
    8. "score" 0–100, honesto.
    \(plan.prompt.isEmpty ? "" : "9. PETICIÓN: el clip cumple lo que pide la persona; si no, corrígelo o descártalo.\n" + plan.prompt)
    Devuelve un elemento por candidato, con "start_word" y "end_word" como índices del texto mostrado.

    \(blocks.joined(separator: "\n\n"))
    """
    let item: [String: Any] = ["type": "OBJECT", "properties": [
        "candidate": ["type": "INTEGER"], "check": ["type": "STRING"], "keep": ["type": "BOOLEAN"],
        "start_word": ["type": "INTEGER"], "end_word": ["type": "INTEGER"], "title": ["type": "STRING"],
        "caption": ["type": "STRING"], "reason": ["type": "STRING"], "score": ["type": "INTEGER"]],
        "required": ["candidate", "check", "keep", "start_word", "end_word", "title", "caption", "reason", "score"]]
    let r = try await gemini(parts: [["text": prompt]],
                             schema: ["type": "OBJECT", "properties": ["clips": ["type": "ARRAY", "items": item]], "required": ["clips"]])
    var out: [Moment] = []
    for c in (r["clips"] as? [[String: Any]] ?? []) {
        guard let k = num(c["candidate"]).map(Int.init), candidates.indices.contains(k) else { continue }
        let check = c["check"] as? String ?? ""
        guard (c["keep"] as? Bool) == true else { log?("  descartado \(k): \(check)"); continue }
        guard var i = num(c["start_word"]).map(Int.init), let j = num(c["end_word"]).map(Int.init),
              windows[k].contains(i), windows[k].contains(j), j > i else { log?("  descartado \(k): índices fuera de rango"); continue }
        // No empezar con el final de la frase anterior ("Sí.", "Vale,", "Bueno,"…).
        let tails: Set<String> = ["sí", "si", "no", "vale", "bueno", "ya", "eh", "ok", "venga", "claro", "yes", "yeah", "ok", "okay", "right", "so"]
        for _ in 0..<2 where i + 1 < j {
            let w = speech[i].text, bare = w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if tails.contains(bare) && (w.last.map { ".,!?…".contains($0) } ?? false) { i += 1 } else { break }
        }
        guard let (si, sj) = sentenceBounds(i, j, words: speech, maxSpan: Double(maxD) * 1.3) else {
            log?("  descartado \(k): no se puede cerrar en frases completas sin pasarse de duración"); continue
        }
        let (s, e) = boundaryTimes(si, sj, words: speech, duration: info.duration)
        guard e - s >= Double(minD) * 0.7, e - s <= Double(maxD) * 1.3 else {
            log?(String(format: "  descartado %d: dura %.0f s", k, e - s)); continue
        }
        let title = (c["title"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"“” "))
        let m = Moment(start: s, end: e, title: title.isEmpty ? candidates[k].title : title,
                       reason: c["reason"] as? String ?? candidates[k].reason,
                       caption: c["caption"] as? String ?? candidates[k].caption,
                       score: max(0, min(100, Int(num(c["score"]) ?? 50))), check: check, part: candidates[k].part)
        if let p = m.part, plan.inside(m, p) < 0.8 {
            log?("  descartado \(k): al ajustarlo se sale de la parte \(p)"); continue
        }
        out.append(m)
        log?("  aprobado \(k) (\(Int(num(c["score"]) ?? 0))): \(check)")
    }
    // Sin solapes; se quedan los de más puntuación.
    var final: [Moment] = []
    // Se devuelven todos los aprobados (no solo `count`): si la verificación tumba alguno, quedan reservas.
    for m in out.sorted(by: { $0.score > $1.score }) where !final.contains(where: { m.start < $0.end && m.end > $0.start }) {
        final.append(m)
    }
    return final
}

/// Ajusta inicio y final a frases completas (con puntuación) o a pausas de la voz (sin ella).
/// Devuelve nil si para que queden frases completas el clip se pasaría de `maxSpan` segundos.
func sentenceBounds(_ i0: Int, _ j0: Int, words: [Word], maxSpan: Double) -> (Int, Int)? {
    let punctuated = words.filter { $0.text.last.map { ".?!,".contains($0) } ?? false }.count * 25 > words.count
    func ends(_ k: Int) -> Bool {
        if k + 1 >= words.count { return true }
        if punctuated { return words[k].text.last.map { ".?!…\"”»".contains($0) } ?? false }
        return words[k + 1].start - words[k].end >= 0.45
    }
    func starts(_ k: Int) -> Bool {
        k == 0 || ends(k - 1) || (punctuated && (words[k].text.first.map { "¿¡\"“«".contains($0) } ?? false))
    }
    var i = i0, j = j0
    if !starts(i) {
        // Atrás hasta el principio de la frase (máx. 15 s); si no aparece, no se puede asegurar.
        guard let k = stride(from: i - 1, through: 0, by: -1).prefix(while: { words[i].start - words[$0].start <= 15 }).first(where: starts) else { return nil }
        i = k
    }
    if !ends(j) {
        guard let k = (j + 1..<words.count).prefix(while: { words[$0].end - words[j].end <= 12 }).first(where: ends) else { return nil }
        j = k
    }
    return words[j].end - words[i].start <= maxSpan ? (i, j) : nil
}

/// Tercera pasada: verificación final de los clips ya decididos, con su texto exacto.
/// Confirma que es una sola situación y que título y texto son ciertos; corrige el título o descarta.
func verifyMoments(_ moments: [Moment], words: [Word], minD: Int, plan: ClipPlan = ClipPlan(), log: ((String) -> Void)? = nil) async throws
    -> (ok: [Moment], failed: [(Moment, String)]) {
    guard !moments.isEmpty else { return ([], []) }
    let speech = words.filter { !$0.isTag }
    let blocks = moments.enumerated().map { k, m -> String in
        let text = speech.filter { $0.start >= m.start - 0.05 && $0.end <= m.end + 0.05 }.map(\.text).joined(separator: " ")
        let before = speech.filter { $0.start >= m.start - 20 && $0.end < m.start }.map(\.text).joined(separator: " ")
        let after = speech.filter { $0.start > m.end && $0.start <= m.end + 20 }.map(\.text).joined(separator: " ")
        return """
        ### Clip \(k) (\(Int(m.end - m.start)) s)\(m.part.map { " · de la Parte \($0): \(plan.parts[$0].title)" } ?? "")
        Título: \(m.title)
        Texto para redes: \(m.caption)
        (Justo antes, NO entra en el clip): …\(before)
        LO QUE ENTRA EN EL CLIP: \(text)
        (Justo después, NO entra en el clip): \(after)…
        """
    }
    let prompt = """
    Verificación final antes de publicar. Para cada clip, con el texto exacto de lo que se dice:
    - "single": ¿cuenta UNA sola situación (aunque haya varias reacciones a ella), sin pegar al final otra escena distinta? (true/false)
    - "starts_clean": ¿la primera frase empieza entera y se entiende sin lo de "justo antes"? Es false SOLO si empieza a mitad de frase o si depende de algo dicho justo antes para entenderse ("y por eso…", "el tío dijo…" sin saber qué tío, la respuesta a una pregunta que quedó fuera). NO exijas que se explique el programa, el juego, el formato ni quiénes son: en redes eso se entiende solo.
    - "ends_complete": ¿incluye el desenlace o remate? Es false SOLO si la respuesta, la gracia o el final de lo que se cuenta está en "justo después".
    - "title_ok": ¿el título describe con verdad lo que pasa? Si no, escribe en "title" uno correcto, corto y con gancho, en el idioma del vídeo; si está bien, repítelo.
    - "caption": el texto para redes, corregido si dice algo que no pasa (1–2 frases y 3–5 hashtags, idioma del vídeo).
    - "request_ok": \(plan.prompt.isEmpty ? "true (no hay instrucciones de la persona)." : "¿cumple lo que pide la persona y, si es de una parte, trata de esa parte? (true/false)\n" + plan.prompt)
    - "problem": en español, qué falla (vacío si nada).
    Sé exigente con lo que de verdad confundiría a alguien que lo ve sin contexto, pero no con lo que es normal en un clip corto.

    \(blocks.joined(separator: "\n\n"))
    """
    let item: [String: Any] = ["type": "OBJECT", "properties": [
        "clip": ["type": "INTEGER"], "single": ["type": "BOOLEAN"], "starts_clean": ["type": "BOOLEAN"],
        "ends_complete": ["type": "BOOLEAN"], "title_ok": ["type": "BOOLEAN"],
        "title": ["type": "STRING"], "caption": ["type": "STRING"], "problem": ["type": "STRING"], "request_ok": ["type": "BOOLEAN"]],
        "required": ["clip", "single", "starts_clean", "ends_complete", "title_ok", "title", "caption", "problem", "request_ok"]]
    let r = try await gemini(parts: [["text": prompt]],
                             schema: ["type": "OBJECT", "properties": ["clips": ["type": "ARRAY", "items": item]], "required": ["clips"]])
    var out: [Moment] = [], failed: [(Moment, String)] = [], seen = Set<Int>()
    for c in (r["clips"] as? [[String: Any]] ?? []) {
        guard let k = num(c["clip"]).map(Int.init), moments.indices.contains(k), !seen.contains(k) else { continue }
        seen.insert(k)
        var m = moments[k]
        let problem = c["problem"] as? String ?? ""
        guard (c["single"] as? Bool) == true, (c["starts_clean"] as? Bool) == true, (c["ends_complete"] as? Bool) == true,
              plan.prompt.isEmpty || (c["request_ok"] as? Bool) == true else {
            log?("  verificación: falla «\(m.title)»: \(problem)")
            failed.append((m, problem.isEmpty ? "Empieza o acaba a medias." : problem)); continue
        }
        if (c["title_ok"] as? Bool) != true, let t = (c["title"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ")), !t.isEmpty {
            log?("  verificación: título «\(m.title)» → «\(t)»")
            m.title = t
        }
        if let cap = c["caption"] as? String, !cap.isEmpty { m.caption = cap }
        out.append(m)
    }
    return (out.sorted { $0.score > $1.score }, failed)
}

private let weakWords: Set<String> = ["a", "al", "de", "del", "que", "para", "por", "la", "el", "los", "las", "lo", "un", "una", "unos", "unas",
    "y", "e", "o", "u", "ni", "con", "sin", "en", "mi", "tu", "su", "mis", "tus", "sus", "se", "me", "te", "nos", "le", "les",
    "pero", "porque", "como", "si", "cuando", "muy", "más", "the", "an", "of", "to", "and", "or", "in", "on", "for", "with",
    "my", "your", "his", "her", "our", "their", "but", "if", "so"]

/// Agrupa palabras en líneas de subtítulo, siempre con el mismo criterio:
/// corta en finales de frase, comas y pausas; nunca deja una línea acabada en "a", "de", "que"…;
/// no separa un número de lo que sigue ni dos palabras con mayúscula seguidas ("Apple Watch").
func groupLines(_ ws: [Word], maxWords: Int, maxChars: Int) -> [[Word]] {
    func bare(_ w: Word) -> String { w.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
    func capital(_ w: Word) -> Bool { w.text.trimmingCharacters(in: CharacterSet(charactersIn: "¿¡\"“«")).first?.isUppercase ?? false }
    var lines: [[Word]] = [], cur: [Word] = []
    for (k, w) in ws.enumerated() {
        cur.append(w)
        let next = k + 1 < ws.count ? ws[k + 1] : nil
        let len = cur.map(\.text.count).reduce(0, +) + cur.count - 1
        let sentenceEnd = w.text.last.map { ".?!…".contains($0) } ?? false
        let comma = w.text.last.map { ",;:".contains($0) } ?? false
        let gap = next.map { $0.start - w.end } ?? 1
        guard let n = next else { break }
        var cut = sentenceEnd || gap > 0.45 || cur.count >= maxWords || (comma && cur.count >= 2) || len + 1 + n.text.count > maxChars
        if cut && !sentenceEnd && !comma && gap <= 0.45 {
            // Mejor alargar un poco la línea que dejarla colgando o partir un nombre o una cifra.
            let joined = weakWords.contains(bare(w)) || (n.text.first?.isNumber ?? false)
                || (cur.count > 1 && capital(w) && capital(n))
            if joined && cur.count <= maxWords && len + 1 + n.text.count <= maxChars + 6 { cut = false }
        }
        if cut { lines.append(cur); cur = [] }
    }
    if !cur.isEmpty { lines.append(cur) }
    // Si aun así alguna línea acaba en palabra débil, esa palabra pasa a la siguiente.
    var k = 0
    while k + 1 < lines.count {
        if lines[k].count > 1, let last = lines[k].last, weakWords.contains(bare(last)),
           !(last.text.last.map { ",.?!".contains($0) } ?? false) {
            lines[k + 1].insert(lines[k].removeLast(), at: 0); continue
        }
        k += 1
    }
    return lines.filter { !$0.isEmpty }
}

/// Subtítulos coherentes: Gemini corrige el texto palabra a palabra (lo mal oído, mayúsculas, tildes, signos, muletillas)
/// y el código agrupa las líneas. Cada palabra conserva su tiempo. Devuelve nil si la respuesta no encaja.
func subtitleScript(words: [Word], vertical: Bool, title: String) async -> [[Word]]? {
    let ws = words.filter { !$0.isTag }
    guard ws.count >= 3 else { return nil }
    let (maxW, maxC) = vertical ? (3, 18) : (5, 32)
    let prompt = """
    Estos son los subtítulos automáticos de un clip ("\(title)"), palabra a palabra con su índice. Corrígelos para mostrarlos en pantalla.
    Reglas:
    - Escribe exactamente lo que se dice, en el mismo idioma. No cambies palabras por sinónimos ni por la versión "oficial" (si dicen "Play", es "Play", no "PS5"). No inventes ni cambies el sentido.
    - Corrige: palabras mal transcritas (por el contexto: nombres, marcas, números), mayúsculas (inicio de frase y nombres propios) y tildes.
    - Si una palabra no existe o no tiene sentido ahí, es un error del reconocimiento de voz: escribe lo que se dice de verdad, aunque sean dos palabras en el mismo "text" ("Robjet" → "Roba objeto"). Si no estás seguro, déjala como está.
    - Puntuación: punto al final de cada frase, coma donde haya pausa natural, signos de pregunta solo en preguntas de verdad (en español con ¿ al principio de la pregunta) y de exclamación solo en exclamaciones claras (con ¡).
    - Números con cifras cuando sean cantidades o nombres ("cinco" → "5", "Play 5").
    - Quita las muletillas sin significado (eh, em, mmm…) omitiendo su índice.
    - Devuelve TODAS las demás palabras, una por elemento, en el mismo orden: {i, text}.

    \(ws.enumerated().map { "\($0.offset):\($0.element.text)" }.joined(separator: " "))
    """
    let schema: [String: Any] = ["type": "OBJECT", "properties": ["words": ["type": "ARRAY", "items": [
        "type": "OBJECT", "properties": ["i": ["type": "INTEGER"], "text": ["type": "STRING"]], "required": ["i", "text"]]]],
        "required": ["words"]]
    // Dos intentos: con Gemini saturado a veces llega tarde o incompleto.
    for _ in 0..<2 {
        guard let r = try? await gemini(parts: [["text": prompt]], schema: schema, timeout: 240),
              let items = r["words"] as? [[String: Any]] else { continue }
        var out: [Word] = [], last = -1
        for w in items {
            // Una palabra mal indicada se descarta sola; no se tira todo el guion.
            guard let i = num(w["i"]).map(Int.init), i > last, i < ws.count,
                  var t = (w["text"] as? String)?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { continue }
            if let q = t.firstIndex(where: { "¿¡".contains($0) }), q != t.startIndex { t = String(t[q...]) }
            out.append(Word(start: ws[i].start, end: ws[i].end, text: t)); last = i
        }
        // Si se ha dejado demasiadas palabras, no es fiable.
        if Double(out.count) >= Double(ws.count) * 0.75 { return groupLines(out, maxWords: maxW, maxChars: maxC) }
    }
    return nil
}

private func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
}

private func norm(_ s: String) -> String {
    s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
}

/// Busca en la transcripción las palabras exactas con las que empieza y acaba el clip
/// (los subtítulos automáticos no traen puntos, así que el texto es la referencia más fiable).
func anchor(_ s: Double, _ e: Double, first: String, last: String, words: [Word], duration: Double) -> (Double, Double) {
    let toks = words.map { norm($0.text) }
    func find(_ phrase: String, near t: Double, atEnd: Bool, after: Int = -1) -> Int? {
        let q = phrase.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
        guard q.count >= 2 else { return nil }
        var best: (Int, Double)? = nil
        for i in toks.indices where i > after {
            let startIdx = atEnd ? i - q.count + 1 : i
            guard startIdx >= 0, startIdx + q.count <= toks.count else { continue }
            let hits = (0..<q.count).filter { toks[startIdx + $0] == q[$0] }.count
            guard hits >= min(3, q.count) else { continue }
            let at = atEnd ? words[i].end : words[i].start
            guard abs(at - t) <= 25 else { continue }
            let score = Double(hits) * 10 - abs(at - t)
            if best == nil || score > best!.1 { best = (i, score) }
        }
        return best?.0
    }
    guard var i = find(first, near: s, atEnd: false), var j = find(last, near: e, atEnd: true, after: i), j > i else {
        return snap(s, e, words: words, duration: duration)
    }
    // Si el texto trae puntuación, terminar de cuadrar con la frase: empezar donde empieza
    // y acabar donde acaba (como mucho unas palabras más allá).
    let punctuated = words.filter { $0.text.last.map { ".?!,".contains($0) } ?? false }.count * 25 > words.count
    if punctuated {
        let opens = CharacterSet(charactersIn: "\"“«¿¡(")
        func endsSentence(_ k: Int) -> Bool { words[k].text.last.map { ".?!…\"”»".contains($0) } ?? false }
        func startsSentence(_ k: Int) -> Bool {
            k == 0 || endsSentence(k - 1) || (words[k].text.unicodeScalars.first.map(opens.contains) ?? false)
        }
        if !startsSentence(i), let k = stride(from: i - 1, through: max(0, i - 3), by: -1).first(where: startsSentence) { i = k }
        if !endsSentence(j), let k = (j + 1..<min(words.count, j + 5)).first(where: endsSentence) { j = k }
    }
    let dur = duration > 0 ? duration : words[j].end + 1
    let prevEnd = i > 0 ? words[i - 1].end : 0
    let nextStart = j + 1 < words.count ? words[j + 1].start : dur
    // Empezar justo antes de la primera palabra, nunca dentro de ella.
    let a = min(words[i].start - 0.03, max(prevEnd + 0.02, words[i].start - 0.15))
    // Cortar antes de que empiece la palabra siguiente; si hay pausa, dejar un poco de aire.
    let b = min(words[j].end + 0.45, max(words[j].end - 0.02, nextStart - 0.05))
    return (max(0, a), min(dur, b))
}

/// Plan B si no aparecen las palabras: ajusta a la palabra más cercana, prefiriendo pausas naturales.
func snap(_ s: Double, _ e: Double, words: [Word], duration: Double) -> (Double, Double) {
    let dur = duration > 0 ? duration : e + 1
    guard !words.isEmpty else { return (max(0, s), min(dur, e)) }
    var bestS: (Int, Double)? = nil
    for (i, w) in words.enumerated() where abs(w.start - s) <= 2.5 {
        let gap = i == 0 ? 3 : w.start - words[i - 1].end
        let score = min(gap, 1.0) - abs(w.start - s) * 0.8
        if bestS == nil || score > bestS!.1 { bestS = (i, score) }
    }
    var bestE: (Int, Double)? = nil
    for (i, w) in words.enumerated() where abs(w.end - e) <= 2.5 && w.end > (bestS.map { words[$0.0].start } ?? s) {
        let gap = i == words.count - 1 ? 3 : words[i + 1].start - w.end
        let score = min(gap, 1.0) - abs(w.end - e) * 0.8
        if bestE == nil || score > bestE!.1 { bestE = (i, score) }
    }
    var a = s, b = e
    if let (i, _) = bestS {
        let prevEnd = i > 0 ? words[i - 1].end : 0
        a = min(words[i].start - 0.03, max(prevEnd + 0.02, words[i].start - 0.15))
    }
    if let (i, _) = bestE {
        let nextStart = i + 1 < words.count ? words[i + 1].start : dur
        b = min(words[i].end + 0.4, max(words[i].end - 0.02, nextStart - 0.05))
    }
    return (max(0, a), min(dur, b))
}

func safeName(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
    var r = s.components(separatedBy: bad).joined(separator: " ")
        .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    while r.hasPrefix(".") { r.removeFirst() }
    return String((r.isEmpty ? "Clip" : r).prefix(60)).trimmingCharacters(in: .whitespaces)
}
