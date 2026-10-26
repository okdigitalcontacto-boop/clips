// Clips · © 2026 OK Digital. Todos los derechos reservados.
import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Paleta

enum Palette {
    /// Coral de "luz de grabación": el color de lo elegido.
    static let cue = Color(red: 1.0, green: 0.36, blue: 0.22)
    /// Índigo frío: el resto del vídeo, lo que no se elige.
    static let indigo = Color(red: 0.43, green: 0.42, blue: 0.94)
    static let ok = Color(red: 0.2, green: 0.74, blue: 0.43)
    static let heat = LinearGradient(colors: [indigo, cue], startPoint: .leading, endPoint: .trailing)
}

extension Animation {
    /// Muelle por defecto, sin rebote.
    static let ui = Animation.spring(response: 0.32, dampingFraction: 1)
}

// MARK: - Fondo translúcido de ventana

struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground; v.blendingMode = .behindWindow; v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Raíz

struct SelectedClip: Identifiable { let id: UUID }

struct RootView: View {
    @StateObject private var m: Model
    init(model: Model? = nil) { _m = StateObject(wrappedValue: model ?? Model.testModel ?? Model()) }
    @State private var dropping = false
    @State private var selected: SelectedClip?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            if !m.snapshot { WindowMaterial().ignoresSafeArea() }
            if m.snapshot { content } else { ScrollView { content }.scrollIndicators(.automatic) }
        }
        .frame(minWidth: 780, minHeight: 680)
        .onDrop(of: [.url, .plainText], isTargeted: $dropping) { providers in
            guard !m.running, let p = providers.first else { return false }
            // Desde el navegador llega como URL; desde un texto, como cadena.
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    guard let u else { return }
                    Task { @MainActor in m.receive(u.absoluteString) }
                }
            } else {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    guard let s = s as? String else { return }
                    Task { @MainActor in m.receive(s) }
                }
            }
            return true
        }
        .animation(.ui, value: dropping)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !m.running { m.pasteIfYouTube() }
        }
        .sheet(item: $selected) { s in ClipDetail(m: m, id: s.id) }
        .onAppear { fieldFocused = m.url.isEmpty }
    }

    var content: some View {
                VStack(alignment: .leading, spacing: 20) {
                    Header()
                    InputBar(m: m, dropping: dropping, focused: $fieldFocused)
                    OptionsBar(m: m)
                    if let n = m.notice, m.error == nil {
                        NoticeLine(text: n).transition(.opacity)
                    }
                    if let e = m.error {
                        ErrorBanner(m: m, error: e).transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if m.running || m.info != nil {
                        JobPanel(m: m, open: open).transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !m.clips.isEmpty {
                        ClipsGrid(m: m, open: open)
                    } else if !m.running && m.info == nil && m.error == nil {
                        EmptyHint().transition(.opacity)
                    }
                }
                .padding(.horizontal, 32).padding(.top, 38).padding(.bottom, 36)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
    }

    func open(_ id: UUID) { Sound.shared.play(.tick); selected = SelectedClip(id: id) }
}

struct Header: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Clips")
                .font(.system(size: 34, weight: .bold))
                .tracking(-1.1)
            Text("Los mejores momentos de un vídeo, listos para subir")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Ajustes (⌘,)")
        }
    }
}

// MARK: - Barra del enlace

