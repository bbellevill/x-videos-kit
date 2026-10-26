import Cocoa
import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Éditeur d'une vidéo, pensé comme Screen Studio : tout se fait sur la frise (coupes, zooms),
/// le style se choisit en un clic, et le bouton principal est toujours visible : « Copier le lien ».
final class EditorModel: ObservableObject {
    let video: Video
    let url: URL
    let player = AVPlayer()
    private let library: Library
    @Published var settings: EditSettings
    @Published var zooms: [ZoomSegment] = []
    @Published var sourceDuration: Double = 1
    @Published var duration: Double = 1          // durée finale (après coupes et silences)
    @Published var playhead: Double = 0          // en temps source
    @Published var hasCamera = false
    @Published var silences: [Silence.Run] = []
    @Published var isPlaying = false
    @Published var selectedZoom: Int?
    @Published var thumbnails: [NSImage] = []
    @Published var transcribing = false
    @Published var captionCount = 0
    // son et montage
    @Published var words: [Captions.Word] = []           // transcription complète (panneau Texte)
    @Published var selectedWords: ClosedRange<Int>?
    @Published var selection: CutRange?                  // plage choisie sur la frise (temps source)
    @Published var fillerCuts: [CutRange] = []
    @Published var speeds: [SpeedRange] = []
    @Published var cleaning = false
    @Published var cleanAudio = false
    @Published var notice: String?
    @Published var selectedMask: Int? { didSet { if selectedMask != nil { selectedAnnotation = nil } } }
    @Published var drawingMask = false           // on dessine un masque sur l'aperçu à la souris
    @Published var selectedAnnotation: Int? { didSet { if selectedAnnotation != nil { selectedMask = nil; selectedZoom = nil; selectedAudio = nil } } }
    @Published var drawingAnnotation: String?    // "texte" / "fleche" / "cadre" : outil actif sur l'aperçu
    @Published var pendingText: (x: Double, y: Double)?   // texte cliqué, en attente de saisie
    @Published var analyzingFace = false
    @Published var presets: [StylePreset] = Presets.load()
    // vidéos mises bout à bout et audios importés
    @Published var parts: [Assemble.Part] = []
    @Published var assembling = false
    @Published var canUndoAppend = false
    @Published var selectedAudio: String?        // id du clip audio choisi sur la frise
    private var maskUndo: EditSettings?
    private var history: [EditSettings] = []
    private(set) var built: Renderer.Built?
    private var rebuild: DispatchWorkItem?
    private var observer: Any?

