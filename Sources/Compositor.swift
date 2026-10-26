import AVFoundation
import CoreImage
import Metal

/// Place de chaque élément dans l'image, selon le format (16:9, 1:1, 9:16) et la mise en page de la caméra.
struct FrameLayout {
    var screen: CGRect                 // écran filmé
    var camera: CGRect?                // caméra hors intro / fin (nil = pas de caméra à l'écran)
    var cameraRadius: CGFloat
    var ring: Bool                     // bulle ronde cerclée de violet
    var screenVisible = true

    static func make(settings s: EditSettings, rec: RecordingInfo, hasCamera: Bool, sourceSize: CGSize,
                     renderSize: CGSize, showsFrame: Bool) -> FrameLayout {
        let W = renderSize.width, H = renderSize.height, unit = min(W, H) / 1080
        let pad = showsFrame ? s.padding * W : 0
        let avail = CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: pad, dy: pad)
        let a = sourceSize.width / max(1, sourceSize.height)
        // l'écran garde ses proportions, centré dans la zone disponible
        func fit(_ box: CGRect) -> CGRect {
            let k = min(box.width / sourceSize.width, box.height / sourceSize.height)
            let w = (sourceSize.width * k).rounded(), h = (sourceSize.height * k).rounded()
            return CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h)
        }
        let radius = showsFrame ? s.radius * unit : 0
        switch hasCamera ? s.cameraLayout : "ecran-seul" {
        case "plein-ecran":
            return FrameLayout(screen: fit(avail), camera: CGRect(x: 0, y: 0, width: W, height: H), cameraRadius: 0, ring: false, screenVisible: false)
        case "cote-a-cote":
            let gap = (0.025 * min(W, H)).rounded()
            if s.aspect == "9:16" {
                // écran en haut, caméra dessous, même largeur
                var sw = avail.width, sh = (sw / a).rounded()
                if sh > avail.height * 0.6 { sh = (avail.height * 0.6).rounded(); sw = (sh * a).rounded() }
                let ch = min(avail.height - sh - gap, sw.rounded())
                let top = (avail.midY + (sh + gap + ch) / 2).rounded()
                let x = (avail.midX - sw / 2).rounded()
                return FrameLayout(screen: CGRect(x: x, y: top - sh, width: sw, height: sh),
                                   camera: CGRect(x: x, y: top - sh - gap - ch, width: sw, height: ch), cameraRadius: radius, ring: false)
            }
            let c: CGFloat = 0.75      // caméra en portrait à droite
            let h = min(avail.height, (avail.width - gap) / (a + c)).rounded()
            let sw = (h * a).rounded(), cw = (h * c).rounded()
            let x0 = (avail.midX - (sw + gap + cw) / 2).rounded(), y0 = (avail.midY - h / 2).rounded()
            return FrameLayout(screen: CGRect(x: x0, y: y0, width: sw, height: h),
                               camera: CGRect(x: x0 + sw + gap, y: y0, width: cw, height: h), cameraRadius: radius, ring: false)
        case "bulle":
            if s.aspect == "9:16" {
                // vertical : écran, puis bulle centrée dessous, le tout au-dessus de l'interface Reels du bas
                var sw = avail.width, sh = (sw / a).rounded(), d = (0.36 * W).rounded()
                let gap = (0.04 * W).rounded()
                let k = min(1, avail.height * 0.8 / (sh + gap + d))
                sw = (sw * k).rounded(); sh = (sh * k).rounded(); d = (d * k).rounded()
                let top = (H * 0.53 + (sh + gap + d) / 2).rounded()
                let screen = CGRect(x: (W / 2 - sw / 2).rounded(), y: top - sh, width: sw, height: sh)
                return FrameLayout(screen: screen, camera: CGRect(x: (W / 2 - d / 2).rounded(), y: top - sh - gap - d, width: d, height: d),
                                   cameraRadius: d / 2, ring: true)
            }
            let screen = fit(avail)
            if s.aspect == "1:1" {
                // carré : bulle à cheval sur le coin bas gauche de l'écran
                let d = (0.26 * W).rounded()
                let cam = CGRect(x: (screen.minX + 0.03 * W).rounded(), y: max((0.03 * H).rounded(), (screen.minY - 0.3 * d).rounded()), width: d, height: d)
                return FrameLayout(screen: screen, camera: cam, cameraRadius: d / 2, ring: true)
            }
            // 16:9 : à l'endroit choisi au tournage
            let d = (rec.bubbleSize * screen.height).rounded()
            let cx = screen.minX + rec.bubbleX * screen.width, cy = screen.maxY - rec.bubbleY * screen.height
            return FrameLayout(screen: screen, camera: CGRect(x: (cx - d / 2).rounded(), y: (cy - d / 2).rounded(), width: d, height: d),
                               cameraRadius: d / 2, ring: true)
        default:
            return FrameLayout(screen: fit(avail), camera: nil, cameraRadius: 0, ring: false)
        }
    }
}

