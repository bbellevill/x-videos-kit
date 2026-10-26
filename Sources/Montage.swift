import Foundation

/// Plan du montage : ce qu'on garde, ce qu'on coupe, ce qu'on accélère.
/// Fonctions pures (testées dans tests/montage-test.swift), tout en temps source.
enum Montage {
    typealias Span = (start: Double, end: Double)

    /// Fusionne des passages qui se chevauchent ou se touchent.
    static func merge(_ spans: [Span], gap: Double = 0.01) -> [Span] {
        var out: [Span] = []
        for s in spans.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let l = out.last, s.start <= l.end + gap { out[out.count - 1].end = max(l.end, s.end) }
            else { out.append(s) }
        }
        return out
    }

    /// Morceaux gardés entre `start` et `end`, moins les passages coupés (les miettes de moins de 0,05 s sautent).
    static func keep(start: Double, end: Double, cuts: [Span]) -> [Span] {
        var keep: [Span] = []
        var t = start
        for r in merge(cuts) where r.end > start && r.start < end {
            if r.start > t + 0.05 { keep.append((t, min(r.start, end))) }
            t = max(t, r.end)
        }
        if end > t + 0.05 { keep.append((t, end)) }
        return keep
    }

    /// Morceaux gardés, redécoupés selon les vitesses (la première plage de la liste gagne en cas de chevauchement)
    /// → segments du montage avec leur place dans la vidéo finale.
    /// `global` : vitesse de toute la vidéo, multipliée à celle de chaque passage (×2 global + passage ×2 = ×4).
    static func plan(keep: [Span], speeds: [SpeedRange], global: Double = 1) -> [Renderer.Segment] {
        let g = max(0.5, min(4, global))
        var segs: [Renderer.Segment] = []
        var at = 0.0
        for (a, b) in keep {
            // points de bascule à l'intérieur du morceau
            var cuts = [a, b]
            for r in speeds where r.end > a && r.start < b { cuts += [max(a, r.start), min(b, r.end)] }
            cuts = Array(Set(cuts)).sorted()
            var pieces: [(a: Double, b: Double, speed: Double)] = []
            for i in 0..<(cuts.count - 1) {
                let x = cuts[i], y = cuts[i + 1], mid = (x + y) / 2
                let sp = speeds.first { mid >= $0.start && mid < $0.end }.map { max(0.25, min(8, $0.speed * g)) } ?? g
                // miette (< 0,05 s) ou même vitesse : on prolonge le morceau précédent
                if let l = pieces.last, l.speed == sp || y - x < 0.05 { pieces[pieces.count - 1].b = y }
                else { pieces.append((x, y, sp)) }
            }
            for p in pieces {
                segs.append(Renderer.Segment(comp: at, src: p.a, dur: p.b - p.a, speed: p.speed))
                at += (p.b - p.a) / p.speed
            }
        }
        return segs
    }

    // MARK: mots parasites

    /// « euh », « heu », « hum », « bah », « ben »… (comparés sans casse ni ponctuation).
    static let fillers: Set<String> = ["euh", "euhh", "euuh", "heu", "heuu", "hum", "humm", "hmm", "hmmm", "mmh", "bah", "ben", "beh"]

    static func isFiller(_ text: String) -> Bool { fillers.contains(text.lowercased().filter { $0.isLetter }) }

    /// Passages à couper pour les mots parasites isolés. Marges : on ne touche jamais au mot d'avant
    /// ni au mot d'après (Whisper allonge souvent la fin d'un mot jusqu'au suivant).
    static func fillerCuts(_ words: [Captions.Word]) -> [Span] {
        var out: [Span] = []
        for (i, w) in words.enumerated() where isFiller(w.text) {
            let prevEnd = i > 0 ? words[i - 1].end : -1
            let nextStart = i + 1 < words.count ? words[i + 1].start : .infinity
            let a = max(w.start, prevEnd + 0.04)
            let b = min(w.end, nextStart - 0.06)
            if b - a >= 0.1 { out.append((a, b)) }
        }
        return out
    }

    // MARK: frappe au clavier

    /// Passages de frappe : événements « typing » espacés de moins de 1,5 s, d'au moins 1 s au total.
    static func typingRanges(_ times: [Double], gap: Double = 1.5, speed: Double = 3) -> [SpeedRange] {
        var out: [SpeedRange] = []
        var first: Double?, last = 0.0, n = 0
        func flush() {
            if let f = first, n >= 2, last - f >= 1 { out.append(SpeedRange(start: max(0, f - 0.1), end: last + 0.3, speed: speed)) }
        }
        for t in times.sorted() {
            if let _ = first, t - last < gap { last = t; n += 1 }
            else { flush(); first = t; last = t; n = 1 }
        }
        flush()
        return out
    }

    struct KeyLog: Decodable {
        struct Event: Decodable { var t: Double; var typing: Bool? }
        var events: [Event]
    }

    static func keysURL(_ video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).keys.json")
    }

    /// Passages de frappe lus dans .meta/<vidéo>.keys.json (fichier absent ou illisible : aucun).
    static func typingRanges(for video: URL) -> [SpeedRange] {
        guard let d = try? Data(contentsOf: keysURL(video)), let log = try? JSONDecoder().decode(KeyLog.self, from: d) else { return [] }
        return typingRanges(log.events.filter { $0.typing ?? true }.map(\.t))
    }
}
