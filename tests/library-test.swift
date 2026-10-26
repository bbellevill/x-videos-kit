// Verrou (2026-10-14) : dossiers + recherche de la bibliothèque. Un ancien .library.json (sans « folder ») doit se relire sans perte.
import Foundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }

// 1. ancien index : aucun champ « folder » (ni les champs plus récents)
let old = """
[{"id":"abc234","file":"X-Videos 2026.mp4","title":"Julie — Studio Nova","created":"2026-10-01T10:00:00Z","duration":42.5,
  "uploaded":true,"views":3,"firstName":"Julie","company":"Studio Nova","recordId":"rec1"}]
"""
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let videos = (try? dec.decode([Video].self, from: Data(old.utf8))) ?? []
check(videos.count == 1, "ancien index relu")
check(videos.first?.folder == nil, "sans dossier par défaut")
check(videos.first?.title == "Julie — Studio Nova" && videos.first?.views == 3 && videos.first?.recordId == "rec1", "rien perdu à la relecture")

// 2. aller-retour avec un dossier
var v = videos[0]; v.folder = "Prospects"
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
let back = try! dec.decode([Video].self, from: enc.encode([v]))
check(back.first?.folder == "Prospects", "dossier sauvegardé puis relu")

// 3. filtre
func mk(_ id: String, _ title: String, _ first: String? = nil, _ company: String? = nil, _ folder: String? = nil) -> Video {
    Video(id: id, file: "\(id).mp4", title: title, created: Date(), duration: 10, firstName: first, company: company, folder: folder)
}
let all = [mk("a", "Vidéo du 10 octobre", nil, nil, nil),
           mk("b", "Julie — Studio Nova", "Julie", "Studio Nova", "Prospects"),
           mk("c", "Élodie — Agence Lumière", "Élodie", "Agence Lumière", "Prospects"),
           mk("d", "Démo produit", nil, nil, "Démos")]
func ids(_ q: String, _ f: String?) -> String { LibraryFilter.apply(all, query: q, folder: f).map(\.id).joined() }
check(ids("", nil) == "abcd", "sans filtre : tout")
check(ids("", "Prospects") == "bc", "dossier seul")
check(ids("julie", nil) == "b", "recherche par prénom")
check(ids("nova", nil) == "b", "recherche par agence")
check(ids("démo", nil) == "d" && ids("demo", nil) == "d", "recherche par titre, accents ignorés")
check(ids("elodie", nil) == "c", "« elodie » trouve Élodie")
check(ids("agence lumiere", nil) == "c", "plusieurs mots")
check(ids("julie", "Démos") == "", "recherche + dossier combinés : aucun résultat")
check(ids("studio", "Prospects") == "b", "recherche + dossier combinés")
check(ids("  JULIE ", nil) == "b", "majuscules et espaces ignorés")
check(ids("zzz", nil) == "", "rien ne correspond")

// 4. liste des dossiers
let names = LibraryFilter.folders(of: all, extra: ["Archives", "prospects", " "])
check(names == ["Archives", "Démos", "Prospects"], "dossiers : créés + utilisés, sans doublon, triés (\(names))")

print(fails == 0 ? "OK : bibliothèque (dossiers et recherche)" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
