import Foundation
import CoreGraphics

/// Réglages de montage d'une vidéo, enregistrés dans <dossier>/.meta/<vidéo>.edit.json.
struct EditSettings: Codable, Equatable {
    var trimStart: Double = 0           // secondes coupées au début
    var trimEnd: Double = 0             // secondes coupées à la fin
    var autoZoom = true
    var zooms: [ZoomSegment]? = nil     // nil = générés automatiquement à partir des clics
    var background = "violet"           // voir Backgrounds
    var padding: Double = 0.06          // marge autour de l'écran (part de la largeur)
    var radius: Double = 18             // coins arrondis (px en 1080p)
    var showCamera = true
    var cursorScale: Double = 1.6       // curseur agrandi (comme Screen Studio)
    var smoothCursor = true
    var hideIdleCursor = true
    var clickEffect = true
    var removeSilences = true           // coupe les pauses de plus de 0,8 s
    var captions = true                 // sous-titres automatiques (Whisper, en local)
    // son et montage (comme Screen Studio)
    var noiseReduction = true           // voix débruitée par ffmpeg (cache .meta/<vidéo>.clean.m4a)
    var removeFillers = true            // coupe les « euh », « hum », « bah »… isolés (mots de Whisper)
    var cuts: [CutRange]? = nil         // passages supprimés depuis le texte (temps source)
    var speedRanges: [SpeedRange]? = nil // passages accélérés à la main (temps source)
    var speedUpTyping = true            // passages de frappe au clavier accélérés ×3
    var music: String? = nil            // fichier de ~/Music/X-Videos, nil = pas de musique
    var musicVolume: Double = 0.12      // volume de la musique sous la voix (remonte dans les blancs)
    var clickSounds = false             // petit son à chaque clic
    var captionStyle = "pastille"       // "pastille", "karaoke" ou "minimal"
    var exportHeight = 1080             // 720, 1080 ou 2160 (4K)
    var exportFPS = 30                  // 30 ou 60 images par seconde
    // — image (comme Screen Studio) —
    var aspect = "16:9"                 // "16:9" / "1:1" / "9:16", voir Formats
    var reelsGuides = true              // repères Reels / TikTok (aperçu seulement)
    var cameraLayout = "bulle"          // "bulle" / "plein-ecran" / "cote-a-cote" / "ecran-seul"
    var cameraIntroOutro: Double = 0    // secondes de caméra plein écran au début et à la fin (0 = non)
    var hideCameraInSilence = false     // la bulle s'efface pendant les silences
    var cameraLook = "naturel"          // "naturel" / "chaud" / "froid" / "contraste"
    var cameraSharpen: Double = 0       // netteté de la caméra 0…1
    var cameraBackground = "aucun"      // fond derrière la personne : "aucun" / "flou" / "couleur" (noir), voir CameraCutout
    var faceTracking = false            // visage gardé au centre de la bulle (Vision)
    var motionBlur: Double = 0.5        // flou de mouvement des zooms 0…1 (0 = non)
    var masks: [MaskRegion]? = nil      // zones floutées ou mises en lumière
    var annotations: [Annotation]? = nil // texte, flèche et cadre posés sur l'écran filmé
    var showKeys = false                // raccourcis clavier affichés en bas
    var backgroundImage: String? = nil  // chemin de l'image perso (fond "image")
    var shadow: Double = 1              // intensité de l'ombre 0…1,5
    var globalSpeed: Double = 1         // toute la vidéo accélérée (×1, ×1,25, ×1,5, ×2), en plus des passages accélérés
    // — audios importés (voix off, sons) posés sur la frise —
    var audioClips: [AudioClip]? = nil
    var muteOriginal = false            // son d'origine coupé (silences, « euh » et sous-titres de la voix d'origine ignorés)

    init() {}

    /// Taille de rendu selon le format (`short` = petit côté : 1080 à l'export, 720 dans l'aperçu).
    func renderSize(short: CGFloat = 1080) -> CGSize { Formats.size(aspect, short: short) }
    /// La piste caméra sert si elle apparaît dans la mise en page ou en intro / fin.
    var wantsCamera: Bool { showCamera && (cameraLayout != "ecran-seul" || cameraIntroOutro > 0) }

