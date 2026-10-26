import Cocoa

/// Barre de menus de l'app. Sans menu « Édition », ⌘A ⌘C ⌘V ⌘X ne marchent dans aucun champ de texte (bug du 2026-10-10).
/// Le ⌘Z de l'éditeur reste prioritaire (moniteur clavier de l'éditeur, appelé avant les menus).
enum Menus {
    static func main() -> NSMenu {
        let bar = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Masquer X-Videos", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quitter X-Videos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        bar.addItem(sub("X-Videos", app))
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        bar.addItem(sub("Édition", edit))
        let win = NSMenu(title: "Fenêtre")
        win.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        bar.addItem(sub("Fenêtre", win))
        return bar
    }

    private static func sub(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.submenu = menu; return i
    }
}
