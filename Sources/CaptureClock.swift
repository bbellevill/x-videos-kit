import Foundation

/// Horloge du tournage avec pauses : convertit un instant de l'horloge machine (secondes, comme
/// CACurrentMediaTime et les horodatages de ScreenCaptureKit) en temps de la vidéo finale, pauses retirées.
/// Sert à l'écran, au son, au curseur et au journal des touches : tout reste aligné.
struct PauseClock: Codable, Equatable {
    struct Pause: Codable, Equatable { var start: Double; var end: Double? }

    var origin: Double?                 // instant de la 1re image (= 0 dans la vidéo)
    private(set) var pauses: [Pause] = []

    var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    mutating func pause(at t: Double) { if !isPaused { pauses.append(Pause(start: t, end: nil)) } }
    mutating func resume(at t: Double) { if isPaused { pauses[pauses.count - 1].end = max(t, pauses[pauses.count - 1].start) } }

    /// Temps dans la vidéo finale, ou nil si l'instant est avant le début ou pendant une pause.
    func map(_ t: Double) -> Double? {
        guard let o = origin, t >= o else { return nil }
        var off = 0.0
        for p in pauses {
            if t < p.start { break }
            guard let e = p.end, t >= e else { return nil }
            off += max(0, e - max(p.start, o))
        }
        return t - o - off
    }

    /// Pour un instant caché (avant le début ou pendant une pause) : temps de la vidéo où l'image reprend.
    func resumeTime(after t: Double) -> Double? {
        guard let o = origin else { return nil }
        if t < o { return 0 }
        guard let p = pauses.first(where: { t >= $0.start && ($0.end.map { t < $0 } ?? true) }), let e = p.end else { return nil }
        return map(e)
    }

    /// « Refaire les dernières secondes » (2026-10-14, Live Rewind de Loom) : pour chaque pause, les secondes à reprendre
    /// avant elle → passages à couper, en temps de la vidéo. `rewinds` : numéro de la pause → secondes.
    func rewindCuts(_ rewinds: [Int: Double]) -> [(start: Double, end: Double)] {
        rewinds.keys.sorted().compactMap { i -> (start: Double, end: Double)? in
            guard i < pauses.count, let s = rewinds[i], s > 0, let at = map(pauses[i].start - 0.000_001) else { return nil }
            return (max(0, at - s), at)    // un recul plus long que ce qui précède s'arrête au début de la vidéo
        }
    }

    /// Durée totale passée en pause (pauses closes seulement).
    var pausedTotal: Double { pauses.reduce(0) { $0 + max(0, ($1.end ?? $1.start) - $1.start) } }
}
