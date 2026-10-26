import Cocoa
import AVFoundation


/// Bibliothèque : fichiers MP4 du dossier + index .library.json (titres, liens, vues).
final class Library: ObservableObject {
    @Published private(set) var videos: [Video] = []
    @Published var progress: [String: Double] = [:]   // id → 0…1 pendant l'envoi
    @Published var flash: [String: String] = [:]      // id → message bref (« Lien copié »)
    @Published var lastError: String?

    let folder: URL
    private var indexURL: URL { folder.appendingPathComponent(".library.json") }
    let uploader = Uploader()
    private var didFirstRefresh = false

    init(folder: URL) {
        self.folder = folder
        load()
    }

    // MARK: index local

    private func load() {
        var known: [Video] = []
        if let d = try? Data(contentsOf: indexURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            known = (try? dec.decode([Video].self, from: d)) ?? []
        }
        // on garde les vidéos encore présentes, et on ajoute les MP4 inconnus (copiés à la main)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.lowercased().hasSuffix(".mp4") }
        var list = known.filter { files.contains($0.file) }
        for f in files where !list.contains(where: { $0.file == f }) {
            list.append(makeVideo(file: f))
        }
        videos = list.sorted { $0.created > $1.created }
        for v in videos { ensureThumbnail(v) }
        DispatchQueue.main.async { [weak self] in self?.resumePendingUploads() }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? enc.encode(videos).write(to: indexURL, options: .atomic)
    }

    private func makeVideo(file: String) -> Video {
        let url = folder.appendingPathComponent(file)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = attrs?[.creationDate] as? Date ?? Date()
        let duration = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "d MMMM 'à' HH'h'mm"
        return Video(id: Self.newID(), file: file, title: "Vidéo du \(f.string(from: created))", created: created,
                     duration: duration.isFinite ? duration : 0)
    }

