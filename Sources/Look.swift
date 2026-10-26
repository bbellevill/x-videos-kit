import Foundation
import CoreGraphics

// Réglages et calculs « image » (comme Screen Studio) sans dépendance graphique : formats, masques,
// touches affichées, flou de mouvement, lissage du suivi de visage, préréglages de style.
// Tout ici est testable sans écran (tests/settings-test.swift, tests/look-test.swift).

/// Formats de sortie : 16:9 (défaut), carré, vertical (Reels, TikTok, Shorts).
enum Formats {
    static let all: [(id: String, name: String)] = [("16:9", "16:9"), ("1:1", "Carré"), ("9:16", "Vertical")]

    /// Taille de rendu, `short` = petit côté (1080 à l'export, 720 dans l'aperçu).
    static func size(_ aspect: String, short: CGFloat) -> CGSize {
        switch aspect {
        case "1:1": return CGSize(width: short, height: short)
        case "9:16": return CGSize(width: short, height: (short * 16 / 9).rounded())
        default: return CGSize(width: (short * 16 / 9).rounded(), height: short)
        }
    }
    static func ratio(_ aspect: String) -> CGFloat { let s = size(aspect, short: 1080); return s.width / s.height }

    /// Zones masquées par l'interface Instagram / TikTok en vertical (part de la hauteur / largeur), aperçu seulement.
    static let reelsTop = 0.12, reelsBottom = 0.20, reelsRight = 0.14
}

/// Mises en page de la caméra.
enum CameraLayouts {
    static let all: [(id: String, name: String, icon: String)] = [
        ("bulle", "Bulle", "person.crop.circle"), ("plein-ecran", "Caméra seule", "person.fill"),
        ("cote-a-cote", "Côte à côte", "rectangle.split.2x1"), ("ecran-seul", "Écran seul", "display"),
    ]
    static let looks: [(id: String, name: String)] = [("naturel", "Naturel"), ("chaud", "Chaud"), ("froid", "Froid"), ("contraste", "Contraste")]

    /// Part de caméra plein écran (1 = plein écran) au temps `t` du montage, pour l'intro et la fin.
    /// Transition adoucie (courbe en S) sur 0,6 s au plus.
    static func introOutro(t: Double, duration: Double, seconds T: Double) -> Double {
        guard T > 0, duration > 0 else { return 0 }
        let T = min(T, duration / 2)
        let ramp = min(0.6, T / 2)
        func s(_ x: Double) -> Double { let x = max(0, min(1, x)); return x * x * (3 - 2 * x) }
        let a = 1 - s((t - (T - ramp)) / ramp)                 // début : 1 → 0
        let b = s((t - (duration - T)) / ramp)                  // fin : 0 → 1
        return max(a, b)
    }

    /// Visibilité de la bulle (0…1) : elle s'efface en fondu pendant les silences d'au moins 1 s (temps source).
    static func silenceVisibility(t: Double, runs: [(start: Double, end: Double)], fade: Double = 0.3) -> Double {
        for r in runs where r.end - r.start >= 1.0 && t > r.start && t < r.end {
            let d = min(t - r.start, r.end - t)
            let x = max(0, min(1, d / fade))
            return 1 - x * x * (3 - 2 * x)
        }
        return 1
    }
}

/// Zone masquée : rectangle normalisé dans l'écran filmé (0…1, origine en haut à gauche, suit les zooms),
/// pendant une plage de temps source. "flou" cache une donnée sensible, "projecteur" assombrit tout le reste.
struct MaskRegion: Codable, Equatable, Identifiable {
    var x: Double, y: Double, w: Double, h: Double
    var start: Double, end: Double
    var kind = "flou"
    var id: String { "\(start)-\(end)-\(x)-\(y)" }

    init(x: Double, y: Double, w: Double, h: Double, start: Double, end: Double, kind: String = "flou") {
        self.x = x; self.y = y; self.w = w; self.h = h; self.start = start; self.end = end; self.kind = kind
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 0
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 0
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "flou"
    }

    /// Opacité au temps source `t` : apparition et disparition en 0,15 s (0 hors de la plage).
    func alpha(at t: Double) -> Double {
        guard t >= start, t < end else { return 0 }
        let f = 0.15
        return max(0, min(1, min((t - start) / f + 0.0001, (end - t) / f)))
    }
}

