import Foundation

/// Titre montré au prospect (lien collé dans Gmail, page en ligne, aperçu du lien).
/// Bug du 2026-10-10 : « Pour Zizou chez Zinaty » était rempli mais le lien collé disait « Vidéo du 10 octobre à 14h00 ».
/// Règle : un titre choisi à la main est gardé ; un titre automatique cède la place à « Vidéo pour Prénom de chez Agence ».
enum ShareTitle {
    static func make(title: String, firstName: String?, company: String?) -> String {
        let f = (firstName ?? "").trimmingCharacters(in: .whitespaces)
        let c = (company ?? "").trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return title }
        // majuscule au début : « khamis » saisi en minuscules (2026-10-13)
        let cap = { (x: String) in x.prefix(1).uppercased() + x.dropFirst() }
        let f2 = cap(f), c2 = cap(c)
        let automatic = title.hasPrefix("Vidéo du ") || title == f || title == "\(f) — \(c)"
        guard automatic else { return title }
        return c.isEmpty ? "Vidéo pour \(f2)" : "Vidéo pour \(f2) de chez \(c2)"
    }

    /// Fin du lien collé : « khamis-kuroflow » (2026-10-13 : sur LinkedIn, seul le lien nu était collé, sans le nom du prospect).
    /// Vide sans prénom ni agence. Le serveur ignore cette fin (/v/<id>/<fin>).
    static func slug(firstName: String?, company: String?) -> String {
        let raw = [firstName ?? "", company ?? ""].joined(separator: " ")
        let plain = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        let parts = plain.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        return String(parts.joined(separator: "-").prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
