import Foundation
import AVFoundation
import QuartzCore

/// Écrit le tournage dans un MP4 à partir des images et du son reçus (sans dépendre de ScreenCaptureKit) :
/// - pause / reprise : ce qui arrive pendant une pause est jeté, la suite est recollée (horodatages décalés) ;
/// - anti-crash (optionnel, `fragment` > 0) : fichier écrit en fragments, lisible jusqu'au dernier fragment après une coupure.
/// Journal des tournages : ~/Library/Logs/X-Videos.log (l'appli n'écrivait aucune erreur, impossible de trouver la cause).
enum CaptureLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/X-Videos.log")
    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: url) }
    }
    /// Erreur + causes sous-jacentes (le code utile d'AVFoundation est souvent dans NSUnderlyingError).
    static func describe(_ e: Error) -> String {
        var n: NSError? = e as NSError, parts: [String] = []
        while let x = n { parts.append("\(x.domain) \(x.code) \(x.localizedDescription)"); n = x.userInfo[NSUnderlyingErrorKey] as? NSError }
        return parts.joined(separator: " <- ")
    }
}

final class CaptureWriter {
    enum Kind { case video, mic, system }

    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let mic: AVAssetWriterInput?
    private let system: AVAssetWriterInput?
    private let lock = NSLock()
    private var clock = PauseClock()
    private var end = CMTime.zero
    private var finished = false
    private var correction: [Kind: Double] = [:]
    private var lastTime: [Kind: Double] = [:]
    /// Coupé seulement par le test qui casse l'écrivain exprès.
    var dropBackwards = true
    /// Horloge machine (remplacée dans les tests).
    var now: () -> Double = { CACurrentMediaTime() }
    /// Appelé une seule fois si l'écriture casse en plein tournage (bug du 2026-10-13 : la suite était jetée
    /// sans bruit et la vidéo s'arrêtait à 2 s). Rend la vraie erreur et la durée déjà écrite.
    var onFail: ((Error, Double) -> Void)?
    var failQueue = DispatchQueue.main
    private var failReported = false