/// Raccourcis clavier tapés pendant le tournage (.meta/<vidéo>.keys.json, écrit à l'enregistrement).
enum KeyEvents {
    struct Event: Codable { var t: Double; var keys: String; var typing: Bool? }
    private struct File: Codable { var events: [Event] }
    static let shown = 1.2      // durée d'affichage d'une pastille

    static func url(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).keys.json")
    }
    /// Seulement les raccourcis (typing = false), triés.
    static func load(for video: URL) -> [Event] { decode((try? Data(contentsOf: url(for: video))) ?? Data()) }
    static func decode(_ d: Data) -> [Event] {
        guard let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.events.filter { $0.typing != true && !$0.keys.isEmpty }.sorted { $0.t < $1.t }
    }
    /// Pastille visible au temps `t` : la plus récente des 1,2 dernières secondes, avec fondu de 0,15 s.
    static func active(_ events: [Event], at t: Double) -> (index: Int, alpha: Double)? {
        guard let i = events.lastIndex(where: { $0.t <= t }), t - events[i].t < shown else { return nil }
        let e = t - events[i].t
        return (i, max(0, min(1, min(e / 0.15 + 0.0001, (shown - e) / 0.15))))
    }
}

/// Flou de mouvement : longueur du flou proportionnelle à la vitesse du cadrage (obturateur à 180° à 30 i/s).
enum MotionBlur {
    /// `a` et `b` : cadrage (centre 0…1, zoom) à deux instants séparés de `dt` secondes ;
    /// `width`/`height` : taille de l'écran rendu en pixels ; `intensity` 0…1.
    /// Rend un flou directionnel (rayon en pixels, angle en radians) et un flou de zoom (pixels au bord).
    static func amount(a: (x: Double, y: Double, s: Double), b: (x: Double, y: Double, s: Double), dt: Double,
                       width: Double, height: Double, intensity: Double) -> (radius: Double, angle: Double, zoom: Double) {
        guard intensity > 0, dt > 0 else { return (0, 0, 0) }
        let shutter = 1.0 / 60
        let s = (a.s + b.s) / 2
        // déplacement du contenu à l'écran, en pixels par seconde (le contenu bouge à l'inverse du cadre)
        let vx = (b.x - a.x) * s * width / dt, vy = (b.y - a.y) * s * height / dt
        var radius = intensity * hypot(vx, vy) * shutter
        // zoom : vitesse relative de grossissement, ramenée au déplacement des bords
        var zoom = intensity * abs(b.s - a.s) / max(1, s) / dt * (width / 2) * shutter
        radius = min(radius, 0.04 * width); zoom = min(zoom, 0.03 * width)
        if radius < 0.75 { radius = 0 }
        if zoom < 0.75 { zoom = 0 }
        return (radius, atan2(-vy, vx), zoom)
    }
}

/// Suivi du visage dans la caméra : points bruts (Vision, toutes les 0,5 s) puis lissés pour un cadrage calme.
enum FaceTrack {
    /// Cache .meta/<vidéo>.face.json : temps caméra (s) et centre du visage (0…1, origine en bas à gauche), taille.
    struct Raw: Codable { var step: Double; var points: [[Double]?] }   // [x, y, taille] ou nil = pas de visage

    struct Smoothed {
        let step: Double
        let points: [(x: Double, y: Double)]
        func sample(_ t: Double) -> (x: Double, y: Double) {
            guard !points.isEmpty else { return (0.5, 0.5) }
            let f = max(0, min(Double(points.count - 1), t / step))
            let i = Int(f), j = min(points.count - 1, i + 1), k = f - Double(i)
            return (points[i].x + (points[j].x - points[i].x) * k, points[i].y + (points[j].y - points[i].y) * k)
        }
    }