/// Une image du montage, calculée sur la carte graphique (Core Image + Metal) :
/// fond → ombre → écran zoomé aux coins arrondis → caméra (bulle, côte à côte, plein écran) → sous-titres, touches.
/// Utilisé à l'identique pour l'aperçu (AVPlayer) et pour l'export : ce que tu vois est ce que tu envoies.
final class EditInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    static let screenTrack: CMPersistentTrackID = 1
    static let cameraTrack: CMPersistentTrackID = 3

    let path: AutoZoom.Path
    let segments: [Renderer.Segment]   // correspondance temps du montage → temps source (coupes, silences)
    let hasCamera: Bool
    let rec: RecordingInfo
    let layout: FrameLayout
    let renderSize: CGSize
    private let look: LookData
    private let background: CIImage
    private var innerRect: CGRect { layout.screen }
    private let roundMask: CIImage
    private let shadow: CIImage
    private let outRect: CGRect
    private let showsFrame: Bool
    private let cursorPath: CursorPath.Path?
    private let cursorImages: [(img: CIImage, info: CursorTracker.CursorImage)]
    private let screenPoints: CGSize
    private let cursorScale: Double
    private let clickEffect: Bool
    private let unit: CGFloat
    private let motionBlur: Double
    private let masks: [MaskRegion]
    private let annotations: [Annotation]
    private let annotationLayer: AnnotationLayer
    private let cameraLook: String
    private let cameraSharpen: Double
    private let cameraBackground: String
    private let cutout = CameraCutout()
    private let introOutro: Double
    private var captionLayer: CaptionLayer?
    private var keyLayer: KeyLayer?

    init(timeRange: CMTimeRange, path: AutoZoom.Path, segments: [Renderer.Segment], settings: EditSettings,
         rec: RecordingInfo, hasCamera: Bool, sourceSize: CGSize, renderSize: CGSize,
         cursorPath: CursorPath.Path? = nil, cursorImages: [(img: CIImage, info: CursorTracker.CursorImage)] = [],
         screenPoints: CGSize = .zero, captions: [Captions.Word] = [], look: LookData = LookData()) {
        self.cursorPath = cursorPath
        self.cursorImages = cursorImages
        self.screenPoints = screenPoints
        self.cursorScale = settings.cursorScale
        self.clickEffect = settings.clickEffect
        self.timeRange = timeRange
        self.path = path
        self.segments = segments
        self.hasCamera = hasCamera
        self.rec = rec
        self.look = look
        self.renderSize = renderSize
        motionBlur = settings.motionBlur
        masks = settings.masks ?? []
        annotations = settings.annotations ?? []
        annotationLayer = AnnotationLayer(unit: min(renderSize.width, renderSize.height) / 1080)
        cameraLook = settings.cameraLook
        cameraSharpen = settings.cameraSharpen
        cameraBackground = settings.cameraBackground
        introOutro = hasCamera ? settings.cameraIntroOutro : 0
        requiredSourceTrackIDs = (hasCamera ? [Self.screenTrack, Self.cameraTrack] : [Self.screenTrack]).map { NSNumber(value: $0) }

        let W = renderSize.width, H = renderSize.height
        outRect = CGRect(x: 0, y: 0, width: W, height: H)
        unit = min(W, H) / 1080
        showsFrame = settings.background != "aucun"
        layout = FrameLayout.make(settings: settings, rec: rec, hasCamera: hasCamera, sourceSize: sourceSize,
                                  renderSize: renderSize, showsFrame: showsFrame)
        let inner = layout.screen
        let plain = CIImage(color: Backgrounds.color(settings.background) ?? CIColor(red: 0, green: 0, blue: 0)).cropped(to: outRect)
        // image de fond (bureau macOS ou fichier choisi), posée sur l'aplat au cas où elle serait transparente
        background = look.backgroundImage.flatMap { Backgrounds.filled($0, size: renderSize) }?.composited(over: plain) ?? plain

        let radius = showsFrame ? settings.radius * unit : 0
        roundMask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: inner), "inputRadius": radius, "inputColor": CIColor.white,
        ])!.outputImage!.cropped(to: inner)
        if showsFrame, settings.shadow > 0.01 {
            let dark = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: inner.offsetBy(dx: 0, dy: -10 * unit)), "inputRadius": radius,
                "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: min(0.9, 0.45 * settings.shadow)),
            ])!.outputImage!
            var sh = dark.applyingGaussianBlur(sigma: 22 * unit).cropped(to: outRect)
            // côte à côte : la caméra a la même ombre que l'écran
            if let c = layout.camera, !layout.ring, layout.screenVisible {
                let camDark = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: c.offsetBy(dx: 0, dy: -10 * unit)), "inputRadius": radius,
                    "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: min(0.9, 0.45 * settings.shadow)),
                ])!.outputImage!
                sh = camDark.applyingGaussianBlur(sigma: 22 * unit).cropped(to: outRect).composited(over: sh)
            }
            shadow = sh
        } else {
            shadow = CIImage.empty()
        }
        // sous-titres : centrés, en bas de l'écran (dans le cadre s'il y en a un)
        let capY = inner.minY + H * 0.05
        if !captions.isEmpty {
            let layer = CaptionLayer(words: captions, renderSize: renderSize, bottomY: capY, style: settings.captionStyle)
            captionLayer = layer.isEmpty ? nil : layer
        }
        // touches : juste au-dessus des sous-titres
        if !look.keys.isEmpty {
            keyLayer = KeyLayer(events: look.keys, renderSize: renderSize, bottomY: captionLayer == nil ? capY : capY + H * 0.075)
        }
        super.init()
    }

    /// Position (0…1 dans l'écran filmé, origine en haut à gauche) → point de l'image rendue, à travers le zoom.
    func toOutput(_ nx: Double, _ ny: Double, zoom z: (x: Double, y: Double, s: Double)) -> CGPoint {
        let vx = (nx - (z.x - 0.5 / z.s)) * z.s, vy = (ny - (z.y - 0.5 / z.s)) * z.s
        return CGPoint(x: innerRect.minX + vx * innerRect.width, y: innerRect.maxY - vy * innerRect.height)
    }
    /// L'inverse (dessin d'un masque sur l'aperçu) : point de l'image rendue → 0…1 dans l'écran filmé.
    func toScreen(_ p: CGPoint, zoom z: (x: Double, y: Double, s: Double)) -> (x: Double, y: Double) {
        ((z.x - 0.5 / z.s) + Double((p.x - innerRect.minX) / innerRect.width) / z.s,
         (z.y - 0.5 / z.s) + Double((innerRect.maxY - p.y) / innerRect.height) / z.s)
    }

    func render(screen: CIImage, camera: CIImage?, at compositionTime: Double) -> CIImage {
        let srcT = Renderer.sourceTime(compositionTime, segments)
        let full = CameraLayouts.introOutro(t: compositionTime, duration: timeRange.duration.seconds, seconds: introOutro)
        var out = background
        if layout.screenVisible && full < 0.999 {
            out = shadow.composited(over: out)
            out = screenLayer(screen, srcT: srcT).composited(over: out)
        }
        if let cam = camera, let c = cameraLayer(cam, full: full, srcT: srcT) { out = c.composited(over: out) }
        if full < 0.5 {
            if let cap = captionLayer?.image(at: srcT) { out = cap.composited(over: out) }
            if let k = keyLayer?.image(at: srcT) { out = k.composited(over: out) }
        }
        return out.cropped(to: outRect)
    }

    /// Écran zoomé, flou de mouvement, masques, loupe, coins arrondis, curseur.
    private func screenLayer(_ screen: CIImage, srcT: Double) -> CIImage {
        let src = screen.extent
        let z = path.sample(srcT)
        // zone de l'écran visible (en pixels source, origine Core Image en bas à gauche)
        let cw = src.width / z.s, ch = src.height / z.s
        let x0 = z.x * src.width - cw / 2
        let yTop = z.y * src.height - ch / 2
        let crop = CGRect(x: x0, y: src.height - yTop - ch, width: cw, height: ch)
        let k = innerRect.width / cw
        var shown = screen.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: innerRect.minX, y: innerRect.minY))
            .cropped(to: innerRect)
        if motionBlur > 0 {
            let dt = 1.0 / 60
            let m = MotionBlur.amount(a: path.sample(srcT - dt / 2), b: path.sample(srcT + dt / 2), dt: dt,
                                      width: innerRect.width, height: innerRect.height, intensity: motionBlur)
            if m.radius > 0 {
                shown = shown.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: m.radius, kCIInputAngleKey: m.angle])
                    .cropped(to: innerRect)
            }
            if m.zoom > 0 {
                shown = shown.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: CIVector(x: innerRect.midX, y: innerRect.midY), "inputAmount": m.zoom]).cropped(to: innerRect)
            }
        }
        for m in masks { if let r = maskLayer(m, on: shown, srcT: srcT, zoom: z) { shown = r } }
        if let l = loupeLayer(shown, srcT: srcT, zoom: z) { shown = l.composited(over: shown) }
        for a in annotations {
            let al = a.alpha(at: srcT)
            guard al > 0.001 else { continue }
            if let img = annotationLayer.image(a, alpha: al, p: toOutput(a.x, a.y, zoom: z), q: toOutput(a.x2, a.y2, zoom: z), clip: innerRect) {
                shown = img.composited(over: shown)
            }
        }
        var out = shown.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: roundMask,
        ])
        if let c = cursorLayer(at: srcT, zoom: z) { out = c.composited(over: out) }
        return out
    }

    /// Masque : "flou" (pixelisé puis flouté, illisible) ou "projecteur" (tout le reste assombri).
    private func maskLayer(_ m: MaskRegion, on shown: CIImage, srcT: Double, zoom z: (x: Double, y: Double, s: Double)) -> CIImage? {
        let a = m.alpha(at: srcT)
        guard a > 0.001 else { return nil }
        let p0 = toOutput(m.x, m.y, zoom: z), p1 = toOutput(m.x + m.w, m.y + m.h, zoom: z)
        let rect = CGRect(x: p0.x, y: p1.y, width: p1.x - p0.x, height: p0.y - p1.y).intersection(innerRect)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": min(8 * unit, rect.width / 2, rect.height / 2),
            "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: a),
        ])!.outputImage!.cropped(to: rect)
        if m.kind == "projecteur" {
            let dark = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.62 * a)).cropped(to: innerRect)
            return dark.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: shape]).composited(over: shown)
        }
        let blurred = shown.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(6, 22 * unit), kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY)])
            .applyingGaussianBlur(sigma: 8 * unit)
            .cropped(to: rect)
        return blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: shape,
        ]).composited(over: shown)
    }

    /// Loupe : cercle grossissant centré sur le curseur, qui s'ouvre et se ferme en 0,25 s.
    private func loupeLayer(_ shown: CIImage, srcT: Double, zoom z: (x: Double, y: Double, s: Double)) -> CIImage? {
        guard let l = look.loupes.first(where: { srcT >= $0.start && srcT < $0.end }),
              let p = (cursorPath ?? look.loupePath)?.sample(srcT) else { return nil }
        let e = max(0, min(1, min((srcT - l.start) / 0.25, (l.end - srcT) / 0.25)))
        let appear = e * e * (3 - 2 * e)
        guard appear > 0.01 else { return nil }
        let c = toOutput(p.x, p.y, zoom: z)
        let r = innerRect.height * 0.2 * (0.6 + 0.4 * appear)
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let mag = shown.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y))
            .transformed(by: CGAffineTransform(scaleX: l.scale, y: l.scale))
            .transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
            .cropped(to: disc)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: disc), "inputRadius": r, "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: appear),
        ])!.outputImage!
        let rw = max(2, 3 * unit)
        let ringRect = disc.insetBy(dx: -rw, dy: -rw)
        let ring = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: ringRect), "inputRadius": ringRect.width / 2,
            "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 0.92 * appear),
        ])!.outputImage!
        let lens = mag.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        return lens.composited(over: ring).cropped(to: innerRect)
    }

    /// Curseur redessiné à sa position adoucie, à travers le même zoom que l'écran, avec un cercle au clic.
    private func cursorLayer(at t: Double, zoom z: (x: Double, y: Double, s: Double)) -> CIImage? {
        guard let path = cursorPath, let p = path.sample(t), p.alpha > 0.01, !cursorImages.isEmpty, screenPoints.width > 0 else { return nil }
        let (img, info) = cursorImages[min(max(0, p.image), cursorImages.count - 1)]
        // position à l'écran (origine Core Image en bas à gauche)
        let pos = toOutput(p.x, p.y, zoom: z)
        let px = pos.x, py = pos.y
        let ptToOut = innerRect.width / screenPoints.width * z.s
        let press = p.down ? 0.86 : 1.0
        let k = ptToOut * cursorScale * press
        var layer = CIImage.empty()
        if clickEffect, p.sinceClick >= 0, p.sinceClick < 0.45 {
            // cercle qui s'agrandit et s'efface (0,45 s)
            let a = p.sinceClick / 0.45
            let r = (10 + 26 * a) * ptToOut / max(1, z.s) * 1.4
            let ring = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: px, y: py), "inputRadius0": max(0, r - 3), "inputRadius1": r,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.55 * (1 - a)), "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            ])!.outputImage!.cropped(to: CGRect(x: px - r - 2, y: py - r - 2, width: 2 * r + 4, height: 2 * r + 4))
            let disc = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: px, y: py), "inputRadius0": 0, "inputRadius1": max(1, r - 3),
                "inputColor0": CIColor(red: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255, alpha: 0.28 * (1 - a)),
                "inputColor1": CIColor(red: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255, alpha: 0.28 * (1 - a)),
            ])!.outputImage!.cropped(to: CGRect(x: px - r, y: py - r, width: 2 * r, height: 2 * r))
            layer = ring.composited(over: disc)
        }
        let e = img.extent
        let sx = info.width * k / e.width, sy = info.height * k / e.height
        let cur = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: px - info.hotX * k, y: py - (info.height - info.hotY) * k))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: p.alpha)])
        layer = cur.composited(over: layer)
        return layer.cropped(to: innerRect)
    }

    /// Caméra : flux recadré (centré sur le visage si suivi), effet miroir, rendu choisi, dans sa forme.
    /// `full` (intro / fin) fait grandir la caméra jusqu'au plein écran ; la bulle s'efface dans les silences.
    private func cameraLayer(_ cam: CIImage, full: Double, srcT: Double) -> CIImage? {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * full }
        var rect = outRect, radius: CGFloat = 0, alpha = full
        if let st = layout.camera {
            rect = CGRect(x: lerp(st.minX, 0), y: lerp(st.minY, 0), width: lerp(st.width, outRect.width), height: lerp(st.height, outRect.height))
                .integral
            radius = lerp(layout.cameraRadius, 0)
            let vis = layout.ring ? CameraLayouts.silenceVisibility(t: srcT, runs: look.silences) : 1
            alpha = full + (1 - full) * vis
        }
        guard alpha > 0.01, rect.width >= 2, rect.height >= 2 else { return nil }
        // fond (flou / noir) : détourage sur l'image entière de la caméra, avant recadrage et miroir
        let cam = cutout.apply(cam, mode: cameraBackground, at: srcT)
        let e = cam.extent
        let target = rect.width / rect.height
        var cw = e.width, ch = e.height
        if e.width / e.height > target { cw = e.height * target } else { ch = e.width / target }
        var cx = e.midX, cy = e.midY
        if let f = look.face {
            // un peu plus serré pour pouvoir recadrer, visage au centre sans sortir de l'image
            cw *= 0.82; ch *= 0.82
            let p = f.sample(srcT - rec.cameraOffset)
            cx = min(max(e.minX + p.x * e.width, e.minX + cw / 2), e.maxX - cw / 2)
            cy = min(max(e.minY + p.y * e.height, e.minY + ch / 2), e.maxY - ch / 2)
        }
        let crop = CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
        let k = rect.width / cw
        var face = cam.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: -k, y: k))          // miroir
            .transformed(by: CGAffineTransform(translationX: rect.maxX, y: rect.minY))
            .cropped(to: rect)
        face = CameraLook.apply(face, look: cameraLook, sharpen: cameraSharpen).cropped(to: rect)
        if radius > 0.5 || alpha < 0.999 {
            let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect), "inputRadius": min(radius, rect.width / 2, rect.height / 2),
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: alpha),
            ])!.outputImage!
            face = face.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: shape,
            ])
        }
        let ringA = layout.ring ? (1 - full) * alpha : 0
        guard ringA > 0.01 else { return face }
        let ringW = max(3, rect.width * 0.022)
        let ringRect = rect.insetBy(dx: -ringW, dy: -ringW)
        let ring = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: ringRect), "inputRadius": min(radius + ringW, ringRect.width / 2),
            "inputColor": CIColor(red: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255, alpha: ringA),
        ])!.outputImage!
        return face.composited(over: ring)
    }
}

