import AVFoundation

/// Le son du montage : voix débruitée, musique de fond qui s'efface sous la voix, sons de clic.
enum Audio {
    /// ffmpeg (Homebrew). nil = pas de débruitage, la piste d'origine est gardée sans rien dire.
    static var ffmpeg: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    // MARK: réduction du bruit

    static func cleanURL(_ video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).clean.m4a")
    }
    /// Voix débruitée déjà prête (nil sinon).
    static func cleaned(_ video: URL) -> URL? {
        FileManager.default.fileExists(atPath: cleanURL(video).path) ? cleanURL(video) : nil
    }
    /// Voix débruitée ; la prépare si besoin (une seule fois par vidéo). nil si ffmpeg absent ou pas de son.
    static func clean(_ video: URL) async -> URL? {
        if let u = cleaned(video) { return u }
        return await CleanStore.shared.run(video)
    }

    /// Filtre : coupe les graves (souffle, ventilation), puis débruitage FFT qui suit le bruit de fond.
    static let denoiseFilter = "highpass=f=70,afftdn=nr=14:nf=-30:tn=1"

    private actor CleanStore {
        static let shared = CleanStore()
        private var tasks: [URL: Task<URL?, Never>] = [:]
        func run(_ video: URL) async -> URL? {
            if let t = tasks[video] { return await t.value }
            let t = Task.detached(priority: .utility) { () -> URL? in
                let dst = Audio.cleanURL(video)
                let tmp = dst.deletingLastPathComponent().appendingPathComponent("\(video.lastPathComponent).clean-tmp.m4a")
                try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard await Audio.ffmpegRun(["-y", "-i", video.path, "-map", "0:a:0", "-vn", "-af", Audio.denoiseFilter,
                                             "-c:a", "aac", "-b:a", "160k", "-ar", "48000", tmp.path]) else {
                    try? FileManager.default.removeItem(at: tmp); return nil
                }
                try? FileManager.default.removeItem(at: dst)
                guard (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil else { return nil }
                return dst
            }
            tasks[video] = t
            let r = await t.value
            tasks[video] = nil
            return r
        }
    }

    /// Lance ffmpeg (priorité basse, pour ne pas ralentir le Mac) ; vrai si tout s'est bien passé.
    static func ffmpegRun(_ args: [String]) async -> Bool {
        guard let bin = ffmpeg else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .utility
        guard (try? p.run()) != nil else { return false }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        return p.terminationStatus == 0
    }

    // MARK: musique de fond

    static var musicFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/X-Videos", isDirectory: true)
    /// Morceaux du dossier ~/Music/X-Videos (créé s'il manque).
    static func musicFiles() -> [String] {
        try? FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        let exts: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]
        return ((try? FileManager.default.contentsOfDirectory(atPath: musicFolder.path)) ?? [])
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    }

    /// Volume de la musique dans le temps : `base` sous la voix, remonte (×2,5) dans les blancs de plus de 1,5 s,
    /// s'éteint sur la dernière seconde et demie. `speech` : passages parlés en temps du montage.
    static func musicKeyframes(speech: [Montage.Span], duration: Double, base: Double,
                               gapMin: Double = 1.5, ramp: Double = 0.4, fade: Double = 1.5) -> [(t: Double, v: Double)] {
        guard duration > 0 else { return [] }
        let high = min(1, base * 2.5)
        let talk = Montage.merge(speech.map { (max(0, $0.start), min(duration, $0.end)) }, gap: gapMin)
        // blancs assez longs pour laisser la musique remonter
        var gaps: [Montage.Span] = []
        var t = 0.0
        for s in talk { if s.start - t >= gapMin { gaps.append((t, s.start)) }; t = max(t, s.end) }
        if duration - t >= gapMin { gaps.append((t, duration)) }
        var pts: [(t: Double, v: Double)] = [(0, base)]
        for g in gaps {
            if g.start <= 0 { pts = [(0, high)] } else { pts += [(g.start, base), (g.start + ramp, high)] }
            if g.end < duration { pts += [(g.end - ramp, high), (g.end, base)] }
        }
        // fondu final
        let f0 = max(0, duration - fade)
        let level = value(pts, at: f0)
        pts = pts.filter { $0.t < f0 } + [(f0, level), (duration, 0)]
        return pts
    }

    static func value(_ pts: [(t: Double, v: Double)], at t: Double) -> Double {
        guard var prev = pts.first else { return 0 }
        for p in pts {
            if p.t >= t { return p.t == prev.t ? p.v : prev.v + (p.v - prev.v) * (t - prev.t) / (p.t - prev.t) }
            prev = p
        }
        return prev.v
    }

    /// Ajoute la musique (en boucle) sur toute la durée, avec son volume. Rien si le fichier est illisible.
    static func addMusic(_ file: URL, to comp: AVMutableComposition, duration: CMTime, keyframes: [(t: Double, v: Double)]) async -> AVMutableAudioMixInputParameters? {
        let asset = AVURLAsset(url: file)
        guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await src.load(.timeRange), range.duration.seconds > 0.5,
              let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var at = CMTime.zero
        while at < duration {
            let len = CMTimeMinimum(range.duration, duration - at)
            guard (try? track.insertTimeRange(CMTimeRange(start: range.start, duration: len), of: src, at: at)) != nil else { break }
            at = at + len
        }
        withExtendedLifetime(asset) {}
        let p = AVMutableAudioMixInputParameters(track: track)
        let cm = { (x: Double) in CMTime(seconds: x, preferredTimescale: 600) }
        if let f = keyframes.first { p.setVolume(Float(f.v), at: .zero) }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where b.t > a.t {
            p.setVolumeRamp(fromStartVolume: Float(a.v), toEndVolume: Float(b.v), timeRange: CMTimeRange(start: cm(a.t), end: cm(b.t)))
        }
        return p
    }

    // MARK: audios importés (voix off, sons) posés sur la frise

    static func audioFolder(_ video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/audio", isDirectory: true)
    }
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]

    /// Copie l'audio dans .meta/audio/ (reste valable si l'original bouge) ; rend le clip posé à `at` (temps source).
    static func importClip(_ src: URL, for video: URL, at: Double) async throws -> AudioClip {
        let dir = audioFolder(video)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension.lowercased()
        var dst = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) { dst = dir.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        try FileManager.default.copyItem(at: src, to: dst)
        let asset = AVURLAsset(url: dst)
        guard let t = try await asset.loadTracks(withMediaType: .audio).first else {
            try? FileManager.default.removeItem(at: dst)
            throw NSError(domain: "X-Videos", code: 5, userInfo: [NSLocalizedDescriptionKey: "Pas de son dans « \(src.lastPathComponent) »"])
        }
        let d = try await t.load(.timeRange).duration.seconds
        return AudioClip(file: dst.lastPathComponent, name: src.deletingPathExtension().lastPathComponent, at: max(0, at), dur: d)
    }

    /// Où joue chaque clip dans le montage : son instant source converti en temps du montage, coupé à la fin de la vidéo.
    static func placements(_ clips: [AudioClip], segments: [Renderer.Segment], duration: Double) -> [(clip: AudioClip, at: Double, len: Double)] {
        clips.compactMap { c in
            let at = Renderer.compTime(c.at, segments, duration: duration)
            let len = min(c.dur, duration - at)
            return len >= 0.05 ? (c, at, len) : nil
        }
    }

    /// Une piste par clip (ils peuvent se chevaucher), chacune à son volume. Les clips illisibles sont ignorés.
    static func addClips(_ placed: [(clip: AudioClip, at: Double, len: Double)], video: URL, to comp: AVMutableComposition) async -> [AVMutableAudioMixInputParameters] {
        var out: [AVMutableAudioMixInputParameters] = []
        for p in placed {
            let asset = AVURLAsset(url: audioFolder(video).appendingPathComponent(p.clip.file))
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await src.load(.timeRange),
                  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let len = CMTimeMinimum(CMTime(seconds: p.len, preferredTimescale: 48000), range.duration)
            guard (try? track.insertTimeRange(CMTimeRange(start: range.start, duration: len), of: src, at: CMTime(seconds: p.at, preferredTimescale: 48000))) != nil else {
                comp.removeTrack(track); continue
            }
            withExtendedLifetime(asset) {}
            let m = AVMutableAudioMixInputParameters(track: track)
            m.setVolume(Float(max(0, min(2, p.clip.volume))), at: .zero)
            out.append(m)
        }
        return out
    }

    // MARK: sons de clic

    /// Petit « tic » synthétisé une fois (WAV 48 kHz mono, 40 ms) dans ~/Library/Caches/X-Videos.
    static func clickSound() -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("X-Videos", isDirectory: true)
        let u = dir.appendingPathComponent("click-v1.wav")
        if FileManager.default.fileExists(atPath: u.path) { return u }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rate = 48000.0, n = Int(rate * 0.04)
        var pcm = Data(capacity: n * 2)
        var seed: UInt32 = 7
        for i in 0..<n {
            let t = Double(i) / rate
            seed = seed &* 1664525 &+ 1013904223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            // claquement bref (bruit) + petite résonance aiguë, enveloppe très courte
            let s = (0.35 * noise * exp(-t / 0.0015) + 0.6 * sin(2 * .pi * 3200 * t) * exp(-t / 0.006) + 0.3 * sin(2 * .pi * 1400 * t) * exp(-t / 0.01))
            let v = Int16(max(-1, min(1, s * 0.7)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var h = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); h.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
        h.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        return (try? (h + pcm).write(to: u)) != nil ? u : nil
    }

    /// Instants des clics (front montant du bouton), en temps source.
    static func clickTimes(_ track: CursorTracker.Track?) -> [Double] {
        var out: [Double] = []
        var was = false
        for s in track?.samples ?? [] {
            let down = s[3] > 0.5
            if down && !was { out.append(s[0]) }
            was = down
        }
        return out
    }

    /// Un son de clic à chaque instant (temps du montage) sur une piste à part.
    static func addClicks(at times: [Double], to comp: AVMutableComposition, duration: CMTime) async -> AVMutableAudioMixInputParameters? {
        guard !times.isEmpty, let u = clickSound() else { return nil }
        let asset = AVURLAsset(url: u)
        guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await src.load(.timeRange),
              let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var end = CMTime.zero
        for t in times.sorted() {
            let at = CMTime(seconds: t, preferredTimescale: 48000)
            guard at >= end, at + range.duration <= duration else { continue }      // pas de chevauchement, rien après la fin
            guard (try? track.insertTimeRange(range, of: src, at: at)) != nil else { continue }
            end = at + range.duration
        }
        withExtendedLifetime(asset) {}
        if end == .zero { comp.removeTrack(track); return nil }
        let p = AVMutableAudioMixInputParameters(track: track)
        p.setVolume(0.55, at: .zero)
        return p
    }
}
