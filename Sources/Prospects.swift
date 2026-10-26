import Foundation
import SwiftUI

/// Contacts (optionnel) lus dans ~/.config/x-videos/contacts.json : {"data":[{"id":"…","displayName":"Prénom Nom","fields":{"company_name":"…"}}]}.
/// Aucune clé, aucun appel réseau. Sans ce fichier, la liste est simplement vide.
/// Une vidéo reliée à sa fiche (recordId) envoie cet id au serveur vidéo avec les vues.
struct Prospect: Equatable, Identifiable {
    let id: String
    let name: String
    let company: String
    /// « Khamis BOUCHKARA » → « Khamis »
    var firstName: String { String(name.split(separator: " ").first ?? Substring(name)).capitalizedName }
}

enum Prospects {
    static var file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/x-videos/contacts.json")

    static func load() -> [Prospect] {
        guard let d = try? Data(contentsOf: file),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rows = o["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let name = r["displayName"] as? String, (r["isArchived"] as? Bool) != true else { return nil }
            let f = r["fields"] as? [String: Any]
            let company = (f?["company_name"] as? String)
                ?? ((f?["company"] as? [String: Any])?["fieldValues"] as? [String: Any])?["name"] as? String
                ?? (f?["v1_company_name"] as? String) ?? ""
            return Prospect(id: id, name: name, company: company)
        }
    }

    /// Recherche sans accents ni majuscules : chaque mot tapé doit commencer un mot du nom ou de l'agence.
    static func search(_ query: String, in all: [Prospect], limit: Int = 8) -> [Prospect] {
        let words = norm(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { p in
            let hay = norm(p.name + " " + p.company).split(separator: " ").map(String.init)
            return words.allSatisfy { w in hay.contains { $0.hasPrefix(w) } }
        }
        .prefix(limit).map { $0 }
    }

    static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) }
    }
}

private extension String {
    var capitalizedName: String { lowercased().split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-") }
}

/// Menu « Fiche CRM » : propose les fiches qui correspondent au prénom / à l'agence tapés.
struct ProspectPicker: View {
    let query: String
    let linkedId: String?
    let onPick: (Prospect?) -> Void
    @State private var all: [Prospect] = []

    var body: some View {
        let matches = Prospects.search(query, in: all)
        let linked = all.first { $0.id == linkedId }
        Menu {
            if matches.isEmpty { Text(query.isEmpty ? "Tape un prénom ou une agence" : "Aucune fiche du CRM pour « \(query) »") }
            ForEach(matches) { p in
                Button { onPick(p) } label: { Text(p.company.isEmpty ? p.name : "\(p.name) · \(p.company)") }
            }
            if linkedId != nil { Divider(); Button("Délier la fiche") { onPick(nil) } }
        } label: {
            Label(linked.map { "CRM : \($0.name)" } ?? (linkedId != nil ? "CRM : relié" : "Relier à une fiche du CRM"),
                  systemImage: linkedId != nil ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Relie la vidéo à la fiche du prospect : la vidéo est rattachée à sa fiche contact")
        .onAppear { all = Prospects.load() }
    }
}
