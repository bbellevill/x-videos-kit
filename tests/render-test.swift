// Verrou (bug du 2026-10-10) : avec la bulle caméra ET les silences coupés, les arrondis de chaque morceau
// faisaient dépasser la piste caméra de la zone dessinée → montage invalide → aperçu noir dans l'éditeur.
// On rejoue les 30 vraies coupes de ce jour-là sur une vidéo de synthèse et on exige un montage valide.
import AVFoundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }
func sh(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args; p.standardError = nil; try! p.run(); p.waitUntilExit() }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xv-render-test-\(getpid())")
let meta = dir.appendingPathComponent(".meta")
try! FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
let video = dir.appendingPathComponent("v.mp4")
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x208:rate=240", "-f", "lavfi", "-i", "sine", "-t", "235.26", "-pix_fmt", "yuv420p", "-shortest", video.path])
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=192x108:rate=325/12", "-t", "234.08209", "-pix_fmt", "yuv420p", meta.appendingPathComponent("v.mp4.camera.mov").path])
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
try! FileManager.default.copyItem(at: fixture, to: Silence.cacheURL(video))
var rec = RecordingInfo(); rec.cameraFile = "v.mp4.camera.mov"; rec.cameraOffset = 1.1657400131225586; rec.save(for: video)

let sem = DispatchSemaphore(value: 0)
Task {
    var s = EditSettings(); s.captions = false; s.showCamera = true; s.removeSilences = true
    let b = try await Renderer.build(video: video, settings: s, renderSize: CGSize(width: 1280, height: 720))
    let end = b.videoComposition.instructions.last!.timeRange.end
    check(b.composition.tracks(withMediaType: .video).count == 2, "bulle caméra présente")
    check(b.silences.count > 20, "silences coupés (\(b.silences.count))")
    check(b.composition.tracks.allSatisfy { $0.timeRange.end <= end }, "aucune piste ne dépasse la zone dessinée")
    let ok = try await b.videoComposition.isValid(for: b.composition, timeRange: CMTimeRange(start: .zero, duration: b.composition.duration), validationDelegate: nil)
    check(ok, "montage valide (sinon aperçu noir)")
    sem.signal()
}
sem.wait()
try? FileManager.default.removeItem(at: dir)
print(fails == 0 ? "OK : aperçu avec caméra + silences coupés" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