    /// Lecture tolérante : un réglage absent (fichier écrit par une version plus ancienne) prend sa valeur par défaut,
    /// au lieu de faire échouer toute la lecture et d'effacer les réglages de l'utilisateur.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = EditSettings()
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? def.trimStart
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd) ?? def.trimEnd
        autoZoom = try c.decodeIfPresent(Bool.self, forKey: .autoZoom) ?? def.autoZoom
        zooms = try c.decodeIfPresent([ZoomSegment].self, forKey: .zooms)
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? def.background
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? def.padding
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? def.radius
        showCamera = try c.decodeIfPresent(Bool.self, forKey: .showCamera) ?? def.showCamera
        cursorScale = try c.decodeIfPresent(Double.self, forKey: .cursorScale) ?? def.cursorScale
        smoothCursor = try c.decodeIfPresent(Bool.self, forKey: .smoothCursor) ?? def.smoothCursor
        hideIdleCursor = try c.decodeIfPresent(Bool.self, forKey: .hideIdleCursor) ?? def.hideIdleCursor
        clickEffect = try c.decodeIfPresent(Bool.self, forKey: .clickEffect) ?? def.clickEffect
        removeSilences = try c.decodeIfPresent(Bool.self, forKey: .removeSilences) ?? def.removeSilences
        captions = try c.decodeIfPresent(Bool.self, forKey: .captions) ?? def.captions
        noiseReduction = try c.decodeIfPresent(Bool.self, forKey: .noiseReduction) ?? def.noiseReduction
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? def.removeFillers
        cuts = try? c.decodeIfPresent([CutRange].self, forKey: .cuts)
        speedRanges = try? c.decodeIfPresent([SpeedRange].self, forKey: .speedRanges)
        speedUpTyping = try c.decodeIfPresent(Bool.self, forKey: .speedUpTyping) ?? def.speedUpTyping
        music = try c.decodeIfPresent(String.self, forKey: .music)
        musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? def.musicVolume
        clickSounds = try c.decodeIfPresent(Bool.self, forKey: .clickSounds) ?? def.clickSounds
        captionStyle = try c.decodeIfPresent(String.self, forKey: .captionStyle) ?? def.captionStyle
        exportHeight = try c.decodeIfPresent(Int.self, forKey: .exportHeight) ?? def.exportHeight
        exportFPS = try c.decodeIfPresent(Int.self, forKey: .exportFPS) ?? def.exportFPS
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect) ?? def.aspect
        reelsGuides = try c.decodeIfPresent(Bool.self, forKey: .reelsGuides) ?? def.reelsGuides
        cameraLayout = try c.decodeIfPresent(String.self, forKey: .cameraLayout) ?? def.cameraLayout
        cameraIntroOutro = try c.decodeIfPresent(Double.self, forKey: .cameraIntroOutro) ?? def.cameraIntroOutro
        hideCameraInSilence = try c.decodeIfPresent(Bool.self, forKey: .hideCameraInSilence) ?? def.hideCameraInSilence
        cameraLook = try c.decodeIfPresent(String.self, forKey: .cameraLook) ?? def.cameraLook
        cameraSharpen = try c.decodeIfPresent(Double.self, forKey: .cameraSharpen) ?? def.cameraSharpen
        cameraBackground = try c.decodeIfPresent(String.self, forKey: .cameraBackground) ?? def.cameraBackground
        faceTracking = try c.decodeIfPresent(Bool.self, forKey: .faceTracking) ?? def.faceTracking
        motionBlur = try c.decodeIfPresent(Double.self, forKey: .motionBlur) ?? def.motionBlur
        masks = try? c.decodeIfPresent([MaskRegion].self, forKey: .masks)
        annotations = try? c.decodeIfPresent([Annotation].self, forKey: .annotations)
        showKeys = try c.decodeIfPresent(Bool.self, forKey: .showKeys) ?? def.showKeys
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? def.shadow
        globalSpeed = try c.decodeIfPresent(Double.self, forKey: .globalSpeed) ?? def.globalSpeed
        audioClips = try? c.decodeIfPresent([AudioClip].self, forKey: .audioClips)
        muteOriginal = try c.decodeIfPresent(Bool.self, forKey: .muteOriginal) ?? def.muteOriginal
    }

    static func url(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).edit.json")
    }
    static func load(for video: URL) -> EditSettings {
        guard let d = try? Data(contentsOf: url(for: video)), let e = try? JSONDecoder().decode(EditSettings.self, from: d) else { return EditSettings() }
        return e
    }
    func save(for video: URL) {
        let u = Self.url(for: video)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: u)
    }
}

