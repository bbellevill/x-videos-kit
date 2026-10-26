// Verrou (2026-10-10) : looms personnalisés — remplacement du prénom, choix du point de coupe, phrase proposée.
import Foundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }

check(Personalize.fill("Salut {prénom}, chez {agence} ?", firstName: "Julie", company: "Studio Nova") == "Salut Julie, chez Studio Nova ?", "prénom et agence remplacés")
check(Personalize.fill("Salut {prenom} !", firstName: "Léa", company: "") == "Salut Léa !", "{prenom} sans accent accepté")

// 50 ms par case : voix (-20 dB), pause courte à 1 s (trop tôt), pause à 4,5 s, longue pause à 7 s
var lv = [Double](repeating: -20, count: 200)
for i in 20..<24 { lv[i] = -60 }       // 1,0–1,2 s : avant 2,5 s, ignorée
for i in 88..<93 { lv[i] = -60 }       // 4,4–4,65 s : la première bonne pause
for i in 135..<150 { lv[i] = -60 }     // 6,75–7,5 s : plus longue mais plus tardive
let cut = Personalize.pickCut(levels: lv, step: 0.05) ?? -1
check(abs(cut - 4.525) < 0.06, "coupe à la première pause après 2,5 s (\(cut))")
check(Personalize.pickCut(levels: [Double](repeating: -20, count: 200), step: 0.05) == nil, "aucune pause : pas de coupe")

check(Personalize.suggestOpening(from: "Salut Zizou, j'espère que tu as la forme.") == "Salut {prénom}, j'espère que tu as la forme.", "prénom après « Salut » remplacé")
check(Personalize.suggestOpening(from: "Qu'est-ce qu'ils disent Zizou ? J'espère que tu as la forme.") == "Salut {prénom} ! J'espère que tu as la forme.", "première phrase remplacée sans salutation")
print(fails == 0 ? "OK : looms personnalisés" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
