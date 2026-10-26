// Verrou (bug du 2026-10-10) : le lien collé doit dire pour qui est la vidéo.
import Foundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }
check(ShareTitle.make(title: "Vidéo du 10 octobre à 14h00", firstName: "Zizou", company: "Zinaty") == "Vidéo pour Zizou de chez Zinaty", "titre auto + prénom + agence")
check(ShareTitle.make(title: "Vidéo du 10 octobre à 14h00", firstName: "Zizou", company: "") == "Vidéo pour Zizou", "sans agence")
check(ShareTitle.make(title: "Vidéo du 10 octobre à 14h00", firstName: nil, company: "Zinaty") == "Vidéo du 10 octobre à 14h00", "sans prénom : titre gardé")
check(ShareTitle.make(title: "Julie — Studio Nova", firstName: "Julie", company: "Studio Nova") == "Vidéo pour Julie de chez Studio Nova", "vidéo personnalisée")
check(ShareTitle.make(title: "Ton portail Kuroflow", firstName: "Khamis", company: "Kuroflow") == "Ton portail Kuroflow", "titre choisi à la main gardé")
check(ShareTitle.make(title: "Vidéo du 13 octobre à 17h01", firstName: "khamis", company: "kuroflow") == "Vidéo pour Khamis de chez Kuroflow", "minuscules saisies : majuscule au début")
check(ShareTitle.slug(firstName: "khamis", company: "kuroflow") == "khamis-kuroflow", "lien : prénom-agence")
check(ShareTitle.slug(firstName: "Élodie", company: "Studio L'Atelier & Co") == "elodie-studio-l-atelier-co", "lien : accents et signes retirés")
check(ShareTitle.slug(firstName: nil, company: nil) == "", "lien sans prospect : inchangé")
print(fails == 0 ? "OK : titre du lien partagé" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
