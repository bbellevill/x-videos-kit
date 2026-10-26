import Foundation
import CoreGraphics

/// Ce qu'on filme : écran entier, une fenêtre, ou une zone dessinée à la souris.
enum CaptureMode: String, CaseIterable {
    case screen, window, area
    var label: String { self == .screen ? "Écran" : self == .window ? "Fenêtre" : "Zone" }
}

/// Son du Mac (musique, vidéo, notification…) en plus du micro.
enum SystemAudio: String, CaseIterable {
    case off, mix, separate
    var label: String { self == .off ? "Non" : self == .mix ? "Mixé avec la voix" : "Piste séparée" }
}

/// Réglages de tournage, mémorisés d'une fois sur l'autre (UserDefaults).
struct CaptureOptions: Equatable {
    var mode = CaptureMode.screen
    var fps = 30                        // 30 ou 60 images par seconde
    var hideDesktopIcons = true         // icônes du bureau retirées de la vidéo (Finder non modifié)
    var systemAudio = SystemAudio.off
    var keyLog = true                   // journal des raccourcis (.meta/<vidéo>.keys.json)
    var lastArea: CGRect?               // dernière zone dessinée (coordonnées écran)

    static func load(_ d: UserDefaults = .standard) -> CaptureOptions {
        var o = CaptureOptions()
        if let m = d.string(forKey: "captureMode").flatMap(CaptureMode.init(rawValue:)) { o.mode = m }
        o.fps = d.integer(forKey: "captureFPS") == 60 ? 60 : 30
        if d.object(forKey: "hideDesktopIcons") != nil { o.hideDesktopIcons = d.bool(forKey: "hideDesktopIcons") }
        if let a = d.string(forKey: "systemAudio").flatMap(SystemAudio.init(rawValue:)) { o.systemAudio = a }
        if d.object(forKey: "keyLog") != nil { o.keyLog = d.bool(forKey: "keyLog") }
        if let s = d.string(forKey: "captureArea") { let r = NSRectFromStringCompat(s); if r.width > 0 { o.lastArea = r } }
        return o
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(mode.rawValue, forKey: "captureMode")
        d.set(fps, forKey: "captureFPS")
        d.set(hideDesktopIcons, forKey: "hideDesktopIcons")
        d.set(systemAudio.rawValue, forKey: "systemAudio")
        d.set(keyLog, forKey: "keyLog")
        if let a = lastArea { d.set("\(a.minX),\(a.minY),\(a.width),\(a.height)", forKey: "captureArea") }
    }
}

private func NSRectFromStringCompat(_ s: String) -> CGRect {
    let v = s.split(separator: ",").compactMap { Double($0) }
    return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : .zero
}

/// Calculs de cadrage, sans écran (testés dans tests/target-test.swift).
enum CaptureGeometry {
    /// Rectangle tiré à la souris (dans n'importe quel sens), arrondi et gardé dans l'écran. nil si trop petit.
    static func area(from a: CGPoint, to b: CGPoint, in screen: CGRect, minSize: CGFloat = 40) -> CGRect? {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .intersection(screen).integral
        guard !r.isNull, r.width >= minSize, r.height >= minSize else { return nil }
        return r
    }

    /// Zone en coordonnées écran Cocoa (origine en bas à gauche) → rectangle source dans l'écran filmé (origine en haut à gauche).
    static func sourceRect(area: CGRect, screen: CGRect) -> CGRect {
        CGRect(x: area.minX - screen.minX, y: screen.maxY - area.maxY, width: area.width, height: area.height)
    }

    /// Rectangle Quartz (origine en haut à gauche de l'écran principal) → Cocoa (origine en bas à gauche).
    static func cocoa(fromQuartz r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Taille de la vidéo en pixels : Retina, plafonnée à 3840 px de large (limite H.264), toujours paire.
    static func pixelSize(points: CGSize, scale: CGFloat, maxWidth: CGFloat = 3840) -> (Int, Int) {
        var w = points.width * scale, h = points.height * scale
        let k = min(1, maxWidth / w); w *= k; h *= k
        return (max(2, Int(w) & ~1), max(2, Int(h) & ~1))
    }

    /// Fenêtre ordinaire sous la souris (liste de CGWindowListCopyWindowInfo, de l'avant vers l'arrière).
    struct WindowInfo { var id: CGWindowID; var pid: pid_t; var layer: Int; var bounds: CGRect; var owner: String }

    static func window(at p: CGPoint, in list: [WindowInfo], excludingPID me: pid_t) -> WindowInfo? {
        list.first { $0.layer == 0 && $0.pid != me && $0.bounds.width >= 60 && $0.bounds.height >= 40 && $0.bounds.contains(p) }
    }

    static func windowInfos(_ raw: [[String: Any]]) -> [WindowInfo] {
        raw.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? Int, let pid = d[kCGWindowOwnerPID as String] as? Int,
                  let b = d[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return WindowInfo(id: CGWindowID(id), pid: pid_t(pid), layer: d[kCGWindowLayer as String] as? Int ?? 0, bounds: r,
                              owner: d[kCGWindowOwnerName as String] as? String ?? "")
        }
    }

    /// Fenêtre d'icônes du bureau : appartient au Finder et se trouve sous les fenêtres ordinaires,
    /// au-dessus du fond d'écran (qu'on garde). Les fenêtres Finder ordinaires (couche 0) restent filmées.
    static func isDesktopIcons(bundleID: String?, layer: Int,
                               desktopLevel: Int = Int(CGWindowLevelForKey(.desktopWindow))) -> Bool {
        bundleID == "com.apple.finder" && layer < 0 && layer > desktopLevel
    }
}