    init(video: Video, library: Library) {
        self.video = video
        self.library = library
        url = library.url(of: video)
        settings = EditSettings.load(for: url)
        hasCamera = RecordingInfo.load(for: url)?.cameraFile != nil
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self = self else { return }
            self.playhead = self.built?.sourceTime(t.seconds) ?? t.seconds
            self.isPlaying = self.player.rate > 0
        }
        words = Captions.cached(for: url) ?? []
        parts = Assemble.parts(of: url)
        canUndoAppend = Assemble.canUndo(url)
        refresh(keepTime: false)
        loadThumbnails()
        transcribeIfNeeded()
        cleanIfNeeded()
        trackFaceIfNeeded()
    }

    /// Suivi du visage : analyse Vision du fichier caméra en arrière-plan (une fois), puis l'aperçu se recalcule.
    func trackFaceIfNeeded() {
        guard settings.faceTracking, hasCamera, FaceTrack.cached(for: url) == nil, !analyzingFace else { return }
        analyzingFace = true
        let u = url
        Task { @MainActor in
            _ = await Task.detached(priority: .utility) { await FaceAnalysis.compute(for: u) }.value
            analyzingFace = false
            refresh(keepTime: true)
        }
    }

    /// Les sous-titres (et le texte, et les « euh ») se préparent en arrière-plan (≈ 1/3 de la durée de la vidéo), puis l'aperçu se recalcule.
    func transcribeIfNeeded() {
        guard settings.captions || settings.removeFillers, Captions.cached(for: url) == nil, Captions.available, !transcribing else { return }
        transcribing = true
        Task { @MainActor in
            words = await Captions.words(for: url)
            transcribing = false
            refresh(keepTime: true)
        }
    }

    /// La voix débruitée se prépare une fois par vidéo (ffmpeg, quelques secondes), puis l'aperçu se recalcule.
    func cleanIfNeeded() {
        guard settings.noiseReduction, Audio.cleaned(url) == nil, Audio.ffmpeg != nil, !cleaning else { return }
        cleaning = true
        Task { @MainActor in
            _ = await Audio.clean(url)
            cleaning = false
            refresh(keepTime: true)
        }
    }

    deinit { if let o = observer { player.removeTimeObserver(o) } }

    var canUndo: Bool { !history.isEmpty }
    var compPlayhead: Double { built?.compTime(playhead) ?? playhead }

    /// Applique un réglage (annulable avec ⌘Z) : sauvegarde, puis recalcule l'aperçu.
    func change(undoable: Bool = true, _ edit: (inout EditSettings) -> Void) {
        if undoable { history.append(settings); if history.count > 60 { history.removeFirst() } }
        edit(&settings)
        commit()
    }

    func undo() {
        guard let last = history.popLast() else { return }
        settings = last
        selectedZoom = nil
        selectedMask = nil
        selectedAnnotation = nil
        commit()
    }

    private func commit() {
        settings.save(for: url)
        library.markEdited(video)
        transcribeIfNeeded()
        cleanIfNeeded()
        trackFaceIfNeeded()
        rebuild?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh(keepTime: true) }
        rebuild = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    private func refresh(keepTime: Bool) {
        let source = playhead
        let wasPlaying = player.rate > 0
        let s = settings
        Task { @MainActor in
            guard let b = try? await Renderer.build(video: url, settings: s, renderSize: s.renderSize(short: 720)) else { return }
            built = b
            sourceDuration = b.sourceDuration
            duration = b.duration
            zooms = b.zooms
            silences = b.silences
            captionCount = b.captionWords.count
            fillerCuts = b.fillerCuts
            speeds = b.speeds
            cleanAudio = b.cleanAudio
            if let i = selectedZoom, i >= zooms.count { selectedZoom = nil }
            let item = AVPlayerItem(asset: b.composition)
            item.videoComposition = b.videoComposition
            item.audioMix = b.audioMix
            item.audioTimePitchAlgorithm = .spectral      // voix accélérée sans effet « chipmunk »
            player.replaceCurrentItem(with: item)
            if keepTime { await player.seek(to: CMTime(seconds: b.compTime(source), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            if wasPlaying { player.play() }
        }
    }

    private func loadThumbnails() {
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            let d = (try? await asset.load(.duration).seconds) ?? 0
            guard d > 0 else { return }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 220, height: 140)
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            var imgs: [NSImage] = []
            let n = 24
            for i in 0..<n {
                let t = CMTime(seconds: d * (Double(i) + 0.5) / Double(n), preferredTimescale: 600)
                if let cg = try? await gen.image(at: t).image { imgs.append(NSImage(cgImage: cg, size: .zero)) }
            }
            thumbnails = imgs
        }
    }

    // MARK: lecture

    func seek(source t: Double) {
        let t = max(0, min(sourceDuration, t))
        playhead = t
        player.seek(to: CMTime(seconds: built?.compTime(t) ?? t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() }
        else {
            if compPlayhead >= duration - 0.05 { seek(source: built?.sourceTime(0) ?? 0) }
            player.play()
        }
        isPlaying = player.rate > 0
    }

    func step(_ s: Double) { seek(source: playhead + s) }

    // MARK: zooms (dès qu'on en modifie un, la liste devient « manuelle » et est enregistrée)

    func addZoomHere() {
        let start = max(0, playhead - 0.3)
        let seg = ZoomSegment(start: start, end: min(sourceDuration, start + 2.8), scale: AutoZoom.scale)
        let list = (zooms + [seg]).sorted { $0.start < $1.start }
        change { $0.autoZoom = true; $0.zooms = list }
        zooms = list
        selectedZoom = list.firstIndex(of: seg)
    }

    func deleteSelectedZoom() {
        guard let i = selectedZoom, i < zooms.count else { return }
        var list = zooms; list.remove(at: i)
        change { $0.zooms = list }
        zooms = list
        selectedZoom = nil
    }

    /// Pendant un glisser : mise à jour immédiate de la frise, aperçu recalculé à la fin.
    func setZoom(_ i: Int, start: Double? = nil, end: Double? = nil, scale: Double? = nil, live: Bool) {
        guard i < zooms.count else { return }
        var z = zooms[i]
        if let s = start { z.start = max(0, min(s, z.end - 0.5)) }
        if let e = end { z.end = min(sourceDuration, max(e, z.start + 0.5)) }
        if let k = scale { z.scale = k }
        zooms[i] = z
        if !live { let list = zooms; change { $0.autoZoom = true; $0.zooms = list } }
    }

    func moveZoom(_ i: Int, by dt: Double, from original: ZoomSegment, live: Bool) {
        guard i < zooms.count else { return }
        let len = original.end - original.start
        let s = max(0, min(sourceDuration - len, original.start + dt))
        zooms[i].start = s; zooms[i].end = s + len
        if !live { let list = zooms; change { $0.autoZoom = true; $0.zooms = list } }
    }

    func resetZooms() { selectedZoom = nil; change { $0.autoZoom = true; $0.zooms = nil } }

    /// Zoom du cadre (nil) ou loupe autour du curseur ("loupe").
    func setZoomKind(_ i: Int, _ kind: String?) {
        guard i < zooms.count else { return }
        var list = zooms; list[i].kind = kind
        change { $0.autoZoom = true; $0.zooms = list }
        zooms = list
    }

    // MARK: masques (flou ou projecteur), dessinés sur l'aperçu

    var masks: [MaskRegion] { settings.masks ?? [] }
    var instruction: EditInstruction? { built?.videoComposition.instructions.first as? EditInstruction }

    /// Rectangle tracé sur l'aperçu (points de la vue, origine en haut à gauche) → masque de 3 s à la tête de lecture.
    func addMask(from a: CGPoint, to b: CGPoint, viewSize: CGSize) {
        guard let inst = instruction, viewSize.width > 0 else { return }
        let R = inst.renderSize
        func screen(_ p: CGPoint) -> (x: Double, y: Double) {
            inst.toScreen(CGPoint(x: p.x / viewSize.width * R.width, y: R.height - p.y / viewSize.height * R.height), zoom: inst.path.sample(playhead))
        }
        let p = screen(a), q = screen(b)
        let x0 = max(0, min(p.x, q.x)), y0 = max(0, min(p.y, q.y)), x1 = min(1, max(p.x, q.x)), y1 = min(1, max(p.y, q.y))
        drawingMask = false
        guard x1 - x0 > 0.005, y1 - y0 > 0.005 else { return }
        let m = MaskRegion(x: x0, y: y0, w: x1 - x0, h: y1 - y0, start: playhead, end: min(sourceDuration, playhead + 3))
        change { $0.masks = ($0.masks ?? []) + [m] }
        selectedZoom = nil
        selectedMask = masks.count - 1
    }

    /// Masque sélectionné en points de la vue (pour l'encadrer sur l'aperçu).
    func maskRect(_ i: Int, viewSize: CGSize) -> CGRect? {
        guard i < masks.count, let inst = instruction else { return nil }
        let m = masks[i], R = inst.renderSize, z = inst.path.sample(playhead)
        let p = inst.toOutput(m.x, m.y, zoom: z), q = inst.toOutput(m.x + m.w, m.y + m.h, zoom: z)
        let sx = viewSize.width / R.width, sy = viewSize.height / R.height
        return CGRect(x: p.x * sx, y: (R.height - p.y) * sy, width: (q.x - p.x) * sx, height: (p.y - q.y) * sy)
    }

    /// Modifie un masque ; pendant un glisser (`live`), l'annulation ⌘Z revient à l'état d'avant le glisser.
    func editMask(_ i: Int, live: Bool, _ f: (inout MaskRegion) -> Void) {
        guard i < masks.count else { return }
        if maskUndo == nil { maskUndo = settings }
        var list = masks
        f(&list[i])
        list[i].start = max(0, min(list[i].start, sourceDuration - 0.3))
        list[i].end = min(sourceDuration, max(list[i].end, list[i].start + 0.3))
        settings.masks = list
        if !live {
            if let u = maskUndo { history.append(u) }
            maskUndo = nil
            commit()
        }
    }

    func deleteSelectedMask() {
        guard let i = selectedMask, i < masks.count else { return }
        var list = masks; list.remove(at: i)
        change { $0.masks = list.isEmpty ? nil : list }
        selectedMask = nil
    }

    // MARK: annotations (texte, flèche, cadre), dessinées sur l'aperçu comme les masques

    var annotations: [Annotation] { settings.annotations ?? [] }

    /// Point de la vue (origine en haut à gauche) → 0…1 dans l'écran filmé, à la tête de lecture.
    func screenPoint(_ p: CGPoint, viewSize: CGSize) -> (x: Double, y: Double)? {
        guard let inst = instruction, viewSize.width > 0 else { return nil }
        let R = inst.renderSize
        return inst.toScreen(CGPoint(x: p.x / viewSize.width * R.width, y: R.height - p.y / viewSize.height * R.height), zoom: inst.path.sample(playhead))
    }

    /// Cadre ou flèche tracé à la souris ; texte : un clic (b = a) pose le point et ouvre le champ de saisie.
    func addAnnotation(kind: String, from a: CGPoint, to b: CGPoint, viewSize: CGSize) {
        guard let p0 = screenPoint(a, viewSize: viewSize), let q0 = screenPoint(b, viewSize: viewSize) else { return }
        func clamp(_ s: (x: Double, y: Double)) -> (x: Double, y: Double) { (max(0, min(1, s.x)), max(0, min(1, s.y))) }
        let p = clamp(p0), q = clamp(q0)
        drawingAnnotation = nil
        if kind == "texte" { pendingText = (p.x, p.y); return }
        guard abs(q.x - p.x) + abs(q.y - p.y) > 0.01 else { return }
        appendAnnotation(Annotation(kind: kind, x: p.x, y: p.y, x2: q.x, y2: q.y, start: playhead, end: min(sourceDuration, playhead + 3)))
    }

    func commitPendingText(_ text: String) {
        defer { pendingText = nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = pendingText, !t.isEmpty else { return }
        appendAnnotation(Annotation(kind: "texte", x: p.x, y: p.y, text: t, start: playhead, end: min(sourceDuration, playhead + 3)))
    }

    private func appendAnnotation(_ a: Annotation) {
        change { $0.annotations = ($0.annotations ?? []) + [a] }
        selectedZoom = nil; selectedMask = nil; selectedAudio = nil
        selectedAnnotation = annotations.count - 1
    }

    /// Boîte de l'annotation sélectionnée en points de la vue (pour l'encadrer et la déplacer sur l'aperçu).
    func annotationRect(_ i: Int, viewSize: CGSize) -> CGRect? {
        guard i < annotations.count, let inst = instruction else { return nil }
        let a = annotations[i], R = inst.renderSize, z = inst.path.sample(playhead)
        let sx = viewSize.width / R.width, sy = viewSize.height / R.height
        let p = inst.toOutput(a.x, a.y, zoom: z), q = inst.toOutput(a.x2, a.y2, zoom: z)
        if a.kind == "texte" {
            let s = AnnotationLayer.pillSize(a.text, unit: min(R.width, R.height) / 1080)
            return CGRect(x: (p.x - s.width / 2) * sx, y: (R.height - p.y - s.height / 2) * sy, width: s.width * sx, height: s.height * sy)
        }
        let pad = 10.0
        return CGRect(x: min(p.x, q.x) * sx - pad, y: (R.height - max(p.y, q.y)) * sy - pad,
                      width: abs(q.x - p.x) * sx + 2 * pad, height: abs(q.y - p.y) * sy + 2 * pad)
    }

    /// Modifie une annotation ; pendant un glisser (`live`), ⌘Z revient à l'état d'avant le glisser (même historique que les masques).
    func editAnnotation(_ i: Int, live: Bool, _ f: (inout Annotation) -> Void) {
        guard i < annotations.count else { return }
        if maskUndo == nil { maskUndo = settings }
        var list = annotations
        f(&list[i])
        list[i].start = max(0, min(list[i].start, sourceDuration - 0.3))
        list[i].end = min(sourceDuration, max(list[i].end, list[i].start + 0.3))
        settings.annotations = list
        if !live {
            if let u = maskUndo { history.append(u) }
            maskUndo = nil
            commit()
        }
    }

    func deleteSelectedAnnotation() {
        guard let i = selectedAnnotation, i < annotations.count else { return }
        var list = annotations; list.remove(at: i)
        change { $0.annotations = list.isEmpty ? nil : list }
        selectedAnnotation = nil
    }

    // MARK: fonds et préréglages

    /// Image perso : copiée dans ~/Library/Application Support/X-Videos/fonds (reste valable si l'original bouge).
    func chooseBackgroundImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let src = p.url else { return }
        let dir = Presets.defaultURL.deletingLastPathComponent().appendingPathComponent("fonds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        if dst.path != src.path { try? FileManager.default.removeItem(at: dst); try? FileManager.default.copyItem(at: src, to: dst) }
        let path = FileManager.default.fileExists(atPath: dst.path) ? dst.path : src.path
        change { $0.background = "image"; $0.backgroundImage = path }
    }

    func savePreset(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        presets = Presets.add(StylePreset(name: n, from: settings))
    }
    func applyPreset(_ p: StylePreset) { change { p.apply(to: &$0) } }
    func deletePreset(_ name: String) { presets = Presets.remove(name) }

    // MARK: coupes du début et de la fin

    func setTrim(start: Double? = nil, end: Double? = nil, live: Bool) {
        if let s = start { settings.trimStart = max(0, min(s, sourceDuration - settings.trimEnd - 1)) ; if live { seek(source: settings.trimStart) } }
        if let e = end { settings.trimEnd = max(0, min(e, sourceDuration - settings.trimStart - 1)); if live { seek(source: sourceDuration - settings.trimEnd) } }
        if !live { let s = settings; change { $0 = s } }
    }

    func copyLink() { library.copyLink(video) }

    // MARK: montage par le texte

    func isCut(_ w: Captions.Word) -> Bool {
        let mid = (w.start + w.end) / 2
        return (settings.cuts ?? []).contains { mid >= $0.start && mid < $0.end }
    }
    func isFillerCut(_ w: Captions.Word) -> Bool {
        let mid = (w.start + w.end) / 2
        return fillerCuts.contains { mid >= $0.start - 0.05 && mid < $0.end + 0.05 }
    }

    /// Clic sur un mot : le sélectionne (⇧ prolonge la sélection) et place la lecture dessus.
    func tapWord(_ i: Int, extend: Bool) {
        guard i < words.count else { return }
        if extend, let s = selectedWords { selectedWords = min(s.lowerBound, i)...max(s.upperBound, i) }
        else { selectedWords = i...i }
        selection = nil
        seek(source: words[i].start)
    }

    /// Supprime les mots sélectionnés (annulable) : la coupe va du début du premier à la fin du dernier,
    /// avec une petite marge prise dans les blancs, jamais sur les mots voisins.
    func cutSelectedWords() {
        guard let r = selectedWords, r.upperBound < words.count else { return }
        let prevEnd = r.lowerBound > 0 ? words[r.lowerBound - 1].end : 0
        let nextStart = r.upperBound + 1 < words.count ? words[r.upperBound + 1].start : sourceDuration
        let cut = CutRange(start: max(prevEnd, words[r.lowerBound].start - 0.03), end: min(nextStart, words[r.upperBound].end + 0.03))
        change { $0.cuts = ($0.cuts ?? []) + [cut] }
        selectedWords = nil
    }

    /// Rétablit les mots sélectionnés (enlève les coupes qui les touchent).
    func restoreSelectedWords() {
        guard let r = selectedWords, r.upperBound < words.count else { return }
        let a = words[r.lowerBound].start, b = words[r.upperBound].end
        change { s in s.cuts = (s.cuts ?? []).filter { $0.end <= a || $0.start >= b }; if s.cuts?.isEmpty == true { s.cuts = nil } }
    }

    /// Fichier .srt à côté de la vidéo, calé sur le montage (coupes et accélérations comprises).
    func exportSRT() {
        guard let b = built else { return }
        let kept = words.filter { Renderer.isKept(($0.start + $0.end) / 2, b.segments) }
            .map { Captions.Word(text: $0.text, start: b.compTime($0.start), end: b.compTime($0.end)) }
        let dst = url.deletingPathExtension().appendingPathExtension("srt")
        do {
            try Captions.srt(words: kept).write(to: dst, atomically: true, encoding: .utf8)
            notice = "Sous-titres enregistrés : \(dst.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([dst])
        } catch { notice = "Impossible d'écrire le fichier .srt" }
    }

    // MARK: plage choisie sur la frise : accélérer ou couper

    /// Vitesse d'une plage (1 = vitesse normale, même dans un passage de frappe accéléré automatiquement).
    func setSpeed(_ sp: Double) {
        guard let sel = selection, sel.end - sel.start > 0.1 else { return }
        change { s in
            let others = (s.speedRanges ?? []).filter { $0.start < sel.start || $0.end > sel.end }
            s.speedRanges = [SpeedRange(start: sel.start, end: sel.end, speed: sp)] + others
        }
    }

    func cutSelection() {
        guard let sel = selection, sel.end - sel.start > 0.05 else { return }
        change { $0.cuts = ($0.cuts ?? []) + [sel] }
        selection = nil
    }

    /// ⌫ : mots sélectionnés, sinon plage de la frise, sinon zoom sélectionné.
    func deleteKey() {
        if selectedAudio != nil { deleteSelectedAudio() }
        else if selectedWords != nil { cutSelectedWords() }
        else if selection != nil { cutSelection() }
        else { deleteSelectedZoom() }
    }

    func clearSelection() { selectedZoom = nil; selectedWords = nil; selection = nil; selectedAudio = nil }

    // MARK: vidéos à la suite (le fichier source est remplacé ; l'ancien reste pour « Retirer le dernier ajout »)

    func chooseVideosToAppend() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = true
        p.message = "Choisis les vidéos à mettre à la suite (dans l'ordre de la sélection)"
        p.prompt = "Ajouter à la suite"
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        appendVideos(p.urls)
    }

    func appendVideos(_ urls: [URL]) {
        guard !assembling else { return }
        assembling = true
        player.pause()
        let u = url
        Task { @MainActor in
            do {
                try await Assemble.append(urls, to: u)
                reloadSource()
                notice = urls.count > 1 ? "\(urls.count) vidéos ajoutées à la suite ✓" : "Vidéo ajoutée à la suite ✓"
            } catch {
                notice = "Ajout impossible : \(error.localizedDescription)"
            }
            assembling = false
        }
    }

    /// Morceaux réarrangés (avancer, reculer, retirer, insérer) : nouveau fichier, réglages recalés, annulable.
    func rearrange(_ order: [Int], done: String) {
        guard !assembling else { return }
        assembling = true
        player.pause()
        let u = url
        Task { @MainActor in
            do { try await Assemble.rearrange(u, order: order); reloadSource(); notice = done }
            catch { notice = error.localizedDescription }
            assembling = false
        }
    }

    func movePart(_ i: Int, by d: Int) {
        let j = i + d
        guard parts.indices.contains(i), parts.indices.contains(j) else { return }
        var o = Array(parts.indices); o.swapAt(i, j)
        rearrange(o, done: "Morceau déplacé ✓")
    }

    func removePart(_ i: Int) {
        guard parts.count > 1 else { return }
        rearrange(parts.indices.filter { $0 != i }, done: "Morceau retiré ✓")
    }

    /// Vidéos insérées juste après le morceau `i` : ajoutées à la suite, puis remises à leur place.
    func insertVideos(after i: Int) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = true
        p.prompt = "Insérer"
        guard p.runModal() == .OK, !p.urls.isEmpty, !assembling else { return }
        assembling = true
        player.pause()
        let u = url, before = parts.count
        Task { @MainActor in
            do {
                try await Assemble.append(p.urls, to: u)
                let n = Assemble.parts(of: u).count
                if i < before - 1 {
                    let added = Array(before..<n)
                    try await Assemble.rearrange(u, order: Array(0...i) + added + Array((i + 1)..<before))
                }
                reloadSource(); notice = "Vidéo insérée ✓"
            } catch { notice = "Insertion impossible : \(error.localizedDescription)" }
            assembling = false
        }
    }

    func undoAppend() {
        player.pause()
        do { try Assemble.undoAppend(url); reloadSource(); notice = "Changement annulé ✓" }
        catch { notice = "Retour impossible : \(error.localizedDescription)" }
    }

    /// Le fichier source a changé : réglages, repères, miniatures et analyses du son sont relus ou refaits.
    private func reloadSource() {
        player.replaceCurrentItem(with: nil)
        settings = EditSettings.load(for: url)
        history.removeAll()                       // les anciens états ne décrivent plus ce fichier
        parts = Assemble.parts(of: url)
        canUndoAppend = Assemble.canUndo(url)
        words = Captions.cached(for: url) ?? []
        selectedZoom = nil; selectedMask = nil; selectedAnnotation = nil; selectedAudio = nil; selection = nil
        library.sourceChanged(video)
        refresh(keepTime: false)
        loadThumbnails()
        transcribeIfNeeded()
        cleanIfNeeded()
    }

    // MARK: audios importés (voix off, sons), posés à la tête de lecture

    var audioClips: [AudioClip] { settings.audioClips ?? [] }

    func chooseAudio() {
        let p = NSOpenPanel()
        p.allowedContentTypes = Audio.audioExts.compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = true
        p.message = "Choisis les audios à poser sur la frise (à la tête de lecture, l'un après l'autre)"
        p.prompt = "Importer"
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let u = url, start = playhead
        Task { @MainActor in
            var at = start
            var added: [AudioClip] = []
            for src in p.urls {
                do { let c = try await Audio.importClip(src, for: u, at: at); added.append(c); at += c.dur }
                catch { notice = "Import impossible : \(error.localizedDescription)" }
            }
            guard !added.isEmpty else { return }
            change { $0.audioClips = ($0.audioClips ?? []) + added }
            selectedAudio = added.last?.id
            notice = added.count > 1 ? "\(added.count) audios posés sur la frise ✓" : "Audio posé sur la frise ✓"
        }
    }

    func editAudio(_ id: String, live: Bool, _ f: (inout AudioClip) -> Void) {
        guard var list = settings.audioClips, let i = list.firstIndex(where: { $0.id == id }) else { return }
        f(&list[i])
        list[i].at = max(0, min(sourceDuration - 0.1, list[i].at))
        if live { settings.audioClips = list } else { change { $0.audioClips = list } }
    }

    /// Glisser : pendant le geste on ne recalcule pas l'aperçu, seulement à la fin (une étape d'annulation).
    func moveAudio(_ id: String, to at: Double, live: Bool) {
        if live {
            if maskUndo == nil { maskUndo = settings }
            editAudio(id, live: true) { $0.at = at }
        } else {
            let before = maskUndo; maskUndo = nil
            if let b = before { history.append(b) }
            editAudio(id, live: true) { $0.at = at }
            commit()
        }
    }

    func deleteSelectedAudio() {
        guard let id = selectedAudio else { return }
        change { $0.audioClips = ($0.audioClips ?? []).filter { $0.id != id }.nilIfEmpty }
        selectedAudio = nil
    }
}


