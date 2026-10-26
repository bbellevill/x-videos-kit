import Cocoa

/// Choix de ce qu'on filme, façon Screen Studio : un voile sur l'écran,
/// - mode Fenêtre : la fenêtre sous la souris s'entoure de violet, clic = choisie ;
/// - mode Zone : on tire un rectangle à la souris (Entrée = reprendre la dernière zone).
/// Échap annule. Les calculs (fenêtre sous la souris, rectangle) sont dans CaptureGeometry, testés.
final class TargetPicker {
    private var panel: NSPanel?
    private var done: ((CaptureTarget?) -> Void)?

    func run(_ mode: CaptureMode, on screen: NSScreen, lastArea: CGRect?, done: @escaping (CaptureTarget?) -> Void) {
        self.done = done
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size), mode: mode, screen: screen,
                           lastArea: lastArea.flatMap { screen.frame.contains($0) ? $0 : nil })
        v.finish = { [weak self] t in self?.finish(t) }
        p.contentView = v
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(v)
        panel = p
        NSCursor.crosshair.push()
    }

    private func finish(_ t: CaptureTarget?) {
        NSCursor.pop()
        panel?.orderOut(nil); panel = nil
        let d = done; done = nil
        d?(t)
    }
}

private final class PickerView: NSView {
    var finish: ((CaptureTarget?) -> Void)?
    private let mode: CaptureMode
    private let screen: NSScreen
    private let lastArea: CGRect?
    private var windows: [CaptureGeometry.WindowInfo] = []
    private var hover: CaptureGeometry.WindowInfo?
    private var dragStart: NSPoint?
    private var dragRect: CGRect?

    init(frame: NSRect, mode: CaptureMode, screen: NSScreen, lastArea: CGRect?) {
        self.mode = mode; self.screen = screen; self.lastArea = lastArea
        super.init(frame: frame)
        // fenêtres ordinaires à l'écran, de l'avant vers l'arrière (sans la nôtre)
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windows = CaptureGeometry.windowInfos(raw)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? screen.frame.height }
    /// Point de la vue → coordonnées écran Cocoa.
    private func global(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x + screen.frame.minX, y: p.y + screen.frame.minY) }
    /// Rectangle écran Cocoa → coordonnées de la vue.
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        let g = global(convert(event.locationInWindow, from: nil))
        let q = CGPoint(x: g.x, y: primaryHeight - g.y)            // Quartz : origine en haut à gauche
        hover = CaptureGeometry.window(at: q, in: windows, excludingPID: getpid())
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .window {
            mouseMoved(with: event)
            guard let w = hover else { return }
            let f = CaptureGeometry.cocoa(fromQuartz: w.bounds, primaryHeight: primaryHeight)
            finish?(.window(w.id, frame: f, screen: screen))
        } else {
            dragStart = convert(event.locationInWindow, from: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let a = dragStart else { return }
        let b = convert(event.locationInWindow, from: nil)
        dragRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, let a = dragStart else { return }
        dragStart = nil
        let b = convert(event.locationInWindow, from: nil)
        guard let r = CaptureGeometry.area(from: global(a), to: global(b), in: screen.frame) else { dragRect = nil; needsDisplay = true; return }
        finish?(.area(r, screen: screen))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish?(nil); return }                            // Échap
        if event.keyCode == 36, mode == .area, let r = lastArea { finish?(.area(r, screen: screen)); return }   // Entrée
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        var hole: CGRect?
        if mode == .window, let w = hover { hole = local(CaptureGeometry.cocoa(fromQuartz: w.bounds, primaryHeight: primaryHeight)) }
        if mode == .area { hole = dragRect ?? lastArea.map(local) }
        if let h = hole {
            NSColor.clear.setFill(); h.fill(using: .copy)
            Theme.violet.setStroke()
            let path = NSBezierPath(rect: h.insetBy(dx: -1.5, dy: -1.5)); path.lineWidth = 3; path.stroke()
            if mode == .area { label("\(Int(h.width)) × \(Int(h.height))", at: NSPoint(x: h.midX, y: h.minY - 26)) }
            if mode == .window, let w = hover { label(w.owner, at: NSPoint(x: h.midX, y: h.midY)) }
        }
        let hint = mode == .window ? "Clique sur la fenêtre à filmer  ·  Échap pour annuler"
            : lastArea != nil ? "Tire un rectangle à la souris  ·  Entrée = dernière zone  ·  Échap pour annuler"
            : "Tire un rectangle à la souris  ·  Échap pour annuler"
        label(hint, at: NSPoint(x: bounds.midX, y: bounds.maxY - 80))
    }

    private func label(_ s: String, at p: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (s as NSString).size(withAttributes: attrs)
        let r = NSRect(x: p.x - size.width / 2 - 12, y: p.y - size.height / 2 - 6, width: size.width + 24, height: size.height + 12)
        Theme.black.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        (s as NSString).draw(at: NSPoint(x: r.minX + 12, y: r.minY + 6), withAttributes: attrs)
    }
}
