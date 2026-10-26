import Foundation

/// Une vidéo de la bibliothèque (fichier local + son éventuel lien en ligne).
struct Video: Identifiable, Codable, Equatable {
    var id: String            // identifiant du lien (aléatoire, impossible à deviner)
    var file: String          // nom du fichier dans ~/Movies/Mes looms
    var title: String
    var created: Date
    var duration: Double
    var uploaded: Bool = false
    var views: Int = 0
    var lastView: Date?
    var edited: Bool? = nil   // montage modifié depuis le dernier envoi
    var firstName: String? = nil   // prospect : affiché sur la page et dans l'aperçu du lien
    var company: String? = nil
    var plays: Int? = nil
    var pct: Int? = nil            // part de la vidéo regardée (25/50/75/100)
    var ctaClicks: Int? = nil
    var recordId: String? = nil    // fiche contact (contacts.json)
    var sentAt: Date? = nil        // 1re copie du lien = vidéo envoyée
    var pending: Bool? = nil       // envoi en cours ou interrompu : repris au lancement
    var thumbTime: Double? = nil   // miniature choisie à la main (seconde du fichier source)
    var requireEmail: Bool? = nil  // la page demande l'e-mail avant de lancer la vidéo
    var locked: Bool? = nil        // lien protégé par mot de passe
    var reactions: Int? = nil
    var comments: Int? = nil
    var emails: [String]? = nil    // e-mails laissés sur la page (porte e-mail)
    var folder: String? = nil      // dossier de rangement (2026-10-14) ; nil = hors dossier. Optionnel : un ancien index se relit sans perte
}

/// Recherche + dossiers de la bibliothèque (fonctions pures, testées dans tests/library-test.swift).
enum LibraryFilter {
    /// Minuscules sans accents : « Élodie » se trouve en tapant « elodie ».
    static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// `folder` nil = « Toutes ». La recherche porte sur le titre, le prénom et l'agence (tous les mots doivent y être).
    static func apply(_ videos: [Video], query: String, folder: String?) -> [Video] {
        let words = norm(query).split(separator: " ").map(String.init)
        return videos.filter { v in
            if let f = folder, v.folder != f { return false }
            if words.isEmpty { return true }
            let hay = norm([v.title, v.firstName ?? "", v.company ?? ""].joined(separator: " "))
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// Dossiers connus (créés à la main ou déjà utilisés), sans doublon, triés.
    static func folders(of videos: [Video], extra: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for n in videos.compactMap({ $0.folder }) + extra {
            let t = n.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, seen.insert(norm(t)).inserted { out.append(t) }
        }
        return out.sorted { norm($0) < norm($1) }
    }
}