struct ZoomSegment: Codable, Equatable, Identifiable {
    var start: Double
    var end: Double
    var scale: Double = 1.8
    var kind: String? = nil             // nil = zoom du cadre, "loupe" = cercle grossissant autour du curseur
    var id: String { "\(start)-\(end)" }
    var isLoupe: Bool { kind == "loupe" }

    init(start: Double, end: Double, scale: Double = 1.8, kind: String? = nil) {
        self.start = start; self.end = end; self.scale = scale; self.kind = kind
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.8
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }
}

/// Annotation posée sur l'écran filmé (comme dans Loom) : "texte", "fleche" ou "cadre".
/// Positions normalisées 0…1 dans l'écran filmé (origine en haut à gauche, suivent les zooms comme les masques) :
/// texte = centre de la pastille (x, y) ; flèche = départ (x, y) et pointe (x2, y2) ; cadre = deux coins opposés.
struct Annotation: Codable, Equatable, Identifiable {
    var kind: String = "texte"
    var x: Double = 0.5, y: Double = 0.5
    var x2: Double = 0.5, y2: Double = 0.5
    var text: String = ""
    var start: Double = 0, end: Double = 3      // temps source
    var id: String { "\(kind)-\(start)-\(end)-\(x)-\(y)-\(x2)-\(y2)-\(text)" }

    init(kind: String, x: Double, y: Double, x2: Double? = nil, y2: Double? = nil, text: String = "", start: Double, end: Double) {
        self.kind = kind; self.x = x; self.y = y; self.x2 = x2 ?? x; self.y2 = y2 ?? y
        self.text = text; self.start = start; self.end = end
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "texte"
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        x2 = try c.decodeIfPresent(Double.self, forKey: .x2) ?? x
        y2 = try c.decodeIfPresent(Double.self, forKey: .y2) ?? y
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 3
    }

    static let fade = 0.2
    /// Opacité au temps source `t` : fondu de 0,2 s à l'apparition et à la disparition (0 hors de la plage).
    func alpha(at t: Double) -> Double {
        guard t >= start, t < end else { return 0 }
        return max(0, min(1, min((t - start) / Self.fade + 0.0001, (end - t) / Self.fade)))
    }
    /// Déplace l'annotation en la gardant dans l'écran filmé.
    mutating func translate(dx: Double, dy: Double) {
        let ddx = max(-min(x, x2), min(1 - max(x, x2), dx)), ddy = max(-min(y, y2), min(1 - max(y, y2), dy))
        x += ddx; x2 += ddx; y += ddy; y2 += ddy
    }
}

/// Audio importé (voix off, son) : fichier rangé dans .meta/audio/, posé à l'instant `at` (temps source,
/// donc il reste collé à son image si on coupe avant lui), joué à vitesse normale pendant `dur` secondes.
struct AudioClip: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var file: String
    var name: String
    var at: Double
    var dur: Double
    var volume: Double = 1
}

/// Passage coupé (temps source).
struct CutRange: Codable, Equatable, Hashable {
    var start: Double
    var end: Double
}

/// Passage accéléré (temps source) : vitesse 1,5, 2, 3 ou 4.
struct SpeedRange: Codable, Equatable, Hashable {
    var start: Double
    var end: Double
    var speed: Double = 2
    init(start: Double, end: Double, speed: Double = 2) { self.start = start; self.end = end; self.speed = speed }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 2
    }
}

/// Infos du tournage : position de la bulle caméra et décalage du fichier caméra.
struct RecordingInfo: Codable {
    var cameraFile: String?             // fichier caméra séparé (.meta/<vidéo>.camera.mov)
    var cameraOffset: Double = 0        // la caméra a démarré N s après l'écran
    var bubbleX: Double = 0.1           // centre de la bulle, 0…1 (origine en haut à gauche)
    var bubbleY: Double = 0.85
    var bubbleSize: Double = 0.17       // diamètre / hauteur de l'écran

