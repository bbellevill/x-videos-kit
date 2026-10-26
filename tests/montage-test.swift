// Verrou (2026-10-10) : plan du montage — coupes, « euh », frappe accélérée, conversions de temps avec accélération,
// volume de la musique sous la voix, fichier .srt. Fonctions pures, sans vidéo.
import Foundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }
func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) < e }

// coupes fusionnées, morceaux gardés
let merged = Montage.merge([(5, 6), (1, 2), (1.5, 3), (2.995, 4)])
check(merged.count == 2 && near(merged[0].start, 1) && near(merged[0].end, 4) && near(merged[1].start, 5), "coupes fusionnées")
let keep = Montage.keep(start: 0, end: 20, cuts: [(8, 10), (3, 4), (19.98, 21)])
check(keep.count == 3 && near(keep[0].end, 3) && near(keep[1].start, 4) && near(keep[2].start, 10) && near(keep[2].end, 19.98), "morceaux gardés (\(keep))")

// vitesses : la plage à la main gagne sur la frappe ; ×1 annule une accélération automatique
let segs = Montage.plan(keep: [(0, 10), (12, 20)], speeds: [SpeedRange(start: 14, end: 18, speed: 2), SpeedRange(start: 13, end: 19, speed: 3)])
check(segs.map(\.speed) == [1, 1, 3, 2, 3, 1], "découpage par vitesse (\(segs.map(\.speed)))")
let dur = segs.last!.comp + segs.last!.compDur
check(near(dur, 10 + 1 + 1.0 / 3 + 2 + 1.0 / 3 + 1), "durée finale (\(dur))")
check(near(Renderer.compTime(16, segs, duration: dur), 10 + 1 + 1.0 / 3 + 1), "temps source → montage dans un passage ×2")
check(near(Renderer.sourceTime(10 + 1 + 1.0 / 3 + 1, segs), 16), "temps montage → source dans un passage ×2")
var roundTrip = true
for x in stride(from: 0.0, to: 20, by: 0.137) where Renderer.isKept(x, segs) {
    if !near(Renderer.sourceTime(Renderer.compTime(x, segs, duration: dur), segs), x, 1e-9) { roundTrip = false }
}
check(roundTrip, "aller-retour source ↔ montage sur tous les instants gardés")
check(!Renderer.isKept(11, segs) && Renderer.isKept(12.5, segs), "instant coupé reconnu")
let normal = Montage.plan(keep: [(0, 10)], speeds: [SpeedRange(start: 2, end: 4, speed: 1), SpeedRange(start: 1, end: 6, speed: 3)])
check(normal.map(\.speed) == [1, 3, 1, 3, 1], "×1 à la main garde la vitesse normale dans une frappe accélérée")
check(Montage.plan(keep: [(0, 10)], speeds: [SpeedRange(start: 3, end: 3.02, speed: 2)]).count == 1, "miette de vitesse ignorée")

// mots parasites
typealias W = Captions.Word
let words = [W(text: "Bon", start: 0, end: 0.4), W(text: "euh,", start: 0.5, end: 1.2), W(text: "voilà", start: 1.15, end: 1.6),
             W(text: "Hum…", start: 2, end: 2.5), W(text: "BEN", start: 3, end: 3.4), W(text: "bénéfice", start: 3.5, end: 4),
             W(text: "heu", start: 4.1, end: 4.15), W(text: "bahut", start: 5, end: 5.5)]
check(Montage.isFiller("Euh...") && Montage.isFiller("«heu»") && !Montage.isFiller("bahut") && !Montage.isFiller("bénéfice"), "liste insensible à la casse et à la ponctuation")
let fc = Montage.fillerCuts(words)
check(fc.count == 3, "trois mots parasites coupés (\(fc.count))")
check(fc.allSatisfy { c in words.filter { !Montage.isFiller($0.text) }.allSatisfy { $0.end <= c.start || $0.start >= c.end } }, "aucun vrai mot touché")
check(fc.first.map { near($0.end, 1.15 - 0.06) && near($0.start, 0.5) } ?? false, "marge avant le mot suivant (\(fc.first!))")