struct InputBar: View {
    @ObservedObject var m: Model
    let dropping: Bool
    var focused: FocusState<Bool>.Binding
    var invalid: Bool { !m.url.trimmingCharacters(in: .whitespaces).isEmpty && extractYouTubeLink(m.url) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: dropping ? "arrow.down.circle.fill" : "link")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(dropping ? Palette.cue : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20)
                if m.snapshot {
                    Text(m.url).font(.system(size: 17)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Pega aquí un enlace de YouTube", text: $m.url)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused(focused)
                        .disabled(m.running)
                        .onSubmit { m.start() }
                }
                if !m.url.isEmpty && !m.running {
                    Button { m.url = ""; Sound.shared.play(.tick) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).help("Borrar").transition(.scale.combined(with: .opacity))
                } else if !m.running {
                    Button("Pegar") {
                        if let s = NSPasteboard.general.string(forType: .string) { m.receive(s) }
                    }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                if m.running {
                    Button { m.cancel() } label: { Label("Cancelar", systemImage: "stop.fill") }
                        .buttonStyle(PrimaryButton(color: Color(white: 0.42)))
                        .keyboardShortcut(.cancelAction)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    Button { m.start() } label: { Label("Sacar clips", systemImage: "scissors") }
                        .buttonStyle(PrimaryButton(color: Palette.cue))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(m.url.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Sacar clips (⌘↩)")
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(.background.opacity(0.78)))
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(dropping ? Palette.cue : invalid ? Palette.cue.opacity(0.5) : Color.primary.opacity(0.09),
                                  style: StrokeStyle(lineWidth: dropping ? 2 : 1, dash: dropping ? [7, 5] : []))
            )
            .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
            .scaleEffect(dropping ? 1.01 : 1)
            .animation(.ui, value: m.running)
            .animation(.ui, value: m.url.isEmpty)

            if invalid && !m.running {
                Text("Eso no parece un enlace de YouTube.")
                    .font(.system(size: 12)).foregroundStyle(Palette.cue)
                    .padding(.leading, 18).transition(.opacity)
            }
        }
        .animation(.ui, value: invalid)
    }
}

struct PrimaryButton: ButtonStyle {
    var color: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 42)
            .background(Capsule().fill(color.opacity(enabled ? 1 : 0.35)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .shadow(color: color.opacity(enabled ? 0.35 : 0), radius: configuration.isPressed ? 3 : 9, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 1), value: configuration.isPressed)
    }
}

// MARK: - Opciones

struct OptionsBar: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CountControl(value: $m.count)
                PillPicker(items: m.durations.indices.map { ($0, "\(m.durations[$0].0)–\(m.durations[$0].1) s", nil) }, selection: $m.durIdx)
                    .help("Duración de cada clip")
                PillPicker(items: [(false, "Horizontal", "rectangle"), (true, "Vertical", "rectangle.portrait")], selection: $m.vertical)
                    .help("Vertical recorta siguiendo la cara de quien habla")
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("Añadir").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                ToggleChip(symbol: "captions.bubble", onSymbol: "captions.bubble.fill", label: "Subtítulos", isOn: $m.subtitles)
                    .help("Subtítulos palabra a palabra, grabados en el vídeo")
                ToggleChip(symbol: "text.bubble", onSymbol: "text.bubble.fill", label: "Título al inicio", isOn: $m.hook)
                    .help("El título del clip arriba durante los primeros 3 segundos, como gancho")
                ToggleChip(symbol: "music.note", onSymbol: "music.note", label: "Música", isOn: $m.music)
                    .help("Música suave de fondo que baja sola cuando se habla")
                if m.music {
                    PillPicker(items: MusicMood.allCases.map { ($0, $0.rawValue, nil) }, selection: $m.mood)
                        .help(ownMusicFiles().isEmpty ? "Estilo de la música que compone Clips" : "Usando tu carpeta de música (Ajustes)")
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .animation(.ui, value: m.music)
            HStack(spacing: 10) {
                Text("Buscar").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                PillPicker(items: Focus.allCases.map { ($0, $0.rawValue, nil) }, selection: $m.focus)
                Spacer(minLength: 0)
            }
            NotesField(m: m)
        }
        .disabled(m.running)
        .opacity(m.running ? 0.45 : 1)
        .animation(.ui, value: m.running)
    }
}

