import AppKit
import AVKit
import KaraifyerCore
import SwiftUI

/// The « Lecteur » tab: song list (deliberate loading), video, position/loop, transport, tempo, pitch, mixer.
struct PlayerView: View {
    @Bindable var model: PlayerModel

    var body: some View {
        HSplitView {
            songList.frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
            VStack(spacing: 6) {
                video
                positionBar
                controls
                mixer.frame(height: 230)
            }
            .padding(8)
            .frame(minWidth: 760)
        }
        .onAppear { model.installSpaceKey(); Task { await KaraokeModel.shared.refresh() } }
        .onDisappear { model.stopEverything(); model.removeSpaceKey() }
        .sheet(isPresented: Bindable(ExportUI.shared).shown) { ExportSheet(player: model) }
    }

    // MARK: song list — a single click selects; double-click, Return or « Charger » loads

    var songList: some View {
        VStack(spacing: 6) {
            TextField("Rechercher (titre, artiste, n°)", text: $model.query)
                .textFieldStyle(.roundedBorder)
            List(model.filteredSongs, id: \.id, selection: $model.selectedID) { s in
                let miss = model.missing(for: s)
                HStack(spacing: 4) {
                    Text(model.loaded?.id == s.id ? "▶︎" : "").frame(width: 14)
                    Text("\(s.id) · \(s.titre) — \(s.artiste)").lineLimit(1)
                }
                .foregroundStyle(miss.isEmpty ? Color.primary : Color.secondary)
                .help(miss.isEmpty ? "Double-clic ou « Charger » pour l'ouvrir" : "Pas prêt : manque " + miss.joined(separator: ", "))
            }
            .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { ids in
                if let id = ids.first { model.load(id) }
            })
            Button("Charger") { if let id = model.selectedID { model.load(id) } }
                .disabled(model.selectedID == nil || model.selectedID == model.loaded?.id)
        }
        .padding(8)
    }

    // MARK: video

    var video: some View {
        ZStack {
            Color.black
            if model.loaded != nil, model.scene != nil {
                LiveVideoView(model: model)
            } else if model.loaded != nil {
                VideoView(player: model.videoPlayer)
                Text("Réanalyser pour la vidéo en direct").font(.caption).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(6)
            } else {
                Text("Choisir un morceau dans la liste").foregroundStyle(.secondary)
            }
            if let e = model.error { Text(e).foregroundStyle(.orange).padding() }
        }
        .frame(minHeight: 260)
    }

    // MARK: position bar with the loop zone

    var positionBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if let (a, b) = model.loopRange, model.length > 0 {
                    Rectangle()
                        .fill(Color.yellow.opacity(model.loopOn ? 0.4 : 0.15))
                        .frame(width: max(2, g.size.width * (b - a) / model.length), height: 10)
                        .offset(x: g.size.width * a / model.length)
                }
                Slider(value: Binding(get: { model.position }, set: { model.seek($0) }), in: 0...max(model.length, 1))
            }
        }
        .frame(height: 22)
        .disabled(model.loaded == nil)
    }

    // MARK: transport, loop, tempo, pitch, export

    var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            transportRow
            HStack(spacing: 10) {
                tempo
                Divider().frame(height: 18)
                pitch
                Spacer()
                Button("Exporter le mix…") { ExportUI.shared.shown = true }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.loaded == nil)
    }

    var transportRow: some View {
        HStack(spacing: 10) {
            Button("Début", systemImage: "backward.end.fill") { model.restart() }.labelStyle(.iconOnly)
            Button(model.isPlaying ? "Pause" : "Lecture", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlay()
            }
            .labelStyle(.iconOnly)
            Text("\(timecode(model.position)) / \(timecode(model.length))").monospacedDigit()
            Divider().frame(height: 18)
            Button("Début de boucle") { model.markLoopStart() }
            Button("Fin de boucle") { model.markLoopEnd() }
            Toggle("Boucle", isOn: Binding(get: { model.loopOn }, set: { _ in model.toggleLoop() }))
                .toggleStyle(.button)
                .disabled(model.loopRange == nil)
            Button("Effacer") { model.clearLoop() }.disabled(model.loopRange == nil)
            Spacer()
        }
    }

    var tempo: some View {
        let song = model.songBPM
        let cur = model.settings.targetBPM ?? song ?? 0
        return HStack(spacing: 4) {
            Text("Tempo :").fixedSize()
            Button("−") { model.setBPM(cur - 1) }
            CommitField(value: song == nil ? "—" : String(Int(cur.rounded())), enabled: song != nil, resignOnCommit: true) {
                model.setBPM(Double($0.replacingOccurrences(of: ",", with: ".")))
            }
            .frame(width: 40)
            Button("+") { model.setBPM(cur + 1) }
            Text("BPM").fixedSize()
            Button("Original (\(Int((song ?? 0).rounded())))") { model.setBPM(nil) }.fixedSize()
        }
        .disabled(song == nil)
    }

    var pitch: some View {
        let n = model.settings.semitones
        return HStack(spacing: 4) {
            Text("Hauteur :").fixedSize()
            Button("−") { model.setSemitones(n - 1) }
            Text(n == 0 ? "0" : String(format: "%+d", n)).monospacedDigit().frame(width: 28)
            Button("+") { model.setSemitones(n + 1) }
            Button("Réinitialiser") { model.setSemitones(0) }.fixedSize().disabled(n == 0)
            if n != 0 && model.scene == nil {
                Text("Transposé \(String(format: "%+d", n)) : accords de la vidéo dans la tonalité d'origine")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Picker("Disposition :", selection: $model.videoLayout) {
                Text("Grille + paroles").tag("grille")
                Text("Accords sur les paroles").tag("paroles")
            }
            .fixedSize()
            .disabled(model.scene == nil)
        }
    }

    // MARK: mixer

    var mixer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(PlayerTrack.allCases, id: \.self) { t in
                channel(t.label, value: model.settings.faders[t] ?? Fader.unity, set: { model.setFader(t, $0) },
                        muted: model.settings.mutes.contains(t), soloed: model.settings.solos.contains(t),
                        mute: { model.toggleMute(t) }, solo: { model.toggleSolo(t) })
            }
            Divider()
            channel("Master", value: model.settings.master, set: { model.setMaster($0) },
                    muted: false, soloed: false, mute: nil, solo: nil)
        }
        .disabled(model.loaded == nil)
    }

    func channel(_ name: String, value: Double, set: @escaping (Double) -> Void, muted: Bool, soloed: Bool,
                 mute: (() -> Void)?, solo: (() -> Void)?) -> some View {
        VStack(spacing: 4) {
            Text(Fader.label(value)).font(.caption2).monospacedDigit()
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
                .rotationEffect(.degrees(-90))
                .frame(width: 140, height: 24)
                .frame(width: 40, height: 140)
            HStack(spacing: 2) {
                if let mute {
                    Toggle("M", isOn: Binding(get: { muted }, set: { _ in mute() })).toggleStyle(.button).tint(.red)
                }
                if let solo {
                    Toggle("S", isOn: Binding(get: { soloed }, set: { _ in solo() })).toggleStyle(.button).tint(.yellow)
                }
            }
            .font(.caption)
            Text(name).font(.caption).lineLimit(1).frame(width: 80)
        }
    }
}

