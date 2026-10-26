import AVFoundation
import CoreImage
import Vision
import AppKit

/// Données « image » préparées une fois par montage (lues sur disque, jamais à chaque image) :
/// visage suivi, silences (bulle masquée), raccourcis clavier, loupes, image de fond.
struct LookData {
    var face: FaceTrack.Smoothed?
    var silences: [(start: Double, end: Double)] = []
    var keys: [KeyEvents.Event] = []
    var loupes: [ZoomSegment] = []
    var loupePath: CursorPath.Path?
    var backgroundImage: CIImage?

    /// `wait` (export) : calcule le suivi du visage s'il manque ; l'aperçu prend seulement ce qui est en cache.
    static func prepare(video: URL, settings s: EditSettings, zooms: [ZoomSegment], track: CursorTracker.Track?,
                        duration: Double, wait: Bool) async -> LookData {
        var d = LookData()
        if s.faceTracking, s.wantsCamera {
            let raw = wait ? await FaceAnalysis.compute(for: video) : FaceTrack.cached(for: video)
            if let r = raw {
                d.face = FaceTrack.smooth(r.points.map { p in p.flatMap { $0.count >= 2 ? ($0[0], $0[1]) : nil } }, step: r.step)
            }
        }
        if s.hideCameraInSilence, s.wantsCamera { d.silences = await Silence.cuts(for: video).map { ($0.start, $0.end) } }
        if s.showKeys { d.keys = KeyEvents.load(for: video) }
        d.loupes = zooms.filter(\.isLoupe)
        if !d.loupes.isEmpty, let t = track { d.loupePath = CursorPath.bake(track: t, duration: duration, settings: s) }
        d.backgroundImage = await Backgrounds.image(s)
        return d
    }
}

/// Analyse du visage dans le fichier caméra (Vision), toutes les 0,5 s, mise en cache dans .meta/<vidéo>.face.json.
enum FaceAnalysis {
    static let step = 0.5

    static func compute(for video: URL) async -> FaceTrack.Raw? {
        if let c = FaceTrack.cached(for: video) { return c }
        guard let rec = RecordingInfo.load(for: video), let cam = rec.cameraFile else { return nil }
        let camURL = video.deletingLastPathComponent().appendingPathComponent(".meta/\(cam)")
        guard let raw = await analyze(camURL) else { return nil }
        try? JSONEncoder().encode(raw).write(to: FaceTrack.url(for: video))
        return raw
    }

    static func analyze(_ url: URL) async -> FaceTrack.Raw? {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration).seconds, dur > 0 else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = CMTime(seconds: step / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: 600)
        var pts: [[Double]?] = []
        var t = 0.0
        while t < dur {
            var p: [Double]?
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let req = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cgImage: img).perform([req])
                // le plus grand visage (celui qui parle, au premier plan)
                if let f = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                    let b = f.boundingBox
                    p = [Double(b.midX), Double(b.midY), Double(b.width)]
                }
            }
            pts.append(p)
            t += step
        }
        return FaceTrack.Raw(step: step, points: pts)
    }
}

/// Rendu sobre de la caméra (Core Image) : légère teinte, contraste, netteté.
enum CameraLook {
    static func apply(_ img: CIImage, look: String, sharpen: Double) -> CIImage {
        var o = img
        switch look {
        case "chaud":
            o = o.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.06, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.92, w: 0)])
        case "froid":
            o = o.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.94, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1.07, w: 0)])
        case "contraste":
            o = o.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.14, kCIInputSaturationKey: 1.06])
        default: break
        }
        if sharpen > 0.01 {
            o = o.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.9 * sharpen, kCIInputRadiusKey: 1.6])
        }
        return o
    }
}

/// Pastille des raccourcis clavier (« ⌘K ») : texte blanc sur aplat sombre, une image par raccourci, en cache.
final class KeyLayer {
    private let events: [KeyEvents.Event]
    private let fontSize: CGFloat
    private let centerX: CGFloat
    private let bottomY: CGFloat
    private var cache: [Int: CIImage] = [:]
    private let lock = NSLock()

