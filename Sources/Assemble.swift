import Foundation
import AVFoundation

/// Plusieurs vidéos bout à bout : une seule vidéo source, que tout l'éditeur sait déjà monter
/// (coupes, zooms, sous-titres…). On ajoute toujours À LA SUITE : les réglages déjà faits gardent leurs instants.
enum Assemble {
    static func err(_ s: String) -> NSError { NSError(domain: "X-Videos", code: 4, userInfo: [NSLocalizedDescriptionKey: s]) }

    /// Morceaux d'une vidéo assemblée (nom du fichier d'origine et instant de départ), pour les repères sur la frise.
    struct Part: Codable, Equatable { var name: String; var start: Double }

    static func meta(_ video: URL, _ suffix: String) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).\(suffix)")
    }
    static func partsURL(_ video: URL) -> URL { meta(video, "parts.json") }
    static func backupURL(_ video: URL) -> URL { meta(video, "avant-ajout.mp4") }

    static func parts(of video: URL) -> [Part] {
        guard let d = try? Data(contentsOf: partsURL(video)), let p = try? JSONDecoder().decode([Part].self, from: d) else { return [] }
        return p
    }
    static func canUndo(_ video: URL) -> Bool { FileManager.default.fileExists(atPath: backupURL(video).path) }

    // MARK: fonctions pures (testées dans tests/assemble-test.swift)

    /// Repères après ajout : la vidéo d'avant devient le 1er morceau (si elle n'en avait pas), puis un morceau par clip ajouté.
    static func partsAfterAppend(_ old: [Part], firstName: String, oldDuration: Double, added: [(name: String, dur: Double)]) -> [Part] {
        var p = old.isEmpty ? [Part(name: firstName, start: 0)] : old
        var at = oldDuration
        for a in added { p.append(Part(name: a.name, start: at)); at += a.dur }
        return p
    }

    /// Réglages après ajout : la fin coupée de l'ancienne vidéo le reste (devient un passage coupé),
    /// sinon la poignée de fin couperait la vidéo ajoutée.
    static func settingsAfterAppend(_ s: EditSettings, oldDuration d: Double) -> EditSettings {
        var s = s
        if s.trimEnd > 0.01 {
            s.cuts = (s.cuts ?? []) + [CutRange(start: max(s.trimStart, d - s.trimEnd), end: d)]
            s.trimEnd = 0
        }
        return s
    }

    /// Image de chaque clip ramenée dans le cadre du premier (proportions gardées, bandes noires si besoin).
    static func fitTransform(natural: CGSize, preferred: CGAffineTransform, into rs: CGSize) -> CGAffineTransform {
        let r = CGRect(origin: .zero, size: natural).applying(preferred)
        let k = min(rs.width / max(1, r.width), rs.height / max(1, r.height))
        return preferred
            .concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: (rs.width - r.width * k) / 2, y: (rs.height - r.height * k) / 2))
    }

    // MARK: réordonner, retirer, insérer (2026-10-14) — fonctions pures testées

    /// Bornes [début, fin) de chaque morceau dans le fichier actuel.
    static func spans(_ parts: [Part], duration: Double) -> [(start: Double, end: Double)] {
        parts.enumerated().map { i, p in (p.start, i + 1 < parts.count ? parts[i + 1].start : duration) }
    }

    /// Instant du fichier actuel → instant après réarrangement (nil = morceau retiré).
    static func remap(_ t: Double, spans sp: [(start: Double, end: Double)], order: [Int]) -> Double? {
        guard let i = sp.firstIndex(where: { t >= $0.start && t < $0.end }) ?? (t >= (sp.last?.end ?? 0) ? sp.indices.last : nil),
              let pos = order.firstIndex(of: i) else { return nil }
        let newStart = order[..<pos].reduce(0) { $0 + sp[$1].end - sp[$1].start }
        return newStart + (t - sp[i].start)
    }

    /// Plage → nouvelle plage, rognée au morceau qui contient son milieu (une plage à cheval ne déborde jamais sur un autre morceau).
    static func remapRange(_ a: Double, _ b: Double, spans sp: [(start: Double, end: Double)], order: [Int]) -> (Double, Double)? {
        let mid = (a + b) / 2
        guard let i = sp.firstIndex(where: { mid >= $0.start && mid < $0.end }) else { return nil }
        let ca = max(a, sp[i].start), cb = min(b, sp[i].end)
        guard cb > ca, let na = remap(ca, spans: sp, order: order) else { return nil }
        return (na, na + (cb - ca))
    }

    static func partsAfterRearrange(_ parts: [Part], duration: Double, order: [Int]) -> [Part] {
        let sp = spans(parts, duration: duration)
        var at = 0.0
        return order.map { i in defer { at += sp[i].end - sp[i].start }; return Part(name: parts[i].name, start: at) }
    }

    /// Réglages suivant leurs morceaux : coupes, vitesses, zooms, masques, annotations, audios. La fin coupée devient un passage coupé.
    static func settingsAfterRearrange(_ s0: EditSettings, parts: [Part], duration: Double, order: [Int]) -> EditSettings {
        var s = settingsAfterAppend(s0, oldDuration: duration)
        let sp = spans(parts, duration: duration)
        func r(_ a: Double, _ b: Double) -> (Double, Double)? { remapRange(a, b, spans: sp, order: order) }
        s.cuts = s.cuts?.compactMap { c in r(c.start, c.end).map { CutRange(start: $0.0, end: $0.1) } }.nilIfEmpty
        s.speedRanges = s.speedRanges?.compactMap { x in r(x.start, x.end).map { var y = x; y.start = $0.0; y.end = $0.1; return y } }.nilIfEmpty
        s.zooms = s.zooms?.compactMap { z in r(z.start, z.end).map { var y = z; y.start = $0.0; y.end = $0.1; return y } }
        s.masks = s.masks?.compactMap { m in r(m.start, m.end).map { var y = m; y.start = $0.0; y.end = $0.1; return y } }.nilIfEmpty
        s.annotations = s.annotations?.compactMap { m in r(m.start, m.end).map { var y = m; y.start = $0.0; y.end = $0.1; return y } }.nilIfEmpty
        s.audioClips = s.audioClips?.compactMap { a in remap(a.at, spans: sp, order: order).map { var y = a; y.at = $0; return y } }.nilIfEmpty
        if order.first != 0 { s.trimStart = 0 }
        return s
    }

    /// Réarrange les morceaux du fichier (nouvel ordre ; un indice absent = morceau retiré). Ancien état gardé pour « Annuler ».
    static func rearrange(_ video: URL, order: [Int]) async throws {
        let fm = FileManager.default
        let asset = AVURLAsset(url: video)
        let dur = try await asset.load(.duration).seconds
        let ps = parts(of: video)
        guard ps.count > 1, !order.isEmpty, Set(order).isSubset(of: Set(ps.indices)) else { throw err("Rien à réarranger") }
        if RecordingInfo.load(for: video) != nil, order.first != 0 { throw err("Le 1er morceau porte ta caméra et ta souris : il reste en premier") }
        let sp = spans(ps, duration: dur)
        let comp = AVMutableComposition()
        guard let sv = try await asset.loadTracks(withMediaType: .video).first,
              let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw err("Pas d'image") }
        vt.preferredTransform = try await sv.load(.preferredTransform)
        let sa = try await asset.loadTracks(withMediaType: .audio).first
        let at = sa != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var cursor = CMTime.zero
        for i in order {
            let range = CMTimeRange(start: CMTime(seconds: sp[i].start, preferredTimescale: 600), end: CMTime(seconds: sp[i].end, preferredTimescale: 600))
            try vt.insertTimeRange(range, of: sv, at: cursor)
            if let sa = sa, let at = at { try? at.insertTimeRange(range, of: sa, at: cursor) }
            cursor = cursor + range.duration
        }
        let tmp = meta(video, "assemblage-tmp.mp4")
        try? fm.removeItem(at: tmp)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw err("Export impossible") }
        ex.shouldOptimizeForNetworkUse = true
        try await ex.export(to: tmp, as: .mp4)
        let backup = backupURL(video)
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: video, to: backup)
        do { try fm.moveItem(at: tmp, to: video) } catch { try? fm.moveItem(at: backup, to: video); throw error }
        for s in ["edit.json", "parts.json"] {
            let src = meta(video, s), b = meta(video, "avant-ajout.\(s)")
            try? fm.removeItem(at: b)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: b) }
        }
        try? JSONEncoder().encode(partsAfterRearrange(ps, duration: dur, order: order)).write(to: partsURL(video))
        settingsAfterRearrange(EditSettings.load(for: video), parts: ps, duration: dur, order: order).save(for: video)
        forgetSoundAnalyses(video)
    }

    // MARK: assemblage

    /// Met les vidéos bout à bout dans `dst` (MP4 H.264, taille du premier clip). Rend la durée de chaque clip.
    @discardableResult
    static func concat(_ urls: [URL], to dst: URL) async throws -> [Double] {
        guard !urls.isEmpty else { throw err("Aucune vidéo à assembler") }
        let comp = AVMutableComposition()
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw err("Montage impossible") }
        var at = CMTime.zero
        var durs: [Double] = []
        var rs: CGSize?
        var fps: Float = 30
        var assets: [AVURLAsset] = []        // gardés en vie jusqu'à l'export
        var aTrack: AVMutableCompositionTrack?
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
        for u in urls {
            let a = AVURLAsset(url: u); assets.append(a)
            guard let sv = try await a.loadTracks(withMediaType: .video).first else { throw err("Pas d'image dans « \(u.lastPathComponent) »") }
            let range = try await sv.load(.timeRange)
            let nat = try await sv.load(.naturalSize)
            let pt = try await sv.load(.preferredTransform)
            fps = max(fps, try await sv.load(.nominalFrameRate))
            if rs == nil {
                let r = CGRect(origin: .zero, size: nat).applying(pt)
                rs = CGSize(width: (abs(r.width) / 2).rounded() * 2, height: (abs(r.height) / 2).rounded() * 2)   // tailles paires (H.264)
            }
            try vt.insertTimeRange(range, of: sv, at: at)
            layer.setTransform(fitTransform(natural: nat, preferred: pt, into: rs!), at: at)
            if let sa = try await a.loadTracks(withMediaType: .audio).first {
                let ar = try await sa.load(.timeRange).intersection(range)
                if aTrack == nil { aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                if ar.duration > .zero { try aTrack?.insertTimeRange(ar, of: sa, at: at + (ar.start - range.start)) }
            }
            durs.append(range.duration.seconds)
            at = at + range.duration
        }
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: at)
        inst.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = rs!
        vc.frameDuration = CMTime(value: 1, timescale: fps > 40 ? 60 : 30)
        vc.instructions = [inst]
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw err("Export impossible") }
        ex.videoComposition = vc
        ex.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: dst)
        try await ex.export(to: dst, as: .mp4)
        withExtendedLifetime(assets) {}
        return durs
    }

    /// Ajoute des vidéos à la suite de `video` (fichier remplacé, l'ancien gardé pour « Retirer le dernier ajout »).
    /// Les analyses liées au son (voix nettoyée, transcription, silences) sont refaites ensuite.
    static func append(_ clips: [URL], to video: URL) async throws {
        let fm = FileManager.default
        let oldDur = try await AVURLAsset(url: video).load(.duration).seconds
        try fm.createDirectory(at: partsURL(video).deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = meta(video, "assemblage-tmp.mp4")
        let durs = try await concat([video] + clips, to: tmp)
        // sauvegarde pour revenir en arrière : vidéo, réglages et repères d'avant
        let backup = backupURL(video)
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: video, to: backup)
        do { try fm.moveItem(at: tmp, to: video) } catch { try? fm.moveItem(at: backup, to: video); throw error }
        for s in ["edit.json", "parts.json"] {
            let src = meta(video, s), b = meta(video, "avant-ajout.\(s)")
            try? fm.removeItem(at: b)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: b) }
        }
        let added = zip(clips, durs.dropFirst()).map { (name: $0.deletingPathExtension().lastPathComponent, dur: $1) }
        let p = partsAfterAppend(parts(of: video), firstName: video.deletingPathExtension().lastPathComponent, oldDuration: oldDur, added: added)
        try? JSONEncoder().encode(p).write(to: partsURL(video))
        settingsAfterAppend(EditSettings.load(for: video), oldDuration: oldDur).save(for: video)
        forgetSoundAnalyses(video)
    }

    /// Revient à la vidéo d'avant le dernier ajout (réglages et repères compris).
    static func undoAppend(_ video: URL) throws {
        let fm = FileManager.default
        let backup = backupURL(video)
        guard fm.fileExists(atPath: backup.path) else { throw err("Rien à retirer") }
        _ = try fm.replaceItemAt(video, withItemAt: backup)
        for s in ["edit.json", "parts.json"] {
            let dst = meta(video, s), b = meta(video, "avant-ajout.\(s)")
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: b.path) { try? fm.moveItem(at: b, to: dst) }
        }
        forgetSoundAnalyses(video)
    }

    /// Voix nettoyée, transcription et silences décrivent l'ancien fichier : on les efface pour qu'ils soient refaits.
    static func forgetSoundAnalyses(_ video: URL) {
        for s in ["clean.m4a", "captions.json", "silences.json"] { try? FileManager.default.removeItem(at: meta(video, s)) }
    }
}
