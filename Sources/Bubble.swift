import Cocoa
import AVFoundation

/// Bulle caméra ronde, déplaçable, toujours au premier plan. Elle est filmée avec l'écran (comme Loom).
/// Glisser = déplacer ; double-clic = taille suivante (S, M, L).
final class CameraBubble: NSObject, AVCaptureFileOutputRecordingDelegate {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    // la caméra est aussi enregistrée dans son propre fichier : au montage, la bulle reste nette et fixe pendant les zooms
    private let movie = AVCaptureMovieFileOutput()
    private(set) var recordingStarted: Date?
    private var onStopped: ((URL?) -> Void)?
    private var configured = false
    private let sizes: [CGFloat] = [180, 260, 380]
    private var sizeIndex = 1

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func show(completion: ((Bool) -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else {
                    Alert.show("Caméra refusée", "Active X-Videos dans Réglages Système > Confidentialité et sécurité > Caméra.")
                    completion?(false); return
                }
                self.showOnMain()
                completion?(true)
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        // si le fichier caméra se termine encore, on coupe la caméra seulement après
        if movie.isRecording {
            let previous = onStopped
            onStopped = { [weak self] u in previous?(u); self?.hide() }
            return
        }
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if s.isRunning { s.stopRunning() } }
    }

    private func showOnMain() {
        if !configured { configure() }
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if !s.isRunning { s.startRunning() } }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let dev = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
        }
        // fichier caméra écrit en fragments de 2 s : récupérable après un crash, comme l'écran
        movie.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        if session.canAddOutput(movie) { session.addOutput(movie) }
        session.commitConfiguration()
        configured = true
    }

    private func makePanel() -> NSPanel {
        let s = sizes[sizeIndex]
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let p = makeHUDPanel(NSRect(x: vf.minX + 40, y: vf.minY + 40, width: s, height: s))
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = BubbleView(frame: NSRect(x: 0, y: 0, width: s, height: s), session: session)
        v.onDoubleClick = { [weak self] in self?.cycleSize() }
        p.contentView = v
        return p
    }

    /// Position de la bulle dans l'écran filmé (pour la replacer au même endroit au montage).
    func placement(in screen: NSScreen) -> (x: Double, y: Double, size: Double)? {
        guard let p = panel, p.isVisible else { return nil }
        let f = screen.frame
        return ((p.frame.midX - f.minX) / f.width, 1 - (p.frame.midY - f.minY) / f.height, p.frame.height / f.height)
    }

    var canRecord: Bool { configured && session.isRunning && movie.connection(with: .video) != nil }

    func startRecording(to url: URL) {
        recordingStarted = nil
        try? FileManager.default.removeItem(at: url)
        movie.startRecording(to: url, recordingDelegate: self)
    }

    /// Pause / reprise : le temps de pause n'est pas écrit dans le fichier caméra (même découpe que l'écran).
    func pauseRecording() { if movie.isRecording && !movie.isRecordingPaused { movie.pauseRecording() } }
    func resumeRecording() { if movie.isRecordingPaused { movie.resumeRecording() } }

    /// Bouton pause sur la bulle pendant le tournage (visible au survol, toujours visible en pause). nil = retiré.
    func setPauseButton(paused: Bool?, action: (() -> Void)? = nil) {
        (panel?.contentView as? BubbleView)?.setPauseButton(paused: paused, action: action)
    }

    func stopRecording(_ done: @escaping (URL?) -> Void) {
        guard movie.isRecording else { done(nil); return }
        onStopped = done
        movie.stopRecording()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        recordingStarted = Date()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        DispatchQueue.main.async {
            self.onStopped?(ok ? outputFileURL : nil)
            self.onStopped = nil
        }
    }

    private func cycleSize() {
        sizeIndex = (sizeIndex + 1) % sizes.count
        guard let p = panel else { return }
        let s = sizes[sizeIndex]
        let c = NSPoint(x: p.frame.midX, y: p.frame.midY)
        p.setFrame(NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s), display: true, animate: true)
    }
}

final class BubbleView: NSView {
    var onDoubleClick: (() -> Void)?
    private let preview: AVCaptureVideoPreviewLayer
    private let ring = CAShapeLayer()
    private var pauseButton: NSButton?
    private var pauseAction: (() -> Void)?
    private var paused = false
    private var hovering = false

    init(frame: NSRect, session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        preview.masksToBounds = true
        layer?.addSublayer(preview)
        ring.fillColor = nil
        ring.strokeColor = Theme.violet.cgColor
        ring.lineWidth = 4
        layer?.addSublayer(ring)
        // effet miroir, comme dans un appel vidéo
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds
        preview.cornerRadius = bounds.width / 2
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        CATransaction.commit()
        pauseButton?.frame = NSRect(x: bounds.midX - 18, y: bounds.minY + 12, width: 36, height: 36)
    }

    func setPauseButton(paused p: Bool?, action: (() -> Void)?) {
        guard let p = p else { pauseButton?.removeFromSuperview(); pauseButton = nil; pauseAction = nil; return }
        paused = p
        pauseAction = action ?? pauseAction
        if pauseButton == nil {
            let b = FirstMouseButton(frame: .zero)
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 18
            b.layer?.backgroundColor = Theme.black.withAlphaComponent(0.85).cgColor
            b.contentTintColor = .white
            b.target = self; b.action = #selector(tapPause)
            addSubview(b)
            pauseButton = b
        }
        pauseButton?.image = NSImage(systemSymbolName: p ? "play.fill" : "pause.fill", accessibilityDescription: p ? "Reprendre" : "Pause")
        pauseButton?.toolTip = p ? "Reprendre l'enregistrement (⌥⇧P)" : "Mettre en pause (⌥⇧P)"
        pauseButton?.isHidden = !(hovering || p)
        needsLayout = true
    }

    @objc private func tapPause() { pauseAction?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; pauseButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { hovering = false; pauseButton?.isHidden = !paused }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { window?.performDrag(with: event) }
    }
}
