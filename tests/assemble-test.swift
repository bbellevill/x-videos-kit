// Verrou (2026-10-11) : vidéos bout à bout et audios importés (demande de Baptiste : « importer une vidéo,
// des audios, et éditer pour créer une vidéo »). Repères, fin coupée gardée, assemblage de 2 tailles différentes,
// ajout puis retour en arrière, voix off posée au bon instant malgré une coupe, son d'origine coupé, export lisible.
import AVFoundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }
func sh(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args; p.standardError = nil; try! p.run(); p.waitUntilExit() }

// 1. fonctions pures
let p = Assemble.partsAfterAppend([], firstName: "Démo", oldDuration: 10, added: [("B", 4), ("C", 6)])
check(p == [Assemble.Part(name: "Démo", start: 0), Assemble.Part(name: "B", start: 10), Assemble.Part(name: "C", start: 14)], "repères : vidéo d'avant + un par clip")
let p2 = Assemble.partsAfterAppend(p, firstName: "x", oldDuration: 20, added: [("D", 3)])
check(p2.count == 4 && p2[3].start == 20 && p2[0].name == "Démo", "repères existants gardés au 2e ajout")
var es = EditSettings(); es.trimStart = 1; es.trimEnd = 2
let es2 = Assemble.settingsAfterAppend(es, oldDuration: 10)
check(es2.trimEnd == 0 && es2.cuts == [CutRange(start: 8, end: 10)] && es2.trimStart == 1, "fin coupée → passage coupé (la vidéo ajoutée n'est pas rognée)")
check(Assemble.settingsAfterAppend(EditSettings(), oldDuration: 10).cuts == nil, "sans fin coupée : réglages inchangés")
let segs = [Renderer.Segment(comp: 0, src: 0, dur: 5), Renderer.Segment(comp: 5, src: 8, dur: 12)]   // 5→8 coupé
let pl = Audio.placements([AudioClip(file: "a", name: "a", at: 10, dur: 3), AudioClip(file: "b", name: "b", at: 18, dur: 5),
                           AudioClip(file: "c", name: "c", at: 19.99, dur: 1)], segments: segs, duration: 17)
