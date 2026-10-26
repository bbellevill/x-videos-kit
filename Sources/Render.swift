import AVFoundation
import CoreImage

/// Construit le montage (coupes + écran + caméra + zooms) et l'exporte en MP4 1080p prêt pour le web.
enum Renderer {
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let duration: Double           // durée après coupes
        let sourceDuration: Double
        let zooms: [ZoomSegment]
        let segments: [Segment]        // morceaux gardés (après coupes et silences)
        let silences: [Silence.Run]
        let captionWords: [Captions.Word]
        var audioMix: AVAudioMix? = nil      // volumes de la musique et des clics
        var fillerCuts: [CutRange] = []      // « euh » coupés (temps source, pour la frise)
        var speeds: [SpeedRange] = []        // passages accélérés (à la main + frappe), temps source
        var cleanAudio = false               // voix débruitée utilisée

        /// Temps source → temps du montage (pour se placer sur la frise).
        func compTime(_ src: Double) -> Double { Renderer.compTime(src, segments, duration: duration) }
        /// Temps du montage → temps source.
        func sourceTime(_ c: Double) -> Double { Renderer.sourceTime(c, segments) }
    }

    /// Morceau gardé : `dur` secondes de la source à partir de `src`, joué à `speed` à partir de `comp` dans le montage.
    struct Segment {
        let comp: Double; let src: Double; let dur: Double
        var speed: Double = 1
        var compDur: Double { dur / speed }
    }

    static func compTime(_ src: Double, _ segs: [Segment], duration: Double) -> Double {
        for s in segs where src < s.src + s.dur { return s.comp + max(0, src - s.src) / s.speed }
        return duration
    }

    static func sourceTime(_ c: Double, _ segs: [Segment]) -> Double {
        for s in segs where c < s.comp + s.compDur { return s.src + max(0, c - s.comp) * s.speed }
        if let l = segs.last { return l.src + l.dur }
        return c
    }

    /// Vrai si l'instant source est gardé dans le montage (ni coupé, ni silence).
    static func isKept(_ src: Double, _ segs: [Segment]) -> Bool {
        segs.contains { src >= $0.src && src < $0.src + $0.dur }
    }

    /// Taille de l'export (16:9) selon la qualité choisie : 720p, 1080p ou 4K.
    static func exportSize(_ s: EditSettings) -> CGSize {
        let h = [720, 1080, 2160].contains(s.exportHeight) ? s.exportHeight : 1080
        return CGSize(width: h * 16 / 9, height: h)
    }

    /// `waitCaptions` : l'export attend la transcription ; l'aperçu prend ce qui est prêt et se recalcule ensuite.
    static func build(video: URL, settings: EditSettings, renderSize: CGSize, waitCaptions: Bool = false, fps: Int = 30) async throws -> Built {
        let asset = AVURLAsset(url: video)
        let srcDur = try await asset.load(.duration).seconds
        guard let sv = try await asset.loadTracks(withMediaType: .video).first else { throw err("pas d'image dans la vidéo") }
        // son d'origine coupé : la piste n'entre pas dans le montage
        var sa = settings.muteOriginal ? nil : try await asset.loadTracks(withMediaType: .audio).first
        // voix débruitée (préparée par ffmpeg) à la place de la piste d'origine ; repli silencieux sinon
        var cleanAudio = false
        var cleanAsset: AVURLAsset?          // gardé en vie : une piste dont l'asset est libéré ne s'insère plus
        if sa != nil, settings.noiseReduction, let u = waitCaptions ? await Audio.clean(video) : Audio.cleaned(video) {
            cleanAsset = AVURLAsset(url: u)
            if let ca = try? await cleanAsset!.loadTracks(withMediaType: .audio).first { sa = ca; cleanAudio = true }
        }
        let saRange = try await sa?.load(.timeRange)
        let srcSize = try await sv.load(.naturalSize)

        let start = max(0, min(settings.trimStart, srcDur - 0.5))
        let end = max(start + 0.5, srcDur - max(0, settings.trimEnd))
        let ts: CMTimeScale = 600
        func cm(_ x: Double) -> CMTime { CMTime(seconds: x, preferredTimescale: ts) }

        // mots transcrits : sous-titres et mots parasites (l'export attend Whisper, l'aperçu prend ce qui est prêt)
        var allWords: [Captions.Word] = []
        if (settings.captions || settings.removeFillers) && !settings.muteOriginal {
            allWords = waitCaptions ? await Captions.words(for: video) : (Captions.cached(for: video) ?? [])
        }

        // morceaux gardés : [début, fin] moins les silences, les « euh » et les coupes faites dans le texte
        let silences = settings.removeSilences && !settings.muteOriginal ? await Silence.cuts(for: video) : []
        let fillers = settings.removeFillers ? Montage.fillerCuts(allWords) : []
        let removed = Montage.merge(silences.map { ($0.start, $0.end) } + fillers + (settings.cuts ?? []).map { ($0.start, $0.end) })
        var keep = Montage.keep(start: start, end: end, cuts: removed)
        if keep.isEmpty { keep = [(start, end)] }
        // vitesses : plages choisies à la main d'abord (elles gagnent), puis la frappe au clavier
        let speeds = (settings.speedRanges ?? []) + (settings.speedUpTyping ? Montage.typingRanges(for: video) : [])
        let segments = Montage.plan(keep: keep, speeds: speeds, global: settings.globalSpeed)
        // on monte d'abord tout à vitesse 1, puis on accélère les passages concernés (toutes les pistes ensemble)
        var flat: [Segment] = []
        var at = 0.0
        for sg in segments { flat.append(Segment(comp: at, src: sg.src, dur: sg.dur)); at += sg.dur }

        let comp = AVMutableComposition()
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: EditInstruction.screenTrack)!
        let a = sa != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: 2) : nil
        for sg in flat {
            let r = CMTimeRange(start: cm(sg.src), duration: cm(sg.dur))
            try v.insertTimeRange(r, of: sv, at: cm(sg.comp))
            if let sa = sa, let a = a, let ar = saRange {
                // la voix débruitée peut finir quelques ms avant l'image : on ne lit jamais au-delà
                let ra = r.intersection(ar)
                if ra.duration > .zero { try a.insertTimeRange(ra, of: sa, at: cm(sg.comp) + (ra.start - r.start)) }
            }
        }
        withExtendedLifetime(cleanAsset) {}

        // caméra enregistrée à part : on l'aligne sur l'écran grâce au décalage mesuré au tournage
        let rec = RecordingInfo.load(for: video) ?? RecordingInfo()
        var hasCamera = false
        if settings.wantsCamera, let camName = rec.cameraFile {
            let camURL = video.deletingLastPathComponent().appendingPathComponent(".meta/\(camName)")
            let camAsset = AVURLAsset(url: camURL)
            if FileManager.default.fileExists(atPath: camURL.path),
               let cv = try? await camAsset.loadTracks(withMediaType: .video).first,
               let c = comp.addMutableTrack(withMediaType: .video, preferredTrackID: EditInstruction.cameraTrack) {
                let camDur = try await camAsset.load(.duration).seconds
                let off = rec.cameraOffset
                for sg in flat {
                    let cStart = max(0, sg.src - off), cEnd = min(camDur, sg.src + sg.dur - off)
                    guard cEnd - cStart > 0.05 else { continue }
                    let place = cm(sg.comp + (cStart + off - sg.src))
                    // jamais au-delà du morceau d'écran : les arrondis cumulés rendaient le montage invalide (aperçu noir)
                    let len = CMTimeMinimum(cm(cEnd) - cm(cStart), cm(sg.comp) + cm(sg.dur) - place)
                    guard len > .zero else { continue }
                    try c.insertTimeRange(CMTimeRange(start: cm(cStart), duration: len), of: cv, at: place)
                    hasCamera = true
                }
            }
        }

        // accélération : du dernier au premier, pour ne pas décaler les passages encore à traiter
        for (f, sg) in zip(flat, segments).reversed() where sg.speed != 1 {
            comp.scaleTimeRange(CMTimeRange(start: cm(f.comp), duration: cm(f.dur)), toDuration: cm(sg.compDur))
        }

        let track = CursorTracker.load(for: video)
        let zooms = settings.autoZoom ? (settings.zooms ?? AutoZoom.segments(from: track, duration: srcDur)) : []
        let path = AutoZoom.bake(zooms: zooms, track: track, duration: srcDur)

        // curseur redessiné (seulement si le tournage l'a enregistré à part)
        var cPath: CursorPath.Path?
        var cImgs: [(img: CIImage, info: CursorTracker.CursorImage)] = []
        if let track = track, let cursors = track.cursors {
            let dir = video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).cursors")
            for c in cursors {
                if let img = CIImage(contentsOf: dir.appendingPathComponent(c.file)) { cImgs.append((img, c)) }
            }
            if !cImgs.isEmpty { cPath = CursorPath.bake(track: track, duration: srcDur, settings: settings) }
        }

        // sous-titres : seulement les mots gardés au montage
        let keptWords = allWords.filter { isKept(($0.start + $0.end) / 2, segments) }
        let words = settings.captions ? keptWords : []
        let duration = segments.last.map { $0.comp + $0.compDur } ?? 0

        // musique de fond (atténuée quand la voix parle) et sons de clic, posés après l'accélération
        let total = comp.duration
        var mix: [AVMutableAudioMixInputParameters] = []
        // audios importés (voix off, sons), à vitesse normale, à leur place dans le montage
        let placed = Audio.placements(settings.audioClips ?? [], segments: segments, duration: min(duration, total.seconds))
        mix += await Audio.addClips(placed, video: video, to: comp)
        if let name = settings.music, !name.isEmpty {
            let file = Audio.musicFolder.appendingPathComponent(name)
            // la musique s'efface sous la voix d'origine ET sous les voix off
            let speech = keptWords.map { (compTime($0.start, segments, duration: duration), compTime($0.end, segments, duration: duration)) }
                + placed.map { ($0.at, $0.at + $0.len) }
            let talk = speech.isEmpty ? [(0.0, duration)] : speech
            let keys = Audio.musicKeyframes(speech: talk, duration: total.seconds, base: settings.musicVolume)
            if let p = await Audio.addMusic(file, to: comp, duration: total, keyframes: keys) { mix.append(p) }
        }
        if settings.clickSounds {
            let times = Audio.clickTimes(track).filter { isKept($0, segments) }.map { compTime($0, segments, duration: duration) }
            if let p = await Audio.addClicks(at: times, to: comp, duration: total) { mix.append(p) }
        }
        var audioMix: AVMutableAudioMix?
        if !mix.isEmpty { audioMix = AVMutableAudioMix(); audioMix!.inputParameters = mix }
        // l'instruction couvre exactement toute la composition (sinon AVPlayer n'affiche rien, sans erreur)
        let inst = EditInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration),
                                   path: path, segments: segments, settings: settings, rec: rec, hasCamera: hasCamera,
                                   sourceSize: srcSize, renderSize: renderSize, cursorPath: cPath, cursorImages: cImgs,
                                   screenPoints: CGSize(width: track?.screenWidth ?? 0, height: track?.screenHeight ?? 0),
                                   captions: words,
                                   look: await LookData.prepare(video: video, settings: settings, zooms: zooms, track: track,
                                                                duration: srcDur, wait: waitCaptions))
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = Compositor.self
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps == 60 ? 60 : 30))
        vc.renderSize = renderSize
        vc.instructions = [inst]
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return Built(composition: comp, videoComposition: vc, duration: duration, sourceDuration: srcDur, zooms: zooms,
                     segments: segments, silences: silences, captionWords: words, audioMix: audioMix,
                     fillerCuts: fillers.map { CutRange(start: $0.start, end: $0.end) }, speeds: speeds, cleanAudio: cleanAudio)
    }

    /// Export final en 720p, 1080p ou 4K, 30 ou 60 i/s, H.264 (lisible partout : Chrome, Safari, iPhone, aperçus), index en tête de fichier.
    @discardableResult
    static func export(video: URL, settings: EditSettings, to dst: URL, progress: @escaping (Double) -> Void) async throws -> Built {
        // taille selon le format (16:9, 1:1, 9:16) et la qualité choisie (petit côté = 720, 1080 ou 2160)
        let size = settings.renderSize(short: CGFloat(settings.exportHeight))
        let b = try await build(video: video, settings: settings, renderSize: size, waitCaptions: true, fps: settings.exportFPS)
        // les préréglages fixes rétréciraient un format carré ou vertical : on garde alors la taille du montage
        let preset = settings.aspect != "16:9" ? AVAssetExportPresetHighestQuality
            : size.height >= 2160 ? AVAssetExportPreset3840x2160 : size.height <= 720 ? AVAssetExportPreset1280x720 : AVAssetExportPreset1920x1080
        guard let s = AVAssetExportSession(asset: b.composition, presetName: preset) else { throw err("export impossible") }
        try? FileManager.default.removeItem(at: dst)
        s.videoComposition = b.videoComposition
        s.audioMix = b.audioMix
        s.audioTimePitchAlgorithm = .spectral      // voix accélérée sans effet « chipmunk »

        s.outputURL = dst
        s.outputFileType = .mp4
        s.shouldOptimizeForNetworkUse = true
        // garde-fou (2026-10-17) : un export figé (0 % de processeur, progression immobile) bloquait l'envoi pour toujours,
        // la page restait sur « Ta vidéo arrive… ». Sans progrès pendant 90 s, on annule : l'envoi réessaie tout seul.
        var watch = StallWatch(limit: 90)
        var stalled = false
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
            progress(Double(s.progress))
            if watch.isStalled(progress: s.progress, now: Date()) { stalled = true; s.cancelExport() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.exportAsynchronously { c.resume() } }
        if stalled { throw err("montage figé à \(Int(s.progress * 100)) %, nouvel essai") }
        if s.status != .completed { throw s.error ?? err("export échoué") }
        return b
    }

    private static func err(_ m: String) -> NSError { NSError(domain: "X-Videos", code: 3, userInfo: [NSLocalizedDescriptionKey: m]) }
}

/// Détecte un export qui n'avance plus : vrai quand la progression n'a pas bougé depuis `limit` secondes.
struct StallWatch {
    let limit: TimeInterval
    private var last: Float = -1
    private var since: Date?
    init(limit: TimeInterval) { self.limit = limit }
    mutating func isStalled(progress: Float, now: Date) -> Bool {
        if progress > last + 0.0001 || since == nil { last = progress; since = now; return false }
        return now.timeIntervalSince(since!) >= limit
    }
}