/// Anotaciones libres: mandan sobre el número de clips, el orden y de qué partes salen.
struct NotesField: View {
    @ObservedObject var m: Model
    @FocusState private var focused: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Notas").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if m.snapshot {
                    Text(m.notes.isEmpty ? "Opcional: «10 en orden cronológico», «está en 5 partes, uno de cada»…" : m.notes)
                        .foregroundStyle(m.notes.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Opcional: «10 en orden cronológico», «está en 5 partes, uno de cada»…", text: $m.notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { m.start() }
                }
                if !m.notes.isEmpty && !m.running {
                    Button { withAnimation(.ui) { m.notes = "" }; Sound.shared.play(.tick) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).help("Borrar notas").transition(.scale.combined(with: .opacity))
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Palette.cue.opacity(0.45) : .clear))
            .animation(.ui, value: focused)
            .animation(.ui, value: m.notes.isEmpty)
        }
        .help("Lo que escribas aquí manda sobre el número de clips y el orden")
    }
}

struct CountControl: View {
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 0) {
            step("minus", -1, disabled: value <= 1)
            HStack(spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                Text(value == 1 ? "clip" : "clips").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 52)
            step("plus", 1, disabled: value >= 10)
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
    func step(_ s: String, _ d: Int, disabled: Bool) -> some View {
        Button {
            withAnimation(.ui) { value += d }
            Sound.shared.play(.tick); haptic()
        } label: {
            Image(systemName: s).font(.system(size: 10.5, weight: .bold))
                .frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .foregroundStyle(disabled ? .tertiary : .secondary)
        .disabled(disabled)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Selector en cápsula: la pastilla blanca se desliza hasta la opción elegida.
struct PillPicker<T: Hashable>: View {
    let items: [(T, String, String?)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let (value, label, symbol) = items[i]
                let on = value == selection
                Button {
                    guard !on else { return }
                    withAnimation(.ui) { selection = value }
                    Sound.shared.play(.tick); haptic()
                } label: {
                    HStack(spacing: 5) {
                        if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                        Text(label)
                    }
                    .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11).frame(height: 26)
                    .background {
                        if on {
                            Capsule().fill(.background)
                                .shadow(color: .black.opacity(0.13), radius: 2.5, y: 1)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct ToggleChip: View {
    let symbol: String
    var onSymbol: String? = nil
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Button {
            withAnimation(.ui) { isOn.toggle() }
            Sound.shared.play(.tick); haptic()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? (onSymbol ?? symbol) : symbol)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isOn ? Palette.cue : .secondary)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(isOn ? Palette.cue.opacity(0.13) : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(isOn ? Palette.cue.opacity(0.35) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }
}

// MARK: - Avisos

struct NoticeLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 12.5)).foregroundStyle(.secondary)
    }
}

struct ErrorBanner: View {
    @ObservedObject var m: Model
    let error: ClipsError
    @State private var shake = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16)).foregroundStyle(Palette.cue)
            Text(error.message)
                .font(.system(size: 13.5)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if error.canUpdateTools {
                if m.updatingTools {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Actualizando…").font(.system(size: 12.5)).foregroundStyle(.secondary) }
                } else {
                    Button("Actualizar yt-dlp") { m.updateTools() }.controlSize(.regular)
                }
            }
            if error.opensSettings {
                SettingsLink { Text("Abrir Ajustes") }.controlSize(.regular)
            } else {
                Button("Reintentar") { m.error = nil; m.start() }.controlSize(.regular)
                    .disabled(m.url.isEmpty || m.updatingTools)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.cue.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cue.opacity(0.28)))
        .keyframeAnimator(initialValue: 0.0, trigger: shake) { v, x in v.offset(x: x) } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-7, duration: 0.06); LinearKeyframe(6, duration: 0.07)
                LinearKeyframe(-4, duration: 0.07); LinearKeyframe(2, duration: 0.07); LinearKeyframe(0, duration: 0.07)
            }
        }
        .onAppear { shake += 1 }
        .onChange(of: error.message) { shake += 1 }
    }
}