check(pl.count == 2 && abs(pl[0].at - 7) < 1e-9 && pl[0].len == 3, "voix off suit son image après une coupe (10 s source → 7 s)")
check(abs(pl[1].at - 15) < 1e-9 && abs(pl[1].len - 2) < 1e-9, "voix off coupée à la fin de la vidéo")
let json = try! JSONEncoder().encode(es2)
check((try? JSONDecoder().decode(EditSettings.self, from: #"{"trimStart":1}"#.data(using: .utf8)!))?.audioClips == nil, "anciens réglages relus sans audios")
var withClip = EditSettings(); withClip.audioClips = [AudioClip(file: "v.m4a", name: "Voix", at: 2, dur: 3, volume: 0.8)]; withClip.muteOriginal = true
let back = try! JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(withClip))
check(back.audioClips == withClip.audioClips && back.muteOriginal && json.count > 0, "audios et son coupé enregistrés puis relus")

// 2. sur de vrais fichiers
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xv-assemble-test-\(getpid())")
try! FileManager.default.createDirectory(at: dir.appendingPathComponent(".meta"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let a = dir.appendingPathComponent("A.mp4"), b = dir.appendingPathComponent("B.mov"), voice = dir.appendingPathComponent("voix.wav")
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=f=220",
    "-t", "6", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", a.path])
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=360x640:rate=30", "-t", "4", "-pix_fmt", "yuv420p", b.path])   // vertical, sans son
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=f=660", "-t", "3", voice.path])

var done = false
Task {
    do {
        // sauvegarde de réglages avec fin coupée, puis ajout à la suite
        var s = EditSettings(); s.trimEnd = 1; s.save(for: a)
        try "[]".write(to: Assemble.meta(a, "captions.json"), atomically: true, encoding: .utf8)
        try await Assemble.append([b], to: a)
        let asset = AVURLAsset(url: a)
        let d = try await asset.load(.duration).seconds
        check(abs(d - 10) < 0.15, "A (6 s) + B (4 s) = \(String(format: "%.2f", d)) s")
        let vt = try await asset.loadTracks(withMediaType: .video).first!
        check(try await vt.load(.naturalSize) == CGSize(width: 640, height: 360), "taille du premier clip gardée (B vertical mis en bandes noires)")
        check(try await !asset.loadTracks(withMediaType: .audio).isEmpty, "son de A gardé")
        check(Assemble.parts(of: a).map(\.name) == ["A", "B"] && abs(Assemble.parts(of: a)[1].start - 6) < 0.1, "repères A puis B à 6 s")
        let s2 = EditSettings.load(for: a)
        check(s2.trimEnd == 0 && s2.cuts?.first.map { abs($0.start - 5) < 0.1 && abs($0.end - 6) < 0.1 } == true, "fin coupée de A devenue un passage coupé 5–6 s")
        check(!FileManager.default.fileExists(atPath: Assemble.meta(a, "captions.json").path), "transcription de l'ancien fichier effacée (sera refaite)")
        check(Assemble.canUndo(a), "retour en arrière possible")

        // voix off posée à 7 s (dans B), son d'origine coupé → montage valide, voix seule
        var e = s2
        e.removeSilences = false; e.captions = false; e.removeFillers = false; e.noiseReduction = false
        e.audioClips = [try await Audio.importClip(voice, for: a, at: 7)]
        e.muteOriginal = true
        check(FileManager.default.fileExists(atPath: Audio.audioFolder(a).appendingPathComponent("voix.wav").path), "audio copié dans .meta/audio")
        check(abs(e.audioClips![0].dur - 3) < 0.05, "durée de l'audio lue (3 s)")
        let built = try await Renderer.build(video: a, settings: e, renderSize: CGSize(width: 640, height: 360))
        let at = built.composition.tracks(withMediaType: .audio)
        check(at.count == 1, "son d'origine coupé : seule la voix off reste (\(at.count) piste)")
        let seg = at.first?.segments.first { !$0.isEmpty }
        check(seg.map { abs($0.timeMapping.target.start.seconds - 6) < 0.05 } == true, "voix off à 6 s du montage (7 s source, 5–6 coupé)")
        let ex = dir.appendingPathComponent("export.mp4")
        try await Renderer.export(video: a, settings: e, to: ex) { _ in }
        let exA = AVURLAsset(url: ex)
        check(try await exA.load(.duration).seconds > 8.5, "export lisible avec la voix off")
        check(try await !exA.loadTracks(withMediaType: .audio).isEmpty, "export : piste son présente")

        // retour en arrière
        try Assemble.undoAppend(a)
        let d0 = try await AVURLAsset(url: a).load(.duration).seconds
        check(abs(d0 - 6) < 0.15 && EditSettings.load(for: a).trimEnd == 1 && Assemble.parts(of: a).isEmpty, "dernier ajout retiré : A, réglages et repères d'avant")

        // réordonner (2026-10-14) : A + B + A2 → B en 2e reste… on échange les morceaux 2 et 3, puis on retire le 2e
        let sp = [(start: 0.0, end: 6.0), (start: 6.0, end: 10.0), (start: 10.0, end: 13.0)]
        check(Assemble.remap(7, spans: sp, order: [0, 2, 1]) == 10, "instant 7 s (dans B) → 10 s quand B passe en dernier")
        check(Assemble.remap(11, spans: sp, order: [0, 2, 1]).map { abs($0 - 7) < 0.001 } == true, "instant 11 s (3e morceau) → 7 s")
        check(Assemble.remap(7, spans: sp, order: [0, 2]) == nil, "morceau retiré : instant perdu")
        check(Assemble.remapRange(5, 8, spans: sp, order: [0, 2, 1]).map { $0.0 == 9 && $0.1 == 11 } == true, "plage à cheval rognée à son morceau (5–8 → B 6–8 → 9–11)")
        var rs = EditSettings(); rs.zooms = [ZoomSegment(start: 7, end: 8)]; rs.cuts = [CutRange(start: 11, end: 12)]; rs.trimEnd = 0.5
        let ps = [Assemble.Part(name: "A", start: 0), Assemble.Part(name: "B", start: 6), Assemble.Part(name: "C", start: 10)]
        let r2 = Assemble.settingsAfterRearrange(rs, parts: ps, duration: 13, order: [0, 2, 1])
        check(r2.zooms?.first.map { $0.start == 10 && $0.end == 11 } == true, "zoom suit son morceau (7–8 → 10–11)")
        check(r2.cuts?.contains { abs($0.start - 7) < 0.001 && abs($0.end - 8) < 0.001 } == true, "coupe suit son morceau (11–12 → 7–8)")
        check(r2.cuts?.contains { abs($0.start - 8.5) < 0.001 && abs($0.end - 9) < 0.001 } == true, "fin coupée devenue passage coupé, déplacée avec C")
        check(Assemble.partsAfterRearrange(ps, duration: 13, order: [0, 2, 1]).map { "\($0.name)@\(Int($0.start))" } == ["A@0", "C@6", "B@9"], "repères recalculés")

        try await Assemble.append([b, b], to: a)            // A (6 s) + B (4 s) + B (4 s)
        try await Assemble.rearrange(a, order: [0, 2])     // retire le 2e morceau
        let dr = try await AVURLAsset(url: a).load(.duration).seconds
        check(abs(dr - 10) < 0.2 && Assemble.parts(of: a).count == 2, "morceau retiré : 10 s, 2 repères (\(String(format: "%.2f", dr)) s)")
        try Assemble.undoAppend(a)
        check(abs(try await AVURLAsset(url: a).load(.duration).seconds - 14) < 0.2, "annuler : les 3 morceaux reviennent")

        // import de plusieurs vidéos en une seule
        let one = dir.appendingPathComponent("un.mp4")
        let aDur = try await AVURLAsset(url: a).load(.duration).seconds
        let durs = try await Assemble.concat([b, a], to: one)
        let oneDur = try await AVURLAsset(url: one).load(.duration).seconds
        check(durs.count == 2 && abs(oneDur - (4 + aDur)) < 0.15, "import assemblé : B + A en une vidéo")
    } catch { check(false, "erreur : \(error)") }
    done = true
}
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
print(fails == 0 ? "assemble-test : tout est bon" : "assemble-test : \(fails) échec(s)")
exit(fails == 0 ? 0 : 1)
