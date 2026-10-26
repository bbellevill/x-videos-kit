// Verrou (2026-10-10) : pause / reprise, sauvegarde anti-crash, son du Mac, import.
// Images et son synthétiques (pas d'écran filmé) passés au même écrivain que le vrai tournage.
import Foundation
import AVFoundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }
func near(_ a: Double, _ b: Double, _ tol: Double = 0.15) -> Bool { abs(a - b) <= tol }

// --- horloge de pause (pure)
var c = PauseClock()
c.origin = 100
c.pause(at: 102); c.resume(at: 105)
c.pause(at: 106); c.resume(at: 107)
check(c.map(99) == nil, "avant la 1re image : ignoré")
check(c.map(101) == 1, "avant la pause : inchangé")
check(c.map(103) == nil, "pendant la pause : jeté")
check(c.map(105.5) == 2.5, "après la pause : 3 s retirées")
check(c.map(108) == 4, "deux pauses : 4 s retirées")
check(c.pausedTotal == 4, "durée totale des pauses")
var c2 = PauseClock(); c2.pause(at: 5); c2.pause(at: 6); c2.resume(at: 7)
check(c2.pauses.count == 1 && c2.pauses[0].start == 5, "double pause ignorée")
// curseur : points recalés sur la vidéo, pause retirée, position tenue à la reprise
var c3 = PauseClock(); c3.origin = 100; c3.pause(at: 102); c3.resume(at: 105)
let cur = CursorTracker.retime([[99.5, 0.1, 0.1, 0, 0], [101, 0.2, 0.2, 0, 0], [103, 0.5, 0.5, 1, 0], [106, 0.6, 0.6, 0, 0]], clock: c3)
check(cur.map { $0[0] } == [0, 1, 2, 3], "curseur : horodatages décalés après la pause \(cur.map { $0[0] })")
check(cur.map { $0[1] } == [0.1, 0.2, 0.5, 0.6], "curseur : position tenue au début et à la reprise")
check((try? JSONDecoder().decode(PauseClock.self, from: JSONEncoder().encode(c))) == c, "horloge enregistrable (JSON)")

// --- échantillons synthétiques sur une fausse horloge machine
let W = 320, H = 240
func frame(_ t: Double, _ shade: UInt8) -> CMSampleBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!), Int32(shade), CVPixelBufferGetDataSize(pb!))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    var fmt: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fmt)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fmt!, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb!
}
func audio(_ t: Double, channels: Int = 1, n: Int = 1024) -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
                                           mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
    let bytes = n * 2 * channels
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                       offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    var samples = (0..<(n * channels)).map { i in Int16(sin(Double(i / channels) * 0.06) * 8000) }
    CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: n,
                                                         presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 48_000),
                                                         packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}
/// Alimente l'écrivain de `from` à `to` (secondes machine), images à 30 i/s et son, en appelant `at` à chaque image.
/// `micClock` : décalage de l'horloge du micro (0 = même horloge que l'écran).
func feed(_ w: CaptureWriter, from: Double, to: Double, system: Bool = false, micClock: Double = 0, at: (Double) -> Void = { _ in }) {
    var t = from, nextAudio = from
    var fakeNow = from
    w.now = { fakeNow }
    while t < to {
        fakeNow = t
        at(t)
        while nextAudio <= t {
            w.append(audio(nextAudio - micClock), .mic)
            if system { w.append(audio(nextAudio, channels: 2), .system) }
            nextAudio += 1024.0 / 48_000
        }
        w.append(frame(t, UInt8(Int(t * 10) % 255)), .video)
        usleep(4000)
        t += 1.0 / 30
    }
}
func run(_ body: @escaping () async throws -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { do { try await body() } catch { print("  erreur : \(error.localizedDescription)"); fails += 1 }; sem.signal() }
    sem.wait()
}
func duration(_ u: URL) async throws -> Double { try await AVURLAsset(url: u).load(.duration).seconds }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xvideos-capture-test-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

// --- 0. tournage réel sans fragments (bug du 2026-10-13 : l'écrivain cassait à chaque fragment, vidéo de 2 s)
check((try? CaptureWriter(url: dir.appendingPathComponent("frag.mp4"), width: W, height: H, fps: 30, mic: true, system: false))?.isFragmented == false,
      "tournage écrit sans fragments par défaut")