    init(events: [KeyEvents.Event], renderSize: CGSize, bottomY: CGFloat) {
        self.events = events
        fontSize = (min(renderSize.width, renderSize.height) * 0.042).rounded()
        centerX = renderSize.width / 2
        self.bottomY = bottomY
    }

    func image(at t: Double) -> CIImage? {
        guard let (i, a) = KeyEvents.active(events, at: t) else { return nil }
        lock.lock()
        let img = cache[i] ?? draw(events[i].keys)
        cache[i] = img
        lock.unlock()
        guard let im = img else { return nil }
        return a >= 0.999 ? im : im.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }

    private func draw(_ keys: String) -> CIImage? {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)!
        let attr = NSAttributedString(string: keys, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let tw = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padX = fontSize * 0.6, padY = fontSize * 0.36
        let w = ceil(tw + 2 * padX), h = ceil(ascent + descent + 2 * padY)
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 0.86))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: fontSize * 0.36, cornerHeight: fontSize * 0.36, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(max(1, fontSize * 0.04))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1), cornerWidth: fontSize * 0.36, cornerHeight: fontSize * 0.36, transform: nil))
        ctx.strokePath()
        ctx.textPosition = CGPoint(x: padX, y: padY + descent)
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: (centerX - w / 2).rounded(), y: bottomY.rounded()))
    }
}

/// Annotations (texte, flèche, cadre) : texte blanc gras sur pastille noire arrondie (42 px en 1080p), flèche violette
/// de 8 px à pointe pleine, cadre violet de 6 px à coins arrondis. Tout est dessiné à la taille de l'image rendue.
final class AnnotationLayer {
    static let violet = CIColor(red: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255)
    private let unit: CGFloat
    private var pills: [String: CIImage] = [:]
    private let lock = NSLock()

    init(unit: CGFloat) { self.unit = unit }

    static func fontSize(unit: CGFloat) -> CGFloat { (42 * unit).rounded() }

    /// Taille de la pastille d'un texte (pour l'encadrer dans l'éditeur).
    static func pillSize(_ text: String, unit: CGFloat) -> CGSize {
        let fs = fontSize(unit: unit)
        let (_, asc, desc, tw) = layout(text, fs)
        return CGSize(width: ceil(tw + 1.2 * fs), height: ceil(asc + desc + 0.72 * fs))
    }

