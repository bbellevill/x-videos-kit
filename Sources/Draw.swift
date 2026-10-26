import Cocoa

/// Dessin à l'écran pendant le tournage (⌥⇧D ou bouton « Dessiner » de la barre), comme Loom.
/// Contrairement aux autres fenêtres de X-Videos, celle-ci EST filmée : le Recorder la garde dans la capture
/// (voir `keepWindowIDs`). Elle est donc créée AVANT le début de la capture et reste en place, transparente et
/// traversée par la souris, jusqu'à la fin du tournage ; dessiner ne fait que lui faire capter la souris.
final class DrawOverlay {
    private var panel: DrawPanel?
    private var canvas: DrawCanvas?
    private(set) var isDrawing = false
    var onChange: ((Bool) -> Void)?

    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    /// À appeler avant de lancer la capture : la fenêtre doit déjà exister quand ScreenCaptureKit liste les fenêtres.
    func prepare(on screen: NSScreen) {
        teardown()
        let p = DrawPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // juste sous la barre de contrôle (.statusBar) : la barre et la bulle restent cliquables pendant qu'on dessine
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.sharingType = .readOnly                // surtout pas .none (comme les notes) : ce dessin doit être filmé
        p.ignoresMouseEvents = true              // au repos, la souris passe à travers
        let c = DrawCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
        c.autoresizingMask = [.width, .height]
        c.onEscape = { [weak self] in self?.setDrawing(false) }
        p.contentView = c
        p.setFrame(screen.frame, display: false)
        p.orderFrontRegardless()
        panel = p; canvas = c
    }

    func toggle() { setDrawing(!isDrawing) }

    func setDrawing(_ on: Bool) {
        guard let p = panel, on != isDrawing else { return }
        isDrawing = on
        p.ignoresMouseEvents = !on
        if on { p.makeKey() } else { canvas?.finishStroke() }
        p.invalidateCursorRects(for: canvas!)
        onChange?(on)
    }

    /// Fin du tournage : la fenêtre disparaît, les traits aussi.
    func teardown() {
        let was = isDrawing
        isDrawing = false
        canvas?.stop()
        panel?.orderOut(nil)
        panel = nil; canvas = nil
        if was { onChange?(false) }
    }
}

/// Panneau qui peut recevoir le clavier (Échap) sans voler le focus de l'app filmée.
private final class DrawPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class DrawCanvas: NSView {
    private var strokes: [DrawStroke] = []
    private var current: DrawStroke?
    private var timer: Timer?
    var onEscape: () -> Void = {}
    static let width: CGFloat = 5

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if window?.ignoresMouseEvents == false { addCursorRect(bounds, cursor: .crosshair) }
    }

    private func now() -> TimeInterval { CACurrentMediaTime() }

    override func mouseDown(with event: NSEvent) {
        current = DrawStroke(points: [convert(event.locationInWindow, from: nil)], endedAt: nil)
        startTimer()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current?.points.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { finishStroke() }

    func finishStroke() {
        guard var s = current else { return }
        s.endedAt = now()
        strokes.append(s)
        current = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
    }

    // 60 images/s tant qu'il reste des traits à fondre ; le minuteur s'arrête tout seul quand tout a disparu
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.strokes = DrawFade.remaining(self.strokes, now: self.now())
            self.needsDisplay = true
            if self.strokes.isEmpty && self.current == nil { self.timer?.invalidate(); self.timer = nil }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; strokes = []; current = nil }

    override func draw(_ dirtyRect: NSRect) {
        let t = now()
        let all = strokes + (current.map { [$0] } ?? [])
        for s in all {
            let a = DrawFade.alpha(endedAt: s.endedAt, now: t)
            guard a > 0, let first = s.points.first else { continue }
            let path = NSBezierPath()
            path.lineWidth = Self.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            if s.points.count == 1 { path.line(to: first) }       // simple clic = un point rond
            for p in s.points.dropFirst() { path.line(to: p) }
            Theme.violet.withAlphaComponent(a).setStroke()
            path.stroke()
        }
    }
}