// --- 1. pause : 4 s filmées dont 1,5 s de pause → vidéo de 2,5 s
run {
    let u = dir.appendingPathComponent("pause.mp4")
    let w = try CaptureWriter(url: u, width: W, height: H, fps: 30, mic: true, system: false)
    feed(w, from: 1000, to: 1004) { t in
        if near(t, 1001.5, 0.017) { w.pause(at: t) }
        if near(t, 1003.0, 0.017) { w.resume(at: t) }
    }
    let clock = try await w.finish()
    let d = try await duration(u)
    check(near(d, 2.5), "pause retirée de la vidéo (\(String(format: "%.2f", d)) s au lieu de 4 s)")
    check(near(clock.pausedTotal, 1.5, 0.05), "horloge rendue avec la pause")
    let a = try await AVURLAsset(url: u).loadTracks(withMediaType: .audio)
    let ad = try await a.first?.load(.timeRange).duration.seconds ?? 0
    check(a.count == 1 && near(ad, 2.5, 0.2), "son coupé pendant la pause aussi (\(String(format: "%.2f", ad)) s)")
}

// --- 1 bis. micro horodaté sur une autre horloge : son recalé, pas jeté
run {
    let u = dir.appendingPathComponent("horloge.mp4")
    let w = try CaptureWriter(url: u, width: W, height: H, fps: 30, mic: true, system: false)
    feed(w, from: 2000, to: 2002, micClock: 1950)
    _ = try await w.finish()
    let a = try await AVURLAsset(url: u).loadTracks(withMediaType: .audio)
    let ad = try await a.first?.load(.timeRange).duration.seconds ?? 0
    check(near(ad, 2, 0.2), "micro sur une autre horloge : son gardé (\(String(format: "%.2f", ad)) s)")
}

// --- 1 ter. écriture cassée en plein tournage (bug du 2026-10-13 : vidéo de 2 s sans alerte) → signalée tout de suite, une seule fois
run {
    let u = dir.appendingPathComponent("casse.mp4")
    let w = try CaptureWriter(url: u, width: W, height: H, fps: 30, mic: true, system: false)
    var calls = 0
    var caught: Error?
    w.failQueue = DispatchQueue.global()   // le fil principal est bloqué par run()
    w.onFail = { e, _ in calls += 1; caught = e }
    feed(w, from: 3000, to: 3001)
    // une image en arrière dans le temps casse l'encodeur (protection coupée pour ce test)
    w.dropBackwards = false
    w.append(frame(3000.5, 9), .video)
    feed(w, from: 3001.5, to: 3002.5)
    try await Task.sleep(nanoseconds: 300_000_000)
    let failedAtEnd = (try? await w.finish()) == nil
    check(calls == 1 && caught != nil, "écriture cassée signalée une seule fois (\(calls) appel(s))")
    check(failedAtEnd, "fin du fichier en échec, pas un faux succès")
    let log = (try? String(contentsOf: CaptureLog.url, encoding: .utf8)) ?? ""
    check(log.contains("écriture cassée"), "cause écrite dans ~/Library/Logs/X-Videos.log")
}

// --- 1 quater. image en arrière dans le temps (cause probable du 2026-10-13) : jetée, le tournage continue
run {
    let u = dir.appendingPathComponent("arriere.mp4")
    let w = try CaptureWriter(url: u, width: W, height: H, fps: 30, mic: true, system: false)
    var calls = 0
    w.failQueue = DispatchQueue.global()
    w.onFail = { _, _ in calls += 1 }
    feed(w, from: 4000, to: 4002)
    w.append(frame(4000.5, 9), .video)
    w.append(audio(4000.5), .mic)
    feed(w, from: 4002.03, to: 4004)
    _ = try await w.finish()
    let d = try await duration(u)
    check(calls == 0 && near(d, 4), "image et son en arrière jetés, vidéo complète (\(String(format: "%.2f", d)) s sur 4 s)")
}

