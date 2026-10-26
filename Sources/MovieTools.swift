import Foundation
import AVFoundation

/// Réécriture rapide d'un film (image recopiée telle quelle, son réencodé en AAC) :
/// sert à réparer un tournage interrompu, à mixer le son du Mac avec la voix, et à importer un MOV.
enum MovieTools {
    static func err(_ s: String) -> NSError { NSError(domain: "X-Videos", code: 3, userInfo: [NSLocalizedDescriptionKey: s]) }

    /// Réécrit `src` en MP4 propre dans `dst`. `mixAudio` : toutes les pistes son fondues en une seule.
    /// Rend la durée obtenue (secondes).
    @discardableResult
    static func remux(_ src: URL, to dst: URL, mixAudio: Bool = false) async throws -> Double {
        let asset = AVURLAsset(url: src)
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !vTracks.isEmpty else { throw err("Aucune image dans la vidéo") }
        let reader = try AVAssetReader(asset: asset)
        try? FileManager.default.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []

        for t in vTracks {
            let fmt = try await t.load(.formatDescriptions).first
            let out = AVAssetReaderTrackOutput(track: t, outputSettings: nil)   // image recopiée, sans perte
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            inp.transform = try await t.load(.preferredTransform)
            guard reader.canAdd(out), writer.canAdd(inp) else { throw err("Format d'image non pris en charge") }
            reader.add(out); writer.add(inp); pairs.append((out, inp))
        }
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                  AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                  AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                  AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        let audioOuts: [AVAssetReaderOutput] = mixAudio && aTracks.count > 1
            ? [AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: pcm)]
            : aTracks.map { AVAssetReaderTrackOutput(track: $0, outputSettings: pcm) }
        for out in audioOuts {
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            guard reader.canAdd(out), writer.canAdd(inp) else { continue }
            reader.add(out); writer.add(inp); pairs.append((out, inp))
        }

        guard reader.startReading() else { throw reader.error ?? err("Lecture de la vidéo impossible") }
        guard writer.startWriting() else { throw writer.error ?? err("Écriture de la vidéo impossible") }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { g in
            for (i, (out, inp)) in pairs.enumerated() {
                g.addTask {
                    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                        let q = DispatchQueue(label: "supercut.remux.\(i)")
                        inp.requestMediaDataWhenReady(on: q) {
                            while inp.isReadyForMoreMediaData {
                                guard reader.status == .reading, let sb = out.copyNextSampleBuffer() else {
                                    inp.markAsFinished(); k.resume(); return
                                }
                                if !inp.append(sb) { inp.markAsFinished(); k.resume(); return }
                            }
                        }
                    }
                }
            }
        }
        // un fichier coupé net (crash) se termine par une erreur de lecture : on garde ce qui a été lu
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? err("La vidéo n'a pas pu être réécrite") }
        let d = try await AVURLAsset(url: dst).load(.duration).seconds
        guard d.isFinite, d > 0 else { try? FileManager.default.removeItem(at: dst); throw err("Vidéo vide") }
        return d
    }

    /// Remplace le fichier par sa version réécrite (même nom).
    @discardableResult
    static func rewriteInPlace(_ url: URL, mixAudio: Bool = false) async throws -> Double {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp.mp4")
        let d = try await remux(url, to: tmp, mixAudio: mixAudio)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return d
    }

    /// Nom libre dans le dossier : « Démo.mp4 », sinon « Démo 2.mp4 », « Démo 3.mp4 »…
    static func uniqueURL(in folder: URL, base: String, ext: String = "mp4") -> URL {
        let clean = base.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let name = clean.isEmpty ? "Vidéo importée" : clean
        var u = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = folder.appendingPathComponent("\(name) \(n).\(ext)"); n += 1
        }
        return u
    }

    /// Importe une vidéo existante (MP4 ou MOV) dans le dossier, toujours en MP4. Rend le nouveau fichier.
    static func importVideo(_ src: URL, into folder: URL) async throws -> URL {
        let dst = uniqueURL(in: folder, base: src.deletingPathExtension().lastPathComponent)
        if src.pathExtension.lowercased() == "mp4" {
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        }
        do { try await remux(src, to: dst); return dst }
        catch {
            // image dans un format que le MP4 ne sait pas porter (ProRes…) : on réencode
            try? FileManager.default.removeItem(at: dst)
            guard let ex = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetHighestQuality) else { throw error }
            try await ex.export(to: dst, as: .mp4)
            return dst
        }
    }
}