final class Compositor: NSObject, AVVideoCompositing {
    private static let attrs: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let sourcePixelBufferAttributes: [String: any Sendable]? = Compositor.attrs
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = Compositor.attrs
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let ctx: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [.workingColorSpace: Compositor.colorSpace, .cacheIntermediates: false])
        }
        return CIContext(options: [.workingColorSpace: Compositor.colorSpace])
    }()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    /// Dernière image d'écran reçue (2026-10-17) : la piste écran finit parfois un peu avant le son ; sans elle,
    /// tout l'export échouait (« image manquante ») et la vidéo n'arrivait jamais en ligne. On fige alors la dernière image.
    private let lastLock = NSLock()
    private var lastScreen: CIImage?

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        let fresh = req.sourceFrame(byTrackID: EditInstruction.screenTrack).map { CIImage(cvPixelBuffer: $0) }
        lastLock.lock()
        if let f = fresh { lastScreen = f }
        let screen = fresh ?? lastScreen
        lastLock.unlock()
        guard let inst = req.videoCompositionInstruction as? EditInstruction,
              let screen = screen,
              let out = req.renderContext.newPixelBuffer() else {
            req.finish(with: NSError(domain: "X-Videos", code: 2, userInfo: [NSLocalizedDescriptionKey: "image manquante"]))
            return
        }
        let cam = inst.hasCamera ? req.sourceFrame(byTrackID: EditInstruction.cameraTrack).map { CIImage(cvPixelBuffer: $0) } : nil
        let img = inst.render(screen: screen, camera: cam, at: req.compositionTime.seconds)
        let size = req.renderContext.size
        ctx.render(img, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.colorSpace)
        req.finish(withComposedVideoFrame: out)
    }
}

/// Fonds proposés (aplats, pas de dégradé). "aucun" = plein écran sans cadre.
/// "fond-ecran" (fond d'écran macOS) et "image" (fichier choisi) : voir Backgrounds.image.
enum Backgrounds {
    static let all: [(id: String, name: String)] = [("violet", "Violet"), ("noir", "Noir"), ("blanc", "Blanc"), ("aucun", "Plein écran")]
    static func color(_ id: String) -> CIColor? {
        switch id {
        case "violet": return CIColor(red: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255)
        case "noir": return CIColor(red: 0x0a / 255, green: 0x0a / 255, blue: 0x0b / 255)
        case "blanc": return CIColor(red: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf6 / 255)
        case "fond-ecran", "image": return CIColor(red: 0x0a / 255, green: 0x0a / 255, blue: 0x0b / 255)   // si l'image manque
        default: return nil
        }
    }
}