    private static func layout(_ text: String, _ fs: CGFloat) -> (CTLine, CGFloat, CGFloat, CGFloat) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fs, nil)!
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        return (line, a, d, w)
    }

    /// `p` / `q` : points de l'image rendue (origine en bas à gauche) ; `clip` : zone où l'annotation peut apparaître.
    func image(_ a: Annotation, alpha: Double, p: CGPoint, q: CGPoint, clip: CGRect) -> CIImage? {
        guard alpha > 0.001 else { return nil }
        var img: CIImage?
        switch a.kind {
        case "fleche": img = arrow(from: p, to: q, clip: clip)
        case "cadre": img = frame(p, q)
        default: img = pill(a.text, center: p)
        }
        guard let im = img else { return nil }
        let faded = alpha >= 0.999 ? im : im.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
        return faded.cropped(to: clip)
    }

    private func pill(_ text: String, center: CGPoint) -> CIImage? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        lock.lock()
        var base = pills[t]
        if base == nil { base = drawPill(t); pills[t] = base }
        lock.unlock()
        guard let b = base else { return nil }
        return b.transformed(by: CGAffineTransform(translationX: (center.x - b.extent.width / 2).rounded(), y: (center.y - b.extent.height / 2).rounded()))
    }

    private func drawPill(_ text: String) -> CIImage? {
        let fs = Self.fontSize(unit: unit)
        let (line, asc, desc, tw) = Self.layout(text, fs)
        let padX = 0.6 * fs, padY = 0.36 * fs
        let w = ceil(tw + 2 * padX), h = ceil(asc + desc + 2 * padY)
        guard w < 8000, let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 0.9))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: h * 0.32, cornerHeight: h * 0.32, transform: nil))
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: padX, y: padY + desc)
        CTLineDraw(line, ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Cadre violet de 6 px (1080p) : anneau = grand rectangle arrondi moins le petit, sur le GPU.
    private func frame(_ p: CGPoint, _ q: CGPoint) -> CIImage? {
        let w = 6 * unit
        let r = CGRect(x: min(p.x, q.x), y: min(q.y, p.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
        guard r.width > 2 * w, r.height > 2 * w else { return nil }
        let outer = r.insetBy(dx: -w / 2, dy: -w / 2), inner = r.insetBy(dx: w / 2, dy: w / 2)
        func rr(_ rect: CGRect, _ rad: CGFloat) -> CIImage {
            CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect), "inputRadius": rad, "inputColor": Self.violet,
            ])!.outputImage!.cropped(to: rect)
        }
        let rad = min(12 * unit, outer.width / 2, outer.height / 2)
        let hole = rr(inner, max(0, min(rad - w, inner.width / 2, inner.height / 2)))
        return rr(outer, rad).applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: hole])
    }

    /// Flèche violette de 8 px, pointe pleine. Dessinée dans une image de la taille de la flèche seulement.
    private func arrow(from p: CGPoint, to q: CGPoint, clip: CGRect) -> CIImage? {
        let len = hypot(q.x - p.x, q.y - p.y)
        guard len > 4 * unit else { return nil }
        let wd = 8 * unit, headL = min(len * 0.6, 34 * unit), headW = 30 * unit
        let pad = headW + wd
        let box = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
            .insetBy(dx: -pad, dy: -pad).intersection(clip).integral
        guard !box.isNull, box.width >= 1, box.height >= 1, box.width < 8000, box.height < 8000,
              let ctx = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        let ux = (q.x - p.x) / len, uy = (q.y - p.y) / len
        let base = CGPoint(x: q.x - ux * headL, y: q.y - uy * headL)
        ctx.setStrokeColor(CGColor(red: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255, alpha: 1))
        ctx.setFillColor(CGColor(red: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255, alpha: 1))
        ctx.setLineWidth(wd); ctx.setLineCap(.round)
        ctx.move(to: p); ctx.addLine(to: CGPoint(x: base.x + ux * 2 * unit, y: base.y + uy * 2 * unit)); ctx.strokePath()
        ctx.move(to: q)
        ctx.addLine(to: CGPoint(x: base.x - uy * headW / 2, y: base.y + ux * headW / 2))
        ctx.addLine(to: CGPoint(x: base.x + uy * headW / 2, y: base.y - ux * headW / 2))
        ctx.closePath(); ctx.fillPath()
        return ctx.makeImage().map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY)) }
    }
}

extension Backgrounds {
    /// Image de fond : fond d'écran macOS courant ("fond-ecran") ou image choisie ("image"). nil sinon ou si illisible.
    static func image(_ s: EditSettings) async -> CIImage? {
        var url: URL?
        switch s.background {
        case "fond-ecran": url = await MainActor.run { NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) } }
        case "image": url = s.backgroundImage.map { URL(fileURLWithPath: $0) }
        default: return nil
        }
        guard let u = url, !u.hasDirectoryPath else { return nil }
        return CIImage(contentsOf: u)
    }

    private static let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// Image recadrée pour remplir `size`, calculée une seule fois (pas de mise à l'échelle à chaque image).
    static func filled(_ img: CIImage, size: CGSize) -> CIImage? {
        let e = img.extent
        guard e.width > 0, e.height > 0, e.width.isFinite else { return nil }
        let k = max(size.width / e.width, size.height / e.height)
        let scaled = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        let dx = (scaled.extent.width - size.width) / 2, dy = (scaled.extent.height - size.height) / 2
        let placed = scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: CGRect(origin: .zero, size: size))
        guard let cg = ctx.createCGImage(placed, from: CGRect(origin: .zero, size: size)) else { return nil }
        return CIImage(cgImage: cg)
    }
}