    init(url: URL, width: Int, height: Int, fps: Int, mic withMic: Bool, system withSystem: Bool, fragment: Double = 0) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // fragments coupés par défaut (2026-10-13) : en tournage réel, l'écrivain MP4 cassait à chaque fragment
        // (-16364 à 2 s, -16341 à 4,2 s) et la vidéo s'arrêtait à 2 s. Prix : un crash en plein tournage n'est plus récupérable.
        if fragment > 0 { writer.movieFragmentInterval = CMTime(seconds: fragment, preferredTimescale: 600) }
        let bitrate = Double(width * height * fps) * 0.12        // ≈ 30 Mbit/s en 4K 30 i/s
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(min(60_000_000, max(4_000_000, bitrate))),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        // la voix d'abord : c'est la piste son que lit le montage
        mic = withMic ? Self.audioInput(channels: 1, bitrate: 128_000) : nil
        system = withSystem ? Self.audioInput(channels: 2, bitrate: 192_000) : nil
        for i in [mic, system].compactMap({ $0 }) { writer.add(i) }
        guard writer.startWriting() else { throw writer.error ?? Self.err("Écriture de la vidéo impossible") }
    }

    private static func audioInput(channels: Int, bitrate: Int) -> AVAssetWriterInput {
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitrate,
        ])
        i.expectsMediaDataInRealTime = true
        return i
    }

    static func err(_ s: String) -> NSError { NSError(domain: "X-Videos", code: 2, userInfo: [NSLocalizedDescriptionKey: s]) }

    var isFragmented: Bool { writer.movieFragmentInterval.isValid }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return clock.isPaused }
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return clock.origin != nil }

    func pause(at t: Double) { lock.lock(); clock.pause(at: t); lock.unlock() }
    func resume(at t: Double) { lock.lock(); clock.resume(at: t); lock.unlock() }

    /// Reçoit un échantillon horodaté sur l'horloge machine. La 1re image fixe le zéro de la vidéo.
    func append(_ sb: CMSampleBuffer, _ kind: Kind) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        guard writer.status == .writing else { reportFailure(); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        // sécurité : une piste horodatée sur une autre horloge (écart > 1 s au 1er échantillon) est recalée sur l'horloge machine,
        // sinon tout son son serait jeté comme « avant le début »
        if correction[kind] == nil { let n = now(); correction[kind] = abs(n - pts.seconds) > 1 ? n - pts.seconds : 0 }
        let t = pts.seconds + (correction[kind] ?? 0)
        if kind == .video && clock.origin == nil {
            clock.origin = t
            writer.startSession(atSourceTime: .zero)
        }
        guard let m = clock.map(t) else { return }          // avant la 1re image ou pendant une pause
        // un échantillon en arrière dans le temps casse l'écrivain pour de bon (-16364, cause probable des vidéos
        // de 2 s du 2026-10-13) : on le jette, le tournage continue
        if dropBackwards, let l = lastTime[kind], m <= l { CaptureLog.write("échantillon \(kind) en arrière jeté (\(m) <= \(l))"); return }
        let input: AVAssetWriterInput? = kind == .video ? video : kind == .mic ? mic : system
        guard let input = input, input.isReadyForMoreMediaData else { return }
        let shift = CMTimeSubtract(pts, CMTime(seconds: m, preferredTimescale: max(pts.timescale, 600)))
        guard let out = Self.retime(sb, minus: shift) else { return }
        if input.append(out) {
            lastTime[kind] = m
            let d = CMSampleBufferGetDuration(out)
            let e = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(out), d.isValid ? d : .zero)
            if CMTimeCompare(e, end) > 0 { end = e }
        } else if writer.status == .failed { reportFailure() }
    }

    /// Appelé sous le verrou.
    private func reportFailure() {
        guard writer.status == .failed, !failReported else { return }
        failReported = true
        let e = writer.error ?? Self.err("Écriture de la vidéo interrompue")
        let at = end.seconds.isFinite ? end.seconds : 0
        CaptureLog.write("écriture cassée à \(String(format: "%.1f", at)) s : \(CaptureLog.describe(e))")
        let cb = onFail
        failQueue.async { cb?(e, at) }
    }

    /// Copie de l'échantillon avec tous ses horodatages reculés de `shift`.
    static func retime(_ sb: CMSampleBuffer, minus shift: CMTime) -> CMSampleBuffer? {
        var n: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &n)
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, n))
        if n > 0 { CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: n, arrayToFill: &info, entriesNeededOut: &n) }
        else { info[0] = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb), decodeTimeStamp: .invalid) }
        for i in info.indices {
            info[i].presentationTimeStamp = CMTimeSubtract(info[i].presentationTimeStamp, shift)
            if info[i].decodeTimeStamp.isValid { info[i].decodeTimeStamp = CMTimeSubtract(info[i].decodeTimeStamp, shift) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: info.count,
                                              sampleTimingArray: &info, sampleBufferOut: &out)
        return out
    }

    /// Termine le fichier. Rend l'horloge (pauses comprises) pour recaler curseur, caméra et touches.
    func finish() async throws -> PauseClock {
        let (c, e) = close()
        guard c.origin != nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw Self.err("Aucune image n'a été filmée")
        }
        writer.endSession(atSourceTime: e)
        for i in [video, mic, system].compactMap({ $0 }) { i.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed {
            let e = writer.error ?? Self.err("La vidéo n'a pas pu être terminée")
            CaptureLog.write("fin du fichier impossible : \(CaptureLog.describe(e))")
            throw e
        }
        return c
    }

    private func close() -> (PauseClock, CMTime) {
        lock.lock(); defer { lock.unlock() }
        finished = true
        return (clock, end)
    }

    func cancel() {
        lock.lock(); finished = true; lock.unlock()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
