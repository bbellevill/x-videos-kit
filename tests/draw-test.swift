// Verrou (2026-10-14) : effacement des traits dessinés à l'écran (net 2 s, fondu 1 s, disparu 3 s après le tracé).
import Foundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }

check(DrawFade.alpha(endedAt: nil, now: 1000) == 1, "trait en cours de tracé : jamais effacé")
check(DrawFade.alpha(endedAt: 10, now: 10) == 1, "juste tracé : net")
check(DrawFade.alpha(endedAt: 10, now: 11.9) == 1, "net pendant 2 s")
let mid = DrawFade.alpha(endedAt: 10, now: 12.5)
check(abs(mid - 0.5) < 0.001, "à mi-fondu : 50 % (\(mid))")
check(DrawFade.alpha(endedAt: 10, now: 13) == 0, "disparu 3 s après le tracé")
check(DrawFade.alpha(endedAt: 10, now: 99) == 0, "reste disparu")

let strokes = [DrawStroke(points: [.zero], endedAt: 1),      // vieux : disparu
               DrawStroke(points: [.zero], endedAt: 9),      // en fondu
               DrawStroke(points: [.zero], endedAt: 10.5),   // net
               DrawStroke(points: [.zero], endedAt: nil)]    // en cours
let left = DrawFade.remaining(strokes, now: 11.5)
check(left.count == 3 && left.first?.endedAt == 9, "il reste les traits non disparus (\(left.count))")
check(DrawFade.remaining(strokes, now: 100).count == 1, "à la fin seul le trait en cours reste")
check(DrawFade.remaining([], now: 5).isEmpty, "rien à effacer")

print(fails == 0 ? "OK : dessin (effacement des traits)" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
