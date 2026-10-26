import CoreImage
import Vision

/// Fond de la caméra, comme Loom : la personne est détourée (Vision) puis posée sur un fond flou ou uni.
/// Un objet par montage : la requête Vision est créée une seule fois, le masque est réutilisé d'une image sur deux.
final class CameraCutout {
    /// "aucun" | "flou" | "couleur" (fond uni noir de la charte)
    static let modes: [(id: String, name: String)] = [("aucun", "Aucun"), ("flou", "Flou"), ("couleur", "Noir")]
    private static let black = CIColor(red: 0x0a / 255, green: 0x0a / 255, blue: 0x0b / 255)

    private let request: VNGeneratePersonSegmentationRequest
    private let handler = VNSequenceRequestHandler()
    private let lock = NSLock()
    private let work = DispatchQueue(label: "xvideos.cutout", qos: .userInitiated)
    private var refreshing = false
    private var lastTime = -1.0
    private var lastExtent = CGRect.zero
    private var scaledMask: CIImage?     // masque mis à l'échelle de l'image, lissé
    /// Écart de temps en dessous duquel on réutilise le masque sans même relancer Vision (.balanced coûte ≈ 18 ms par appel :
    /// plus que le reste du rendu). 0,07 s = au plus un détourage toutes les 3 images à 30 i/s.
    var reuseWindow = 0.07

    init() {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Image de caméra avec le fond choisi. `time` = temps source (sert à réutiliser le masque). Sans personne détectée : image inchangée.
    func apply(_ cam: CIImage, mode: String, at time: Double) -> CIImage {
        guard mode == "flou" || mode == "couleur" else { return cam }
        guard let mask = mask(for: cam, at: time) else { return cam }
        let e = cam.extent
        let back: CIImage
        if mode == "flou" {
            // flou fort sur une image réduite (3× moins de pixels à flouter), bords étendus pour ne pas noircir les côtés
            // flou « normalisé » (2026-10-14) : on floute le fond SANS la personne puis on divise par le masque flouté,
            // sinon la personne déteint autour d'elle (halo clair autour de la tête vu sur le 1er rendu)
            let k: CGFloat = 0.5
            let small = CGAffineTransform(scaleX: k, y: k), sigma = Double(e.width * k) * 0.014
            let se = CGRect(x: e.minX * k, y: e.minY * k, width: e.width * k, height: e.height * k)
            let bgMask = mask.transformed(by: small).applyingFilter("CIColorInvert")
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: Double(e.width * k) * 0.012])   // marge autour de la personne
            let num = cam.transformed(by: small).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: bgMask])
                .clampedToExtent().applyingGaussianBlur(sigma: sigma)
            let den = bgMask.clampedToExtent().applyingGaussianBlur(sigma: sigma)
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.02, y: 0.02, z: 0.02, w: 1)])
            let filled = den.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: num]).applyingFilter("CIColorClamp")
            back = filled.cropped(to: se)
                .transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k))
                .cropped(to: e)
        } else {
            back = CIImage(color: Self.black).cropped(to: e)
        }
        return cam.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: back, kCIInputMaskImageKey: mask]).cropped(to: e)
    }

    /// Masque de l'image. Le détourage (Vision) est le plus gros coût : après le premier, il se rafraîchit en arrière-plan
    /// (le rendu continue avec le dernier masque, ≈ 0,1 s de retard) ; après un saut dans le temps (lecture, export, déplacement
    /// sur la frise), il est recalculé tout de suite pour ne jamais montrer le masque d'un autre moment.
    private func mask(for cam: CIImage, at t: Double) -> CIImage? {
        lock.lock()
        let e = cam.extent
        if let m = scaledMask, lastExtent == e {
            let gap = abs(t - lastTime)
            if gap < reuseWindow || (gap < 0.5 && refreshing) { lock.unlock(); return m }
            if gap < 0.5 {
                refreshing = true
                lock.unlock()
                work.async { [self] in
                    let new = compute(cam, e)
                    lock.lock()
                    if let new = new { scaledMask = new; lastTime = t; lastExtent = e }
                    refreshing = false
                    lock.unlock()
                }
                return m
            }
        }
        lock.unlock()
        // premier masque ou saut dans le temps : tout de suite
        let fresh: CIImage? = work.sync { compute(cam, e) }
        lock.lock(); defer { lock.unlock() }
        if let f = fresh { scaledMask = f; lastTime = t; lastExtent = e }
        return fresh ?? scaledMask
    }

    /// Un détourage Vision + lissage. Appelé seulement depuis la file `work` (la requête Vision est réutilisée, jamais partagée).
    private func compute(_ cam: CIImage, _ e: CGRect) -> CIImage? {
        // image de la caméra = tampon vidéo : Vision le lit directement (sans repasser par Core Image)
        do {
            if let src = cam.pixelBuffer { try handler.perform([request], on: src) } else { try handler.perform([request], on: cam) }
        } catch { return nil }
        guard let pb = request.results?.first?.pixelBuffer else { return nil }
        let raw = CIImage(cvPixelBuffer: pb)
        let re = raw.extent
        guard re.width > 0, re.height > 0 else { return nil }
        // lissage et contraste sur le petit masque (peu de pixels), puis mise à l'échelle de l'image : bords doux, personne pleine
        return raw.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(re.width) * 0.0025)
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.6])
            .applyingFilter("CIColorClamp")   // sans bornes 0…1, le mélange surexpose la personne
            .cropped(to: re)
            .transformed(by: CGAffineTransform(scaleX: e.width / re.width, y: e.height / re.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
    }
}