/// The lyrics video. Double-click opens it full screen (on the window's screen); double-click or Escape closes.
struct VideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = DoubleClickPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

final class DoubleClickPlayerView: AVPlayerView {
    /// AVPlayerView's inner views swallow clicks: take every click in the frame here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let p = player {
            MainActor.assumeIsolated { FullScreenVideo.toggle(player: p, screen: window?.screen) }
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// The live lyrics video: the renderer draws the frame at the engine's position, on every display refresh while
/// playing (and once on any change while paused), letterboxed to 16:9. Double-click: full screen.
struct LiveVideoView: NSViewRepresentable {
    let model: PlayerModel
    func makeNSView(context: Context) -> LiveVideoNSView {
        let v = LiveVideoNSView()
        v.model = model
        return v
    }
    func updateNSView(_ v: LiveVideoNSView, context: Context) {
        _ = (model.position, model.videoLayout, model.settings.semitones, model.isPlaying)   // redraw on these
        v.show()
    }
}

final class LiveVideoNSView: NSView {
    weak var model: PlayerModel?
    private var link: CADisplayLink?
    private var shownRevision = -1
    var isFullScreen = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .black
        layer?.contentsGravity = .resizeAspect          // the 1080p frame is scaled by the GPU, letterboxed
        layer?.magnificationFilter = .linear
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        if window != nil {
            let l = displayLink(target: self, selector: #selector(refresh))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            l.add(to: .main, forMode: .common)
            link = l
            show()
        }
    }

    @objc private func refresh() {
        MainActor.assumeIsolated {
            guard let m = model else { return }
            // the main window's view rests while the full-screen view covers the show screen
            if !isFullScreen && FullScreenVideo.window != nil { return }
            if m.isPlaying || m.videoRevision != shownRevision { show() }
        }
    }

    func show() {
        MainActor.assumeIsolated {
            guard let m = model, let r = m.renderer else { layer?.contents = nil; return }
            shownRevision = m.videoRevision
            layer?.contents = r.frame(at: m.positionNow, layout: m.videoLayout, transpose: m.settings.semitones)
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let m = model {
            MainActor.assumeIsolated { FullScreenVideo.toggleLive(model: m, screen: window?.screen) }
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// A borderless window covering the screen with its own AVPlayerView on the same AVPlayer (one player, two layers).
@MainActor enum FullScreenVideo {
    static var window: NSWindow?

    /// Closing stops the full-screen view's display link (it would otherwise keep the view alive and firing).
    static func close(_ w: NSWindow) {
        (w.contentView as? LiveVideoNSView)?.stop()
        w.contentView = nil
        w.orderOut(nil)
        window = nil
    }

    /// Full screen for the live video: a second live view on the same model.
    static func toggleLive(model: PlayerModel, screen: NSScreen?) {
        if let w = window { close(w); return }
        let frame = (screen ?? NSScreen.main)?.frame ?? .zero
        let w = EscWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .mainMenu + 1
        w.backgroundColor = .black
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        w.isReleasedWhenClosed = false
        let v = LiveVideoNSView(frame: NSRect(origin: .zero, size: frame.size))
        v.model = model
        v.isFullScreen = true
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    static func toggle(player: AVPlayer, screen: NSScreen?) {
        if let w = window { w.orderOut(nil); window = nil; return }
        let frame = (screen ?? NSScreen.main)?.frame ?? .zero
        let w = EscWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .mainMenu + 1
        w.backgroundColor = .black
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        w.isReleasedWhenClosed = false
        let v = DoubleClickPlayerView(frame: NSRect(origin: .zero, size: frame.size))
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

final class EscWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { FullScreenVideo.close(self) }
    }
}
