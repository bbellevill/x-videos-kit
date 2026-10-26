import Foundation
import CoreGraphics

/// Un trait dessiné à l'écran pendant le tournage. `endedAt` = instant où la souris a été relâchée (nil = encore en train de tracer).
struct DrawStroke {
    var points: [CGPoint]
    var endedAt: TimeInterval?
}

/// Effacement des traits (logique pure, testée dans tests/draw-test.swift).
/// Décision du 2026-10-14, comme Loom : un trait reste net 2 s après avoir été tracé, puis s'efface en fondu pendant 1 s
/// (disparu 3 s après la fin du tracé). Un trait en cours de tracé ne s'efface jamais.
enum DrawFade {
    static let hold: TimeInterval = 2
    static let fade: TimeInterval = 1
    static var lifetime: TimeInterval { hold + fade }

    /// Opacité d'un trait à l'instant `now` (1 = net, 0 = disparu).
    static func alpha(endedAt: TimeInterval?, now: TimeInterval) -> CGFloat {
        guard let e = endedAt else { return 1 }
        let age = now - e
        if age <= hold { return 1 }
        if age >= lifetime { return 0 }
        return CGFloat(1 - (age - hold) / fade)
    }

    /// Les traits qui restent à afficher à l'instant `now`.
    static func remaining(_ strokes: [DrawStroke], now: TimeInterval) -> [DrawStroke] {
        strokes.filter { alpha(endedAt: $0.endedAt, now: now) > 0 }
    }
}