    init(cameraFile: String? = nil, cameraOffset: Double = 0, bubbleX: Double = 0.1, bubbleY: Double = 0.85, bubbleSize: Double = 0.17) {
        self.cameraFile = cameraFile; self.cameraOffset = cameraOffset
        self.bubbleX = bubbleX; self.bubbleY = bubbleY; self.bubbleSize = bubbleSize
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        cameraFile = try c.decodeIfPresent(String.self, forKey: .cameraFile)
        cameraOffset = try c.decodeIfPresent(Double.self, forKey: .cameraOffset) ?? 0
        bubbleX = try c.decodeIfPresent(Double.self, forKey: .bubbleX) ?? 0.1
        bubbleY = try c.decodeIfPresent(Double.self, forKey: .bubbleY) ?? 0.85
        bubbleSize = try c.decodeIfPresent(Double.self, forKey: .bubbleSize) ?? 0.17
    }

    static func url(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).rec.json")
    }
    static func load(for video: URL) -> RecordingInfo? {
        guard let d = try? Data(contentsOf: url(for: video)) else { return nil }
        return try? JSONDecoder().decode(RecordingInfo.self, from: d)
    }
    func save(for video: URL) {
        let u = Self.url(for: video)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: u)
    }
}

/// Montage automatique : zooms sur les clics, caméra qui suit la souris avec un ressort.
enum AutoZoom {
    // Réglages repris de Cap (auto-zoom par clics) : début 0,3 s avant le clic, maintien 2,5 s,
    // clics à moins de 2,5 s fusionnés, zoom 2×, rien dans la dernière seconde (le clic « Terminer »).
    static let scale = 2.0
    static let leadIn = 0.3
    static let hold = 2.5
    static let mergeGap = 2.5
    static let minDuration = 1.0
    static let ignoreLast = 1.0
    static let endMargin = 0.8

    static func segments(from track: CursorTracker.Track?, duration: Double) -> [ZoomSegment] {
        guard let track = track else { return [] }
        // instants des clics (front montant)
        var clicks: [Double] = []
        var wasDown = false
        for s in track.samples {
            let down = s[3] > 0.5
            if down && !wasDown { clicks.append(s[0]) }
            wasDown = down
        }
        var out: [ZoomSegment] = []
        for c in clicks where c < duration - ignoreLast {
            let start = max(0, c - leadIn), end = min(duration - endMargin, c + hold)
            if let last = out.last, start - last.end < mergeGap {
                out[out.count - 1].end = max(last.end, end)
            } else {
                out.append(ZoomSegment(start: start, end: end, scale: scale))
            }
        }
        return out.filter { $0.end - $0.start >= minDuration }
    }

    /// Trajectoire de la caméra précalculée à 60 Hz (identique en aperçu et à l'export).
    /// Chaque point : centre (0…1, origine en haut à gauche) et facteur de zoom.
    struct Path {
        let fps = 60.0
        var points: [(x: Double, y: Double, s: Double)]

        func sample(_ t: Double) -> (x: Double, y: Double, s: Double) {
            guard !points.isEmpty else { return (0.5, 0.5, 1) }
            let f = max(0, min(Double(points.count - 1), t * fps))
            let i = Int(f), j = min(points.count - 1, i + 1), k = f - Double(i)
            let a = points[i], b = points[j]
            return (a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k, a.s + (b.s - a.s) * k)
        }
    }

