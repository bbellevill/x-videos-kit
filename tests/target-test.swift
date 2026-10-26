// Verrou (2026-10-10) : choix de la capture (écran / fenêtre / zone), icônes du bureau masquées,
// réglages mémorisés (mode, 30/60 i/s, son du Mac). Calculs purs : aucun écran filmé.
import Foundation
import CoreGraphics
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }

// --- réglages mémorisés
let suite = "xvideos-target-test-\(getpid())"
let d = UserDefaults(suiteName: suite)!
defer { d.removePersistentDomain(forName: suite) }
check(CaptureOptions.load(d) == CaptureOptions(), "1er lancement : écran entier, 30 i/s, icônes masquées, sans son du Mac")
check(CaptureOptions().hideDesktopIcons && CaptureOptions().keyLog, "icônes masquées et journal des touches activés par défaut")
var o = CaptureOptions()
o.mode = .area; o.fps = 60; o.hideDesktopIcons = false; o.systemAudio = .separate; o.keyLog = false
o.lastArea = CGRect(x: 100, y: 50, width: 800, height: 450)
o.save(d)
check(CaptureOptions.load(d) == o, "dernier choix relu à l'identique")
d.set(45, forKey: "captureFPS"); d.set("n'importe quoi", forKey: "captureMode")
let bad = CaptureOptions.load(d)
check(bad.fps == 30 && bad.mode == .screen, "valeur inconnue : retour à 30 i/s et écran entier")

// --- zone dessinée
let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
check(CaptureGeometry.area(from: CGPoint(x: 900, y: 700), to: CGPoint(x: 100.4, y: 200.6), in: screen) == CGRect(x: 100, y: 200, width: 800, height: 500),
      "zone tirée dans n'importe quel sens")
check(CaptureGeometry.area(from: CGPoint(x: 1400, y: 900), to: CGPoint(x: 1700, y: 1100), in: screen) == CGRect(x: 1400, y: 900, width: 112, height: 82),
      "zone gardée dans l'écran")
check(CaptureGeometry.area(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 300), in: screen) == nil, "zone trop petite refusée")
// écran secondaire au-dessus de l'écran principal
let second = CGRect(x: 0, y: 982, width: 1920, height: 1080)
check(CaptureGeometry.sourceRect(area: CGRect(x: 100, y: 1962, width: 400, height: 100), screen: second) == CGRect(x: 100, y: 0, width: 400, height: 100),
      "zone convertie pour la capture (origine en haut à gauche)")
check(CaptureGeometry.cocoa(fromQuartz: CGRect(x: 10, y: 20, width: 300, height: 200), primaryHeight: 982) == CGRect(x: 10, y: 762, width: 300, height: 200),
      "fenêtre convertie en coordonnées écran")
let (w, h) = CaptureGeometry.pixelSize(points: CGSize(width: 2560, height: 1441), scale: 2)
check(w == 3840 && h % 2 == 0 && h <= 2162, "taille plafonnée à 3840 px, paire (\(w)×\(h))")

// --- fenêtre sous la souris
let me: pid_t = 42
let list = [
    CaptureGeometry.WindowInfo(id: 1, pid: 77, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1512, height: 30), owner: "Barre des menus"),
    CaptureGeometry.WindowInfo(id: 2, pid: me, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 600), owner: "X-Videos"),
    CaptureGeometry.WindowInfo(id: 3, pid: 90, layer: 0, bounds: CGRect(x: 100, y: 100, width: 20, height: 20), owner: "Minuscule"),
    CaptureGeometry.WindowInfo(id: 4, pid: 91, layer: 0, bounds: CGRect(x: 50, y: 50, width: 900, height: 700), owner: "Safari"),
    CaptureGeometry.WindowInfo(id: 5, pid: 92, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), owner: "Finder"),
]
check(CaptureGeometry.window(at: CGPoint(x: 105, y: 105), in: list, excludingPID: me)?.owner == "Safari",
      "fenêtre de devant choisie (barre des menus, X-Videos et minuscules ignorées)")
check(CaptureGeometry.window(at: CGPoint(x: 1200, y: 900), in: list, excludingPID: me)?.owner == "Finder", "fenêtre de derrière si rien devant")
let raw: [[String: Any]] = [[kCGWindowNumber as String: 9, kCGWindowOwnerPID as String: 3, kCGWindowLayer as String: 0,
                             kCGWindowOwnerName as String: "Notes",
                             kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation]]
check(CaptureGeometry.windowInfos(raw).first?.bounds == CGRect(x: 1, y: 2, width: 3, height: 4), "liste des fenêtres système lue")

// --- icônes du bureau (couches relevées sur le Mac de Baptiste le 2026-10-10)
check(CaptureGeometry.isDesktopIcons(bundleID: "com.apple.finder", layer: -2147483603), "icônes du bureau (Finder) retirées")
check(!CaptureGeometry.isDesktopIcons(bundleID: "com.apple.finder", layer: 0), "fenêtres Finder ordinaires gardées")
check(!CaptureGeometry.isDesktopIcons(bundleID: "com.apple.wallpaper", layer: -2147483625), "fond d'écran gardé")
check(!CaptureGeometry.isDesktopIcons(bundleID: "com.apple.dock", layer: -2147483624), "Dock gardé")
check(!CaptureGeometry.isDesktopIcons(bundleID: "com.apple.finder", layer: -2147483623), "fond d'écran dessiné par le Finder gardé")

print(fails == 0 ? "OK : choix de la capture et réglages de tournage" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
