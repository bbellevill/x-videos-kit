// Verrou (bug du 2026-10-10) : sans menu Édition, ⌘A ⌘C ⌘V ne marchent dans aucun champ de texte.
import Cocoa
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }
let items = Menus.main().items.compactMap { $0.submenu }.flatMap { $0.items }
for (sel, key) in [(#selector(NSText.selectAll(_:)), "a"), (#selector(NSText.copy(_:)), "c"), (#selector(NSText.paste(_:)), "v"), (#selector(NSText.cut(_:)), "x")] {
    check(items.contains { $0.action == sel && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }, "⌘\(key.uppercased()) → \(sel)")
}
print(fails == 0 ? "OK : menu Édition (⌘A ⌘C ⌘V ⌘X)" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
