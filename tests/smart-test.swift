// Verrou : lecture de la réponse de Haiku (titre, résumé, chapitres) — JSON entouré de texte, chapitres en désordre,
// doublons, hors durée, 1er chapitre ramené à 0, un seul chapitre = aucun.
import Foundation
var fails = 0
func check(_ ok: Bool, _ name: String) { if !ok { print("ÉCHEC : \(name)"); fails += 1 } }
let raw = """
Voici : {"title": " «Ton portail client» ", "summary": "Tu vas voir ton espace.", "chapters": [{"t": 50, "title": "Tâches"}, {"t": 3, "title": "Intro"}, {"t": 50.4, "title": "Doublon"}, {"t": 999, "title": "Fin"}, {"t": 20, "title": "  "}]} merci
"""
let r = Smart.parse(raw, duration: 120)
check(r != nil, "JSON trouvé dans le texte")
check(r?.title == "Ton portail client", "titre nettoyé : \(r?.title ?? "")")
check(r?.chapters.map(\.title) == ["Intro", "Tâches", "Fin"], "triés, doublon et vide retirés : \(r?.chapters.map(\.title) ?? [])")
check(r?.chapters.first?.t == 0, "1er chapitre à 0")
check(r?.chapters.last?.t == 119, "borné à la durée")
let one = Smart.parse(#"{"title":"A","summary":"B","chapters":[{"t":0,"title":"Seul"}]}"#, duration: 60)
check(one?.chapters.isEmpty == true, "un seul chapitre = aucun")
check(Smart.parse("pas de json", duration: 10) == nil, "réponse invalide = rien")
let words = [Captions.Word(text: "Salut", start: 0, end: 0.4), Captions.Word(text: "Julie", start: 0.4, end: 0.8), Captions.Word(text: "voici", start: 9, end: 9.3)]
check(Smart.transcript(words) == "[0] Salut Julie \n[9] voici", "repères toutes les 8 s : \(Smart.transcript(words))")
print(fails == 0 ? "OK smart : réponse de Haiku lue et nettoyée" : "\(fails) échec(s)")
exit(fails == 0 ? 0 : 1)