    static func newID() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<14).map { _ in chars.randomElement()! })
    }

    func url(of v: Video) -> URL { folder.appendingPathComponent(v.file) }
    func thumbURL(of v: Video) -> URL { folder.appendingPathComponent(".thumbs/\(v.id).jpg") }
    func link(of v: Video) -> URL? { uploader.endpoint.map { URL(string: "\($0)/v/\(v.id)")! } }

    private func update(_ id: String, _ change: (inout Video) -> Void) {
        guard let i = videos.firstIndex(where: { $0.id == id }) else { return }
        change(&videos[i]); save()
    }

    // MARK: dossiers (2026-10-14)

    /// Dossiers vides créés à la main (un dossier utilisé par une vidéo existe de toute façon).
    @Published private(set) var extraFolders: [String] = UserDefaults.standard.stringArray(forKey: "libraryFolders") ?? []
    var folderNames: [String] { LibraryFilter.folders(of: videos, extra: extraFolders) }

    func addFolder(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let same = folderNames.first(where: { LibraryFilter.norm($0) == LibraryFilter.norm(n) }) { return same }
        extraFolders.append(n)
        UserDefaults.standard.set(extraFolders, forKey: "libraryFolders")
        objectWillChange.send()
        return n
    }

    /// Petite fenêtre « Nom du dossier » ; nil si annulé.
    static func askFolderName() -> String? {
        let a = NSAlert()
        a.messageText = "Nouveau dossier"
        a.informativeText = "Donne-lui un nom court (ex. : Prospects, Démos)."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Créer"); a.addButton(withTitle: "Annuler")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = f.stringValue.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    /// nil = sortir du dossier.
    func move(_ v: Video, toFolder f: String?) { update(v.id) { $0.folder = f } }

    // MARK: actions

    /// Nouvelle vidéo enregistrée : on l'ajoute en tête et on l'envoie tout de suite.
    func addRecording(_ url: URL) {
        let v = makeVideo(file: url.lastPathComponent)
        videos.insert(v, at: 0); save()
        ensureThumbnail(v)
        copyLink(v)
    }

    /// Tournage interrompu puis réparé au lancement : remis (ou mis à jour) en tête, sans envoi automatique.
    func addRecovered(_ url: URL) {
        if let i = videos.firstIndex(where: { $0.file == url.lastPathComponent }) {
            let d = CMTimeGetSeconds(AVURLAsset(url: url).duration)
            videos[i].duration = d.isFinite ? d : videos[i].duration
            try? FileManager.default.removeItem(at: thumbURL(of: videos[i]))
            save(); ensureThumbnail(videos[i])
        } else {
            var v = makeVideo(file: url.lastPathComponent)
            v.title = "\(v.title) (récupérée)"
            videos.insert(v, at: 0); save()
            ensureThumbnail(v)
        }
    }

    /// Importe des vidéos existantes (MP4 ou MOV) : copiées dans le dossier en MP4, avec leur miniature.
    func importFiles(_ urls: [URL]) {
        for src in urls {
            Task { @MainActor in
                do {
                    let dst = try await MovieTools.importVideo(src, into: folder)
                    var v = makeVideo(file: dst.lastPathComponent)
                    v.title = src.deletingPathExtension().lastPathComponent
                    v.created = Date()
                    videos.insert(v, at: 0); save()
                    ensureThumbnail(v)
                    say(v, "Vidéo importée ✓")
                } catch {
                    lastError = "Import impossible de « \(src.lastPathComponent) » : \(error.localizedDescription)"
                }
            }
        }
    }

    /// Plusieurs vidéos mises bout à bout en une seule (repères des jonctions gardés pour la frise).
    func importAssembled(_ urls: [URL]) {
        Task { @MainActor in
            do {
                let name = urls[0].deletingPathExtension().lastPathComponent
                let dst = MovieTools.uniqueURL(in: folder, base: "\(name) (assemblée)")
                let durs = try await Assemble.concat(urls, to: dst)
                var at = 0.0
                let parts = zip(urls, durs).map { u, d -> Assemble.Part in defer { at += d }; return Assemble.Part(name: u.deletingPathExtension().lastPathComponent, start: at) }
                try? FileManager.default.createDirectory(at: Assemble.partsURL(dst).deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(parts).write(to: Assemble.partsURL(dst))
                var v = makeVideo(file: dst.lastPathComponent)
                v.title = dst.deletingPathExtension().lastPathComponent
                v.created = Date()
                videos.insert(v, at: 0); save()
                ensureThumbnail(v)
                say(v, "\(urls.count) vidéos assemblées ✓")
            } catch {
                lastError = "Assemblage impossible : \(error.localizedDescription)"
            }
        }
    }

    /// Loom personnalisé créé à partir d'un modèle : ajouté en tête, déjà marqué « pour Prénom · Agence ».
    func addPersonalized(file: String, from template: Video, firstName: String, company: String, recordId: String? = nil) {
        var v = makeVideo(file: file)
        v.title = company.isEmpty ? firstName : "\(firstName) — \(company)"
        v.firstName = firstName.isEmpty ? nil : firstName
        v.company = company.isEmpty ? nil : company
        v.duration = template.duration
        v.recordId = recordId
        videos.insert(v, at: 0); save()
        ensureThumbnail(v)
    }

    func rename(_ v: Video, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != v.title else { return }
        update(v.id) { $0.title = t }
        if v.uploaded, let nv = videos.first(where: { $0.id == v.id }) {
            Task { try? await uploader.putMeta(nv) }
        }
    }

    /// Copie le lien (envoie la vidéo d'abord si besoin). Collé dans Gmail : miniature cliquable ; ailleurs : le lien.
    /// Pour qui est la vidéo : mis à jour en ligne tout de suite (pas besoin de renvoyer la vidéo).
    func setProspect(_ v: Video, firstName: String, company: String) {
        let f = firstName.trimmingCharacters(in: .whitespaces), c = company.trimmingCharacters(in: .whitespaces)
        update(v.id) { $0.firstName = f.isEmpty ? nil : f; $0.company = c.isEmpty ? nil : c }
        if let nv = videos.first(where: { $0.id == v.id }), nv.uploaded { Task { try? await uploader.putMeta(nv) } }
    }

    /// Relie la vidéo à une fiche du CRM (prénom et agence repris de la fiche si vides).
    func link(_ v: Video, to p: Prospect?) {
        update(v.id) {
            $0.recordId = p?.id
            if let p = p {
                if ($0.firstName ?? "").isEmpty { $0.firstName = p.firstName }
                if ($0.company ?? "").isEmpty, !p.company.isEmpty { $0.company = p.company }
            }
        }
        if let nv = videos.first(where: { $0.id == v.id }), nv.uploaded { Task { try? await uploader.putMeta(nv) } }
    }

    func markEdited(_ v: Video) { update(v.id) { $0.edited = true } }

    /// Fichier remplacé (vidéos ajoutées à la suite, ou retirées) : nouvelle durée, nouvelle miniature, à renvoyer.
    func sourceChanged(_ v: Video) {
        let d = CMTimeGetSeconds(AVURLAsset(url: url(of: v)).duration)
        update(v.id) { $0.duration = d.isFinite ? d : $0.duration; $0.edited = true }
        try? FileManager.default.removeItem(at: thumbURL(of: v))
        if let nv = videos.first(where: { $0.id == v.id }) { ensureThumbnail(nv) }
    }

    func needsUpload(_ id: String) -> Bool {
        guard let v = videos.first(where: { $0.id == id }) else { return true }
        return !v.uploaded || v.edited == true
    }

    /// Le lien est copié au clic, même si la vidéo n'est pas encore en ligne : la page affiche « Ta vidéo arrive… »
    /// et lance la vidéo dès qu'elle est envoyée (2026-10-14 : avant, il fallait attendre tout le montage et tout l'envoi).
    func copyLink(_ v0: Video) {
        if videos.first(where: { $0.id == v0.id })?.sentAt == nil { update(v0.id) { $0.sentAt = Date() } }   // 1re copie = envoyée
        let v = videos.first(where: { $0.id == v0.id }) ?? v0
        uploader.reload()   // la config a pu être créée après le lancement de l'app
        guard uploader.isConfigured else {
            lastError = "L'hébergement des vidéos n'est pas encore en ligne (lance server/deploy.sh)."
            return
        }
        putLinkOnPasteboard(v)
        NSSound(named: "Glass")?.play()
        if needsUpload(v.id) {
            say(v, "Lien copié ✓  colle-le, la vidéo arrive en ligne")
            startUpload(v)
        } else {
            say(v, "Lien copié ✓")
            Task { try? await uploader.putMeta(v) }   // titre de la page en ligne à jour
        }
    }

    /// Envoi en arrière-plan. Une modification faite pendant l'envoi relance un envoi à la fin ; une coupure réessaie.
    func startUpload(_ v0: Video, attempt: Int = 0) {
        guard progress[v0.id] == nil, uploader.isConfigured else { return }
        progress[v0.id] = 0
        update(v0.id) { $0.pending = true; $0.edited = false }
        let v = videos.first(where: { $0.id == v0.id }) ?? v0
        Task { @MainActor in
            do {
                let smart = try await uploader.upload(v, file: url(of: v), thumb: thumbURL(of: v)) { [weak self] p in
                    DispatchQueue.main.async { if self?.progress[v.id] != nil { self?.progress[v.id] = p } }
                }
                progress[v.id] = nil
                update(v.id) { $0.uploaded = true; $0.pending = nil }
                // titre automatique (comme Loom AI) seulement si personne ne l'a choisi et que la vidéo n'est pas pour un prospect
                if let t = smart?.title, !t.isEmpty, let cur = videos.first(where: { $0.id == v.id }), Self.isAutoTitle(cur.title), cur.firstName == nil {
                    rename(cur, to: t)
                }
                if videos.first(where: { $0.id == v.id })?.edited == true { startUpload(v); return }   // retouchée pendant l'envoi
                say(v, "Vidéo en ligne ✓")
            } catch {
                progress[v.id] = nil
                update(v.id) { $0.edited = true }
                if attempt < 4 {
                    say(v, "Connexion coupée, nouvel essai…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(10 * (attempt + 1))) { [weak self] in
                        guard let self = self, let nv = self.videos.first(where: { $0.id == v.id }) else { return }
                        self.startUpload(nv, attempt: attempt + 1)
                    }
                } else {
                    lastError = "Envoi impossible : \(error.localizedDescription). Il reprendra au prochain lancement."
                }
            }
        }
    }

    /// Titre donné par l'app (« Vidéo du 14 octobre à 09h12 », « … (récupérée) »), donc remplaçable par le titre automatique.
    static func isAutoTitle(_ t: String) -> Bool { t.hasPrefix("Vidéo du ") || t.hasPrefix("X-Videos 20") }

    /// E-mail demandé avant de regarder : appliqué en ligne tout de suite si la vidéo y est déjà.
    func setRequireEmail(_ v: Video, _ on: Bool) {
        update(v.id) { $0.requireEmail = on ? true : nil }
        guard v.uploaded || v.pending == true else { return }
        Task { @MainActor in
            do { try await uploader.setAccess(v.id, requireEmail: on); say(v, on ? "E-mail demandé avant la vidéo ✓" : "Vidéo en accès libre ✓") }
            catch { lastError = "Réglage impossible : \(error.localizedDescription)" }
        }
    }

    /// Mot de passe du lien (vide = retiré). Envoyé une fois, jamais gardé sur le Mac.
    func setPassword(_ v: Video, _ pw: String) {
        let p = pw.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            do {
                if !(v.uploaded || v.pending == true) { try await uploader.putMeta(v) }   // la page doit exister
                try await uploader.setAccess(v.id, password: p)
                update(v.id) { $0.locked = p.isEmpty ? nil : true }
                say(v, p.isEmpty ? "Mot de passe retiré ✓" : "Lien protégé par mot de passe ✓")
            } catch { lastError = "Réglage impossible : \(error.localizedDescription)" }
        }
    }

    /// Miniature choisie à la main (seconde du fichier source) : locale tout de suite, en ligne au prochain envoi.
    func setThumbTime(_ v: Video, _ t: Double) {
        update(v.id) { $0.thumbTime = t; $0.edited = true }
        try? FileManager.default.removeItem(at: thumbURL(of: v))
        if let nv = videos.first(where: { $0.id == v.id }) { ensureThumbnail(nv) }
        say(v, "Miniature choisie ✓")
    }

    /// Au lancement : reprend les envois interrompus (app quittée, Mac éteint, réseau coupé).
    func resumePendingUploads() {
        uploader.reload()
        for v in videos where v.pending == true { startUpload(v) }
    }

    /// Montage fermé : une vidéo déjà partagée est renvoyée tout de suite, pour que son lien montre la dernière version.
    func syncAfterEditing(_ id: String) {
        guard let v = videos.first(where: { $0.id == id }), v.uploaded || v.sentAt != nil, needsUpload(id) else { return }
        startUpload(v)
    }

    /// Copie le fichier monté (zooms, fond, caméra) : à coller en pièce jointe.
    func copyFile(_ v: Video) {
        let out = folder.appendingPathComponent(".meta/\(v.id).final.mp4")
        say(v, "Montage du fichier…")
        Task { @MainActor in
            do {
                try await Renderer.export(video: url(of: v), settings: EditSettings.load(for: url(of: v)), to: out) { _ in }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([out as NSURL])
                say(v, "Vidéo copiée ✓")
            } catch { lastError = "Montage impossible : \(error.localizedDescription)" }
        }
    }

    /// Ouvre l'éditeur (aperçu exact de ce que verra le prospect).
    func play(_ v: Video) { EditorWindow.show(v, library: self) }

    func reveal(_ v: Video) { NSWorkspace.shared.activateFileViewerSelecting([url(of: v)]) }

    func openPage(_ v: Video) { if let l = uploader.ownerLink(v.id) ?? link(of: v) { NSWorkspace.shared.open(l) } }   // ta vue ne compte pas

    func delete(_ v: Video) {
        let a = NSAlert()
        a.messageText = "Supprimer « \(v.title) » ?"
        a.informativeText = v.uploaded ? "Le fichier va à la corbeille et le lien cessera de marcher." : "Le fichier va à la corbeille."
        a.addButton(withTitle: "Supprimer")
        a.addButton(withTitle: "Annuler")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([url(of: v)])
        try? FileManager.default.removeItem(at: thumbURL(of: v))
        if v.uploaded { Task { try? await uploader.delete(v.id) } }
        videos.removeAll { $0.id == v.id }; save()
    }

    /// Met à jour le nombre de vues depuis le serveur.
    func refreshViews() {
        guard uploader.isConfigured else { return }
        Task { @MainActor in
            guard let remote = try? await uploader.list() else { return }
            for r in remote {
                if let i = videos.firstIndex(where: { $0.id == r.id }) {
                    let before = videos[i].views
                    videos[i].views = r.views
                    videos[i].lastView = r.lastView
                    videos[i].plays = r.plays
                    videos[i].pct = r.pct
                    if (r.ctaClicks ?? 0) > (videos[i].ctaClicks ?? 0) {
                        Notifier.send("\(videos[i].firstName ?? "Un prospect") a cliqué « Réserver 15 min »", videos[i].title)
                    } else if r.views > before && before >= 0 && didFirstRefresh {
                        Notifier.send("\(videos[i].firstName ?? "Quelqu'un") regarde ta vidéo 👀", videos[i].company ?? videos[i].title)
                    }
                    videos[i].ctaClicks = r.ctaClicks
                    // commentaires, réactions, e-mails laissés : alerte seulement pour ce qui est nouveau
                    let who = videos[i].firstName ?? "Quelqu'un"
                    if didFirstRefresh {
                        if (r.comments ?? 0) > (videos[i].comments ?? 0) { Notifier.send("\(who) a commenté ta vidéo 💬", videos[i].title) }
                        if (r.reactions ?? 0) > (videos[i].reactions ?? 0) { Notifier.send("\(who) a réagi à ta vidéo", videos[i].title) }
                        for e in (r.emails ?? []).map(\.email) where !(videos[i].emails ?? []).contains(e) {
                            Notifier.send("\(e) a ouvert ta vidéo", videos[i].title)
                        }
                    }
                    videos[i].comments = r.comments
                    videos[i].reactions = r.reactions
                    videos[i].emails = r.emails.map { $0.map(\.email) }
                }
            }
            didFirstRefresh = true
            save()
        }
    }

    private func putLinkOnPasteboard(_ v: Video) {
        guard let bare = link(of: v), let base = uploader.endpoint else { return }
        let slug = ShareTitle.slug(firstName: v.firstName, company: v.company)
        let link = slug.isEmpty ? bare : bare.appendingPathComponent(slug)
        let thumb = "\(base)/t/\(v.id).gif"
        let title = ShareTitle.make(title: v.title, firstName: v.firstName, company: v.company).replacingOccurrences(of: "<", with: "&lt;")
        let html = "<a href=\"\(link)\"><img src=\"\(thumb)\" width=\"480\" alt=\"\(title)\" style=\"border-radius:10px\"></a><br><a href=\"\(link)\">▶ \(title) (\(Self.fmt(v.duration)))</a>"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.html, .string], owner: nil)
        pb.setString(html, forType: .html)
        pb.setString(link.absoluteString, forType: .string)
    }

    private func say(_ v: Video, _ text: String) {
        flash[v.id] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.flash[v.id] == text { self?.flash[v.id] = nil }
        }
    }

    static func fmt(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: miniatures

    private func ensureThumbnail(_ v: Video) {
        let out = thumbURL(of: v)
        guard !FileManager.default.fileExists(atPath: out.path) else { return }
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url(of: v)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 800)
        let t = CMTime(seconds: v.thumbTime ?? min(1, max(0, v.duration / 2)), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        gen.generateCGImageAsynchronously(for: t) { [weak self] cg, _, _ in
            guard let cg = cg, let data = Thumbs.jpeg(cg) else { return }
            try? data.write(to: out)
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }
}

enum Thumbs {
    static func jpeg(_ cg: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    /// Miniature 1280×720 avec un bouton lecture violet : c'est l'image des aperçus LinkedIn / Gmail.
    static func withPlayButton(_ src: NSImage, width W: Int = 1280, height H: Int = 720, jpeg: Bool = true) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let canvas = NSRect(x: 0, y: 0, width: W, height: H)
        Theme.black.setFill(); canvas.fill()
        // image recadrée pour remplir le 16:9
        let s = src.size
        let k = max(CGFloat(W) / s.width, CGFloat(H) / s.height)
        let dw = s.width * k, dh = s.height * k
        src.draw(in: NSRect(x: (CGFloat(W) - dw) / 2, y: (CGFloat(H) - dh) / 2, width: dw, height: dh))
        let d: CGFloat = CGFloat(H) * 0.21
        let c = NSRect(x: CGFloat(W) / 2 - d / 2, y: CGFloat(H) / 2 - d / 2, width: d, height: d)
        Theme.violet.setFill(); NSBezierPath(ovalIn: c).fill()
        let tri = NSBezierPath()
        let u = d / 150
        tri.move(to: NSPoint(x: c.midX - 22 * u, y: c.midY - 34 * u))
        tri.line(to: NSPoint(x: c.midX - 22 * u, y: c.midY + 34 * u))
        tri.line(to: NSPoint(x: c.midX + 38 * u, y: c.midY))
        tri.close()
        NSColor.white.setFill(); tri.fill()
        NSGraphicsContext.restoreGraphicsState()
        return jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) : rep.tiffRepresentation
    }

    /// GIF animé de 3 s (480 px, 10 images/s, bouton lecture) : la miniature qui fait le plus cliquer dans un e-mail.
    static func gif(from video: URL, start: Double) async -> Data? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 270)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 30, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        var n = 0
        for i in 0..<30 {
            guard let cg = try? await gen.image(at: CMTime(seconds: start + Double(i) * 0.1, preferredTimescale: 600)).image,
                  let tiff = withPlayButton(NSImage(cgImage: cg, size: .zero), width: 480, height: 270, jpeg: false),
                  let rep = NSBitmapImageRep(data: tiff), let out = rep.cgImage else { continue }
            CGImageDestinationAddImage(dest, out, frame)
            n += 1
        }
        guard n > 0, CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