struct EmptyHint: View {
    @AppStorage("outputDir") private var outputDir = ""
    var body: some View {
        VStack(spacing: 18) {
            FilmStrip().frame(width: 260, height: 54).opacity(0.55)
            VStack(spacing: 6) {
                Text("Pega un enlace y elige cuántos clips quieres.")
                    .font(.system(size: 15, weight: .medium))
                Text("Clips lee lo que se dice, encuentra los momentos con más gancho y te los da montados.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 22) {
                hint("arrow.down.doc", "Arrastra un enlace a la ventana")
                hint("command", "⌘↩ para empezar")
                hint("folder", outputDir.isEmpty ? "Se guardan en Películas › Clips" : "Se guardan en \((outputDir as NSString).lastPathComponent)")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
    func hint(_ s: String, _ t: String) -> some View {
        Label(t, systemImage: s).font(.system(size: 12)).foregroundStyle(.tertiary)
    }
}

/// Tira de película con un tramo marcado: lo que hace la app, en un dibujo.
struct FilmStrip: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let frame = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.fill(Path(roundedRect: frame, cornerRadius: 8), with: .color(.primary.opacity(0.12)))
            let holes = 18
            for i in 0..<holes {
                let x = (CGFloat(i) + 0.5) * w / CGFloat(holes) - 3
                for y in [5.0, h - 10] {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: 6, height: 5), cornerRadius: 1.5), with: .color(.primary.opacity(0.22)))
                }
            }
            let cut = CGRect(x: w * 0.56, y: 0, width: w * 0.2, height: h)
            ctx.fill(Path(roundedRect: cut, cornerRadius: 6), with: .color(Palette.cue.opacity(0.85)))
        }
    }
}

// MARK: - Panel del trabajo: vídeo, línea de tiempo y pasos

struct JobPanel: View {
    @ObservedObject var m: Model
    let open: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AsyncImage(url: m.info?.thumbnail) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Rectangle().fill(Color.primary.opacity(0.08)).shimmer(active: m.info == nil) }
                .frame(width: 118, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.info?.title ?? "Leyendo el vídeo…")
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    if let i = m.info {
                        Text([i.channel, fmt(i.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Timeline(m: m, open: open)
            StagesRow(m: m)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

/// La firma de la app: todo el vídeo como una curva (lo que más repite la gente)
/// con los clips elegidos encima, en el sitio exacto donde están.
struct Timeline: View {
    @ObservedObject var m: Model
    let open: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let total = max(m.info?.duration ?? 0, m.words.last?.end ?? 0, 1)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045))
                    if !m.curve.isEmpty {
                        CurveShape(values: m.curve, closed: true)
                            .fill(LinearGradient(colors: [Palette.indigo.opacity(0.32), Palette.cue.opacity(0.32)], startPoint: .leading, endPoint: .trailing))
                        CurveShape(values: m.curve, closed: false)
                            .stroke(Palette.heat, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                    if m.analyzing {
                        Sweep(reduceMotion: reduceMotion).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    ForEach(m.clips) { c in
                        let x = CGFloat(c.m.start / total) * w
                        let cw = max(5, CGFloat(c.duration / total) * w)
                        let hot = m.hovered == c.id
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Palette.cue.opacity(hot ? 1 : 0.82))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 1))
                            .overlay(alignment: .top) {
                                if cw > 15 {
                                    Text("\(c.rank)").font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white).padding(.top, 4)
                                }
                            }
                            .shadow(color: Palette.cue.opacity(hot ? 0.6 : 0.25), radius: hot ? 8 : 3)
                            .frame(width: cw, height: h - (hot ? 2 : 10))
                            .offset(x: x, y: hot ? 1 : 5)
                            .onHover { m.hovered = $0 ? c.id : nil }
                            .onTapGesture { if c.state == .ready { open(c.id) } }
                            .help(c.m.title)
                            .transition(.scale(scale: 0.3, anchor: .bottom).combined(with: .opacity))
                            .animation(.ui, value: hot)
                    }
                }
            }
            .frame(height: 66)
            HStack {
                Text(m.curve.isEmpty ? " " : m.curveIsHeat ? "Curva: lo que más repiten los espectadores" : "Curva: cuánto se habla en cada tramo")
                Spacer()
                if let d = m.info?.duration, d > 0 { Text(fmt(d)).monospacedDigit() }
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

struct CurveShape: Shape {
    var values: [Double]
    var closed: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let top = r.minY + 8, usable = r.height - 12
        let pts = values.enumerated().map { i, v in
            CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(values.count - 1), y: top + usable * (1 - CGFloat(max(0, min(1, v)))))
        }
        if closed { p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: pts[0]) } else { p.move(to: pts[0]) }
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        if closed { p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath() }
        return p
    }
}