final class EditorWindow {
    private static var open: [String: NSWindow] = [:]
    private static var monitors: [String: Any] = [:]

    static func show(_ v: Video, library: Library) {
        if let w = open[v.id] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let model = EditorModel(video: v, library: library)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = v.title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.black
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: EditorView(m: model, lib: library))
        w.setContentSize(NSSize(width: 1240, height: 800))
        w.center()
        open[v.id] = w
        // raccourcis clavier (sauf pendant la saisie d'un texte)
        monitors[v.id] = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak w] e in
            guard let w = w, w.isKeyWindow else { return e }
            if w.firstResponder is NSTextView { return e }
            let cmd = e.modifierFlags.contains(.command)
            switch (e.keyCode, cmd) {
            case (49, false): model.togglePlay(); return nil                         // espace
            case (123, false): model.step(e.modifierFlags.contains(.shift) ? -5 : -1); return nil   // ←
            case (124, false): model.step(e.modifierFlags.contains(.shift) ? 5 : 1); return nil     // →
            case (6, false): model.addZoomHere(); return nil                         // Z
            case (51, false), (117, false):                                          // ⌫
                if model.selectedMask != nil { model.deleteSelectedMask() }
                else if model.selectedAnnotation != nil { model.deleteSelectedAnnotation() } else { model.deleteKey() }
                return nil
            case (6, true): model.undo(); return nil                                 // ⌘Z
            case (53, false):                                                        // échap
                model.clearSelection(); model.selectedMask = nil; model.drawingMask = false
                model.selectedAnnotation = nil; model.drawingAnnotation = nil; model.pendingText = nil
                return nil
            default: return e
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            model.player.pause()
            library.syncAfterEditing(v.id)
            if let m = monitors[v.id] { NSEvent.removeMonitor(m) }
            monitors[v.id] = nil
            open[v.id] = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

private let violet = Color(Theme.violet)
private let muted = Color(white: 0.58)
private let panel = Color(white: 0.07)
private let line = Color(Theme.border)

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none          // nos propres commandes, sous la vidéo
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

func clock(_ s: Double) -> String {
    let t = max(0, s)
    return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
}

// MARK: - Vue principale

struct EditorView: View {
    @ObservedObject var m: EditorModel
    @ObservedObject var lib: Library

    var body: some View {
        VStack(spacing: 0) {
            TopBar(m: m, lib: lib)
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 12) {
                    ZStack {
                        PlayerView(player: m.player)
                            .aspectRatio(Formats.ratio(m.settings.aspect), contentMode: .fit)
                            .overlay(PreviewOverlay(m: m))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(m.drawingMask || m.drawingAnnotation != nil ? violet : line))
                            .onTapGesture { m.togglePlay() }
                        if !m.isPlaying && !m.drawingMask && m.drawingAnnotation == nil && m.pendingText == nil {
                            Button { m.togglePlay() } label: {
                                Circle().fill(violet).frame(width: 64, height: 64)
                                    .overlay(Image(systemName: "play.fill").font(.system(size: 24)).foregroundColor(.white).offset(x: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                StylePanel(m: m)
                    .frame(width: 270)
            }
            .padding(.horizontal, 22).padding(.top, 6)
            Transport(m: m).padding(.horizontal, 22).padding(.top, 14)
            Timeline(m: m).padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 18)
        }
        .frame(minWidth: 1000, minHeight: 680)
        .background(Color(Theme.black))
        .foregroundColor(.white)
    }
}

// MARK: - Sur l'aperçu : repères Reels, masque sélectionné, dessin d'un masque à la souris

struct PreviewOverlay: View {
    @ObservedObject var m: EditorModel
    @State private var start: CGPoint?
    @State private var now: CGPoint?
    @State private var moveOrigin: Annotation?
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                if m.settings.aspect == "9:16" && m.settings.reelsGuides { ReelsGuides(size: g.size).allowsHitTesting(false) }
                if let i = m.selectedMask, let r = m.maskRect(i, viewSize: g.size) {
                    Rectangle().stroke(violet, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: max(1, r.width), height: max(1, r.height)).offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
                // annotation choisie : cadre en pointillés, à glisser pour la déplacer
                if let i = m.selectedAnnotation, i < m.annotations.count, m.drawingAnnotation == nil,
                   let r = m.annotationRect(i, viewSize: g.size) {
                    Rectangle().stroke(violet, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .background(Color.white.opacity(0.001))
                        .frame(width: max(8, r.width), height: max(8, r.height)).offset(x: r.minX, y: r.minY)
                        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                            if moveOrigin == nil { moveOrigin = m.annotations[i] }
                            guard let o = moveOrigin, let a = m.screenPoint(.zero, viewSize: g.size),
                                  let b = m.screenPoint(CGPoint(x: v.translation.width, y: v.translation.height), viewSize: g.size) else { return }
                            // le zoom change l'échelle : on convertit le déplacement en points de la vue en fraction de l'écran filmé
                            let dx = b.x - a.x, dy = b.y - a.y
                            m.editAnnotation(i, live: true) { $0 = o; $0.translate(dx: dx, dy: dy) }
                        }.onEnded { _ in
                            moveOrigin = nil
                            m.editAnnotation(i, live: false) { _ in }
                        })
                }
                if let tool = m.drawingAnnotation {
                    Color.black.opacity(0.18).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            start = v.startLocation; now = v.location
                        }.onEnded { v in
                            m.addAnnotation(kind: tool, from: v.startLocation, to: v.location, viewSize: g.size)
                            start = nil; now = nil
                        })
                    if let a = start, let b = now, tool != "texte" {
                        Group {
                            if tool == "cadre" {
                                RoundedRectangle(cornerRadius: 8).stroke(violet, lineWidth: 3)
                                    .frame(width: abs(b.x - a.x), height: abs(b.y - a.y)).offset(x: min(a.x, b.x), y: min(a.y, b.y))
                            } else {
                                Path { p in p.move(to: a); p.addLine(to: b) }.stroke(violet, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            }
                        }.allowsHitTesting(false)
                    } else if start == nil {
                        Text(tool == "texte" ? "Clique où poser le texte" : tool == "fleche" ? "Trace la flèche : du départ vers la pointe" : "Trace le cadre")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.black.opacity(0.75)))
                            .frame(width: g.size.width).offset(y: 12).allowsHitTesting(false)
                    }
                }
                // texte cliqué : champ pour taper, Entrée valide, Échap annule
                if let pt = m.pendingText, let inst = m.instruction {
                    let R = inst.renderSize, z = inst.path.sample(m.playhead)
                    let o = inst.toOutput(pt.x, pt.y, zoom: z)
                    TextField("Ton texte", text: $typed)
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .bold)).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(width: 260)
                        .background(Capsule().fill(Color.black.opacity(0.9)))
                        .overlay(Capsule().stroke(violet, lineWidth: 1.5))
                        .focused($typing)
                        .onSubmit { m.commitPendingText(typed); typed = "" }
                        .onExitCommand { m.pendingText = nil; typed = "" }
                        .position(x: min(max(130, o.x / R.width * g.size.width), g.size.width - 130),
                                  y: min(max(20, (R.height - o.y) / R.height * g.size.height), g.size.height - 20))
                        .onAppear { typed = ""; typing = true }
                }
                if m.drawingMask {
                    Color.black.opacity(0.18).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                            start = v.startLocation; now = v.location
                        }.onEnded { v in
                            m.addMask(from: v.startLocation, to: v.location, viewSize: g.size)
                            start = nil; now = nil
                        })
                    if let a = start, let b = now {
                        Rectangle().fill(violet.opacity(0.18)).overlay(Rectangle().stroke(violet, lineWidth: 1.5))
                            .frame(width: abs(b.x - a.x), height: abs(b.y - a.y)).offset(x: min(a.x, b.x), y: min(a.y, b.y))
                            .allowsHitTesting(false)
                    } else {
                        Text("Trace la zone à masquer").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.black.opacity(0.75)))
                            .frame(width: g.size.width).offset(y: 12).allowsHitTesting(false)
                    }
                }
            }
        }
        // l'aperçu reste cliquable (lecture) sauf pendant un tracé ; seuls les éléments ci-dessus captent la souris
    }
}

