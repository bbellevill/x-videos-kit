import Cocoa
import ScreenCaptureKit

/// Ce qu'on filme. `frame` = zone filmée en coordonnées écran Cocoa (sert au curseur).
enum CaptureTarget {
    case screen(NSScreen)
    case window(CGWindowID, frame: NSRect, screen: NSScreen)
    case area(NSRect, screen: NSScreen)

    var screen: NSScreen {
        switch self { case .screen(let s), .window(_, _, let s), .area(_, let s): return s }
    }
    var frame: NSRect {
        switch self { case .screen(let s): return s.frame; case .window(_, let f, _), .area(let f, _): return f }
    }
}

/// Enregistre l'écran (ou une fenêtre, ou une zone) + le micro (+ le son du Mac) dans un MP4 (ScreenCaptureKit, macOS 15+).
/// Les images passent par CaptureWriter : pause / reprise et fichier écrit en fragments (récupérable après un crash).
/// Les fenêtres de X-Videos sont exclues de la vidéo, sauf la bulle caméra quand elle est filmée avec l'écran.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var writer: CaptureWriter?
    private var mixAudio = false
    private var writeError: Error?
    private var onFinish: ((Result<(URL, PauseClock), Error>) -> Void)?
    private let queue = DispatchQueue(label: "supercut.capture")
    private let audioQueue = DispatchQueue(label: "supercut.capture.audio")

    var isPaused: Bool { writer?.isPaused ?? false }

    func start(target: CaptureTarget, keepWindowIDs: [CGWindowID], hideWindowIDs: [CGWindowID], options: CaptureOptions,
               micID: String?, to url: URL, onFinish: @escaping (Result<(URL, PauseClock), Error>) -> Void) async throws {
        // fenêtres cachées comprises : nos propres fenêtres doivent toutes pouvoir être exclues
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let screen = target.screen
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NSError(domain: "X-Videos", code: 1, userInfo: [NSLocalizedDescriptionKey: "Aucun écran trouvé"])
        }
        let scale = screen.backingScaleFactor
        let cfg = SCStreamConfiguration()
        let filter: SCContentFilter
        var points = CGSize(width: display.width, height: display.height)

        switch target {
        case .window(let id, _, _):
            guard let w = content.windows.first(where: { $0.windowID == id }) else {
                throw NSError(domain: "X-Videos", code: 1, userInfo: [NSLocalizedDescriptionKey: "La fenêtre choisie a été fermée"])
            }
            filter = SCContentFilter(desktopIndependentWindow: w)
            points = w.frame.size
        case .screen, .area:
            let mine = Bundle.main.bundleIdentifier
            let keep = Set(keepWindowIDs), hide = Set(hideWindowIDs)
            if options.hideDesktopIcons || mine == nil {
                // liste explicite : nos fenêtres (sauf la bulle filmée) + les icônes du bureau (le Finder n'est pas touché)
                let out = content.windows.filter { w in
                    let app = w.owningApplication?.bundleIdentifier
                    if hide.contains(w.windowID) { return true }
                    if app != nil && app == mine { return !keep.contains(w.windowID) }
                    return options.hideDesktopIcons && CaptureGeometry.isDesktopIcons(bundleID: app, layer: w.windowLayer)
                }
                filter = SCContentFilter(display: display, excludingWindows: out)
            } else {
                let me = content.applications.filter { $0.bundleIdentifier == mine }
                filter = SCContentFilter(display: display, excludingApplications: me,
                                         exceptingWindows: content.windows.filter { keep.contains($0.windowID) })
            }
            if case .area(let r, _) = target {
                cfg.sourceRect = CaptureGeometry.sourceRect(area: r, screen: screen.frame)
                points = r.size
            }
        }

        let (w, h) = CaptureGeometry.pixelSize(points: points, scale: scale)
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = false        // le curseur est redessiné au montage (adouci, agrandi, cercle au clic)
        cfg.queueDepth = options.fps > 30 ? 8 : 6
        cfg.capturesAudio = options.systemAudio != .off
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = true
        if let micID = micID { cfg.microphoneCaptureDeviceID = micID }

        let wr = try CaptureWriter(url: url, width: w, height: h, fps: options.fps, mic: true, system: options.systemAudio != .off)
        // écriture cassée : on arrête tout de suite (sinon on filme dans le vide et seul le début est récupéré)
        wr.onFail = { [weak self] e, _ in self?.writeError = e; self?.stop() }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        if cfg.capturesAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        self.onFinish = onFinish
        mixAudio = options.systemAudio == .mix
        writer = wr; stream = s
        do { try await s.startCapture() } catch {
            wr.cancel(); writer = nil; stream = nil; self.onFinish = nil
            throw error
        }
    }

    func pause() { writer?.pause(at: CACurrentMediaTime()) }
    func resume() { writer?.resume(at: CACurrentMediaTime()) }

    func stop() {
        guard let s = stream else { return }
        s.stopCapture { [weak self] _ in DispatchQueue.main.async { self?.finishWriting(nil) } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let w = writer else { return }
        switch type {
        case .screen:
            // seules les images complètes portent une image (les autres signalent un écran immobile)
            guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            w.append(sb, .video)
        case .microphone: w.append(sb, .mic)
        case .audio: w.append(sb, .system)
        @unknown default: break
        }
    }

    // coupure de la capture (écran débranché…) : on garde ce qui a été filmé
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        CaptureLog.write("capture coupée par macOS : \(CaptureLog.describe(error))")
        DispatchQueue.main.async { self.finishWriting(error) }
    }

    private func finishWriting(_ streamError: Error?) {
        guard let w = writer else { return }
        writer = nil
        let mix = mixAudio
        let failed = writeError
        writeError = nil
        Task {
            do {
                let clock = try await w.finish()
                if mix { _ = try? await MovieTools.rewriteInPlace(w.url, mixAudio: true) }   // voix + son du Mac sur une seule piste
                complete(.success((w.url, clock)))
            } catch { complete(.failure(failed ?? streamError ?? error)) }
        }
    }

    private func complete(_ result: Result<(URL, PauseClock), Error>) {
        DispatchQueue.main.async {
            let f = self.onFinish
            self.onFinish = nil; self.stream = nil
            f?(result)
        }
    }
}