/// Barrido de luz mientras la IA lee el vídeo.
struct Sweep: View {
    let reduceMotion: Bool
    var body: some View {
        if reduceMotion {
            Rectangle().fill(Palette.cue.opacity(0.06))
        } else {
            TimelineView(.animation) { ctx in
                GeometryReader { g in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 90)
                        .offset(x: CGFloat(eased) * (g.size.width + 90) - 90)
                        .blendMode(.plusLighter)
                }
            }
        }
    }
}

struct StagesRow: View {
    @ObservedObject var m: Model
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 0) {
                ForEach(Stage.allCases) { s in
                    StageDot(stage: s, state: m.state(of: s))
                    if s != Stage.allCases.last {
                        Capsule()
                            .fill(m.done.contains(s) ? Palette.ok.opacity(0.6) : Color.primary.opacity(0.1))
                            .frame(width: 22, height: 2).padding(.horizontal, 6)
                    }
                }
            }
            Text(m.detail)
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .id(m.detail)
                .transition(.opacity)
            Spacer()
            if !m.running, m.readyCount > 0, let d = m.outDir {
                Button { NSWorkspace.shared.open(d); Sound.shared.play(.tick) } label: { Label("Abrir carpeta", systemImage: "folder") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.ui, value: m.detail)
        .animation(.ui, value: m.running)
    }
}

struct StageDot: View {
    let stage: Stage
    let state: StageState
    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(bg).frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(fg)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: state == .active)
            }
            Text(stage.label)
                .font(.system(size: 12, weight: state == .active ? .semibold : .medium))
                .foregroundStyle(state == .pending ? .tertiary : .primary)
        }
        .animation(.ui, value: state)
    }
    var icon: String {
        switch state {
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        default: return stage.symbol
        }
    }
    var bg: Color {
        switch state {
        case .done: return Palette.ok.opacity(0.18)
        case .active, .failed: return Palette.cue.opacity(0.16)
        case .pending: return Color.primary.opacity(0.06)
        }
    }
    var fg: Color {
        switch state {
        case .done: return Palette.ok
        case .active, .failed: return Palette.cue
        case .pending: return .secondary
        }
    }
}

// MARK: - Clips

struct ClipsGrid: View {
    @ObservedObject var m: Model
    let open: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.finished ? "Tus clips" : "Clips elegidos")
                    .font(.system(size: 20, weight: .bold)).tracking(-0.4)
                Text(m.chronological ? "en el orden del vídeo" : "ordenados por potencial").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                if m.readyCount > 0 {
                    Button { m.copyAllCaptions() } label: { Label("Copiar todos los textos", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(m.clips) { c in
                    ClipCard(m: m, c: c, open: open)
                        .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity).combined(with: .offset(y: 12)),
                                                removal: .opacity))
                }
            }
        }
    }
}

struct ClipCard: View {
    @ObservedObject var m: Model
    let c: ClipItem
    let open: (UUID) -> Void
    @State private var hover = false
    @State private var copied = false

