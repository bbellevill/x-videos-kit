// Verrou des sous-titres : jetons Whisper → mots, « x tableau » → « XTablo », lignes courtes sans chevauchement.
import Foundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }

let json = #"""
{"transcription":[{"offsets":{"from":0,"to":3000},"tokens":[
 {"text":"[_BEG_]","offsets":{"from":0,"to":0}},
 {"text":" ok","offsets":{"from":0,"to":400}},
 {"text":" l","offsets":{"from":500,"to":600}},{"text":"'","offsets":{"from":600,"to":650}},{"text":"éc","offsets":{"from":650,"to":800}},{"text":"ran","offsets":{"from":800,"to":1000}},
 {"text":" x","offsets":{"from":1100,"to":1200}},{"text":" tableau.","offsets":{"from":1200,"to":1600}},
 {"text":" voilà","offsets":{"from":2600,"to":3000}}]}]}
"""#
let words = Captions.parse(Data(json.utf8))
check(words.map(\.text) == ["ok", "l'écran", "x", "tableau.", "voilà"], "jetons regroupés en mots")
check(words[1].start == 0.5 && words[1].end == 1.0, "instants des mots")
let fixed = Captions.Vocab(words: [], replacements: ["x tableau": "XTablo"]).apply(words)
check(fixed.map(\.text) == ["ok", "l'écran", "XTablo.", "voilà"], "remplacement du dictionnaire (ponctuation gardée)")
let lines = Captions.lines(fixed)
check(lines.count == 2, "coupure après le point")
check(lines[0].end <= lines[1].start, "pas de chevauchement")
let long = (0..<20).map { Captions.Word(text: "mot\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
check(Captions.lines(long).allSatisfy { $0.words.map(\.text.count).reduce(0, +) + $0.words.count - 1 <= 32 }, "lignes ≤ 32 caractères")
// styles de sous-titres (2026-10-10) : chacun dessine une image
for st in CaptionLayer.styles.map(\.id) {
    let layer = CaptionLayer(words: fixed, renderSize: CGSize(width: 1280, height: 720), bottomY: 40, style: st)
    check(layer.image(at: 0.6).map { $0.extent.width > 50 } ?? false, "style « \(st) » dessiné")
}
check(Captions.srt(words: fixed).hasPrefix("1\n00:00:00,000 --> "), "fichier .srt")
print(fails == 0 ? "OK : sous-titres découpés correctement" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