    static func bake(zooms: [ZoomSegment], track: CursorTracker.Track?, duration: Double) -> Path {
        let zooms = zooms.filter { !$0.isLoupe }      // la loupe ne bouge pas le cadre
        let fps = 60.0, dt = 1 / fps
        let n = Int(duration * fps) + 2
        var cx = Spring(x: 0.5), cy = Spring(x: 0.5), cs = Spring(x: 1)
        var focusX = 0.5, focusY = 0.5
        var si = 0
        let samples = track?.samples ?? []
        var pts: [(x: Double, y: Double, s: Double)] = []
        pts.reserveCapacity(n)
        for f in 0..<n {
            let t = Double(f) * dt
            while si + 1 < samples.count && samples[si + 1][0] <= t { si += 1 }
            let mouse = samples.isEmpty ? (0.5, 0.5) : (samples[si][1], samples[si][2])
            let z = zooms.first(where: { t >= $0.start && t < $0.end })
            let target = z?.scale ?? 1
            if z != nil {
                // zone morte : on ne recadre que si la souris s'approche du bord de la zone visible
                let half = 0.5 / target, margin = half * 0.25
                if abs(mouse.0 - focusX) > half - margin { focusX += (mouse.0 - focusX) - (half - margin) * (mouse.0 > focusX ? 1 : -1) }
                if abs(mouse.1 - focusY) > half - margin { focusY += (mouse.1 - focusY) - (half - margin) * (mouse.1 > focusY ? 1 : -1) }
                if cs.x < 1.05 { focusX = mouse.0; focusY = mouse.1 }   // au début du zoom : on vise le clic
            } else {
                focusX = 0.5; focusY = 0.5
            }
            cs.step(to: target, dt: dt, w: 9)
            cx.step(to: focusX, dt: dt, w: 10)
            cy.step(to: focusY, dt: dt, w: 10)
            // on garde la zone visible dans l'écran
            let half = 0.5 / max(1, cs.x)
            pts.append((min(1 - half, max(half, cx.x)), min(1 - half, max(half, cy.x)), max(1, cs.x)))
        }
        return Path(points: pts)
    }
}

/// Curseur redessiné : position adoucie, opacité (masqué au repos), image, clic.
enum CursorPath {
    struct Point { var x: Double; var y: Double; var alpha: Double; var image: Int; var down: Bool; var sinceClick: Double }
    struct Path {
        let fps = 60.0
        var points: [Point]
        func sample(_ t: Double) -> Point? {
            guard !points.isEmpty else { return nil }
            let i = max(0, min(points.count - 1, Int((t * fps).rounded())))
            return points[i]
        }
    }

    static func bake(track: CursorTracker.Track, duration: Double, settings: EditSettings) -> Path {
        let fps = 60.0, dt = 1 / fps
        let s = track.samples
        guard !s.isEmpty else { return Path(points: []) }
        let n = Int(duration * fps) + 2
        // ressort repris de Cap (pulsation ≈ 12,5, quasi critique) ; on vise la position un peu en avance
        // pour compenser le retard du ressort et rester synchro avec ce qui se passe à l'écran
        let w = settings.smoothCursor ? 13.0 : 400.0
        let lookahead = settings.smoothCursor ? 0.12 : 0
        var sx = Spring(x: s[0][1]), sy = Spring(x: s[0][2]), alpha = Spring(x: 1)
        var i = 0, j = 0
        var lastMove = 0.0, lastClick = -10.0
        var wasDown = false
        var pts: [Point] = []
        pts.reserveCapacity(n)
        for f in 0..<n {
            let t = Double(f) * dt
            while i + 1 < s.count && s[i + 1][0] <= t { i += 1 }
            while j + 1 < s.count && s[j + 1][0] <= t + lookahead { j += 1 }
            let cur = s[i], ahead = s[j]
            let down = cur[3] > 0.5
            if down && !wasDown { lastClick = cur[0] }
            wasDown = down
            if i > 0, abs(s[i][1] - s[i - 1][1]) + abs(s[i][2] - s[i - 1][2]) > 0.0015 { lastMove = max(lastMove, s[i][0]) }
            sx.step(to: ahead[1], dt: dt, w: w)
            sy.step(to: ahead[2], dt: dt, w: w)
            // masqué après 2 s d'immobilité, réapparaît dès qu'on bouge ou clique
            let idle = settings.hideIdleCursor && t - max(lastMove, lastClick) > 2.0
            alpha.step(to: idle ? 0 : 1, dt: dt, w: 12)
            pts.append(Point(x: sx.x, y: sy.x, alpha: max(0, min(1, alpha.x)), image: cur.count > 4 ? Int(cur[4]) : 0,
                             down: down, sinceClick: t - lastClick))
        }
        return Path(points: pts)
    }
}

/// Ressort amorti critique (pas de rebond), indépendant de la fréquence d'images.
struct Spring {
    var x: Double
    var v: Double = 0
    mutating func step(to target: Double, dt: Double, w: Double) {
        let d = x - target
        let e = exp(-w * dt)
        let c2 = v + w * d
        x = target + (d + c2 * dt) * e
        v = (v - w * c2 * dt) * e
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