/// Zones couvertes par l'interface Instagram / TikTok en vertical (aperçu seulement, jamais dans l'export).
struct ReelsGuides: View {
    let size: CGSize
    var body: some View {
        let W = size.width, H = size.height
        let zones = [
            CGRect(x: 0, y: 0, width: W, height: H * Formats.reelsTop),
            CGRect(x: 0, y: H * (1 - Formats.reelsBottom), width: W, height: H * Formats.reelsBottom),
            CGRect(x: W * (1 - Formats.reelsRight), y: H * 0.45, width: W * Formats.reelsRight, height: H * (0.55 - Formats.reelsBottom)),
        ]
        ZStack(alignment: .topLeading) {
            ForEach(Array(zones.enumerated()), id: \.offset) { _, r in
                Rectangle().fill(Color.black.opacity(0.32))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            }
            Text("Interface Instagram / TikTok").font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8)).padding(6).offset(y: H * (1 - Formats.reelsBottom))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Barre du haut : pour qui → copier le lien

/// Réglages du lien, à côté de « Copier le lien » : miniature, e-mail demandé, mot de passe (2026-10-14, parité Loom).
struct ShareMenu: View {
    @ObservedObject var m: EditorModel
    @ObservedObject var lib: Library
    @State private var askPassword = false
    @State private var pw = ""

    private var v: Video { lib.videos.first { $0.id == m.video.id } ?? m.video }

    var body: some View {
        Menu {
            Button { lib.setThumbTime(v, m.playhead) } label: { Label("Miniature : l'image affichée", systemImage: "photo") }
            Divider()
            Toggle("Demander l'e-mail avant de regarder", isOn: Binding(get: { v.requireEmail == true }, set: { lib.setRequireEmail(v, $0) }))
            Button { pw = ""; askPassword = true } label: {
                Label(v.locked == true ? "Changer le mot de passe…" : "Protéger par mot de passe…", systemImage: "lock")
            }
            if v.locked == true { Button("Retirer le mot de passe") { lib.setPassword(v, "") } }
        } label: {
            Image(systemName: v.requireEmail == true || v.locked == true ? "lock.fill" : "slider.horizontal.3")
                .font(.system(size: 13)).frame(width: 34, height: 34)
                .background(Circle().fill(Color(white: 0.14))).foregroundColor(.white)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Réglages du lien : miniature, e-mail demandé, mot de passe")
        .sheet(isPresented: $askPassword) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mot de passe du lien").font(.system(size: 16, weight: .bold))
                Text("Ton prospect devra le saisir pour voir la vidéo. Envoie-le avec le lien.").font(.system(size: 12)).foregroundColor(muted)
                SecureField("Mot de passe", text: $pw).textFieldStyle(.roundedBorder)
                HStack { Spacer()
                    Button("Annuler") { askPassword = false }.keyboardShortcut(.cancelAction)
                    Button("Protéger") { lib.setPassword(v, pw); askPassword = false }.keyboardShortcut(.defaultAction).disabled(pw.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(22).frame(width: 380)
        }
    }
}

struct TopBar: View {
    @ObservedObject var m: EditorModel
    @ObservedObject var lib: Library
    @State private var title = ""
    @State private var first = ""
    @State private var company = ""

    private func saveProspect() { lib.setProspect(m.video, firstName: first, company: company) }

    var body: some View {
        HStack(spacing: 14) {
            TextField("Titre de la vidéo", text: $title, onCommit: {
                if let v = lib.videos.first(where: { $0.id == m.video.id }) { lib.rename(v, to: title) }
            })
            .textFieldStyle(.plain)
            .font(.system(size: 16, weight: .bold))
            .frame(minWidth: 180, maxWidth: 320)
            .help("Le titre que verra ton prospect")

            Spacer()

            HStack(spacing: 8) {
                Text("Pour").foregroundColor(muted).font(.system(size: 13))
                TextField("Prénom", text: $first, onCommit: saveProspect).textFieldStyle(.roundedBorder).frame(width: 110)
                Text("chez").foregroundColor(muted).font(.system(size: 13))
                TextField("Agence", text: $company, onCommit: saveProspect).textFieldStyle(.roundedBorder).frame(width: 150)
                ProspectPicker(query: "\(first) \(company)", linkedId: lib.videos.first { $0.id == m.video.id }?.recordId) { p in
                    if let v = lib.videos.first(where: { $0.id == m.video.id }) {
                        if let p = p { first = first.isEmpty ? p.firstName : first; company = company.isEmpty ? p.company : company }
                        lib.link(v, to: p); saveProspect()
                    }
                }
            }
            .help("Sa page affichera « Salut Prénom, une vidéo pour Agence »")

            ShareMenu(m: m, lib: lib)

            if let f = lib.flash[m.video.id] {
                Label(f, systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundColor(violet)
                    .frame(width: 190)
            } else {
                Button { saveProspect(); m.copyLink() } label: {
                    Label("Copier le lien", systemImage: "link")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(violet))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .help(lib.needsUpload(m.video.id) ? "Copie le lien tout de suite ; la vidéo s'envoie pendant que tu le colles" : "Copie le lien (déjà en ligne)")
            }
            if let p = lib.progress[m.video.id] { UploadLine(p: p).frame(width: 150) }
        }
        .padding(.leading, 86).padding(.trailing, 22).padding(.top, 10).padding(.bottom, 10)
        .onAppear {
            let v = lib.videos.first(where: { $0.id == m.video.id }) ?? m.video
            title = v.title; first = v.firstName ?? ""; company = v.company ?? ""
        }
        .onDisappear(perform: saveProspect)
    }
}

// MARK: - Style en un clic (+ réglages fins repliés)

struct StylePanel: View {
    @ObservedObject var m: EditorModel
    @State private var advanced = false
    @State private var tab = "style"
    @State private var musics: [String] = []

    private let presets: [(id: String, name: String)] = [("violet", "Violet"), ("noir", "Sombre"), ("blanc", "Clair"), ("aucun", "Plein écran"),
                                                         ("fond-ecran", "Mon bureau"), ("image", "Image…")]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Style").tag("style"); Text("Texte").tag("texte"); Text("Son").tag("son")
            }
            .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 12)
            switch tab {
            case "texte": TranscriptPanel(m: m)
            case "son": soundPanel
            default: stylePanel
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(line))
    }

