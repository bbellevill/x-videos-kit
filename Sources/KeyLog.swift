import Cocoa
import QuartzCore

/// Journal des touches pendant le tournage → <dossier>/.meta/<vidéo>.keys.json
/// Format : {"events":[{"t":12.34,"keys":"⌘K","typing":false}]}
/// t = secondes dans la vidéo finale (pauses retirées). Frappe de texte : typing true et keys "" (rien n'est gardé
/// de ce qui est tapé). Raccourci avec ⌘, ⌃ ou ⌥ : keys lisible, ex. « ⌘⇧4 ». Sert au montage (bulles de raccourcis,
/// passages de frappe accélérés).
enum KeyLog {
    struct Event: Equatable { var t: Double; var keys: String; var typing: Bool }

    /// Une touche → événement du journal. `plain` = caractère de la touche sans modificateur (disposition du clavier).
    static func describe(keyCode: UInt16, plain: String?, command: Bool, control: Bool, option: Bool, shift: Bool) -> (keys: String, typing: Bool) {
        guard command || control || option else { return ("", true) }
        // ordre affiché : ⌘ ⌃ ⌥ puis ⇧ (« ⌘⇧4 »)
        var s = ""
        if command { s += "⌘" }
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        return (s + keyName(keyCode: keyCode, plain: plain), false)
    }

    /// Nom de la touche : symbole pour les touches spéciales, chiffre pour la rangée des chiffres
    /// (sur un clavier AZERTY, ⌘⇧4 reste « 4 »), sinon le caractère de la disposition en majuscule.
    static func keyName(keyCode: UInt16, plain: String?) -> String {
        let special: [UInt16: String] = [
            36: "↩", 76: "⌤", 48: "⇥", 49: "Espace", 51: "⌫", 117: "⌦", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let n = special[keyCode] { return n }
        let digits: [UInt16: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]
        if let n = digits[keyCode] { return n }
        let p = (plain ?? "").trimmingCharacters(in: .controlCharacters)
        return p.isEmpty ? "#\(keyCode)" : p.uppercased()
    }

    /// Instants machine → temps de la vidéo ; frappes pendant une pause ou avant la 1re image retirées.
    static func retime(_ raw: [Event], clock: PauseClock) -> [Event] {
        raw.compactMap { e in clock.map(e.t).map { Event(t: ($0 * 1000).rounded() / 1000, keys: e.keys, typing: e.typing) } }
    }

    /// JSON au format exact attendu par le montage (ordre des champs fixe, t à 2 décimales).
    static func json(_ events: [Event]) -> String {
        let items = events.map { e -> String in
            let k = e.keys.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"t\":\(String(format: "%.2f", e.t)),\"keys\":\"\(k)\",\"typing\":\(e.typing)}"
        }
        return "{\"events\":[\(items.joined(separator: ","))]}"
    }

    static func url(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).keys.json")
    }

    static func save(_ events: [Event], for video: URL) {
        let u = url(for: video)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(json(events).utf8).write(to: u)
    }
}

/// Écoute le clavier de tout le Mac pendant le tournage. Nécessite l'autorisation Accessibilité :
/// demandée une seule fois ; refusée = pas de journal (le tournage marche normalement).
final class KeyRecorder {
    private var monitor: Any?
    private var events: [KeyLog.Event] = []

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Affiche la demande système la première fois seulement (ensuite : réglage dans Confidentialité > Accessibilité).
    static func askOnce() {
        let d = UserDefaults.standard
        guard !AXIsProcessTrusted(), !d.bool(forKey: "askedKeyLogPermission") else { return }
        d.set(true, forKey: "askedKeyLogPermission")
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    }

    /// false si l'autorisation manque (repli : rien n'est enregistré).
    @discardableResult
    func start() -> Bool {
        events = []
        guard Self.isAllowed else { return false }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let f = e.modifierFlags
            let d = KeyLog.describe(keyCode: e.keyCode, plain: e.characters(byApplyingModifiers: []),
                                    command: f.contains(.command), control: f.contains(.control),
                                    option: f.contains(.option), shift: f.contains(.shift))
            if e.isARepeat && !d.typing { return }      // raccourci maintenu : une seule fois
            self?.events.append(KeyLog.Event(t: CACurrentMediaTime(), keys: d.keys, typing: d.typing))
        }
        return monitor != nil
    }

    /// Arrête et rend les événements bruts (horloge machine).
    func stop() -> [KeyLog.Event] {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        defer { events = [] }
        return events
    }
}
