// Verrou « montage figé » (2026-10-17) : la vidéo de Paul est restée sur « Ta vidéo arrive… » car l'export
// s'était arrêté sans erreur. Une progression immobile 90 s doit être repérée ; une progression lente, jamais.
import Foundation
var fails = 0
func check(_ ok: Bool, _ name: String) { if !ok { print("ÉCHEC : \(name)"); fails += 1 } }
let t0 = Date()
var w = StallWatch(limit: 90)
check(!w.isStalled(progress: 0.2, now: t0), "premier relevé")
check(!w.isStalled(progress: 0.2, now: t0 + 89), "89 s immobile : on attend encore")
check(w.isStalled(progress: 0.2, now: t0 + 90), "90 s immobile : figé")
var slow = StallWatch(limit: 90)
var ok = true
for i in 0..<100 { if slow.isStalled(progress: Float(i) * 0.01, now: t0 + Double(i) * 60) { ok = false } }
check(ok, "lent mais qui avance (1 %/min) : jamais figé")
print(fails == 0 ? "OK : montage figé repéré" : "\(fails) échec(s)")
exit(fails == 0 ? 0 : 1)
