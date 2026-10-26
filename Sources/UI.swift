import SwiftUI
import Cocoa

/// Charte : noir, blanc, un seul violet plat. Pas de dégradé ni de halo.
enum Theme {
    static let violet = NSColor(srgbRed: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255, alpha: 1)  // #7b5bf4
    static let black = NSColor(srgbRed: 0x0a / 255, green: 0x0a / 255, blue: 0x0b / 255, alpha: 1)   // #0a0a0b
    static let border = NSColor(srgbRed: 0x2a / 255, green: 0x2a / 255, blue: 0x30 / 255, alpha: 1)  // #2a2a30
    static let red = NSColor(srgbRed: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)     // #ef4444 = enregistrement
}

/// Fenêtre flottante sans bord, qui ne vole pas le focus de l'app en cours.
func makeHUDPanel(_ frame: NSRect) -> NSPanel {
    let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.level = .statusBar
    p.hasShadow = true
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return p
}

/// Capsule ou disque plein (rayon = moitié de la plus petite dimension).
final class RoundView: NSView {
    var fill: NSColor = .black { didSet { needsDisplay = true } }
    var border: NSColor?
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let rad = min(r.width, r.height) / 2
        let path = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
        fill.setFill(); path.fill()
        if let border = border { border.setStroke(); path.lineWidth = 1; path.stroke() }
    }
}

