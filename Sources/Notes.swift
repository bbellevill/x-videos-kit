import Cocoa

/// Notes de présentation : petite fenêtre flottante, toujours au premier plan, jamais filmée
/// (exclue du filtre de capture comme toutes les fenêtres de X-Videos, et marquée non partageable).
/// Le texte est gardé d'une fois sur l'autre.
final class NotesPanel: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private var panel: NSPanel?
    private var text: NSTextView?
    static let key = "presenterNotes"
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil { panel = make() }
        panel?.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    func hide() {
        panel?.orderOut(nil)
        onVisibilityChange?(false)
    }

    private func make() -> NSPanel {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let p = NSPanel(contentRect: NSRect(x: vf.maxX - 360, y: vf.maxY - 300, width: 340, height: 280),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Notes de présentation"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = .none                   // invisible pour les autres logiciels de capture aussi
        p.appearance = NSAppearance(named: .darkAqua)
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.setFrameAutosaveName("XVideosNotes")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = p.contentView!.bounds
        scroll.autoresizingMask = [.width, .height]
        let tv = scroll.documentView as! NSTextView
        tv.font = .systemFont(ofSize: 16)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.string = UserDefaults.standard.string(forKey: Self.key) ?? "Tes notes ici : elles ne seront pas filmées."
        tv.delegate = self
        p.contentView?.addSubview(scroll)
        text = tv
        return p
    }

    func textDidChange(_ notification: Notification) {
        UserDefaults.standard.set(text?.string ?? "", forKey: Self.key)
    }

    func windowWillClose(_ notification: Notification) { onVisibilityChange?(false) }
}
