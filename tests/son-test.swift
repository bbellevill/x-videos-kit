// Verrou (2026-10-10) : son et montage sur une vraie composition (vidéo de synthèse ffmpeg) —
// voix débruitée (et repli sans ffmpeg), coupes + « euh » + accélération (temps calés sur AVFoundation),
// musique et clics présents, aperçu AVPlayer qui produit des images, export 720p 60 i/s en H.264.
import AVFoundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }
func sh(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args; p.standardError = nil; try! p.run(); p.waitUntilExit() }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xv-son-test-\(getpid())")
let meta = dir.appendingPathComponent(".meta")
try! FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let video = dir.appendingPathComponent("v.mp4")
// voix de synthèse : un son + du souffle
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x208:rate=30", "-f", "lavfi", "-i", "sine=f=220",
    "-f", "lavfi", "-i", "anoisesrc=a=0.05", "-filter_complex", "[1][2]amix=inputs=2[a]", "-map", "0:v", "-map", "[a]",
    "-t", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path])
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=192x108:rate=325/12", "-t", "29.5", "-pix_fmt", "yuv420p", meta.appendingPathComponent("v.mp4.camera.mov").path])
var rec = RecordingInfo(); rec.cameraFile = "v.mp4.camera.mov"; rec.cameraOffset = 0.37; rec.save(for: video)
// silences, mots (avec un « euh »), frappe, clics
try! JSONEncoder().encode([Silence.Run(start: 2, end: 3), Silence.Run(start: 24, end: 25)]).write(to: Silence.cacheURL(video))
try! JSONEncoder().encode([Captions.Word(text: "Alors", start: 7.5, end: 7.9), Captions.Word(text: "euh", start: 8, end: 8.4),
                           Captions.Word(text: "regarde", start: 8.5, end: 9), Captions.Word(text: "ici.", start: 15, end: 15.5)]).write(to: Captions.cacheURL(video))
try! #"{"events":[{"t":18,"typing":true},{"t":18.6,"typing":true},{"t":19.5,"typing":true},{"t":20.4,"typing":true},{"t":21,"typing":true}]}"#
    .write(to: Montage.keysURL(video), atomically: true, encoding: .utf8)
let clicks = [[0, 0.5, 0.5, 0, 0], [4, 0.5, 0.5, 1, 0], [4.1, 0.5, 0.5, 0, 0], [5.5, 0.4, 0.4, 1, 0], [5.6, 0.4, 0.4, 0, 0], [11, 0.3, 0.3, 1, 0], [11.1, 0.3, 0.3, 0, 0]]
try! JSONEncoder().encode(CursorTracker.Track(screenWidth: 1440, screenHeight: 900, samples: clicks)).write(to: CursorTracker.url(for: video))
// musique dans un dossier de test (pas dans ~/Music)
Audio.musicFolder = dir.appendingPathComponent("music")
try! FileManager.default.createDirectory(at: Audio.musicFolder, withIntermediateDirectories: true)
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=f=440", "-t", "7", "-c:a", "aac", Audio.musicFolder.appendingPathComponent("douce.m4a").path])

/// Temps source réel d'un instant du montage, lu dans la composition elle-même (ce que joue AVFoundation).
func avSource(_ track: AVCompositionTrack, _ c: Double) -> Double? {
    guard let seg = track.segment(forTrackTime: CMTime(seconds: c, preferredTimescale: 600)), !seg.isEmpty else { return nil }
    let s = seg.timeMapping.source, t = seg.timeMapping.target
    return s.start.seconds + (c - t.start.seconds) * s.duration.seconds / t.duration.seconds
}

