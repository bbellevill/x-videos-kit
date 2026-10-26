// Verrou « image » (2026-10-10) : formats 16:9 / 1:1 / 9:16 × mises en page caméra → montage valide et images non vides ;
// intro / fin caméra, bulle masquée dans les silences, rendu caméra, flou de mouvement proportionnel à la vitesse,
// lissage du suivi de visage, masques appliqués à la bonne plage de temps, loupe, touches, fond image, préréglages,
// export vertical en 1080×1920, et aperçu temps réel ≥ 20 i/s avec tous les effets (AVPlayer + AVPlayerItemVideoOutput).
import AVFoundation
import CoreImage
import AppKit
setvbuf(stdout, nil, _IOLBF, 0)
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }
func sh(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args; p.standardError = nil; try! p.run(); p.waitUntilExit() }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xv-look-test-\(getpid())")
let meta = dir.appendingPathComponent(".meta")
try! FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

// écran : damier fixe (bords nets, pour voir le flou) ; caméra : mire ; son : sinusoïde (pas de silence détecté)
let video = dir.appendingPathComponent("v.mp4")
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=640x400:r=30,geq=lum='if(mod(floor(X/8)+floor(Y/8)\\,2)\\,235\\,16)':cb=128:cr=128",
    "-f", "lavfi", "-i", "sine", "-t", "8", "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-shortest", video.path])
sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30", "-t", "8", "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
    meta.appendingPathComponent("v.mp4.camera.mov").path])
var rec = RecordingInfo(); rec.cameraFile = "v.mp4.camera.mov"; rec.save(for: video)
// souris immobile au centre, un clic à 1 s (pour la loupe)
let track = CursorTracker.Track(screenWidth: 1440, screenHeight: 900, samples: [[0, 0.5, 0.5, 0, 0], [1, 0.5, 0.5, 1, 0], [1.1, 0.5, 0.5, 0, 0], [7.9, 0.5, 0.5, 0, 0]])
try! JSONEncoder().encode(track).write(to: CursorTracker.url(for: video))

struct Img {
    let w: Int, h: Int, d: [UInt8]
    init(_ cg: CGImage) {
        w = cg.width; h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        d = buf
    }
    /// (x, y) en coordonnées Core Image (origine en bas à gauche)
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = ((h - 1 - min(h - 1, max(0, y))) * w + min(w - 1, max(0, x))) * 4
        return (Double(d[i]), Double(d[i + 1]), Double(d[i + 2]))
    }
    func lum(_ x: Int, _ y: Int) -> Double { let p = rgb(x, y); return 0.3 * p.0 + 0.59 * p.1 + 0.11 * p.2 }
    /// écart type de la luminance et énergie des contours dans un rectangle
    func stats(_ r: CGRect) -> (mean: Double, sd: Double, edges: Double) {
        var s = 0.0, s2 = 0.0, e = 0.0, n = 0.0
        for y in stride(from: Int(r.minY) + 1, to: Int(r.maxY) - 1, by: 1) {
            for x in stride(from: Int(r.minX) + 1, to: Int(r.maxX) - 1, by: 1) {
                let l = lum(x, y); s += l; s2 += l * l; n += 1
                e += abs(l - lum(x + 1, y)) + abs(l - lum(x, y + 1))
            }
        }
        let m = s / max(1, n)
        return (m, sqrt(max(0, s2 / max(1, n) - m * m)), e / max(1, n))
    }
}

