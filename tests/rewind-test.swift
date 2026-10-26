// Verrou « refaire les dernières secondes » (2026-10-14) : le recul demandé pendant une pause devient un passage coupé,
// en temps de la vidéo (pauses retirées), jamais avant le début.
import Foundation
var fails = 0
func check(_ ok: Bool, _ name: String) { if !ok { print("ÉCHEC : \(name)"); fails += 1 } }
var c = PauseClock(); c.origin = 100
c.pause(at: 112); c.resume(at: 130)      // 1re pause après 12 s filmées
c.pause(at: 133); c.resume(at: 140)      // 2e pause après 15 s filmées
let cuts = c.rewindCuts([0: 5, 1: 20])
check(cuts.count == 2, "deux passages")
check(abs(cuts[0].start - 7) < 0.01 && abs(cuts[0].end - 12) < 0.01, "1re pause : 7 → 12 s (\(cuts[0]))")
check(cuts[1].start == 0 && abs(cuts[1].end - 15) < 0.01, "recul trop long : arrêté au début (\(cuts[1]))")
check(c.rewindCuts([:]).isEmpty && c.rewindCuts([5: 3]).isEmpty, "rien demandé / pause inconnue = rien")
print(fails == 0 ? "OK : refaire les dernières secondes" : "\(fails) échec(s)")
exit(fails == 0 ? 0 : 1)