var done = false
Task {
    do {
        // 1. réduction du bruit
        let saved = Audio.ffmpeg
        Audio.ffmpeg = nil
        check(await Audio.clean(video) == nil, "sans ffmpeg : pas de débruitage, pas d'erreur")
        Audio.ffmpeg = saved
        let clean = await Audio.clean(video)
        check(clean != nil && FileManager.default.fileExists(atPath: Audio.cleanURL(video).path), "voix débruitée mise en cache (.clean.m4a)")
        let cd = try await AVURLAsset(url: Audio.cleanURL(video)).load(.duration).seconds
        check(abs(cd - 30) < 0.2, "voix débruitée de même durée (\(cd))")

        var s = EditSettings()
        s.cuts = [CutRange(start: 5, end: 6)]
        s.speedRanges = [SpeedRange(start: 10, end: 14, speed: 2)]
        s.music = "douce.m4a"
        s.clickSounds = true
        let b = try await Renderer.build(video: video, settings: s, renderSize: CGSize(width: 1280, height: 720))
        check(b.cleanAudio, "le montage utilise la voix débruitée")
        check(b.composition.tracks(withMediaType: .video).count == 2, "bulle caméra présente")
        var s0 = s; s0.noiseReduction = false
        check(!(try await Renderer.build(video: video, settings: s0, renderSize: CGSize(width: 1280, height: 720))).cleanAudio, "réglage coupé : voix d'origine")

        // 2-4. coupes, « euh », vitesses
        check(b.fillerCuts.count == 1 && abs(b.fillerCuts[0].start - 8) < 0.01, "« euh » coupé")
        check(b.speeds.contains { $0.speed == 3 && abs($0.start - 17.9) < 0.01 }, "frappe accélérée ×3")
        check(!Renderer.isKept(5.5, b.segments) && !Renderer.isKept(8.2, b.segments) && !Renderer.isKept(2.5, b.segments), "coupe du texte, « euh » et silence retirés")
        let expected = 30 - 1 - 1 - 1 - 0.4 - 2 - (21.3 - 17.9) * 2 / 3
        check(abs(b.duration - expected) < 0.05, "durée finale (\(b.duration) ≈ \(expected))")
        check(abs(b.composition.duration.seconds - b.duration) < 0.05, "composition de la même durée (\(b.composition.duration.seconds))")
        let screen = b.composition.track(withTrackID: EditInstruction.screenTrack)!
        var worst = 0.0
        for c in stride(from: 0.05, to: b.duration - 0.1, by: 0.1) {
            if let src = avSource(screen, c) { worst = max(worst, abs(src - b.sourceTime(c))) } else { worst = 99 }
        }
        check(worst < 0.03, "temps du montage → source identique à AVFoundation (écart max \(String(format: "%.4f", worst)) s)")
        check(abs(b.compTime(12) - b.compTime(10) - 1) < 1e-6, "×2 : 2 s de source = 1 s de vidéo")

        // 5-6. musique et clics
        let audio = b.composition.tracks(withMediaType: .audio)
        check(audio.count == 3, "voix + musique + clics (\(audio.count) pistes son)")
        check((b.audioMix?.inputParameters.count ?? 0) == 2, "volumes de la musique et des clics")
        // musique : commence tout de suite ; clics : piste qui commence par un blanc
        if let music = audio.first(where: { $0.trackID != 2 && $0.segments.first?.isEmpty == false }) {
            check(abs(music.timeRange.end.seconds - b.composition.duration.seconds) < 0.05, "musique en boucle jusqu'à la fin")
        } else { check(false, "piste musique") }
        let clickTrack = audio.first { $0.trackID != 2 && $0.segments.first?.isEmpty == true }
        check(clickTrack?.segments.filter { !$0.isEmpty }.count == 2, "2 clics gardés (le clic dans la coupe saute)")

        // aperçu : montage valide et AVPlayer qui produit des images, y compris dans un passage accéléré
        let ok = try await b.videoComposition.isValid(for: b.composition, timeRange: CMTimeRange(start: .zero, duration: b.composition.duration), validationDelegate: nil)
        check(ok, "montage valide (sinon aperçu noir)")
        let item = AVPlayerItem(asset: b.composition)
        item.videoComposition = b.videoComposition
        item.audioMix = b.audioMix
        item.audioTimePitchAlgorithm = .spectral
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0..<100 where item.status != .readyToPlay { try await Task.sleep(nanoseconds: 50_000_000) }
        check(item.status == .readyToPlay, "aperçu prêt (\(item.error?.localizedDescription ?? "sans erreur"))")
        await player.seek(to: CMTime(seconds: b.compTime(11), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        var frames = 0
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 25_000_000)
            let t = out.itemTime(forHostTime: CACurrentMediaTime())
            if out.hasNewPixelBuffer(forItemTime: t), out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil { frames += 1 }
        }
        player.pause()
        check(frames >= 10, "lecture : \(frames) images produites dans le passage accéléré")

        // 7-8. export 720p 60 i/s, H.264
        var e = s; e.exportHeight = 720; e.exportFPS = 60; e.captionStyle = "karaoke"
        let dst = dir.appendingPathComponent("out.mp4")
        try await Renderer.export(video: video, settings: e, to: dst) { _ in }
        let ex = AVURLAsset(url: dst)
        let vt = try await ex.loadTracks(withMediaType: .video).first!
        let size = try await vt.load(.naturalSize), fps = try await vt.load(.nominalFrameRate)
        let codec = try await vt.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        check(size == CGSize(width: 1280, height: 720), "export 720p (\(size))")
        check(fps > 55, "export 60 i/s (\(fps))")
        check(codec == kCMVideoCodecType_H264, "export H.264")
        check(try await ex.loadTracks(withMediaType: .audio).count == 1, "son mixé dans une seule piste")
        let exd = try await ex.load(.duration).seconds
        check(abs(exd - b.duration) < 0.1, "export de la bonne durée (\(exd))")
        check(Renderer.exportSize({ var x = EditSettings(); x.exportHeight = 2160; return x }()) == CGSize(width: 3840, height: 2160), "4K = 3840×2160")
    } catch { check(false, "erreur : \(error.localizedDescription)") }
    done = true
}
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
print(fails == 0 ? "OK : son et montage (débruitage, coupes, vitesses, musique, clics, aperçu, export)" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