func frame(_ b: Renderer.Built, _ t: Double) async throws -> Img {
    let g = AVAssetImageGenerator(asset: b.composition)
    g.videoComposition = b.videoComposition
    g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
    return Img(try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
}
func base() -> EditSettings {
    var s = EditSettings(); s.captions = false; s.removeSilences = false; s.autoZoom = false; s.motionBlur = 0; return s
}
func build(_ s: EditSettings, short: CGFloat = 360) async throws -> Renderer.Built {
    try await Renderer.build(video: video, settings: s, renderSize: s.renderSize(short: short))
}
func valid(_ b: Renderer.Built) async -> Bool {
    (try? await b.videoComposition.isValid(for: b.composition, timeRange: CMTimeRange(start: .zero, duration: b.composition.duration), validationDelegate: nil)) ?? false
}

var perf: (comp: AVComposition, vc: AVVideoComposition)?
var exported: CGSize = .zero
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        // 1-2. chaque format × chaque mise en page caméra
        for aspect in ["16:9", "1:1", "9:16"] {
            for layout in ["bulle", "plein-ecran", "cote-a-cote", "ecran-seul"] {
                var s = base(); s.aspect = aspect; s.cameraLayout = layout
                let b = try await build(s)
                let size = s.renderSize(short: 360)
                let inst = b.videoComposition.instructions.first as! EditInstruction
                let img = try await frame(b, 3)
                let st = img.stats(CGRect(x: 0, y: 0, width: img.w, height: img.h))
                let out = CGRect(origin: .zero, size: size)
                var geo = out.contains(inst.layout.screen)
                if let c = inst.layout.camera { geo = geo && out.contains(c) }
                if layout == "cote-a-cote" { geo = geo && !(inst.layout.camera.map { $0.intersects(inst.layout.screen) } ?? true) }
                if layout == "ecran-seul" { geo = geo && inst.layout.camera == nil }
                check(await valid(b) && img.w == Int(size.width) && img.h == Int(size.height) && st.sd > 20 && geo,
                      "\(aspect) \(layout) : montage valide, image \(img.w)×\(img.h) non vide (écart \(Int(st.sd))), placement correct")
            }
        }
        // écran seul : la caméra n'est même pas décodée
        var so = base(); so.cameraLayout = "ecran-seul"
        check(try await build(so).composition.tracks(withMediaType: .video).count == 1, "écran seul : pas de piste caméra")

        // intro / fin en caméra plein écran, transition adoucie
        let f = (0...80).map { CameraLayouts.introOutro(t: Double($0) / 10, duration: 8, seconds: 1.5) }
        check(f[0] == 1 && f[40] == 0 && f[80] == 1 && zip(f[0..<40], f[1...40]).allSatisfy { $0 >= $1 } && f[12] > 0 && f[12] < 1,
              "intro / fin : 1 → 0 → 1, sans saut")
        var si = base(); si.cameraIntroOutro = 1.5
        let bi = try await build(si)
        let i0 = try await frame(bi, 0.2), i4 = try await frame(bi, 4)
        let instI = bi.videoComposition.instructions.first as! EditInstruction
        let sc = instI.layout.screen
        // au début, le centre de l'écran montre la caméra (mire), pas le damier
        check(await valid(bi) && abs(i0.stats(sc.insetBy(dx: sc.width * 0.3, dy: sc.height * 0.3)).edges - i4.stats(sc.insetBy(dx: sc.width * 0.3, dy: sc.height * 0.3)).edges) > 5,
              "intro : caméra plein écran au début, écran ensuite")
        // bulle masquée pendant un silence d'au moins 1 s
        let runs = [(start: 2.0, end: 4.0)]
        check(CameraLayouts.silenceVisibility(t: 3, runs: runs) == 0 && CameraLayouts.silenceVisibility(t: 1, runs: runs) == 1
              && CameraLayouts.silenceVisibility(t: 2.15, runs: runs) > 0 && CameraLayouts.silenceVisibility(t: 2.15, runs: runs) < 1
              && CameraLayouts.silenceVisibility(t: 3, runs: [(start: 2.6, end: 3.4)]) == 1, "bulle : fondu dans les silences ≥ 1 s seulement")
        try JSONEncoder().encode([Silence.Run(start: 2, end: 4)]).write(to: Silence.cacheURL(video))
        var sh2 = base(); sh2.hideCameraInSilence = true
        let bh = try await build(sh2)
        let cam = (bh.videoComposition.instructions.first as! EditInstruction).layout.camera!
        let inSil = try await frame(bh, 3), outSil = try await frame(bh, 5.5)
        let ca = inSil.stats(cam.insetBy(dx: cam.width * 0.2, dy: cam.height * 0.2)), cb = outSil.stats(cam.insetBy(dx: cam.width * 0.2, dy: cam.height * 0.2))
        check(abs(ca.edges - cb.edges) > 3 || abs(ca.mean - cb.mean) > 10, "bulle absente pendant le silence, présente après")
        try? FileManager.default.removeItem(at: Silence.cacheURL(video))

        // 3. rendu caméra : chaud = plus de rouge, froid = plus de bleu
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let ctx = CIContext()
        func avg(_ i: CIImage) -> (Double, Double) {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(i, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return (Double(px[0]), Double(px[2]))
        }
        let warm = avg(CameraLook.apply(grey, look: "chaud", sharpen: 0)), cold = avg(CameraLook.apply(grey, look: "froid", sharpen: 0.5))
        check(warm.0 > warm.1 + 5 && cold.1 > cold.0 + 5, "rendu caméra : chaud \(warm), froid \(cold)")
        // suivi du visage : lissage
        var raw: [(x: Double, y: Double)?] = []
        var seed: UInt64 = 42
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
        for i in 0..<120 {
            if i % 17 == 5 { raw.append(nil); continue }                     // visage perdu
            if i == 30 { raw.append((0.95, 0.1)); continue }                   // détection aberrante
            raw.append(((i < 60 ? 0.4 : 0.6) + noise() * 0.06, 0.55 + noise() * 0.06))
        }
        let sm = FaceTrack.smooth(raw, step: 0.5)
        let jitter = zip(sm.points.dropFirst(), sm.points).map { abs($0.x - $1.x) + abs($0.y - $1.y) }.max() ?? 1
        let rawJitter = zip(raw.compactMap { $0 }.dropFirst(), raw.compactMap { $0 }).map { abs($0.x - $1.x) }.reduce(0, +) / 100
        check(sm.points.count == 120 && jitter < 0.03 && abs(sm.points[30].x - 0.4) < 0.05 && abs(sm.sample(55).x - 0.6) < 0.05
              && abs(sm.sample(15).x - 0.4) < 0.05, "suivi du visage lissé (saut max \(String(format: "%.3f", jitter)) contre bruit \(String(format: "%.3f", rawJitter)), aberration ignorée, trous comblés)")
        check(FaceTrack.smooth([nil, nil], step: 0.5).points.allSatisfy { $0.x == 0.5 }, "pas de visage : cadrage centré")
        // analyse Vision sur la mire (pas de visage) : ne plante pas, donne un point par 0,5 s
        let an = await FaceAnalysis.analyze(meta.appendingPathComponent("v.mp4.camera.mov"))
        check(an?.points.count == 16, "analyse Vision : \(an?.points.count ?? 0) échantillons sur 8 s")
        // suivi activé (cache .face.json) : montage valide
        try JSONEncoder().encode(FaceTrack.Raw(step: 0.5, points: (0..<16).map { _ in [0.7, 0.6, 0.2] })).write(to: FaceTrack.url(for: video))
        var sf = base(); sf.faceTracking = true; sf.cameraLook = "contraste"; sf.cameraSharpen = 0.6
        let bf = try await build(sf)
        check(await valid(bf), "suivi du visage + rendu caméra : montage valide")

        // 4. flou de mouvement proportionnel à la vitesse
        let still = MotionBlur.amount(a: (0.5, 0.5, 2), b: (0.5, 0.5, 2), dt: 1 / 60, width: 1600, height: 1000, intensity: 1)
        let m1 = MotionBlur.amount(a: (0.5, 0.5, 2), b: (0.502, 0.5, 2), dt: 1 / 60, width: 1600, height: 1000, intensity: 1)
        let m2 = MotionBlur.amount(a: (0.5, 0.5, 2), b: (0.504, 0.5, 2), dt: 1 / 60, width: 1600, height: 1000, intensity: 1)
        let mh = MotionBlur.amount(a: (0.5, 0.5, 2), b: (0.504, 0.5, 2), dt: 1 / 60, width: 1600, height: 1000, intensity: 0.5)
        let z1 = MotionBlur.amount(a: (0.5, 0.5, 1.5), b: (0.5, 0.5, 1.52), dt: 1 / 60, width: 1600, height: 1000, intensity: 1)
        let fast = MotionBlur.amount(a: (0.1, 0.5, 2), b: (0.9, 0.5, 2), dt: 1 / 60, width: 1600, height: 1000, intensity: 1)
        check(still.radius == 0 && still.zoom == 0 && m1.radius > 0 && abs(m2.radius / m1.radius - 2) < 0.01 && abs(mh.radius / m2.radius - 0.5) < 0.01
              && z1.zoom > 0 && fast.radius <= 0.04 * 1600 && MotionBlur.amount(a: (0.5, 0.5, 2), b: (0.6, 0.5, 2), dt: 1 / 60, width: 1600, height: 1000, intensity: 0).radius == 0,
              "flou : 0 à l'arrêt, ×2 si vitesse ×2 (\(String(format: "%.1f → %.1f px", m1.radius, m2.radius))), plafonné, zoom flouté")
        var sb = base(); sb.autoZoom = true; sb.motionBlur = 1; sb.zooms = [ZoomSegment(start: 2, end: 6, scale: 2)]
        let bb = try await build(sb)
        let ib = (bb.videoComposition.instructions.first as! EditInstruction).layout.screen
        var sb0 = sb; sb0.motionBlur = 0
        let bb0 = try await build(sb0)
        // même image (zoom en cours à 2,25 s, puis stable à 4,5 s), avec et sans flou
        let zr = CGRect(x: ib.minX + 4, y: ib.midY - 40, width: 70, height: 80)     // près du bord : le flou de zoom y est le plus fort
        let eMid = try await frame(bb, 2.25).stats(zr).edges, eMid0 = try await frame(bb0, 2.25).stats(zr).edges
        let eSt = try await frame(bb, 4.5).stats(zr).edges, eSt0 = try await frame(bb0, 4.5).stats(zr).edges
        check(await valid(bb) && eMid < eMid0 * 0.8 && abs(eSt - eSt0) < 1,
              "flou pendant le zoom (contours \(Int(eMid)) contre \(Int(eMid0)) sans flou), aucun flou à l'arrêt (\(Int(eSt)) = \(Int(eSt0)))")

        // 5. loupe : cercle grossissant au curseur, le cadre ne bouge pas
        var sl = base(); sl.autoZoom = true; sl.zooms = [ZoomSegment(start: 2, end: 6, scale: 2.5, kind: "loupe")]
        let bl = try await build(sl)
        let il = bl.videoComposition.instructions.first as! EditInstruction
        let lo = try await frame(bl, 4), plain = try await frame(try await build(base()), 4)
        let c = il.layout.screen
        let center = CGRect(x: c.midX - 20, y: c.midY - 20, width: 40, height: 40)
        let corner = CGRect(x: c.minX + 6, y: c.minY + 6, width: 30, height: 30)
        // damier grossi 2,5× : cases plus grandes = moins de contours au centre ; coin inchangé
        check(await valid(bl) && lo.stats(center).edges < plain.stats(center).edges * 0.7 && abs(lo.stats(corner).edges - plain.stats(corner).edges) < 2
              && il.path.sample(4).s == 1, "loupe : centre grossi, coin intact, cadre non zoomé")

        // 6. masques : flou pendant [2, 4] s seulement ; projecteur assombrit le reste
        var sm2 = base(); sm2.masks = [MaskRegion(x: 0.1, y: 0.1, w: 0.3, h: 0.3, start: 2, end: 4, kind: "flou")]
        let bm = try await build(sm2)
        let im = bm.videoComposition.instructions.first as! EditInstruction
        let p0 = im.toOutput(0.15, 0.15, zoom: (0.5, 0.5, 1)), p1 = im.toOutput(0.35, 0.35, zoom: (0.5, 0.5, 1))
        let zone = CGRect(x: p0.x, y: p1.y, width: p1.x - p0.x, height: p0.y - p1.y)
        let during = try await frame(bm, 3), after = try await frame(bm, 5), before = try await frame(bm, 1)
        let ed = during.stats(zone).edges, ea = after.stats(zone).edges, eb = before.stats(zone).edges
        check(await valid(bm) && ed < ea * 0.25 && eb > ea * 0.8, "masque flou à 3 s (contours \(Int(ed))), net à 1 s (\(Int(eb))) et 5 s (\(Int(ea)))")
        let back = im.toScreen(im.toOutput(0.3, 0.7, zoom: (0.4, 0.6, 2)), zoom: (0.4, 0.6, 2))
        check(abs(back.x - 0.3) < 1e-6 && abs(back.y - 0.7) < 1e-6, "dessin du masque : aperçu ↔ écran filmé réversible")
        var sp = base(); sp.masks = [MaskRegion(x: 0.1, y: 0.1, w: 0.3, h: 0.3, start: 2, end: 4, kind: "projecteur")]
        let bp = try await build(sp)
        let outside = CGRect(x: c.maxX - 60, y: c.minY + 10, width: 40, height: 40)
        let pd = try await frame(bp, 3), pa = try await frame(bp, 5)
        check(pd.stats(outside).mean < pa.stats(outside).mean * 0.6 && abs(pd.stats(zone).mean - pa.stats(zone).mean) < 8,
              "projecteur : reste assombri (\(Int(pd.stats(outside).mean)) contre \(Int(pa.stats(outside).mean))), zone intacte")
        let mr = try JSONDecoder().decode(MaskRegion.self, from: Data(#"{"x":0.1,"y":0.2,"w":0.3,"h":0.1,"start":1,"end":2}"#.utf8))
        check(mr.kind == "flou" && mr.alpha(at: 0.9) == 0 && mr.alpha(at: 1.5) == 1 && mr.alpha(at: 2) == 0, "masque relu sans type, plage respectée")

        // 6 bis. annotations (texte, flèche, cadre) : placées dans l'écran filmé, elles suivent le zoom, fondu de 0,2 s
        var sa = base(); sa.cameraLayout = "ecran-seul"; sa.autoZoom = true; sa.zooms = [ZoomSegment(start: 2, end: 7, scale: 2)]
        sa.annotations = [
            Annotation(kind: "cadre", x: 0.35, y: 0.3, x2: 0.65, y2: 0.55, start: 3, end: 6),
            Annotation(kind: "fleche", x: 0.3, y: 0.7, x2: 0.55, y2: 0.7, start: 3, end: 6),
            Annotation(kind: "texte", x: 0.5, y: 0.6, text: "Clique ici", start: 3, end: 6),
        ]
        let bA = try await build(sa)
        let iA = bA.videoComposition.instructions.first as! EditInstruction
        let zA = iA.path.sample(4.5)
        var sn = sa; sn.annotations = nil
        let bN = try await build(sn)
        let aOn = try await frame(bA, 4.5), aNone = try await frame(bN, 4.5), aBefore = try await frame(bA, 1), aAfter = try await frame(bA, 6.5)
        let nBefore = try await frame(bN, 1), nAfter = try await frame(bN, 6.5)
        func violet(_ img: Img, _ p: CGPoint) -> Bool { let c = img.rgb(Int(p.x.rounded()), Int(p.y.rounded())); return c.2 - c.0 > 80 && c.2 > 180 && c.1 < 140 }
        func nearViolet(_ img: Img, _ p: CGPoint, r: Int = 3) -> Bool {
            for dy in -r...r { for dx in -r...r where violet(img, CGPoint(x: p.x + CGFloat(dx), y: p.y + CGFloat(dy))) { return true } }
            return false
        }
        let cl = iA.toOutput(0.35, 0.425, zoom: zA), cr = iA.toOutput(0.65, 0.425, zoom: zA)     // milieu des côtés gauche et droit du cadre
        let ct = iA.toOutput(0.5, 0.3, zoom: zA)                                                  // côté haut
        check(nearViolet(aOn, cl) && nearViolet(aOn, cr) && nearViolet(aOn, ct) && !violet(aOn, iA.toOutput(0.5, 0.425, zoom: zA)),
              "cadre violet posé sur ses 4 côtés sous zoom ×\(String(format: "%.1f", zA.s)), intérieur intact")
        check(!nearViolet(aOn, iA.toOutput(0.35, 0.425, zoom: (0.5, 0.5, 1))), "cadre : suit le zoom (rien à sa place sans zoom)")
        let am = iA.toOutput(0.425, 0.7, zoom: zA), ae = iA.toOutput(0.54, 0.7, zoom: zA)
        check(nearViolet(aOn, am) && nearViolet(aOn, ae) && !nearViolet(aOn, iA.toOutput(0.27, 0.7, zoom: zA), r: 1), "flèche violette du départ à la pointe, rien avant le départ")
        let ps = AnnotationLayer.pillSize("Clique ici", unit: 360.0 / 1080), pc = iA.toOutput(0.5, 0.6, zoom: zA)
        let pillR = CGRect(x: pc.x - ps.width / 2, y: pc.y - ps.height / 2, width: ps.width, height: ps.height)
        let darkM = aOn.stats(pillR).mean, plainM = aNone.stats(pillR).mean
        check(darkM < plainM * 0.75 && aOn.lum(Int(pillR.minX) + 2, Int(pc.y)) < 40 && aOn.stats(pillR).sd > 40,
              "texte : pastille noire (luminance \(Int(darkM)) contre \(Int(plainM))) avec lettres blanches, centrée sur sa position")
        check(!nearViolet(aBefore, cl) && !nearViolet(aAfter, cl) && !nearViolet(aAfter, am) && abs(aBefore.stats(pillR).mean - nBefore.stats(pillR).mean) < 1 && abs(aAfter.stats(pillR).mean - nAfter.stats(pillR).mean) < 1,
              "annotations absentes avant 3 s et après 6 s")
        let anF = Annotation(kind: "cadre", x: 0.1, y: 0.1, x2: 0.2, y2: 0.2, start: 3, end: 6)
        check(anF.alpha(at: 2.9) == 0 && anF.alpha(at: 3.1) > 0.4 && anF.alpha(at: 3.1) < 0.6 && anF.alpha(at: 4.5) == 1 && anF.alpha(at: 5.9) < 0.6 && anF.alpha(at: 6) == 0,
              "annotation : fondu de 0,2 s à l'apparition et à la disparition")
        // image d'export 1080p avec les 3 annotations, gardée pour les yeux : build/annotations-test.png
        let b1080 = try await Renderer.build(video: video, settings: sa, renderSize: sa.renderSize(short: 1080))
        let g1080 = AVAssetImageGenerator(asset: b1080.composition)
        g1080.videoComposition = b1080.videoComposition
        g1080.requestedTimeToleranceBefore = .zero; g1080.requestedTimeToleranceAfter = .zero
        let big1080 = try await g1080.image(at: CMTime(seconds: 4.5, preferredTimescale: 600)).image
        let png = NSBitmapImageRep(cgImage: big1080).representation(using: .png, properties: [:])
        try? png?.write(to: URL(fileURLWithPath: "build/annotations-test.png"))
        check(big1080.width == 1920 && big1080.height == 1080 && png != nil, "export 1080p avec 3 annotations : build/annotations-test.png")

        // 7. touches : seulement les raccourcis, pastille 1,2 s
        let keysJSON = #"{"events":[{"t":2,"keys":"⌘K","typing":false},{"t":2.5,"keys":"b","typing":true},{"t":5,"keys":"⌘⇧P","typing":false}]}"#
        let ev = KeyEvents.decode(Data(keysJSON.utf8))
        check(ev.count == 2 && KeyEvents.active(ev, at: 2.6)?.index == 0 && KeyEvents.active(ev, at: 3.3) == nil && KeyEvents.active(ev, at: 5.5)?.index == 1,
              "touches : frappe ignorée, raccourci affiché 1,2 s")
        try Data(keysJSON.utf8).write(to: KeyEvents.url(for: video))
        var sk = base(); sk.showKeys = true
        let bk = try await build(sk)
        let ik = (bk.videoComposition.instructions.first as! EditInstruction).layout.screen
        let band = CGRect(x: ik.midX - 40, y: ik.minY + 10, width: 80, height: 40)
        let kOn = try await frame(bk, 2.6), kOff = try await frame(bk, 4)
        check(await valid(bk) && abs(kOn.stats(band).mean - kOff.stats(band).mean) > 10, "pastille ⌘K visible en bas à 2,6 s, partie à 4 s")

        // 8. fond image perso + ombre réglable
        let red = dir.appendingPathComponent("fond.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 { for y in 0..<40 { rep.setColor(NSColor(deviceRed: 0.9, green: 0.1, blue: 0.1, alpha: 1), atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: red)
        var sg = base(); sg.background = "image"; sg.backgroundImage = red.path; sg.shadow = 0
        let bg = try await frame(try await build(sg), 3)
        let px = bg.rgb(3, 3)
        check(px.0 > 180 && px.1 < 70, "fond image perso affiché (coin \(Int(px.0)),\(Int(px.1)),\(Int(px.2)))")
        var sw = base(); sw.background = "fond-ecran"
        check(await valid(try await build(sw)), "fond d'écran macOS : montage valide")

        // préréglages : enregistrer, relire, appliquer
        let pURL = dir.appendingPathComponent("presets.json")
        var styled = base(); styled.background = "noir"; styled.padding = 0.1; styled.radius = 30; styled.shadow = 0.5
        styled.cameraLayout = "cote-a-cote"; styled.cameraLook = "chaud"; styled.aspect = "9:16"
        Presets.add(StylePreset(name: "Reels sombre", from: styled), to: pURL)
        Presets.add(StylePreset(name: "Autre", from: base()), to: pURL)
        Presets.add(StylePreset(name: "Reels sombre", from: styled), to: pURL)
        let list = Presets.load(pURL)
        var target = base(); list.first { $0.name == "Reels sombre" }!.apply(to: &target)
        check(list.count == 2 && target.background == "noir" && target.padding == 0.1 && target.radius == 30 && target.shadow == 0.5
              && target.cameraLayout == "cote-a-cote" && target.cameraLook == "chaud" && target.aspect == "9:16" && target.captions == false,
              "préréglage enregistré, remplacé par nom, appliqué (fond, marge, coins, ombre, caméra, format)")
        check(Presets.remove("Autre", from: pURL).count == 1, "préréglage supprimé")

        // export vertical : 1080×1920, pas rétréci par le préréglage 1920×1080
        var sv = base(); sv.aspect = "9:16"; sv.trimEnd = 6
        let dst = dir.appendingPathComponent("out.mp4")
        try await Renderer.export(video: video, settings: sv, to: dst) { _ in }
        if let t = try await AVURLAsset(url: dst).loadTracks(withMediaType: .video).first { exported = try await t.load(.naturalSize) }

        // aperçu temps réel : tous les effets ensemble, écran 1920×1200 animé
        let big = dir.appendingPathComponent("big.mp4")
        sh(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1200:rate=30", "-f", "lavfi", "-i", "sine", "-t", "9",
            "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-shortest", big.path])
        try FileManager.default.copyItem(at: meta.appendingPathComponent("v.mp4.camera.mov"), to: meta.appendingPathComponent("big.mp4.camera.mov"))
        var rb = RecordingInfo(); rb.cameraFile = "big.mp4.camera.mov"; rb.save(for: big)
        try JSONEncoder().encode(track).write(to: CursorTracker.url(for: big))
        try Data(keysJSON.utf8).write(to: KeyEvents.url(for: big))
        try JSONEncoder().encode(FaceTrack.Raw(step: 0.5, points: (0..<18).map { _ in [0.6, 0.5, 0.2] })).write(to: FaceTrack.url(for: big))
        var all = base()
        all.autoZoom = true; all.motionBlur = 1; all.faceTracking = true; all.cameraLook = "chaud"; all.cameraSharpen = 0.5
        all.hideCameraInSilence = true; all.cameraIntroOutro = 0.8; all.showKeys = true; all.background = "image"; all.backgroundImage = red.path
        all.zooms = [ZoomSegment(start: 0.5, end: 3, scale: 2), ZoomSegment(start: 3.5, end: 5.5, scale: 2.2, kind: "loupe"), ZoomSegment(start: 6, end: 8.5, scale: 1.8)]
        all.masks = [MaskRegion(x: 0.1, y: 0.1, w: 0.3, h: 0.2, start: 1, end: 6, kind: "flou"), MaskRegion(x: 0.5, y: 0.5, w: 0.3, h: 0.3, start: 4, end: 8, kind: "projecteur")]
        let ba = try await Renderer.build(video: big, settings: all, renderSize: all.renderSize(short: 720))
        check(await valid(ba), "tous les effets : montage valide")
        perf = (ba.composition, ba.videoComposition)
    } catch { check(false, "erreur : \(error)") }
    sem.signal()
}
// la boucle principale tourne (le fond d'écran macOS se lit sur le fil principal)
while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date() + 0.02) }
check(exported == CGSize(width: 1080, height: 1920), "export 9:16 en \(Int(exported.width))×\(Int(exported.height))")

// harnais : lecture réelle (AVPlayer + AVPlayerItemVideoOutput), images distinctes sorties en 5 s
if let p = perf {
    let item = AVPlayerItem(asset: p.comp)
    item.videoComposition = p.vc
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    let ready = Date()
    while item.status != .readyToPlay && Date().timeIntervalSince(ready) < 10 { RunLoop.main.run(until: Date() + 0.02) }
    player.play()
    var frames = 0
    let start = Date()
    while Date().timeIntervalSince(start) < 5 {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t), output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil { frames += 1 }
        RunLoop.main.run(until: Date() + 0.003)
    }
    player.pause()
    let fps = Double(frames) / 5
    check(fps >= 20, String(format: "aperçu temps réel, tous effets, 1280×720 : %.1f i/s (≥ 20)", fps))
}
print(fails == 0 ? "OK : image (formats, caméra, flou, loupe, masques, touches, fonds, préréglages)" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