// frappe au clavier
let typ = Montage.typingRanges([10, 10.4, 11, 12.2, 13, 20, 30, 30.5, 31.9, 32.3])
check(typ.count == 2 && near(typ[0].start, 9.9) && near(typ[0].end, 13.3) && typ[0].speed == 3, "passages de frappe (écart < 1,5 s)")
check(Montage.typingRanges([5]).isEmpty, "une touche isolée n'accélère rien")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xv-montage-\(getpid())")
try! FileManager.default.createDirectory(at: dir.appendingPathComponent(".meta"), withIntermediateDirectories: true)
let video = dir.appendingPathComponent("v.mp4")
check(Montage.typingRanges(for: video).isEmpty, "fichier de frappe absent : rien")
try! #"{"events":[{"t":1,"keys":"a","typing":true},{"t":1.5,"keys":"","typing":true},{"t":2.4,"typing":true},{"t":2.6,"keys":"⌘","typing":false}]}"#
    .write(to: Montage.keysURL(video), atomically: true, encoding: .utf8)
let fromFile = Montage.typingRanges(for: video)
check(fromFile.count == 1 && near(fromFile[0].end, 2.7), "fichier .keys.json lu (raccourcis ignorés)")
try? FileManager.default.removeItem(at: dir)

// musique : basse sous la voix, remonte dans les blancs, fondu final
let keys = Audio.musicKeyframes(speech: [(0.5, 4), (4.5, 6), (10, 14)], duration: 20, base: 0.12)
check(near(Audio.value(keys, at: 3), 0.12), "musique basse pendant la voix")
check(near(Audio.value(keys, at: 4.2), 0.12), "pause courte : pas de remontée")
check(near(Audio.value(keys, at: 8), 0.3), "remonte dans un blanc de 4 s")
check(near(Audio.value(keys, at: 16), 0.3) && near(Audio.value(keys, at: 20), 0), "remonte après la voix, puis fondu final")
check(zip(keys, keys.dropFirst()).allSatisfy { $0.t <= $1.t }, "instants dans l'ordre")

// .srt
let srt = Captions.srt(words: [W(text: "Salut", start: 0.5, end: 0.9), W(text: "Julie.", start: 1, end: 1.4), W(text: "Regarde", start: 3725.25, end: 3725.8)])
check(srt == "1\n00:00:00,500 --> 00:00:01,900\nSalut Julie.\n\n2\n01:02:05,250 --> 01:02:06,300\nRegarde\n", "fichier .srt (\(srt.debugDescription))")


// vitesse globale (10/10) : ×2 sur tout = moitié de la durée ; un passage ×2 devient ×4
let g = Montage.plan(keep: [(0, 10)], speeds: [SpeedRange(start: 4, end: 6, speed: 2)], global: 2)
let gDur = g.reduce(0) { $0 + $1.compDur }
check(abs(gDur - 4.5) < 0.001, "×2 global : 10 s (dont 2 s déjà ×2) → 4,5 s (\(gDur))")
check(g.first { $0.src == 4 }?.speed == 4 && g.first?.speed == 2, "passage ×2 + global ×2 = ×4, le reste ×2")
check(Montage.plan(keep: [(0, 10)], speeds: [], global: 1).reduce(0) { $0 + $1.compDur } == 10, "×1 global : durée inchangée")
var gs = EditSettings(); gs.globalSpeed = 1.5
check((try? JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(gs)))?.globalSpeed == 1.5 && EditSettings().globalSpeed == 1, "vitesse globale relue, ×1 par défaut")
print(fails == 0 ? "OK : plan du montage (coupes, « euh », vitesses, vitesse globale, musique, srt)" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