    var highlighted: Bool { m.hovered == c.id }
    let thumbH: CGFloat = 158

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumb
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    Text(c.m.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    ScoreRing(score: c.m.score)
                }
                Text("\(fmt(c.m.start, tenths: true)) → \(fmt(c.m.end, tenths: true))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(c.m.reason)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                actions.padding(.top, 2)
            }
            .padding(13)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.opacity(0.82)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(highlighted ? Palette.cue.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: highlighted ? 1.5 : 1))
        .shadow(color: .black.opacity(hover ? 0.15 : 0.06), radius: hover ? 18 : 8, y: hover ? 9 : 3)
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.ui, value: hover)
        .animation(.ui, value: highlighted)
        .onHover { h in hover = h; m.hovered = h ? c.id : (m.hovered == c.id ? nil : m.hovered) }
        .onTapGesture { if c.state == .ready { open(c.id) } }
        .onDrag {
            if let f = c.file, c.state == .ready { return NSItemProvider(contentsOf: f) ?? NSItemProvider() }
            return NSItemProvider()
        }
    }

    @ViewBuilder var thumb: some View {
        ZStack {
            if let img = c.thumb {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: thumbH).clipped()
                    .blur(radius: 22).opacity(0.7)
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: thumbH)
                    .transition(.opacity)
            } else {
                Rectangle().fill(Color.primary.opacity(0.07)).shimmer(active: c.state.isBusy)
            }
            stateOverlay
            if c.state == .ready {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .shadow(radius: 8)
                    .scaleEffect(hover ? 1 : 0.7).opacity(hover ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity).frame(height: thumbH)
        .clipped()
        .overlay(alignment: .topLeading) {
            Text("\(c.rank)")
                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.cue))
                .padding(9)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(Int(c.duration.rounded())) s")
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(9)
        }
    }

    @ViewBuilder var stateOverlay: some View {
        switch c.state {
        case .queued:
            label("En cola", "clock")
        case .downloading(let p):
            VStack(spacing: 8) {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 120).tint(Palette.cue)
                Text("Descargando \(Int(p * 100)) %").font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
        case .rendering:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(c.thumb == nil ? "Montando…" : "Volviendo a montar…").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(10).background(c.thumb == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 10))
        case .failed(let msg):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Palette.cue)
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 14)
            }
        case .ready:
            EmptyView()
        }
    }

    func label(_ t: String, _ s: String) -> some View {
        Label(t, systemImage: s).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
    }

    @ViewBuilder var actions: some View {
        HStack(spacing: 6) {
            switch c.state {
            case .ready:
                IconButton(symbol: "play.fill", help: "Ver el clip") { open(c.id) }
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copiar título y texto para redes", tint: copied ? Palette.ok : nil) {
                    m.copyCaption(c)
                    withAnimation(.ui) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.ui) { copied = false } }
                }
                IconButton(symbol: "folder", help: "Mostrar en Finder") {
                    if let f = c.file { NSWorkspace.shared.activateFileViewerSelecting([f]); Sound.shared.play(.tick) }
                }
                Spacer()
                PublishMenu(m: m, c: c)
            case .failed(let msg) where msg != "Cancelado" || !m.running:
                Button { m.retry(c.id) } label: { Label("Reintentar", systemImage: "arrow.clockwise") }
                    .controlSize(.small).disabled(m.running && msg != "Cancelado")
                Spacer()
            default:
                Spacer().frame(height: 26)
            }
        }
        .animation(.ui, value: hover)
    }
}

/// Botón «Subir»: abre la web de subida de la red elegida con el texto copiado y el archivo a mano.
struct PublishMenu: View {
    @ObservedObject var m: Model
    let c: ClipItem
    @State private var hover = false
    var body: some View {
        if m.snapshot { chrome(Label("Subir", systemImage: "square.and.arrow.up").font(.system(size: 11.5, weight: .semibold))) } else { menu }
    }
    var menu: some View {
        chrome(Menu {
            Section("El texto se copia y el clip aparece en Finder para arrastrarlo") {
                ForEach(Platform.allCases) { p in
                    Button(p.rawValue) { m.publish(c, to: p) }
                }
            }
        } label: {
            Label("Subir", systemImage: "square.and.arrow.up")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize())
        .help("Subir a YouTube, Instagram o TikTok")
    }
    func chrome(_ v: some View) -> some View {
        v.foregroundStyle(hover ? Color.primary : Color.secondary)
        .padding(.horizontal, 9).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : 0.05)))
        .onHover { hover = $0 }
        .animation(.ui, value: hover)
    }
}