    static func url(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).face.json")
    }
    static func cached(for video: URL) -> Raw? {
        guard let d = try? Data(contentsOf: url(for: video)) else { return nil }
        return try? JSONDecoder().decode(Raw.self, from: d)
    }

    /// Lissage : trous comblés (dernier visage vu), médiane glissante (retire les détections aberrantes),
    /// moyenne glissante (≈ 2 s), puis zone morte : on ne recadre pas pour un mouvement de quelques %.
    static func smooth(_ raw: [(x: Double, y: Double)?], step: Double) -> Smoothed {
        guard let first = raw.first(where: { $0 != nil }) ?? nil else { return Smoothed(step: step, points: raw.map { _ in (0.5, 0.5) }) }
        var filled: [(x: Double, y: Double)] = []
        var last = first
        for p in raw { if let p = p { last = p }; filled.append(last) }
        func window(_ v: [Double], _ r: Int, _ f: ([Double]) -> Double) -> [Double] {
            v.indices.map { i in f(Array(v[max(0, i - r)...min(v.count - 1, i + r)])) }
        }
        let median: ([Double]) -> Double = { a in let s = a.sorted(); return s[s.count / 2] }
        let mean: ([Double]) -> Double = { a in a.reduce(0, +) / Double(a.count) }
        let r = max(1, Int((1.0 / step).rounded()))     // ±1 s
        var xs = window(window(filled.map(\.x), r, median), r * 2, mean)
        var ys = window(window(filled.map(\.y), r, median), r * 2, mean)
        // zone morte de 3 % : le cadrage reste immobile tant que le visage bouge peu
        for v in [0, 1] {
            var a = v == 0 ? xs : ys
            var hold = a.first ?? 0.5
            for i in a.indices { if abs(a[i] - hold) > 0.03 { hold += a[i] - hold - 0.03 * (a[i] > hold ? 1 : -1) }; a[i] = hold }
            if v == 0 { xs = a } else { ys = a }
        }
        return Smoothed(step: step, points: zip(xs, ys).map { ($0, $1) })
    }
}

/// Préréglages de style : un style complet enregistré sous un nom.
/// Stockés dans ~/Library/Application Support/X-Videos/presets.json.
struct StylePreset: Codable, Equatable, Identifiable {
    var name: String
    var background: String
    var backgroundImage: String?
    var padding: Double
    var radius: Double
    var shadow: Double
    var showCamera: Bool
    var cameraLayout: String
    var cameraLook: String
    var cameraSharpen: Double
    var cameraBackground: String
    var faceTracking: Bool
    var aspect: String
    var id: String { name }

    init(name: String, from s: EditSettings) {
        self.name = name
        background = s.background; backgroundImage = s.backgroundImage; padding = s.padding; radius = s.radius
        shadow = s.shadow; showCamera = s.showCamera; cameraLayout = s.cameraLayout; cameraLook = s.cameraLook
        cameraSharpen = s.cameraSharpen; faceTracking = s.faceTracking; aspect = s.aspect
        cameraBackground = s.cameraBackground
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = EditSettings()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Style"
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? def.background
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? def.padding
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? def.radius
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? def.shadow
        showCamera = try c.decodeIfPresent(Bool.self, forKey: .showCamera) ?? def.showCamera
        cameraLayout = try c.decodeIfPresent(String.self, forKey: .cameraLayout) ?? def.cameraLayout
        cameraLook = try c.decodeIfPresent(String.self, forKey: .cameraLook) ?? def.cameraLook
        cameraSharpen = try c.decodeIfPresent(Double.self, forKey: .cameraSharpen) ?? def.cameraSharpen
        cameraBackground = try c.decodeIfPresent(String.self, forKey: .cameraBackground) ?? def.cameraBackground
        faceTracking = try c.decodeIfPresent(Bool.self, forKey: .faceTracking) ?? def.faceTracking
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect) ?? def.aspect
    }

    func apply(to s: inout EditSettings) {
        s.background = background; s.backgroundImage = backgroundImage; s.padding = padding; s.radius = radius
        s.shadow = shadow; s.showCamera = showCamera; s.cameraLayout = cameraLayout; s.cameraLook = cameraLook
        s.cameraSharpen = cameraSharpen; s.faceTracking = faceTracking; s.aspect = aspect; s.cameraBackground = cameraBackground
    }
}

enum Presets {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("X-Videos/presets.json")
    }
    static func load(_ url: URL = defaultURL) -> [StylePreset] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StylePreset].self, from: d)) ?? []
    }
    static func save(_ list: [StylePreset], to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(list).write(to: url)
    }
    /// Enregistre (ou remplace, même nom) le style courant.
    @discardableResult
    static func add(_ p: StylePreset, to url: URL = defaultURL) -> [StylePreset] {
        var list = load(url).filter { $0.name != p.name }
        list.append(p)
        save(list, to: url)
        return list
    }
    @discardableResult
    static func remove(_ name: String, from url: URL = defaultURL) -> [StylePreset] {
        let list = load(url).filter { $0.name != name }
        save(list, to: url)
        return list
    }
}