    // MARK: son : voix, mots parasites, frappe, musique, clics
    private var soundPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    label("Voix")
                    toggle("Réduire le bruit", "waveform.badge.minus", \.noiseReduction)
                    if m.settings.noiseReduction {
                        Group {
                            if m.cleaning { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Nettoyage de ta voix…") } }
                            else if Audio.ffmpeg == nil { Text("ffmpeg introuvable : son d'origine") }
                        }
                        .font(.system(size: 11)).foregroundColor(muted).padding(.leading, 26)
                    }
                    toggle("Couper les « euh »", "mouth", \.removeFillers)
                    if m.settings.removeFillers && !m.fillerCuts.isEmpty {
                        Text("\(m.fillerCuts.count) « euh » retiré\(m.fillerCuts.count > 1 ? "s" : "")")
                            .font(.system(size: 11)).foregroundColor(muted).padding(.leading, 26)
                    }
                    toggle("Accélérer la frappe (×3)", "keyboard", \.speedUpTyping)
                }
                VStack(alignment: .leading, spacing: 10) {
                    label("Audios importés")
                    toggle("Couper le son d'origine", "speaker.slash", \.muteOriginal)
                    if m.settings.muteOriginal {
                        Text("Silences, « euh » et sous-titres de la voix d'origine désactivés")
                            .font(.system(size: 11)).foregroundColor(muted).padding(.leading, 26)
                    }
                    ForEach(m.audioClips) { c in
                        Button { m.selectedAudio = c.id; m.seek(source: c.at) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform").foregroundColor(violet)
                                Text(c.name).lineLimit(1)
                                Spacer()
                                Text(clock(c.at)).font(.system(size: 10.5, design: .monospaced)).foregroundColor(muted)
                            }
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(m.selectedAudio == c.id ? violet.opacity(0.25) : Color(white: 0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { m.chooseAudio() } label: {
                        Label("Importer un audio ici…", systemImage: "plus").font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain).foregroundColor(violet)
                    .help("Voix off, son… posé à la tête de lecture ; glisse-le ensuite sur la frise")
                }
                VStack(alignment: .leading, spacing: 10) {
                    label("Musique")
                    Picker("", selection: Binding(get: { m.settings.music ?? "" }, set: { v in m.change { $0.music = v.isEmpty ? nil : v } })) {
                        Text("Aucune").tag("")
                        ForEach(musics, id: \.self) { Text(($0 as NSString).deletingPathExtension).tag($0) }
                    }
                    .labelsHidden()
                    if m.settings.music != nil {
                        sliderRow("Volume sous la voix", value: \.musicVolume, range: 0.02...0.4)
                    }
                    Button { NSWorkspace.shared.open(Audio.musicFolder) } label: {
                        Label("Ouvrir le dossier Musique", systemImage: "folder").font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain).foregroundColor(muted)
                    .help("Dépose tes morceaux (mp3, m4a, wav) dans ~/Music/X-Videos")
                }
                VStack(alignment: .leading, spacing: 10) {
                    label("Clics")
                    toggle("Son à chaque clic", "cursorarrow.click", \.clickSounds)
                }
            }
            .padding(16)
        }
        .onAppear { musics = Audio.musicFiles() }
    }

    private var stylePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                label("Format")
                Picker("", selection: Binding(get: { m.settings.aspect }, set: { v in m.change { $0.aspect = v } })) {
                    ForEach(Formats.all, id: \.id) { f in Text(f.name).tag(f.id) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if m.settings.aspect == "9:16" { toggle("Repères Reels (aperçu)", "rectangle.dashed", \.reelsGuides) }

                label("Style")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(presets, id: \.id) { p in
                        Button {
                            if p.id == "image" { m.chooseBackgroundImage() } else { m.change { $0.background = p.id } }
                        } label: {
                            VStack(spacing: 6) {
                                StyleTile(id: p.id, imagePath: m.settings.backgroundImage).frame(height: 62)
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(m.settings.background == p.id ? violet : line,
                                                                                    lineWidth: m.settings.background == p.id ? 2 : 1))
                                Text(p.name).font(.system(size: 11, weight: .medium))
                                    .foregroundColor(m.settings.background == p.id ? .white : muted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    label("Automatique")
                    toggle("Zooms sur mes clics", "plus.magnifyingglass", \.autoZoom)
                    toggle("Couper les silences", "scissors", \.removeSilences)
                    toggle("Sous-titres", "captions.bubble", \.captions)
                    if m.settings.captions {
                        Group {
                            if m.transcribing {
                                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Transcription de ta voix…") }
                            } else if !Captions.available {
                                Text("Moteur Whisper introuvable")
                            } else if m.captionCount == 0 {
                                Text("Aucune parole détectée")
                            }
                        }
                        .font(.system(size: 11)).foregroundColor(muted).padding(.leading, 26)
                        Picker("", selection: Binding(get: { m.settings.captionStyle }, set: { v in m.change { $0.captionStyle = v } })) {
                            ForEach(CaptionLayer.styles, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(.leading, 26)
                    }
                    if m.hasCamera { toggle("Ma caméra", "person.crop.circle", \.showCamera) }
                    toggle("Raccourcis affichés", "command", \.showKeys)
                }

                if m.hasCamera && m.settings.showCamera { cameraSection }

                presetSection

                if m.settings.removeSilences && !m.silences.isEmpty {
                    Text("\(m.silences.count) pause\(m.silences.count > 1 ? "s" : "") retirée\(m.silences.count > 1 ? "s" : "") · \(clock(m.sourceDuration)) → \(clock(m.duration))")
                        .font(.system(size: 11)).foregroundColor(muted)
                }

                DisclosureGroup(isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        if m.settings.background != "aucun" {
                            sliderRow("Marge", value: \.padding, range: 0.02...0.12)
                            sliderRow("Coins arrondis", value: \.radius, range: 0...40)
                            sliderRow("Ombre", value: \.shadow, range: 0...1.5)
                        }
                        sliderRow("Flou de mouvement", value: \.motionBlur, range: 0...1)
                        sliderRow("Taille du curseur", value: \.cursorScale, range: 1...2.6)
                        toggle("Curseur adouci", "cursorarrow.motionlines", \.smoothCursor)
                        toggle("Cercle au clic", "circle.circle", \.clickEffect)
                        toggle("Masquer le curseur au repos", "eye.slash", \.hideIdleCursor)
                        Text("Qualité d'export").font(.system(size: 12)).foregroundColor(muted)
                        Picker("", selection: Binding(get: { m.settings.exportHeight }, set: { v in m.change { $0.exportHeight = v } })) {
                            Text("720p").tag(720); Text("1080p").tag(1080); Text("4K").tag(2160)
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        Picker("", selection: Binding(get: { m.settings.exportFPS }, set: { v in m.change { $0.exportFPS = v } })) {
                            Text("30 i/s").tag(30); Text("60 i/s").tag(60)
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Réglages fins").font(.system(size: 12, weight: .medium)).foregroundColor(muted)
                }
                .tint(muted)
            }
            .padding(16)
        }
    }

    /// Caméra : mise en page, intro / fin, silences, rendu, netteté, suivi du visage.
    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Caméra")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(CameraLayouts.all, id: \.id) { l in
                    let on = m.settings.cameraLayout == l.id
                    Button { m.change { $0.cameraLayout = l.id } } label: {
                        Label(l.name, systemImage: l.icon).font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? violet.opacity(0.22) : Color(white: 0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? violet : line))
                            .foregroundColor(on ? .white : muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Caméra plein écran au début et à la fin").font(.system(size: 12)).foregroundColor(muted)
                Spacer()
                Picker("", selection: Binding(get: { m.settings.cameraIntroOutro }, set: { v in m.change { $0.cameraIntroOutro = v } })) {
                    Text("Non").tag(0.0); Text("2 s").tag(2.0); Text("4 s").tag(4.0)
                }
                .labelsHidden().frame(width: 70).controlSize(.small)
            }
            if m.settings.cameraLayout == "bulle" { toggle("Masquer la bulle dans les silences", "speaker.slash", \.hideCameraInSilence) }
            Picker("", selection: Binding(get: { m.settings.cameraLook }, set: { v in m.change { $0.cameraLook = v } })) {
                ForEach(CameraLayouts.looks, id: \.id) { l in Text(l.name).tag(l.id) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            sliderRow("Netteté", value: \.cameraSharpen, range: 0...1)
            HStack {
                Text("Fond").font(.system(size: 12)).foregroundColor(muted)
                Spacer()
                Picker("", selection: Binding(get: { m.settings.cameraBackground }, set: { v in m.change { $0.cameraBackground = v } })) {
                    ForEach(CameraCutout.modes, id: \.id) { b in Text(b.name).tag(b.id) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 190)
            }
            toggle("Visage centré (suivi)", "face.smiling", \.faceTracking)
            if m.analyzingFace {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Analyse du visage…") }
                    .font(.system(size: 11)).foregroundColor(muted).padding(.leading, 26)
            }
        }
    }

    /// Préréglages : un style complet (fond, marge, coins, ombre, caméra, format) enregistré sous un nom.
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Préréglages")
            ForEach(m.presets) { p in
                HStack {
                    Button { m.applyPreset(p) } label: {
                        Label(p.name, systemImage: "paintpalette").font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).help("Appliquer ce style")
                    Button { m.deletePreset(p.name) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundColor(muted).help("Supprimer ce préréglage")
                }
            }
            Button {
                let a = NSAlert()
                a.messageText = "Enregistrer ce style"
                a.informativeText = "Fond, marge, coins, ombre, caméra et format, sous un nom."
                let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                f.placeholderString = "Ex. Reels sombre"
                a.accessoryView = f
                a.addButton(withTitle: "Enregistrer"); a.addButton(withTitle: "Annuler")
                a.window.initialFirstResponder = f
                if a.runModal() == .alertFirstButtonReturn { m.savePreset(named: f.stringValue) }
            } label: {
                Label("Enregistrer ce style…", systemImage: "plus").font(.system(size: 12, weight: .medium)).foregroundColor(violet)
            }
            .buttonStyle(.plain)
        }
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundColor(muted)
    }

    private func toggle(_ t: String, _ icon: String, _ kp: WritableKeyPath<EditSettings, Bool>) -> some View {
        Toggle(isOn: Binding(get: { m.settings[keyPath: kp] }, set: { v in m.change { $0[keyPath: kp] = v } })) {
            Label(t, systemImage: icon).font(.system(size: 12.5))
        }
        .toggleStyle(.switch).controlSize(.small).tint(violet)
    }

    private func sliderRow(_ t: String, value kp: WritableKeyPath<EditSettings, Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.system(size: 12)).foregroundColor(muted)
            Slider(value: Binding(get: { m.settings[keyPath: kp] }, set: { v in m.change(undoable: false) { $0[keyPath: kp] = v } }), in: range)
                .tint(violet).controlSize(.small)
        }
    }
}

// MARK: - Panneau Texte : la transcription mot par mot, on sélectionne et on supprime

struct TranscriptPanel: View {
    @ObservedObject var m: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let r = m.selectedWords {
                    let allCut = r.allSatisfy { $0 < m.words.count && m.isCut(m.words[$0]) }
                    Button { allCut ? m.restoreSelectedWords() : m.cutSelectedWords() } label: {
                        Label(allCut ? "Rétablir" : "Supprimer", systemImage: allCut ? "arrow.uturn.backward" : "scissors")
                            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(violet)).foregroundColor(.white)
                    }
                    .buttonStyle(.plain).help(allCut ? "Remettre ces mots dans la vidéo" : "Retirer ces mots de la vidéo (⌫)")
                    Text("\(r.count) mot\(r.count > 1 ? "s" : "")").font(.system(size: 11)).foregroundColor(muted)
                } else {
                    Text("Clique un mot, ⇧-clique le dernier, puis ⌫").font(.system(size: 11)).foregroundColor(muted)
                }
                Spacer()
                Button { m.exportSRT() } label: { Label(".srt", systemImage: "square.and.arrow.down").font(.system(size: 11.5)) }
                    .buttonStyle(.plain).foregroundColor(muted).disabled(m.words.isEmpty)
                    .help("Enregistre les sous-titres (.srt) à côté de la vidéo")
            }
            if let n = m.notice { Text(n).font(.system(size: 11)).foregroundColor(violet) }
            ScrollView {
                if m.words.isEmpty {
                    Text(m.transcribing ? "Transcription de ta voix…" : Captions.available ? "Aucune parole détectée" : "Moteur Whisper introuvable")
                        .font(.system(size: 12)).foregroundColor(muted).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    WordsView(words: m.words, cut: m.words.map { m.isCut($0) }, filler: m.words.map { m.isFillerCut($0) },
                              selection: m.selectedWords) { i in m.tapWord(i, extend: NSEvent.modifierFlags.contains(.shift)) }
                        .equatable()
                }
            }
        }
        .padding(16)
    }
}