// --- 2. anti-crash : copie du fichier en plein tournage (= coupure) → récupérable
run {
    let u = dir.appendingPathComponent("crash.mp4")
    let w = try CaptureWriter(url: u, width: W, height: H, fps: 30, mic: true, system: false, fragment: 1)
    feed(w, from: 50, to: 55)
    try await Task.sleep(nanoseconds: 1_500_000_000)   // laisse l'encodeur écrire ses fragments
    // la copie = ce qui reste sur le disque après la coupure, avec son marqueur de tournage et sa caméra
    let looms = dir.appendingPathComponent("looms"); try FileManager.default.createDirectory(at: looms, withIntermediateDirectories: true)
    let crashed = looms.appendingPathComponent("X-Videos coupée.mp4")
    try FileManager.default.copyItem(at: u, to: crashed)
    w.cancel()
    try FileManager.default.createDirectory(at: looms.appendingPathComponent(".meta"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: crashed, to: looms.appendingPathComponent(".meta/X-Videos coupée.mp4.camera.mov"))
    Recovery.mark(crashed, RecordingMarker(started: Date(), cameraFile: "X-Videos coupée.mp4.camera.mov", cameraOffset: 0.2,
                                           bubbleX: 0.2, bubbleY: 0.8, bubbleSize: 0.2))
    Recovery.mark(looms.appendingPathComponent("disparue.mp4"), RecordingMarker(started: Date()))
    check(Recovery.pending(in: looms).map { $0.lastPathComponent } == ["X-Videos coupée.mp4", "disparue.mp4"], "tournages inachevés repérés au lancement")
    let d = await Recovery.recover(crashed)
    check((d ?? 0) >= 2, "tournage coupé récupéré (\(String(format: "%.1f", d ?? 0)) s sur 5 s)")
    let v = try await AVURLAsset(url: crashed).loadTracks(withMediaType: .video)
    check(v.count == 1, "image présente dans la vidéo récupérée")
    let rec = RecordingInfo.load(for: crashed)
    check(rec?.cameraFile == "X-Videos coupée.mp4.camera.mov" && rec?.cameraOffset == 0.2 && rec?.bubbleX == 0.2, "caméra rattachée à la vidéo récupérée")
    let gone = await Recovery.recover(looms.appendingPathComponent("disparue.mp4"))
    check(gone == nil && Recovery.pending(in: looms).isEmpty, "marqueurs retirés après récupération")
}

// --- 3. son du Mac : piste séparée, puis mixée avec la voix
run {
    let u = dir.appendingPathComponent("son.mp4")
    let w = try CaptureWriter(url: u, width: W, height: H, fps: 30, mic: true, system: true)
    feed(w, from: 10, to: 12, system: true)
    _ = try await w.finish()
    let sep = try await AVURLAsset(url: u).loadTracks(withMediaType: .audio)
    check(sep.count == 2, "son du Mac en piste séparée (2 pistes son)")
    let d = try await MovieTools.rewriteInPlace(u, mixAudio: true)
    let mixed = try await AVURLAsset(url: u).loadTracks(withMediaType: .audio)
    check(mixed.count == 1 && near(d, 2), "son du Mac mixé avec la voix (1 piste, \(String(format: "%.2f", d)) s)")
}

// --- 4. import : un MOV devient un MP4 dans le dossier, sans écraser un fichier existant
run {
    let mov = dir.appendingPathComponent("Démo client.mov")
    let wr = try AVAssetWriter(outputURL: mov, fileType: .mov)
    let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H])
    wr.add(vi); wr.startWriting(); wr.startSession(atSourceTime: .zero)
    for i in 0..<45 {
        while !vi.isReadyForMoreMediaData { usleep(1000) }
        vi.append(frame(Double(i) / 30, UInt8(i * 5)))
    }
    vi.markAsFinished(); await wr.finishWriting()
    let lib = dir.appendingPathComponent("Mes looms"); try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: lib.appendingPathComponent("Démo client.mp4").path, contents: Data())
    let out = try await MovieTools.importVideo(mov, into: lib)
    check(out.lastPathComponent == "Démo client 2.mp4", "nom libre trouvé (\(out.lastPathComponent))")
    let d = try await duration(out)
    check(near(d, 1.5), "MOV importé en MP4 lisible (\(String(format: "%.2f", d)) s)")
}

print(fails == 0 ? "OK : pause, anti-crash, son du Mac, import" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
