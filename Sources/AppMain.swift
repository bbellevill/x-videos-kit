import Cocoa
import AVFoundation
import Carbon
import QuartzCore
import UniformTypeIdentifiers

/// X-Videos : enregistreur d'écran façon Loom, 100 % local.
/// ⌥⇧R (ou le menu) : compte à rebours → écran (ou fenêtre, ou zone) + bulle caméra + micro → MP4 dans ~/Movies/Mes looms.
/// ⌥⇧P : pause / reprise (rien de la pause n'est gardé). Un tournage coupé par un crash est réparé au lancement.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.regular)  // icône dans le Dock : toujours trouvable
        app.run()
    }

    enum State { case idle, countdown, recording, saving }
    private var state = State.idle { didSet { updateIcon() } }
    private var statusItem: NSStatusItem!
    private let bubble = CameraBubble()
    private let countdown = Countdown()
    private let controls = ControlBar()
    private let recorder = ScreenRecorder()
    private let cursor = CursorTracker()
    private let keys = KeyRecorder()
    private let notes = NotesPanel()
    private let draw = DrawOverlay()
    private let picker = TargetPicker()
    private lazy var library = Library(folder: Self.folder)
    private lazy var home = HomeWindow(library: library)
    private var hotKey: HotKey?
    private var pauseHotKey: HotKey?
    private var drawHotKey: HotKey?
    private var rewindHotKey: HotKey?
    private var pauseCount = 0                 // pauses du tournage en cours
    private var rewinds: [Int: Double] = [:]   // numéro de pause → secondes à refaire
    private var cancelled = false
    private var paused = false
    private var keyLogOn = false
    private var lastURL: URL?
    private var recordingURL: URL?
    private var cameraTake: (url: URL, placement: (x: Double, y: Double, size: Double))?

    private let defaults = UserDefaults.standard
    private var cameraOn: Bool {
        get { defaults.object(forKey: "cameraOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cameraOn") }
    }
    private var micID: String? {
        get { defaults.string(forKey: "micID") }
        set { defaults.set(newValue, forKey: "micID") }
    }

    static let folder: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Mes looms", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Menus.main()
        // ouvre l'éditeur d'une vidéo au lancement (preuves en capture, sans clic) : XV_OUVRIR=<titre ou fichier>
        if let t = ProcessInfo.processInfo.environment["XV_OUVRIR"], let v = library.videos.first(where: { $0.title == t || $0.file == t }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                EditorWindow.show(v, library: self.library)
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        home.model.cameraOn = cameraOn
        home.model.micID = micID
        home.model.onStart = { [weak self] in self?.toggle() }
        home.model.onCamera = { [weak self] on in
            self?.cameraOn = on
            if on { self?.bubble.show() } else { self?.bubble.hide() }
        }
        home.model.onMic = { [weak self] id in self?.micID = id }
        home.model.onNotes = { [weak self] in self?.notes.toggle() }
        notes.onVisibilityChange = { [weak self] on in self?.home.model.notesOn = on }
        Notifier.requestPermission()
        showLauncher()
        // pour les tests : X_VIDEOS_OPEN_EDITOR=1 ouvre directement le montage de la dernière vidéo
        if ProcessInfo.processInfo.environment["X_VIDEOS_OPEN_EDITOR"] != nil, let v = library.videos.first { library.play(v) }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey)) { [weak self] in self?.toggle() }
        pauseHotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | shiftKey)) { [weak self] in self?.togglePause() }
        drawHotKey = HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | shiftKey)) { [weak self] in self?.toggleDraw() }
        rewindHotKey = HotKey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey)) { [weak self] in self?.rewind() }
        draw.onChange = { [weak self] on in self?.controls.setDrawing(on) }
        recoverInterrupted()
        // journal des touches : demande d'autorisation affichée une seule fois, au lancement (jamais pendant un tournage)
        if home.model.options.keyLog { KeyRecorder.askOnce() }
    }

    /// Tournages coupés (crash, coupure) : réparés et remis dans la bibliothèque, avec un message.
    private func recoverInterrupted() {
        let pending = Recovery.pending(in: Self.folder)
        guard !pending.isEmpty else { return }
        Task { @MainActor in
            var saved: [String] = []
            for v in pending {
                if let d = await Recovery.recover(v) {
                    library.addRecovered(v)
                    saved.append("\(v.deletingPathExtension().lastPathComponent) (\(Library.fmt(d)))")
                }
            }
            guard !saved.isEmpty else { return }
            let text = saved.count == 1 ? "Un enregistrement interrompu a été récupéré : \(saved[0])."
                : "\(saved.count) enregistrements interrompus ont été récupérés : \(saved.joined(separator: ", "))."
            library.lastError = text
            Notifier.send("Enregistrement récupéré", text)
        }
    }

    /// Clic sur l'icône du Dock : on rouvre la fenêtre.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if state == .idle { showLauncher() }
        return true
    }

    private func showLauncher() {
        home.show()
        if cameraOn { bubble.show() }   // aperçu de la bulle pour la placer avant d'enregistrer
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch state {
        case .idle: menu.addItem(item("Démarrer l'enregistrement   ⌥⇧R", #selector(toggle)))
        case .countdown: menu.addItem(item("Annuler le compte à rebours", nil))
        case .recording:
            menu.addItem(item("Terminer l'enregistrement   ⌥⇧R", #selector(toggle)))
            menu.addItem(item(paused ? "Reprendre   ⌥⇧P" : "Mettre en pause   ⌥⇧P", #selector(togglePause)))
            if draw.windowID != nil { menu.addItem(item(draw.isDrawing ? "Arrêter de dessiner   ⌥⇧D" : "Dessiner à l'écran   ⌥⇧D", #selector(toggleDraw))) }
        case .saving: menu.addItem(item("Enregistrement de la vidéo…", nil))
        }
        menu.addItem(.separator())
        let cam = item("Caméra en bulle", #selector(toggleCamera))
        cam.state = cameraOn ? .on : .off
        menu.addItem(cam)
        let mic = NSMenuItem(title: "Micro", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let def = item("Micro par défaut du système", #selector(pickMic(_:)))
        def.state = micID == nil ? .on : .off
        sub.addItem(def)
        for d in Self.microphones() {
            let i = item(d.localizedName, #selector(pickMic(_:)))
            i.representedObject = d.uniqueID
            i.state = micID == d.uniqueID ? .on : .off
            sub.addItem(i)
        }
        mic.submenu = sub
        menu.addItem(mic)
        let o = home.model.options
        menu.addItem(choices("Capture", CaptureMode.allCases.map { ($0.label, $0.rawValue, $0 == o.mode) }, #selector(pickMode(_:))))
        menu.addItem(choices("Images par seconde", [("30 i/s", "30", o.fps == 30), ("60 i/s", "60", o.fps == 60)], #selector(pickFPS(_:))))
        menu.addItem(choices("Son du Mac", SystemAudio.allCases.map { ($0.label, $0.rawValue, $0 == o.systemAudio) }, #selector(pickSystemAudio(_:))))
        let icons = item("Masquer les icônes du bureau", #selector(toggleDesktopIcons))
        icons.state = o.hideDesktopIcons ? .on : .off
        menu.addItem(icons)
        let kl = item("Journal des raccourcis clavier", #selector(toggleKeyLog))
        kl.state = o.keyLog ? .on : .off
        menu.addItem(kl)
        let nt = item("Notes de présentation", #selector(toggleNotes))
        nt.state = notes.isVisible ? .on : .off
        menu.addItem(nt)
        menu.addItem(.separator())
        menu.addItem(item("Importer une vidéo…", #selector(importVideo)))
        if lastURL != nil { menu.addItem(item("Ouvrir la dernière vidéo", #selector(openLast))) }
        menu.addItem(item("Ouvrir le dossier des vidéos", #selector(openFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quitter X-Videos", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.isEnabled = action != nil
        return i
    }

    private func choices(_ title: String, _ list: [(String, String, Bool)], _ action: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value, on) in list {
            let i = item(label, action)
            i.representedObject = value
            i.state = on ? .on : .off
            sub.addItem(i)
        }
        m.submenu = sub
        return m
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    private func updateIcon() {
        guard let b = statusItem?.button else { return }
        let recording = state == .recording
        let symbol = recording ? (paused ? "pause.circle.fill" : "stop.circle.fill") : "record.circle"
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "X-Videos")
        b.contentTintColor = recording ? (paused ? Theme.violet : Theme.red) : nil
    }

    @objc private func toggleCamera() {
        cameraOn.toggle()
        if cameraOn { bubble.show() } else { bubble.hide() }
    }
    @objc private func pickMic(_ sender: NSMenuItem) { micID = sender.representedObject as? String }
    @objc private func pickMode(_ sender: NSMenuItem) {
        if let m = (sender.representedObject as? String).flatMap(CaptureMode.init(rawValue:)) { home.model.options.mode = m }
    }
    @objc private func pickFPS(_ sender: NSMenuItem) { home.model.options.fps = sender.representedObject as? String == "60" ? 60 : 30 }
    @objc private func pickSystemAudio(_ sender: NSMenuItem) {
        if let a = (sender.representedObject as? String).flatMap(SystemAudio.init(rawValue:)) { home.model.options.systemAudio = a }
    }
    @objc private func toggleDesktopIcons() { home.model.options.hideDesktopIcons.toggle() }
    @objc private func toggleKeyLog() { home.model.options.keyLog.toggle() }
    @objc private func toggleNotes() { notes.toggle() }
    @objc private func importVideo() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = true
        p.prompt = "Importer"
        if p.runModal() == .OK { library.importFiles(p.urls); showLauncher() }
    }
    @objc func openFolder() { NSWorkspace.shared.open(Self.folder) }
    @objc private func openLast() { if let u = lastURL { openInQuickTime(u) } }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: enregistrement

    @objc func toggle() {
        switch state {
        case .idle: startFlow()
        case .recording: stopRecording()
        default: break
        }
    }

    private func startFlow() {
        guard CGPreflightScreenCaptureAccess() else {
            // on ouvre directement le bon réglage (la demande système se cachait derrière notre fenêtre)
            CGRequestScreenCaptureAccess()
            home.hide()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            Alert.show("Dernière autorisation : filmer l'écran",
                       "Dans la fenêtre Réglages qui vient de s'ouvrir, active « X-Videos ». macOS proposera « Quitter et rouvrir » : accepte. Ensuite, clique de nouveau sur Démarrer.")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else {
                    Alert.show("Micro refusé", "Active X-Videos dans Réglages Système > Confidentialité et sécurité > Microphone.")
                    return
                }
                self.chooseTarget()
            }
        }
    }

    /// Écran entier : tout de suite. Fenêtre ou zone : on la choisit d'abord à la souris.
    private func chooseTarget() {
        let screen = Self.screenUnderMouse()
        let o = home.model.options
        guard o.mode != .screen else { runCountdown(.screen(screen)); return }
        home.hide()
        state = .countdown
        picker.run(o.mode, on: screen, lastArea: o.lastArea) { [weak self] t in
            guard let self = self else { return }
            guard let t = t else { self.state = .idle; self.showLauncher(); return }
            if case .area(let r, _) = t { self.home.model.options.lastArea = r }
            self.runCountdown(t)
        }
    }

    private func runCountdown(_ target: CaptureTarget) {
        home.hide()
        state = .countdown
        if cameraOn { bubble.show() }
        countdown.run(on: target.screen) { [weak self] in self?.beginRecording(target) }
    }

    private func beginRecording(_ target: CaptureTarget) {
        let screen = target.screen
        let options = home.model.options
        cancelled = false
        paused = false
        pauseCount = 0; rewinds = [:]
        // dessin à l'écran : fenêtre créée AVANT la capture (elle doit être filmée, contrairement aux autres) ;
        // impossible en mode « une fenêtre » (la capture ne montre que cette fenêtre)
        var canDraw = true
        if case .window = target { canDraw = false }
        if canDraw { draw.prepare(on: screen) }
        // la barre est affichée avant la capture pour pouvoir l'exclure de la vidéo
        controls.show(on: screen, onStop: { [weak self] in self?.stopRecording() },
                      onCancel: { [weak self] in self?.cancelRecording() },
                      onPause: { [weak self] in self?.togglePause() },
                      onDraw: canDraw ? { [weak self] in self?.toggleDraw() } : nil,
                      onRewind: { [weak self] in self?.rewind() })
        // caméra enregistrée à part : la bulle est alors exclue de la capture d'écran et recomposée au montage
        let separateCamera = cameraOn && bubble.canRecord
        let keep = (cameraOn && !separateCamera ? [bubble.windowID] : []).compactMap { $0 } + [draw.windowID].compactMap { $0 }
        let hide = [controls.windowID, notes.windowID].compactMap { $0 }
        let url = Self.newVideoURL()
        Task { @MainActor in
            do {
                try await recorder.start(target: target, keepWindowIDs: keep, hideWindowIDs: hide, options: options,
                                         micID: micID, to: url) { [weak self] r in self?.finished(r) }
                state = .recording
                recordingURL = url
                let started = Date()
                cursor.begin(frame: target.frame, video: url)
                // journal des touches : sans autorisation Accessibilité, tournage normal sans journal
                keyLogOn = options.keyLog && keys.start()
                var marker = RecordingMarker(started: started)
                cameraTake = nil
                if separateCamera, let pl = bubble.placement(in: screen) {
                    let cam = CursorTracker.url(for: url).deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).camera.mov")
                    try? FileManager.default.createDirectory(at: cam.deletingLastPathComponent(), withIntermediateDirectories: true)
                    bubble.startRecording(to: cam)
                    cameraTake = (cam, pl)
                    marker.cameraFile = cam.lastPathComponent
                    marker.bubbleX = pl.x; marker.bubbleY = pl.y; marker.bubbleSize = pl.size
                }
                // marqueur anti-crash : retiré quand la vidéo est bien terminée
                Recovery.mark(url, marker)
                if cameraTake != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self = self, self.recordingURL == url, let cs = self.bubble.recordingStarted else { return }
                        marker.cameraOffset = cs.timeIntervalSince(started)
                        Recovery.mark(url, marker)
                    }
                }
                bubble.setPauseButton(paused: false) { [weak self] in self?.togglePause() }
                controls.startClock()
            } catch {
                controls.hide(); bubble.hide(); draw.teardown()
                state = .idle
                showLauncher()
                Alert.show("Impossible de démarrer l'enregistrement", error.localizedDescription)
            }
        }
    }

    /// Pause / reprise (⌥⇧P, menu, barre ou bulle) : écran, son, caméra, curseur et touches s'arrêtent ensemble.
    @objc func togglePause() {
        guard state == .recording else { return }
        paused.toggle()
        if paused { pauseCount += 1; recorder.pause(); bubble.pauseRecording() } else { recorder.resume(); bubble.resumeRecording() }
        controls.setPaused(paused)
        bubble.setPauseButton(paused: paused)
        updateIcon()
    }

    /// Refaire les dernières secondes (⌥⇧B ou « ↺ 5 s ») : met en pause si besoin, recule de 5 s à chaque appui.
    /// Rien n'est effacé pendant le tournage : le passage est coupé dans le montage à la fin (Edit.cuts), donc annulable.
    @objc func rewind() {
        guard state == .recording else { return }
        if !paused { togglePause() }
        let i = pauseCount - 1
        rewinds[i, default: 0] += 5
        controls.setRewind(total: rewinds[i]!, step: 5)
    }

    /// Dessiner à l'écran (⌥⇧D, menu ou barre) : les traits sont filmés et s'effacent tout seuls.
    @objc func toggleDraw() {
        guard state == .recording else { return }
        draw.toggle()
    }

    private func stopRecording() {
        guard state == .recording else { return }
        state = .saving
        draw.teardown()
        paused = false
        bubble.setPauseButton(paused: nil)
        controls.hide()
        bubble.stopRecording { _ in }
        recorder.stop()
    }

    private func cancelRecording() {
        cancelled = true
        stopRecording()
    }

    private func finished(_ result: Result<(URL, PauseClock), Error>) {
        draw.teardown()
        controls.hide()
        bubble.setPauseButton(paused: nil)
        bubble.hide()
        state = .idle
        paused = false
        updateIcon()
        let wasCancelled = cancelled
        cancelled = false
        let rawKeys = keys.stop()
        let target = recordingURL
        recordingURL = nil
        switch result {
        case .success(let (url, clock)):
            Recovery.unmark(url)
            if wasCancelled {
                cursor.cancel()
                try? FileManager.default.removeItem(at: url)
                if let take = cameraTake { try? FileManager.default.removeItem(at: take.url) }
                showLauncher(); return
            }
            cursor.end(saveFor: url, clock: clock)
            let redo = clock.rewindCuts(rewinds)
            if !redo.isEmpty {
                var st = EditSettings.load(for: url)
                st.cuts = (st.cuts ?? []) + redo.map { CutRange(start: $0.start, end: $0.end) }
                st.save(for: url)
            }
            if keyLogOn { KeyLog.save(KeyLog.retime(rawKeys, clock: clock), for: url) }
            if let take = cameraTake {
                // la bulle est replacée au même endroit, avec le décalage mesuré entre la caméra et la 1re image de l'écran
                let origin = clock.origin.map { Date().addingTimeInterval($0 - CACurrentMediaTime()) } ?? Date()
                let offset = (bubble.recordingStarted ?? origin).timeIntervalSince(origin)
                RecordingInfo(cameraFile: take.url.lastPathComponent, cameraOffset: offset,
                              bubbleX: take.placement.x, bubbleY: take.placement.y, bubbleSize: take.placement.size).save(for: url)
            }
            lastURL = url
            // la vidéo apparaît en tête de la bibliothèque, part en ligne et son lien est copié tout seul
            library.addRecording(url)
            showLauncher()
        case .failure(let error):
            cursor.cancel()
            showLauncher()
            guard let url = target else { if !wasCancelled { Alert.show("L'enregistrement a échoué", error.localizedDescription) }; return }
            if wasCancelled { Recovery.unmark(url); try? FileManager.default.removeItem(at: url); return }
            // la fin du fichier a échoué : réparation tout de suite (le fichier est écrit en fragments)
            Task { @MainActor in
                if let d = await Recovery.recover(url) {
                    library.addRecovered(url)
                    library.lastError = "L'enregistrement s'est mal terminé, mais il a été récupéré (\(Library.fmt(d)))."
                    // alerte visible : avant le 2026-10-13, un tournage coupé à 2 s passait inaperçu
                    Alert.show("Enregistrement coupé à \(Library.fmt(d))",
                               "Le début est gardé dans la bibliothèque. Relance un tournage.\n\nCause : \(error.localizedDescription)\n(détail : ~/Library/Logs/X-Videos.log)")
                } else {
                    Alert.show("L'enregistrement a échoué", error.localizedDescription)
                }
            }
        }
    }

    private func openInQuickTime(_ url: URL) {
        let qt = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        NSWorkspace.shared.open([url], withApplicationAt: qt, configuration: NSWorkspace.OpenConfiguration())
    }

    static func newVideoURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'à' HH'h'mm'm'ss"
        return folder.appendingPathComponent("X-Videos \(f.string(from: Date())).mp4")
    }

    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