/// Les mots (ne se redessinent pas à chaque image de la lecture : seulement quand le texte ou la sélection change).
struct WordsView: View, Equatable {
    let words: [Captions.Word]
    let cut: [Bool]
    let filler: [Bool]
    let selection: ClosedRange<Int>?
    let onTap: (Int) -> Void

    static func == (a: WordsView, b: WordsView) -> Bool {
        a.words == b.words && a.cut == b.cut && a.filler == b.filler && a.selection == b.selection
    }

    var body: some View {
        Flow(spacing: 2) {
            ForEach(words.indices, id: \.self) { i in
                let gone = cut[i] || filler[i]
                let sel = selection?.contains(i) ?? false
                Text(words[i].text)
                    .font(.system(size: 13))
                    .strikethrough(gone, color: muted)
                    .foregroundColor(sel ? .white : gone ? muted.opacity(0.7) : Color(white: 0.9))
                    .padding(.horizontal, 2).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(sel ? violet : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(i) }
                    .help(filler[i] ? "« euh » retiré automatiquement" : "")
            }
        }
    }
}

/// Mise en page « texte » : les éléments vont à la ligne quand la largeur est pleine.
struct Flow: Layout {
    var spacing: CGFloat = 2
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 240
        return CGSize(width: w, height: arrange(subviews, width: w).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, p) in zip(subviews, arrange(subviews, width: bounds.width).points) {
            s.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], height: CGFloat) {
        var pts: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return (pts, y + rowH)
    }
}

/// Vignette d'un style : le fond, et l'écran posé dessus.
struct StyleTile: View {
    let id: String
    var imagePath: String? = nil
    private static var thumbs: [String: NSImage] = [:]     // vignettes réduites, lues une seule fois
    private var picture: NSImage? {
        let path: String?
        switch id {
        case "fond-ecran": path = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }?.path
        case "image": path = imagePath
        default: return nil
        }
        guard let p = path else { return nil }
        if let t = Self.thumbs[p] { return t }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary) else { return nil }
        let t = NSImage(cgImage: cg, size: .zero)
        Self.thumbs[p] = t
        return t
    }
    var body: some View {
        GeometryReader { g in
            ZStack {
                if let p = picture { Image(nsImage: p).resizable().aspectRatio(contentMode: .fill).frame(width: g.size.width, height: g.size.height).clipped() }
                else if id == "image" { Color(white: 0.16).overlay(Image(systemName: "photo").font(.system(size: 16)).foregroundColor(muted).offset(y: -14)) }
                else if let c = Backgrounds.color(id) { Color(nsColor: NSColor(ciColor: c)) } else { Color(white: 0.16) }
                RoundedRectangle(cornerRadius: id == "aucun" ? 0 : 4)
                    .fill(id == "noir" ? Color(white: 0.32) : Color(white: 0.22))
                    .overlay(VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<3, id: \.self) { k in Capsule().fill(Color.white.opacity(0.25)).frame(width: g.size.width * (k == 0 ? 0.3 : 0.45), height: 3) }
                    }.padding(6), alignment: .topLeading)
                    .padding(id == "aucun" ? 0 : g.size.height * 0.2)
                    .shadow(color: .black.opacity(id == "aucun" ? 0 : 0.35), radius: 3, y: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Barre de lecture

struct Transport: View {
    @ObservedObject var m: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Button { m.togglePlay() } label: {
                Image(systemName: m.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15))
                    .frame(width: 38, height: 38).background(Circle().fill(Color(white: 0.15)))
            }
            .buttonStyle(.plain).help("Lecture / pause (Espace)")

            Text("\(clock(m.compPlayhead)) / \(clock(m.duration))")
                .font(.system(size: 13, weight: .medium, design: .monospaced))

            Divider().frame(height: 22)

            chip("Zoom ici", "plus.magnifyingglass", "Ajoute un zoom à la position actuelle (Z)") { m.addZoomHere() }
            // importer : vidéos à la suite, audios à la tête de lecture
            Menu {
                Button { m.chooseVideosToAppend() } label: { Label("Vidéo à la suite…", systemImage: "film.stack") }
                Button { m.chooseAudio() } label: { Label("Audio ici (voix off, son)…", systemImage: "waveform") }
                if m.canUndoAppend {
                    Divider()
                    Button { m.undoAppend() } label: { Label("Annuler le dernier changement de morceaux", systemImage: "arrow.uturn.backward") }
                }
            } label: {
                HStack(spacing: 6) {
                    if m.assembling { ProgressView().controlSize(.mini) }
                    Label(m.assembling ? "Assemblage…" : "Importer", systemImage: "square.and.arrow.down")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color(white: 0.14)))
                .foregroundColor(.white)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(m.assembling)
            .help("Ajouter une vidéo à la suite, ou poser un audio (voix off, son) à la tête de lecture")
            // vitesse de toute la vidéo (demande de Baptiste du 10/10 : « choisir ×2 et ça accélère tout »)
            Menu {
                ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { v in
                    Button { m.change { $0.globalSpeed = v } } label: {
                        Text(speedLabel(v)); if m.settings.globalSpeed == v { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                Label("Vitesse " + speedLabel(m.settings.globalSpeed), systemImage: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(m.settings.globalSpeed == 1 ? Color(white: 0.14) : violet))
                    .foregroundColor(.white)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Accélère toute la vidéo (aperçu, export et lien)")
            chip(m.drawingMask ? "Annuler le tracé" : "Masquer une zone", "eye.slash",
                 "Trace un rectangle sur l'aperçu : flou (donnée sensible) ou projecteur, 3 s à partir d'ici") {
                m.drawingMask.toggle(); if m.drawingMask { m.player.pause(); m.drawingAnnotation = nil; m.pendingText = nil }
            }
            annotationTool("texte", "textformat", "Texte", "Clique sur l'aperçu, tape ton texte : 3 s à partir d'ici")
            annotationTool("fleche", "arrow.up.right", "Flèche", "Trace une flèche sur l'aperçu : 3 s à partir d'ici")
            annotationTool("cadre", "rectangle", "Cadre", "Trace un cadre sur l'aperçu : 3 s à partir d'ici")

            if let i = m.selectedAnnotation, i < m.annotations.count {
                HStack(spacing: 8) {
                    Image(systemName: m.annotations[i].kind == "texte" ? "textformat" : m.annotations[i].kind == "fleche" ? "arrow.up.right" : "rectangle")
                        .foregroundColor(violet)
                    if m.annotations[i].kind == "texte" {
                        TextField("Texte", text: Binding(get: { m.annotations[i].text },
                                                         set: { v in m.editAnnotation(i, live: true) { $0.text = v } }))
                            .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).frame(width: 130)
                            .onSubmit { m.editAnnotation(i, live: false) { _ in } }     // Entrée : une seule étape d'annulation
                    }
                    Button { m.deleteSelectedAnnotation() } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundColor(muted).help("Supprimer (⌫)")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(violet.opacity(0.18)))
                .overlay(Capsule().stroke(violet.opacity(0.6)))
            }

            if let i = m.selectedMask, i < m.masks.count {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { m.masks[i].kind }, set: { v in m.editMask(i, live: false) { $0.kind = v } })) {
                        Text("Flou").tag("flou"); Text("Projecteur").tag("projecteur")
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
                    Button { m.deleteSelectedMask() } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundColor(muted).help("Supprimer ce masque (⌫)")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(violet.opacity(0.18)))
                .overlay(Capsule().stroke(violet.opacity(0.6)))
            }

            if let id = m.selectedAudio, let c = m.audioClips.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundColor(violet)
                    Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: 130)
                    Text("\(Int((c.volume * 100).rounded())) %").font(.system(size: 11.5, design: .monospaced)).frame(width: 40)
                    Slider(value: Binding(get: { c.volume }, set: { v in m.editAudio(id, live: true) { $0.volume = v } }),
                           in: 0...2, onEditingChanged: { editing in if !editing { m.editAudio(id, live: false) { _ in } } })
                        .tint(violet).controlSize(.small).frame(width: 110)
                        .help("Volume de cet audio (100 % = d'origine)")
                    Button { m.deleteSelectedAudio() } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundColor(muted).help("Retirer cet audio (⌫)")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(violet.opacity(0.18)))
                .overlay(Capsule().stroke(violet.opacity(0.6)))
            }

            if let i = m.selectedZoom, i < m.zooms.count {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { m.zooms[i].kind ?? "cadre" }, set: { v in m.setZoomKind(i, v == "loupe" ? "loupe" : nil) })) {
                        Text("Zoom").tag("cadre"); Text("Loupe").tag("loupe")
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 110)
                    .help("Zoom : tout le cadre se rapproche · Loupe : un cercle grossit autour du curseur")
                    Text(String(format: "%.1f×", m.zooms[i].scale)).font(.system(size: 12, weight: .semibold))
                    Slider(value: Binding(get: { m.zooms[i].scale }, set: { v in m.setZoom(i, scale: v, live: true) }),
                           in: 1.25...3, onEditingChanged: { editing in if !editing { m.setZoom(i, live: false) } })
                        .tint(violet).controlSize(.small).frame(width: 120)
                    Button { m.deleteSelectedZoom() } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundColor(muted).help("Supprimer ce zoom (⌫)")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(violet.opacity(0.18)))
                .overlay(Capsule().stroke(violet.opacity(0.6)))
            }

            if let sel = m.selection {
                HStack(spacing: 6) {
                    Text("\(clock(sel.start))–\(clock(sel.end))").font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    ForEach([1.5, 2, 4], id: \.self) { sp in
                        Button { m.setSpeed(sp) } label: { Text(sp == 1.5 ? "×1,5" : "×\(Int(sp))").font(.system(size: 11.5, weight: .semibold)) }
                            .buttonStyle(.plain).help("Accélérer ce passage")
                    }
                    Button { m.setSpeed(1) } label: { Text("Normal").font(.system(size: 11.5)) }.buttonStyle(.plain).help("Vitesse normale")
                    Button { m.cutSelection() } label: { Image(systemName: "scissors") }.buttonStyle(.plain).help("Couper ce passage (⌫)")
                    Button { m.selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(muted)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(violet.opacity(0.18)))
                .overlay(Capsule().stroke(violet.opacity(0.6)))
            }

            Spacer()

            if m.canUndo {
                chip("Annuler", "arrow.uturn.backward", "Annuler la dernière modification (⌘Z)") { m.undo() }
            }
            if let n = m.notice, n.contains("✓") || n.contains("impossible") {
                Text(n).font(.system(size: 11.5, weight: .semibold)).foregroundColor(violet).lineLimit(1)
            } else {
                Text("Espace · Z zoom · ⌫ · ⌘Z")
                    .font(.system(size: 11)).foregroundColor(muted)
            }
        }
    }

    /// Outil d'annotation : un clic l'active, puis on dessine sur l'aperçu (texte : un clic, puis on tape).
    private func annotationTool(_ kind: String, _ icon: String, _ label: String, _ help: String) -> some View {
        let on = m.drawingAnnotation == kind
        return Button {
            m.drawingAnnotation = on ? nil : kind
            m.pendingText = nil
            if !on { m.player.pause(); m.drawingMask = false }
        } label: {
            Label(label, systemImage: icon).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(on ? violet : Color(white: 0.14)))
        }
        .buttonStyle(.plain).help(help)
    }

    private func chip(_ t: String, _ icon: String, _ help: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Label(t, systemImage: icon).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color(white: 0.14)))
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - Frise : vignettes, coupes à glisser, zooms à déplacer et étirer

