// Verrou « fond de la caméra » (2026-10-14) : détourage de la personne (Vision) + fond flou ou noir (Core Image).
// Sur une vraie image de caméra (tests/fixtures/camera-frame.jpg) : le fond change, la personne reste proche de l'original,
// « aucun » ne touche à rien, le masque est réutilisé d'une image sur deux. Écrit un avant / après PNG (dossier $XV_CUTOUT_OUT, sinon tmp).
import CoreImage
import AppKit
setvbuf(stdout, nil, _IOLBF, 0)
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }

let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let srcURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tests/fixtures/camera-frame.jpg")
guard let cam = CIImage(contentsOf: srcURL) else { print("ÉCHEC : image de test illisible"); exit(1) }
let e = cam.extent
let W = Int(e.width), H = Int(e.height)

func pixels(_ img: CIImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: W * H * 4)
    ctx.render(img, toBitmap: &buf, rowBytes: W * 4, bounds: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return buf
}
/// (écart moyen absolu entre a et b, énergie des contours de b) sur un rectangle en coordonnées image (origine en haut à gauche)
func region(_ a: [UInt8], _ b: [UInt8], _ r: CGRect) -> (diff: Double, edges: Double) {
    var d = 0.0, ed = 0.0, n = 0.0
    for y in Int(r.minY)..<Int(r.maxY) - 1 {
        for x in Int(r.minX)..<Int(r.maxX) - 1 {
            let i = (y * W + x) * 4
            for c in 0..<3 { d += abs(Double(a[i + c]) - Double(b[i + c])) }
            ed += abs(Double(b[i]) - Double(b[i + 4])) + abs(Double(b[i]) - Double(b[i + W * 4]))
            n += 1
        }
    }
    return (d / (3 * n), ed / n)
}

let orig = pixels(cam)
let cutout = CameraCutout()
let blurred = cutout.apply(cam, mode: "flou", at: 0)
let blurPx = pixels(blurred)
// fond : étagère et mur à gauche ; personne : visage et torse au centre
let bgRect = CGRect(x: 10, y: 80, width: 180, height: 250)
let faceRect = CGRect(x: 310, y: 110, width: 90, height: 120)
let bg = region(orig, blurPx, bgRect), bgOrig = region(orig, orig, bgRect)
let face = region(orig, blurPx, faceRect)
print(String(format: "  fond : écart %.1f, contours %.1f -> %.1f ; personne : écart %.1f", bg.diff, bgOrig.edges, bg.edges, face.diff))
check(bg.diff > 4 && bg.edges < bgOrig.edges * 0.6, "fond flou : le fond a changé (contours nettement atténués)")
check(face.diff < 3, "fond flou : la personne reste proche de l'original")

let blackImg = cutout.apply(cam, mode: "couleur", at: 1)
let blackPx = pixels(blackImg)
let bgB = region(orig, blackPx, bgRect), faceB = region(orig, blackPx, faceRect)
var dark = 0.0
for y in 80..<330 { for x in 10..<190 { let i = (y * W + x) * 4; dark += Double(blackPx[i]) + Double(blackPx[i + 1]) + Double(blackPx[i + 2]) } }
dark /= 3 * 250 * 180
print(String(format: "  fond noir : luminosité moyenne du fond %.1f, personne : écart %.1f", dark, faceB.diff))
check(dark < 40 && bgB.diff > 20, "fond noir : le fond est devenu noir")
check(faceB.diff < 3, "fond noir : la personne reste proche de l'original")

check(pixels(cutout.apply(cam, mode: "aucun", at: 2)) == orig, "« aucun » : image inchangée")
check(pixels(cutout.apply(cam, mode: "inconnu", at: 2)) == orig, "mode inconnu : image inchangée")

// vitesse : masque réutilisé d'une image sur 2 (30 i/s) = Vision n'est pas rappelé
let c2 = CameraCutout()
func time(_ f: () -> Void) -> Double { let t = Date(); f(); return Date().timeIntervalSince(t) * 1000 }
_ = pixels(c2.apply(cam, mode: "flou", at: 0))
var withMask = 0.0, reused = 0.0
for i in 0..<10 {
    let t0 = 10 + Double(i) * 2
    withMask += time { _ = pixels(c2.apply(cam, mode: "flou", at: t0)) }
    reused += time { _ = pixels(c2.apply(cam, mode: "flou", at: t0 + 0.033)) }
}
print(String(format: "  image avec détourage %.0f ms, image au masque réutilisé %.0f ms (moyenne sur 10, %dx%d)", withMask / 10, reused / 10, W, H))
check(reused < withMask, "le masque réutilisé rend l'image plus vite")

// avant / après
let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XV_CUTOUT_OUT"] ?? NSTemporaryDirectory())
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
func png(_ img: CIImage, _ name: String) {
    if let cg = ctx.createCGImage(img, from: e), let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
        try? d.write(to: outDir.appendingPathComponent(name))
    }
}
png(cam, "camera-avant.png"); png(blurred, "camera-flou.png"); png(blackImg, "camera-noir.png")
print("  images : \(outDir.path)/camera-avant.png, camera-flou.png, camera-noir.png")
print(fails == 0 ? "OK : fond de la caméra (flou, noir) vérifié" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