struct IconButton: View {
    let symbol: String, help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? (hover ? Color.primary : Color.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : 0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(help)
        .onHover { hover = $0 }
        .animation(.ui, value: hover)
    }
}

/// Anillo con la puntuación que da la IA (0–100).
struct ScoreRing: View {
    let score: Int
    @State private var shown = 0.0
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 3)
            Circle().trim(from: 0, to: shown)
                .stroke(Palette.heat, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .frame(width: 30, height: 30)
        .help("Potencial viral según la IA: \(score) de 100")
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 1).delay(0.15)) { shown = Double(score) / 100 } }
    }
}

// MARK: - Brillo de carga

struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay {
            if active && !reduceMotion {
                TimelineView(.animation) { ctx in
                    GeometryReader { g in
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                        LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6)
                            .offset(x: CGFloat(t) * g.size.width * 1.6 - g.size.width * 0.6)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func shimmer(active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

// MARK: - Detalle de un clip: verlo y retocarlo

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

struct ClipDetail: View {
    @ObservedObject var m: Model
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var start: Double
    @State private var end: Double
    @State private var copied = false

    init(m: Model, id: UUID) {
        _m = ObservedObject(wrappedValue: m)
        self.id = id
        let c = m.clips.first { $0.id == id }
        _start = State(initialValue: c?.m.start ?? 0)
        _end = State(initialValue: c?.m.end ?? 1)
    }

    /// Límites para retocar: el inicio hasta 1 s antes del final; el final hasta el final del vídeo.
    var startRange: ClosedRange<Double> { let lo = max(0, end - 180); return lo...max(lo, end - 1) }
    var endRange: ClosedRange<Double> {
        let total = (m.info?.duration ?? 0) > 0 ? m.info!.duration : end + 60
        let lo = start + 1
        return lo...max(lo, total)
    }

    var clip: ClipItem? { m.clips.first { $0.id == id } }
    var changed: Bool { guard let c = clip else { return false }; return abs(c.m.start - start) > 0.01 || abs(c.m.end - end) > 0.01 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Color.black
                PlayerView(player: player)
                if clip?.state == .rendering || clip?.state.isBusy == true {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        Text("Volviendo a montar…").font(.system(size: 13, weight: .medium))
                    }
                    .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity)
                }
            }
            .frame(height: 430)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let c = clip {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(c.m.title).font(.system(size: 18, weight: .bold)).tracking(-0.3)
                        Text(c.m.reason).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ScoreRing(score: c.m.score)
                }
                if !c.m.caption.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Text(c.m.caption).font(.system(size: 12.5)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copiar texto para redes", tint: copied ? Palette.ok : nil) {
                            m.copyCaption(c)
                            withAnimation(.ui) { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.ui) { copied = false } }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
                HStack(spacing: 18) {
                    TrimStepper(label: "Inicio", value: $start, range: startRange)
                    TrimStepper(label: "Final", value: $end, range: endRange)
                    Text("\(Int((end - start).rounded())) s").font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    if changed {
                        Button("Deshacer") { withAnimation(.ui) { start = c.m.start; end = c.m.end } }
                            .controlSize(.regular)
                        Button { m.retrim(id, start: start, end: end) } label: { Label("Volver a montar", systemImage: "scissors") }
                            .buttonStyle(PrimaryButton(color: Palette.cue))
                            .disabled(c.state.isBusy)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.ui, value: changed)
            }
            HStack {
                Button { if let f = clip?.file { NSWorkspace.shared.activateFileViewerSelecting([f]) } } label: { Label("Mostrar en Finder", systemImage: "folder") }
                Spacer()
                if let c = clip, c.state == .ready {
                    ForEach(Platform.allCases) { p in
                        Button(p.rawValue) { m.publish(c, to: p) }.help(p.hint)
                    }
                    Spacer().frame(width: 10)
                }
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 680)
        .onAppear {
            if let c = clip { start = c.m.start; end = c.m.end }
            load()
        }
        .onChange(of: clip?.version) {
            if let c = clip { start = c.m.start; end = c.m.end }
            load()
        }
        .onDisappear { player?.pause() }
        .animation(.ui, value: clip?.state)
    }

    func load() {
        guard let f = clip?.file, clip?.state == .ready else { return }
        player?.pause()
        let p = AVPlayer(url: f)
        player = p
        p.play()
    }
}

struct TrimStepper: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                b("gobackward", -0.5)
                Text(fmt(value, tenths: true))
                    .font(.system(size: 12.5, design: .monospaced))
                    .contentTransition(.numericText(value: value))
                    .frame(minWidth: 56)
                b("goforward", 0.5)
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }
    func b(_ s: String, _ d: Double) -> some View {
        Button {
            let v = min(range.upperBound, max(range.lowerBound, value + d))
            guard v != value else { haptic(.generic); return }
            withAnimation(.ui) { value = v }
            Sound.shared.play(.tick); haptic()
        } label: {
            Image(systemName: s).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .foregroundStyle(.secondary)
        .help(d < 0 ? "Medio segundo antes" : "Medio segundo después")
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @State private var key = UserDefaults.standard.string(forKey: "geminiKey") ?? ""
    @State private var check: Bool? = nil
    @State private var checking = false
    @AppStorage("sounds") private var sounds = true
    @AppStorage("musicDir") private var musicDir = ""
    @AppStorage("outputDir") private var outputDir = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    SecureField("Pega aquí tu clave", text: $key)
                        .onChange(of: key) {
                            UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "geminiKey")
                            check = nil
                        }
                    Button(checking ? "Probando…" : "Probar") {
                        checking = true
                        Task {
                            let ok = await testGeminiKey(geminiKey())
                            checking = false
                            withAnimation(.ui) { check = ok }
                            Sound.shared.play(ok ? .success : .error)
                        }
                    }
                    .disabled(checking || geminiKey().isEmpty)
                    if let ok = check {
                        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(ok ? Palette.ok : Palette.cue)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cómo conseguirla gratis:").font(.system(size: 12, weight: .semibold))
                    Text("1. Abre Google AI Studio e inicia sesión con tu cuenta de Google.")
                    Text("2. Pulsa «Create API key» y copia la clave.")
                    Text("3. Pégala arriba y pulsa «Probar».")
                    Link("Abrir Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .padding(.top, 2)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            } header: { Text("Clave de Gemini") }

            Section {
                HStack {
                    Text(outputDir.isEmpty ? "Películas › Clips" : (outputDir as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Cambiar…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        p.prompt = "Elegir"
                        if p.runModal() == .OK, let u = p.url { outputDir = u.path }
                    }
                    if !outputDir.isEmpty { Button("Restablecer") { outputDir = "" } }
                }
            } header: { Text("Dónde se guardan los clips") }

            Section {
                HStack {
                    Text(musicDir.isEmpty ? "La compone Clips para cada vídeo" : (musicDir as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Elegir carpeta…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false
                        p.prompt = "Elegir"
                        if p.runModal() == .OK, let u = p.url { musicDir = u.path }
                    }
                    if !musicDir.isEmpty { Button("Quitar") { musicDir = "" } }
                }
                Text("Si eliges una carpeta con tus canciones (mp3, m4a, wav), Clips usa esas en vez de componer una.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } header: { Text("Música de fondo") }

            Section {
                Toggle("Sonidos", isOn: $sounds)
                    .onChange(of: sounds) { if sounds { Sound.shared.play(.pop) } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }
}