struct Timeline: View {
    @ObservedObject var m: EditorModel
    @State private var dragOrigin: ZoomSegment?
    @State private var trimOrigin: Double?
    @State private var maskOrigin: MaskRegion?

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, D = max(0.1, m.sourceDuration)
            let x = { (t: Double) -> CGFloat in CGFloat(t / D) * W }
            let t = { (px: CGFloat) -> Double in Double(px / W) * D }
            VStack(spacing: 6) {
                // règle des temps
                ZStack(alignment: .topLeading) {
                    ForEach(ticks(D), id: \.self) { s in
                        Text(clock(s)).font(.system(size: 9.5, design: .monospaced)).foregroundColor(muted)
                            .offset(x: min(W - 26, x(s)))
                    }
                }
                .frame(width: W, height: 12, alignment: .topLeading)

                // piste vidéo : vignettes + silences + coupes
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Array(m.thumbnails.enumerated()), id: \.offset) { _, img in
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: W / CGFloat(max(1, m.thumbnails.count)), height: 58).clipped()
                        }
                    }
                    .frame(width: W, height: 58, alignment: .leading)
                    .background(Color(white: 0.12))
                    .opacity(0.85)

                    // passages coupés depuis le texte ou la frise, et « euh » retirés
                    ForEach(Array(((m.settings.cuts ?? []) + (m.settings.removeFillers ? m.fillerCuts : [])).enumerated()), id: \.offset) { _, r in
                        Rectangle().fill(Color.black.opacity(0.72))
                            .overlay(Image(systemName: "scissors").font(.system(size: 9)).foregroundColor(.white).opacity(x(r.end) - x(r.start) > 14 ? 1 : 0))
                            .frame(width: max(1, x(r.end) - x(r.start)), height: 58).offset(x: x(r.start))
                            .help("Passage coupé")
                    }
                    if m.settings.removeSilences {
                        ForEach(Array(m.silences.enumerated()), id: \.offset) { _, r in
                            Rectangle().fill(Color.black.opacity(0.62))
                                .overlay(Image(systemName: "scissors").font(.system(size: 9)).foregroundColor(muted).opacity(x(r.end) - x(r.start) > 14 ? 1 : 0))
                                .frame(width: max(1, x(r.end) - x(r.start)), height: 58).offset(x: x(r.start))
                                .help("Pause retirée")
                        }
                    }
                    // jonctions des vidéos mises bout à bout
                    ForEach(Array(m.parts.enumerated()), id: \.offset) { i, p in
                        if i > 0 {
                            Rectangle().fill(violet).frame(width: 2, height: 58).offset(x: x(p.start) - 1)
                                .help("Début de « \(p.name) »")
                        }
                        // menu du morceau (2026-10-14) : avancer, reculer, insérer après, retirer
                        Menu {
                            if i > 0 { Button { m.movePart(i, by: -1) } label: { Label("Avancer", systemImage: "arrow.left") } }
                            if i + 1 < m.parts.count { Button { m.movePart(i, by: 1) } label: { Label("Reculer", systemImage: "arrow.right") } }
                            Button { m.insertVideos(after: i) } label: { Label("Insérer une vidéo après…", systemImage: "film.stack") }
                            if m.parts.count > 1 { Divider(); Button(role: .destructive) { m.removePart(i) } label: { Label("Retirer ce morceau", systemImage: "trash") } }
                        } label: {
                            HStack(spacing: 3) {
                                Text(p.name).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                            }
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .frame(maxWidth: max(0, x((i + 1 < m.parts.count ? m.parts[i + 1].start : D)) - x(p.start) - 8), alignment: .leading)
                        .offset(x: x(p.start) + 4, y: -18)
                        .help("Déplacer, insérer après ou retirer ce morceau")
                    }
                    // parties coupées au début et à la fin
                    Rectangle().fill(Color.black.opacity(0.72)).frame(width: x(m.settings.trimStart), height: 58)
                    Rectangle().fill(Color.black.opacity(0.72)).frame(width: x(m.settings.trimEnd), height: 58).offset(x: W - x(m.settings.trimEnd))
                    // poignées de coupe
                    trimHandle(left: true).offset(x: x(m.settings.trimStart))
                        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                            if trimOrigin == nil { trimOrigin = m.settings.trimStart }
                            m.setTrim(start: trimOrigin! + t(v.translation.width), live: true)
                        }.onEnded { _ in trimOrigin = nil; m.setTrim(live: false) })
                    trimHandle(left: false).offset(x: W - x(m.settings.trimEnd) - 12)
                        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                            if trimOrigin == nil { trimOrigin = m.settings.trimEnd }
                            m.setTrim(end: trimOrigin! - t(v.translation.width), live: true)
                        }.onEnded { _ in trimOrigin = nil; m.setTrim(live: false) })
                }
                .frame(width: W, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .simultaneousGesture(SpatialTapGesture().onEnded { e in m.selectedZoom = nil; m.seek(source: t(e.location.x)) })

                // piste des zooms
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.1))
                        .overlay(Text(m.zooms.isEmpty ? "Pas de zoom · touche Z pour en ajouter un ici" : "")
                            .font(.system(size: 11)).foregroundColor(muted))
                        .contentShape(Rectangle())
                        .onTapGesture { m.selectedZoom = nil }
                    ForEach(Array(m.zooms.enumerated()), id: \.offset) { i, z in
                        zoomBlock(i, z, x: x, t: t)
                    }
                }
                .frame(width: W, height: 30)

                // piste des vitesses : glisser pour choisir une plage, puis ×1,5 / ×2 / ×4 ou couper
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.1))
                        .overlay(Text(m.speeds.isEmpty && m.selection == nil ? "Glisse ici pour accélérer ou couper un passage" : "")
                            .font(.system(size: 10.5)).foregroundColor(muted))
                    ForEach(Array(m.speeds.enumerated()), id: \.offset) { _, r in
                        if r.speed != 1 {
                            RoundedRectangle(cornerRadius: 5).fill(violet.opacity(0.55))
                                .overlay(Text(r.speed == 1.5 ? "×1,5" : String(format: "×%g", r.speed)).font(.system(size: 9.5, weight: .semibold))
                                    .opacity(x(r.end) - x(r.start) > 26 ? 1 : 0))
                                .frame(width: max(2, x(r.end) - x(r.start)), height: 22).offset(x: x(r.start))
                                .onTapGesture { m.selection = CutRange(start: r.start, end: r.end); m.selectedWords = nil }
                                .help("Passage accéléré · clic pour le régler")
                        }
                    }
                    if let s = m.selection {
                        RoundedRectangle(cornerRadius: 5).stroke(Color.white, lineWidth: 1.5).background(Color.white.opacity(0.15))
                            .frame(width: max(2, x(s.end) - x(s.start)), height: 22).offset(x: x(s.start)).allowsHitTesting(false)
                    }
                }
                .frame(width: W, height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                    let a = max(0, t(v.startLocation.x)), b = min(D, t(v.location.x))
                    m.selection = CutRange(start: min(a, b), end: max(a, b)); m.selectedWords = nil
                })
                // piste des audios importés : glisser pour déplacer, clic pour régler le volume
                if !m.audioClips.isEmpty {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.08))
                            .contentShape(Rectangle()).onTapGesture { m.selectedAudio = nil }
                        ForEach(m.audioClips) { c in audioBlock(c, x: x, t: t) }
                    }
                    .frame(width: W, height: 22)
                }
                // piste des masques (flou / projecteur)
                if !m.masks.isEmpty {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.08))
                            .contentShape(Rectangle()).onTapGesture { m.selectedMask = nil }
                        ForEach(Array(m.masks.enumerated()), id: \.offset) { i, mk in
                            maskBlock(i, mk, x: x, t: t)
                        }
                    }
                    .frame(width: W, height: 22)
                }
                // piste des annotations (texte / flèche / cadre)
                if !m.annotations.isEmpty {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.08))
                            .contentShape(Rectangle()).onTapGesture { m.selectedAnnotation = nil }
                        ForEach(Array(m.annotations.enumerated()), id: \.offset) { i, an in
                            annotationBlock(i, an, x: x, t: t)
                        }
                    }
                    .frame(width: W, height: 22)
                }
            }
            .overlay(alignment: .topLeading) {
                // tête de lecture, à glisser
                VStack(spacing: 0) {
                    Circle().fill(Color.white).frame(width: 11, height: 11)
                    Rectangle().fill(Color.white).frame(width: 2)
                }
                .frame(width: 14, height: 152 + extraRows * 28)
                .offset(x: x(m.playhead) - 7, y: 12)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("frise")).onChanged { v in m.seek(source: t(v.location.x)) })
            }
            .coordinateSpace(name: "frise")
        }
        .frame(height: 168 + extraRows * 28)
    }

    /// Pistes en plus sous la frise (audios, masques), pour la hauteur de la tête de lecture.
    private var extraRows: CGFloat { CGFloat((m.masks.isEmpty ? 0 : 1) + (m.audioClips.isEmpty ? 0 : 1) + (m.annotations.isEmpty ? 0 : 1)) }

    @State private var annotationOrigin: Annotation?

    /// Bloc d'une annotation : glisser pour déplacer, bords pour allonger, clic pour la choisir (comme un masque).
    @ViewBuilder
    private func annotationBlock(_ i: Int, _ an: Annotation, x: (Double) -> CGFloat, t: @escaping (CGFloat) -> Double) -> some View {
        let selected = m.selectedAnnotation == i
        let w = max(14, x(an.end) - x(an.start))
        let icon = an.kind == "texte" ? "textformat" : an.kind == "fleche" ? "arrow.up.right" : "rectangle"
        let name = an.kind == "texte" ? (an.text.isEmpty ? "Texte" : an.text) : an.kind == "fleche" ? "Flèche" : "Cadre"
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: selected ? 0.55 : 0.32))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? violet : Color.clear, lineWidth: 1.5))
            Label(name, systemImage: icon).labelStyle(.titleAndIcon).lineLimit(1)
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.white).opacity(w > 70 ? 1 : 0).padding(.horizontal, 8)
            HStack {
                edge().gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if annotationOrigin == nil { annotationOrigin = an; m.selectedAnnotation = i }
                    m.editAnnotation(i, live: true) { $0.start = min(annotationOrigin!.start + t(v.translation.width), $0.end - 0.3) }
                }.onEnded { _ in annotationOrigin = nil; m.editAnnotation(i, live: false) { _ in } })
                Spacer()
                edge().gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if annotationOrigin == nil { annotationOrigin = an; m.selectedAnnotation = i }
                    m.editAnnotation(i, live: true) { $0.end = max(annotationOrigin!.end + t(v.translation.width), $0.start + 0.3) }
                }.onEnded { _ in annotationOrigin = nil; m.editAnnotation(i, live: false) { _ in } })
            }
        }
        .frame(width: w, height: 22)
        .offset(x: x(an.start))
        .help("Annotation : glisse pour déplacer, tire les bords pour allonger · ⌫ pour supprimer")
        .onTapGesture { m.selectedAnnotation = i; m.seek(source: an.start + 0.3) }
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in
            if annotationOrigin == nil { annotationOrigin = an; m.selectedAnnotation = i }
            let len = annotationOrigin!.end - annotationOrigin!.start
            let s = max(0, min(m.sourceDuration - len, annotationOrigin!.start + t(v.translation.width)))
            m.editAnnotation(i, live: true) { $0.start = s; $0.end = s + len }
        }.onEnded { _ in annotationOrigin = nil; m.editAnnotation(i, live: false) { _ in } })
    }

    @State private var audioOrigin: Double?

    /// Bloc d'un audio importé : sa longueur sur la frise, glisser pour le déplacer.
    private func audioBlock(_ c: AudioClip, x: (Double) -> CGFloat, t: @escaping (CGFloat) -> Double) -> some View {
        let selected = m.selectedAudio == c.id
        let w = max(14, x(c.at + c.dur) - x(c.at))
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(violet.opacity(selected ? 0.95 : 0.55))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
            Label(c.name, systemImage: "waveform").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                .foregroundColor(.white).padding(.leading, 6).opacity(w > 34 ? 1 : 0)
        }
        .frame(width: w, height: 22)
        .offset(x: x(c.at))
        .help("\(c.name) · glisse pour déplacer · clic pour régler le volume · ⌫ pour retirer")
        .onTapGesture { m.selectedAudio = c.id; m.selectedZoom = nil; m.selectedMask = nil; m.seek(source: c.at) }
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in
            if audioOrigin == nil { audioOrigin = c.at; m.selectedAudio = c.id; m.selectedZoom = nil }
            m.moveAudio(c.id, to: audioOrigin! + t(v.translation.width), live: true)
        }.onEnded { v in
            if let o = audioOrigin { m.moveAudio(c.id, to: o + t(v.translation.width), live: false) }
            audioOrigin = nil
        })
    }

    /// Bloc d'un masque : glisser pour déplacer, bords pour allonger, clic pour choisir flou / projecteur.
    @ViewBuilder
    private func maskBlock(_ i: Int, _ mk: MaskRegion, x: (Double) -> CGFloat, t: @escaping (CGFloat) -> Double) -> some View {
        let selected = m.selectedMask == i
        let w = max(14, x(mk.end) - x(mk.start))
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: selected ? 0.55 : 0.32))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? violet : Color.clear, lineWidth: 1.5))
            Label(mk.kind == "projecteur" ? "Projecteur" : "Flou", systemImage: mk.kind == "projecteur" ? "light.max" : "eye.slash")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.white).opacity(w > 70 ? 1 : 0)
            HStack {
                edge().gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if maskOrigin == nil { maskOrigin = mk; m.selectedMask = i; m.selectedZoom = nil }
                    m.editMask(i, live: true) { $0.start = min(maskOrigin!.start + t(v.translation.width), $0.end - 0.3) }
                }.onEnded { _ in maskOrigin = nil; m.editMask(i, live: false) { _ in } })
                Spacer()
                edge().gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if maskOrigin == nil { maskOrigin = mk; m.selectedMask = i; m.selectedZoom = nil }
                    m.editMask(i, live: true) { $0.end = max(maskOrigin!.end + t(v.translation.width), $0.start + 0.3) }
                }.onEnded { _ in maskOrigin = nil; m.editMask(i, live: false) { _ in } })
            }
        }
        .frame(width: w, height: 22)
        .offset(x: x(mk.start))
        .help("Masque : glisse pour déplacer, tire les bords pour allonger · ⌫ pour supprimer")
        .onTapGesture { m.selectedMask = i; m.selectedZoom = nil; m.seek(source: mk.start + 0.2) }
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in
            if maskOrigin == nil { maskOrigin = mk; m.selectedMask = i; m.selectedZoom = nil }
            let len = maskOrigin!.end - maskOrigin!.start
            let s = max(0, min(m.sourceDuration - len, maskOrigin!.start + t(v.translation.width)))
            m.editMask(i, live: true) { $0.start = s; $0.end = s + len }
        }.onEnded { _ in maskOrigin = nil; m.editMask(i, live: false) { _ in } })
    }

    private func trimHandle(left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Theme.violet))
            .frame(width: 12, height: 58)
            .overlay(Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: 18))
            .help(left ? "Glisse pour couper le début" : "Glisse pour couper la fin")
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
    }

    @ViewBuilder
    private func zoomBlock(_ i: Int, _ z: ZoomSegment, x: (Double) -> CGFloat, t: @escaping (CGFloat) -> Double) -> some View {
        let selected = m.selectedZoom == i
        let w = max(18, x(z.end) - x(z.start))
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(violet.opacity(selected ? 1 : 0.75))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
            Label(String(format: z.isLoupe ? "Loupe %.1f×" : "%.1f×", z.scale), systemImage: z.isLoupe ? "magnifyingglass.circle" : "plus.magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold)).labelStyle(.titleAndIcon).foregroundColor(.white)
                .opacity(w > 56 ? 1 : 0)
            HStack {
                edge().gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if dragOrigin == nil { dragOrigin = z; m.selectedZoom = i }
                    m.setZoom(i, start: dragOrigin!.start + t(v.translation.width), live: true)
                }.onEnded { _ in dragOrigin = nil; m.setZoom(i, live: false) })
                Spacer()
                edge().gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if dragOrigin == nil { dragOrigin = z; m.selectedZoom = i }
                    m.setZoom(i, end: dragOrigin!.end + t(v.translation.width), live: true)
                }.onEnded { _ in dragOrigin = nil; m.setZoom(i, live: false) })
            }
        }
        .frame(width: w, height: 30)
        .offset(x: x(z.start))
        .help("Glisse pour déplacer, tire les bords pour allonger · clic pour régler le zoom")
        .onTapGesture { m.selectedZoom = i; m.selectedMask = nil; m.seek(source: z.start + 0.6) }
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in
            if dragOrigin == nil { dragOrigin = z; m.selectedZoom = i }
            m.moveZoom(i, by: t(v.translation.width), from: dragOrigin!, live: true)
        }.onEnded { _ in
            if let o = dragOrigin { m.moveZoom(i, by: 0, from: m.zooms[i], live: false); _ = o }
            dragOrigin = nil
        })
    }

    private func edge() -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 9)
            .overlay(Capsule().fill(Color.white.opacity(0.7)).frame(width: 2, height: 12))
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
    }

    private func ticks(_ d: Double) -> [Double] {
        let step: Double = d <= 20 ? 2 : d <= 60 ? 5 : d <= 180 ? 15 : 30
        return stride(from: 0, through: d, by: step).map { $0 }
    }
}

/// ×1 · ×1,25 · ×1,5 · ×2 (virgule à la française)
func speedLabel(_ v: Double) -> String { "×" + String(format: "%g", v).replacingOccurrences(of: ".", with: ",") }
