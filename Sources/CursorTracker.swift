import Cocoa
import QuartzCore

/// Enregistre la souris pendant le tournage (60 fois par seconde, sans autorisation particulière) :
/// position normalisée 0…1 dans l'écran filmé (origine en haut à gauche, comme la vidéo) et clic gauche.
/// Sert au montage automatique : zooms sur les clics et suivi du curseur.
final class CursorTracker {
    struct Track: Codable {
        var screenWidth: Double     // en points
        var screenHeight: Double
        var samples: [[Double]]     // [t secondes, x 0…1, y 0…1, clic 0/1, n° d'image de curseur]
        var cursors: [CursorImage]? = nil   // présent = curseur absent de la vidéo, redessiné au montage
    }
    /// Image d'un curseur système rencontré (flèche, main, barre de texte…), enregistrée en PNG haute définition.
    struct CursorImage: Codable {
        var file: String
        var width: Double           // en points
        var height: Double
        var hotX: Double            // point actif, depuis le haut à gauche
        var hotY: Double
    }

    private var timer: Timer?
    private var frame = NSRect.zero
    private var samples: [[Double]] = []
    private var cursorImages: [CursorImage] = []
    private var cursorKeys: [String: Int] = [:]
    private var lastCursor: NSCursor?
    private var lastCursorIndex = 0.0
    private var dir: URL?

    /// `video` : fichier de destination (les images de curseur sont rangées à côté, dans .meta).
    /// `frame` : zone filmée en coordonnées écran (écran entier, fenêtre ou zone dessinée).
    func begin(frame: NSRect, video: URL) {
        self.frame = frame
        samples = []
        cursorImages = []; cursorKeys = [:]; lastCursor = nil; lastCursorIndex = 0
        dir = video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).cursors", isDirectory: true)
        if let dir = dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func sample() {
        let p = NSEvent.mouseLocation
        let x = (p.x - frame.minX) / frame.width
        let y = 1 - (p.y - frame.minY) / frame.height
        let down = NSEvent.pressedMouseButtons & 1 == 1 ? 1.0 : 0.0
        let t = CACurrentMediaTime()        // horloge machine brute : recalée sur la vidéo à la fin (pauses retirées)
        let ci = cursorIndex()
        // on ne garde un point que s'il apporte quelque chose (mouvement ou changement de clic)
        if let last = samples.last, last[3] == down, last.count > 4, last[4] == ci,
           abs(last[1] - x) < 0.0005, abs(last[2] - y) < 0.0005, t - last[0] < 0.5 { return }
        samples.append([t, x, y, down, ci])
    }

    /// N° de l'image du curseur affiché en ce moment (enregistrée la première fois qu'on la voit).
    private func cursorIndex() -> Double {
        let c = NSCursor.currentSystem ?? NSCursor.arrow
        if c === lastCursor { return lastCursorIndex }
        lastCursor = c
        let img = c.image
        guard let tiff = img.tiffRepresentation else { return lastCursorIndex }
        let key = "\(tiff.count)-\(tiff.hashValue)-\(c.hotSpot.x)-\(c.hotSpot.y)"
        if let i = cursorKeys[key] { lastCursorIndex = Double(i); return lastCursorIndex }
        let i = cursorImages.count
        let name = "\(i).png"
        // rendu à 4× pour rester net quand le curseur est agrandi et zoomé
        let px = NSSize(width: max(1, (img.size.width * 4).rounded()), height: max(1, (img.size.height * 4).rounded()))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(origin: .zero, size: px))
            NSGraphicsContext.restoreGraphicsState()
            if let dir = dir { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name)) }
        }
        cursorImages.append(CursorImage(file: name, width: img.size.width, height: img.size.height, hotX: c.hotSpot.x, hotY: c.hotSpot.y))
        cursorKeys[key] = i
        lastCursorIndex = Double(i)
        return lastCursorIndex
    }

    /// Arrête et écrit le fichier à côté de la vidéo : <dossier>/.meta/<vidéo>.cursor.json
    /// `clock` : horloge du tournage (début de la vidéo + pauses) pour caler le curseur sur l'image.
    func end(saveFor video: URL, clock: PauseClock) {
        timer?.invalidate(); timer = nil
        let dir = video.deletingLastPathComponent().appendingPathComponent(".meta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let track = Track(screenWidth: frame.width, screenHeight: frame.height, samples: Self.retime(samples, clock: clock),
                          cursors: cursorImages.isEmpty ? nil : cursorImages)
        try? JSONEncoder().encode(track).write(to: Self.url(for: video))
    }

    func cancel() { timer?.invalidate(); timer = nil }

    /// Instants machine → temps de la vidéo finale : points avant le début ou pendant une pause retirés.
    /// Le dernier point caché est replacé au moment de la reprise : la souris repart d'où elle était vraiment.
    static func retime(_ raw: [[Double]], clock: PauseClock) -> [[Double]] {
        var out: [[Double]] = []
        var held: [Double]?
        for s in raw {
            guard let t = clock.map(s[0]) else { held = s; continue }
            if var h = held, let t0 = clock.resumeTime(after: h[0]), t0 < t { h[0] = t0; out.append(h) }
            held = nil
            var r = s; r[0] = t; out.append(r)
        }
        return out.map { var r = $0; r[0] = (r[0] * 1000).rounded() / 1000; return r }
    }

    static func url(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).cursor.json")
    }

    static func load(for video: URL) -> Track? {
        guard let d = try? Data(contentsOf: url(for: video)) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: d)
    }
}
