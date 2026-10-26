import Foundation
import AVFoundation

/// Sauvegarde anti-crash : pendant un tournage, un marqueur .meta/<vidéo>.recording.json existe.
/// Il disparaît quand la vidéo est bien terminée. S'il est encore là au lancement, le tournage a été coupé
/// (crash, coupure de courant) : le MP4 fragmenté est réparé et remis dans la bibliothèque.
struct RecordingMarker: Codable {
    var started: Date
    var cameraFile: String?
    var cameraOffset: Double?
    var bubbleX: Double?
    var bubbleY: Double?
    var bubbleSize: Double?
}

enum Recovery {
    static func markerURL(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).recording.json")
    }

    static func mark(_ video: URL, _ m: RecordingMarker) {
        let u = markerURL(for: video)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(m).write(to: u, options: .atomic)
    }

    static func unmark(_ video: URL) { try? FileManager.default.removeItem(at: markerURL(for: video)) }

    /// Vidéos dont le tournage n'a pas été terminé.
    static func pending(in folder: URL) -> [URL] {
        let meta = folder.appendingPathComponent(".meta")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: meta.path)) ?? []
        return names.filter { $0.hasSuffix(".recording.json") }
            .map { folder.appendingPathComponent(String($0.dropLast(".recording.json".count))) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Répare une vidéo interrompue. Rend sa durée, ou nil si rien n'était récupérable (fichier retiré).
    static func recover(_ video: URL) async -> Double? {
        let marker = (try? Data(contentsOf: markerURL(for: video))).flatMap { try? JSONDecoder().decode(RecordingMarker.self, from: $0) }
        defer { unmark(video) }
        guard FileManager.default.fileExists(atPath: video.path),
              let d = try? await MovieTools.rewriteInPlace(video), d > 0.5 else {
            try? FileManager.default.removeItem(at: video)
            return nil
        }
        // la caméra (fichier fragmenté elle aussi) est rattachée si elle a survécu
        if let m = marker, let cam = m.cameraFile, RecordingInfo.load(for: video) == nil {
            let camURL = video.deletingLastPathComponent().appendingPathComponent(".meta/\(cam)")
            let ok = ((try? await AVURLAsset(url: camURL).load(.duration).seconds) ?? 0) > 0.5
            if ok {
                RecordingInfo(cameraFile: cam, cameraOffset: m.cameraOffset ?? 0, bubbleX: m.bubbleX ?? 0.1, bubbleY: m.bubbleY ?? 0.85,
                              bubbleSize: m.bubbleSize ?? 0.17).save(for: video)
            }
        }
        return d
    }
}