/// Bouton capsule plat (fonctionne dans un panneau non activant grâce à acceptsFirstMouse).
/// Bouton qui réagit dès le 1er clic, même dans un panneau qui ne prend pas le focus.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PillButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    var fill: NSColor { didSet { needsDisplay = true } }
    private let symbol: String?          // icône SF Symbols à la place du texte
    private let action: () -> Void
    init(frame: NSRect, title: String, symbol: String? = nil, fill: NSColor, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.fill = fill; self.action = action
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        if let name = symbol, let base = NSImage(systemSymbolName: name, accessibilityDescription: title),
           let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            img.draw(in: NSRect(x: (bounds.width - img.size.width) / 2, y: (bounds.height - img.size.height) / 2,
                                width: img.size.width, height: img.size.height))
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

enum Alert {
    static func show(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// Compte à rebours 3-2-1 au centre de l'écran (jamais filmé : il disparaît avant le début).
final class Countdown {
    private var panel: NSPanel?
    private var timer: Timer?

    func run(seconds: Int = 3, on screen: NSScreen, done: @escaping () -> Void) {
        let s: CGFloat = 150
        let f = screen.frame
        let p = makeHUDPanel(NSRect(x: f.midX - s / 2, y: f.midY - s / 2, width: s, height: s))
        let v = RoundView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        v.fill = Theme.black.withAlphaComponent(0.92)
        v.border = Theme.violet
        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (s - 86) / 2, width: s, height: 86)
        v.addSubview(label)
        p.contentView = v
        p.orderFrontRegardless()
        panel = p
        var n = seconds
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            n -= 1
            if n <= 0 {
                t.invalidate()
                self?.panel?.orderOut(nil); self?.panel = nil
                done()
            } else {
                label.stringValue = "\(n)"
            }
        }
    }
}

/// Barre de contrôle pendant l'enregistrement : point rouge, chrono, Pause, Terminer, Annuler. Exclue de la vidéo.
final class ControlBar {
    private var panel: NSPanel?
    private var timer: Timer?
    private var dot: RoundView?
    private var pauseButton: PillButton?
    private var drawButton: PillButton?
    private var rewindButton: PillButton?
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private var elapsed = 0.0               // secondes filmées (pauses non comprises)
    private var since: Date?                // nil = en pause

    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func show(on screen: NSScreen, onStop: @escaping () -> Void, onCancel: @escaping () -> Void, onPause: @escaping () -> Void,
              onDraw: (() -> Void)? = nil, onRewind: (() -> Void)? = nil) {
        // « Dessiner » (2026-10-14) : seulement si le dessin peut être filmé (pas en mode « une fenêtre »)
        let w: CGFloat = (onDraw == nil ? 282 : 324) + (onRewind == nil ? 0 : 64), h: CGFloat = 46
        let vf = screen.visibleFrame
        let p = makeHUDPanel(NSRect(x: vf.midX - w / 2, y: vf.minY + 20, width: w, height: h))
        let v = RoundView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        v.fill = Theme.black.withAlphaComponent(0.96)
        v.border = Theme.border
        let d = RoundView(frame: NSRect(x: 18, y: h / 2 - 5, width: 10, height: 10))
        d.fill = Theme.red
        timeLabel.stringValue = "00:00"
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.frame = NSRect(x: 36, y: h / 2 - 9, width: 56, height: 18)
        let pause = PillButton(frame: NSRect(x: 98, y: 8, width: 36, height: h - 16), title: "❚❚", fill: Theme.border, action: onPause)
        var x: CGFloat = 140
        // « ↺ 5 s » (2026-10-14, Live Rewind) : met en pause et recule le point de reprise ; le raté est coupé au montage
        var rewind: PillButton?
        if let onRewind = onRewind {
            rewind = PillButton(frame: NSRect(x: x, y: 8, width: 58, height: h - 16), title: "↺ 5 s", fill: Theme.border, action: onRewind)
            x += 64
        }
        var draw: PillButton?
        if let onDraw = onDraw {
            draw = PillButton(frame: NSRect(x: x, y: 8, width: 36, height: h - 16), title: "Dessiner", symbol: "pencil.tip", fill: Theme.border, action: onDraw)
            x += 42
        }
        let stop = PillButton(frame: NSRect(x: x, y: 8, width: 96, height: h - 16), title: "Terminer", fill: Theme.violet, action: onStop)
        let cancel = PillButton(frame: NSRect(x: x + 102, y: 8, width: 30, height: h - 16), title: "✕", fill: Theme.border, action: onCancel)
        for sub in [d, timeLabel, pause, stop, cancel] as [NSView] { v.addSubview(sub) }
        if let draw = draw { v.addSubview(draw) }
        if let rewind = rewind { v.addSubview(rewind) }
        drawButton = draw; rewindButton = rewind
        p.contentView = v
        p.orderFrontRegardless()
        panel = p; dot = d; pauseButton = pause
    }

    /// En pause : chrono arrêté, point fixe violet, bouton ▶.
    func setPaused(_ paused: Bool) {
        if paused, let s = since { elapsed += Date().timeIntervalSince(s); since = nil }
        if !paused, since == nil { since = Date(); rewindButton?.title = "↺ 5 s"; rewindButton?.fill = Theme.border }
        pauseButton?.title = paused ? "▶" : "❚❚"
        dot?.alphaValue = 1
        dot?.fill = paused ? Theme.violet : Theme.red
    }

    /// Recul demandé pour la pause en cours : le chrono recule d'autant, le bouton dit le total (« ↺ 10 s »).
    func setRewind(total: Double, step: Double) {
        elapsed = max(0, elapsed - step)
        let s = Int(elapsed)
        timeLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
        rewindButton?.title = total > 0 ? "↺ \(Int(total)) s" : "↺ 5 s"
        rewindButton?.fill = total > 0 ? Theme.violet : Theme.border
    }

    /// Bouton « Dessiner » allumé (violet) tant qu'on dessine.
    func setDrawing(_ on: Bool) { drawButton?.fill = on ? Theme.violet : Theme.border }

    /// Démarre le chrono quand la capture a vraiment commencé.
    func startClock() {
        elapsed = 0; since = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.since else { return }      // en pause : rien ne bouge
            let s = Int(self.elapsed + Date().timeIntervalSince(start))
            self.timeLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
            self.timeLabel.textColor = s >= 60 ? Theme.violet : .white   // au-delà de 60 s : trop long pour un 1er contact
            if let d = self.dot { d.alphaValue = d.alphaValue < 1 ? 1 : 0.35 }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil; dot = nil; pauseButton = nil; drawButton = nil; rewindButton = nil
    }
}

/// Envoi en cours, discret : le lien marche déjà, la barre dit juste quand la vidéo sera visible.
struct UploadLine: View {
    let p: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: p).tint(Color(Theme.violet)).controlSize(.small)
            Text(p < 0.34 ? "Lien prêt · montage de la vidéo…" : "Lien prêt · envoi \(Int(p * 100)) %").font(.system(size: 11)).foregroundColor(Color(white: 0.6))
        }
    }
}

