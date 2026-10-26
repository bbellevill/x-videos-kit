// Verrou (2026-10-10) : journal des touches .meta/<vidéo>.keys.json au format EXACT attendu par le montage,
// sans aucun caractère tapé, horodaté dans la vidéo finale (pauses retirées).
import Foundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }

// raccourcis lisibles
check(KeyLog.describe(keyCode: 40, plain: "k", command: true, control: false, option: false, shift: false) == ("⌘K", false), "⌘K")
check(KeyLog.describe(keyCode: 21, plain: "'", command: true, control: false, option: false, shift: true) == ("⌘⇧4", false), "⌘⇧4 (clavier AZERTY)")
check(KeyLog.describe(keyCode: 12, plain: "a", command: true, control: false, option: false, shift: false) == ("⌘A", false), "⌘A (A d'AZERTY, pas Q)")
check(KeyLog.describe(keyCode: 36, plain: "\r", command: true, control: false, option: false, shift: false) == ("⌘↩", false), "⌘↩")
check(KeyLog.describe(keyCode: 3, plain: "f", command: false, control: true, option: true, shift: false) == ("⌃⌥F", false), "⌃⌥F")
check(KeyLog.describe(keyCode: 49, plain: " ", command: true, control: false, option: false, shift: false) == ("⌘Espace", false), "⌘Espace")
// frappe : rien n'est gardé
check(KeyLog.describe(keyCode: 0, plain: "q", command: false, control: false, option: false, shift: false) == ("", true), "lettre seule = frappe, caractère non gardé")
check(KeyLog.describe(keyCode: 0, plain: "q", command: false, control: false, option: false, shift: true) == ("", true), "majuscule = frappe")
check(KeyLog.describe(keyCode: 51, plain: "", command: false, control: false, option: false, shift: false) == ("", true), "effacement = frappe")

// horodatage : pause de 3 s retirée, frappes pendant la pause et avant le début jetées
var c = PauseClock(); c.origin = 1000; c.pause(at: 1010); c.resume(at: 1013)
let raw = [KeyLog.Event(t: 999, keys: "⌘Q", typing: false), KeyLog.Event(t: 1002.344, keys: "", typing: true),
           KeyLog.Event(t: 1011, keys: "⌘V", typing: false), KeyLog.Event(t: 1015.5, keys: "⌘K", typing: false)]
let ev = KeyLog.retime(raw, clock: c)
check(ev.map { $0.t } == [2.344, 12.5], "temps de la vidéo finale, pause retirée")

// format exact
let s = KeyLog.json(ev)
check(s == #"{"events":[{"t":2.34,"keys":"","typing":true},{"t":12.50,"keys":"⌘K","typing":false}]}"#, "JSON au format exact : \(s)")
check(KeyLog.json([]) == #"{"events":[]}"#, "journal vide")
check(KeyLog.json([KeyLog.Event(t: 1, keys: "⌘\"", typing: false)]).contains(#""keys":"⌘\"""#), "guillemet échappé")
let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
let first = (parsed?["events"] as? [[String: Any]])?.last
check(first?["keys"] as? String == "⌘K" && first?["typing"] as? Bool == false && (first?["t"] as? Double) == 12.5, "JSON relisible")

// fichier rangé dans .meta
let v = URL(fileURLWithPath: "/tmp/Mes looms/X-Videos 2026.mp4")
check(KeyLog.url(for: v).path == "/tmp/Mes looms/.meta/X-Videos 2026.mp4.keys.json", "chemin .meta/<vidéo>.keys.json")

print(fails == 0 ? "OK : journal des touches" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
