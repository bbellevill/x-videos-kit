import CryptoKit
import Cocoa
import AVFoundation

/// Envoi vers l'hébergement X-Videos (Cloudflare, adresse dans ~/.config/x-videos/config.json).
/// La vidéo est d'abord réduite en 1080p « prête pour le web » (lecture immédiate), puis envoyée par morceaux de 10 Mo.
final class Uploader {
    struct Lead: Decodable, Equatable { let email: String; let at: String?; let lieu: String? }
    struct Remote: Decodable {
        let id: String; let views: Int; let lastView: Date?; let plays: Int?; let pct: Int?; let ctaClicks: Int?
        let reactions: Int?; let comments: Int?; let emails: [Lead]?
    }

    private(set) var endpoint: String?
    private var token: String?
    var isConfigured: Bool { endpoint != nil && token != nil }
    /// Lien qui ouvre une vidéo en marquant cet appareil comme celui du propriétaire : ses vues ne comptent pas (2026-10-13).
    func ownerLink(_ id: String) -> URL? {
        guard let e = endpoint, let t = token else { return nil }
        let cle = SHA256.hash(data: Data("\(t):moi".utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return URL(string: "\(e)/moi/\(cle)?v=\(id)")
    }

    init() { reload() }

    /// Config : ~/.config/x-videos/config.json, créé par server/deploy.sh ({"endpoint": "...", "token": "..."}).
    func reload() {
        // X_VIDEOS_CONFIG : autre fichier de config (tests contre un serveur local)
        let u = ProcessInfo.processInfo.environment["X_VIDEOS_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/x-videos/config.json")
        guard let d = try? Data(contentsOf: u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return }
        endpoint = o["endpoint"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        token = o["token"]
    }

    /// Envoi complet, pensé pour que le lien marche dès le clic (2026-10-14, « les liens se copient en 3 heures ») :
    /// 1. méta + miniature + GIF tirés du fichier brut (1 à 2 s) : la page et l'aperçu Gmail existent tout de suite ;
    /// 2. montage 1080p ; 3. vidéo envoyée par morceaux, 3 à la fois, chaque morceau réessayé ; 4. aperçus du montage et transcription.
    /// La page affiche « Ta vidéo arrive… » jusqu'à la fin, puis lance la vidéo sans recharger.
    @discardableResult
    func upload(_ v: Video, file: URL, thumb: URL, progress: @escaping (Double) -> Void) async throws -> Smart.Result? {
        reload()
        try await putMeta(v)
        try await sendPreviews(v, from: file, at: v.thumbTime, localThumb: thumb)
        progress(0.04)

        // montage complet (zooms, fond, caméra) rendu en 1080p
        let web = FileManager.default.temporaryDirectory.appendingPathComponent("\(v.id)-\(UUID().uuidString.prefix(6)).mp4")
        try? FileManager.default.removeItem(at: web)
        let built = try await Renderer.export(video: file, settings: EditSettings.load(for: file), to: web) { p in progress(0.04 + p * 0.3) }
        defer { try? FileManager.default.removeItem(at: web) }

        // aperçus du montage (fond, bulle) et titre / résumé / chapitres pendant que la vidéo part
        async let finalPreviews: Void = sendPreviews(v, from: web, at: v.thumbTime.map { built.compTime($0) }, localThumb: nil)
        async let smart = Smart.analyze(video: file, words: Captions.cached(for: file) ?? [], duration: v.duration)
        try await sendVideo(v, web) { p in progress(0.34 + 0.64 * p) }
        try? await finalPreviews
        if let srt = Self.srt(for: file, built: built) { try? await send("PUT", "srt/\(v.id)", body: Data(srt.utf8)) }
        var result = await smart
        if var r = result {
            // chapitres recalés sur le montage (coupes, silences, accélérations) ; ceux coupés disparaissent
            r.chapters = r.chapters.filter { $0.t == 0 || Renderer.isKept($0.t, built.segments) }.map { Smart.Chapter(t: $0.t == 0 ? 0 : built.compTime($0.t), title: $0.title) }
            if r.chapters.count < 2 { r.chapters = [] }
            result = r
            let body: [String: Any] = ["summary": r.summary, "chapters": r.chapters.map { ["t": ($0.t * 10).rounded() / 10, "title": $0.title] }]
            try? await send("PUT", "meta/\(v.id)", body: try JSONSerialization.data(withJSONObject: body))
        }
        progress(1)
        return result
    }

    /// Réglages de la page : e-mail demandé avant de regarder, mot de passe (texte clair envoyé une fois, haché par le serveur ; vide = retiré).
    func setAccess(_ id: String, requireEmail: Bool? = nil, password: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let r = requireEmail { body["requireEmail"] = r }
        if let p = password { body["password"] = p }
        try await send("PUT", "meta/\(id)", body: try JSONSerialization.data(withJSONObject: body))
    }

    /// Miniature, miniature avec bouton lecture et GIF : depuis le fichier brut (immédiat) ou depuis le montage (définitif).
    private func sendPreviews(_ v: Video, from movie: URL, at time: Double?, localThumb: URL?) async throws {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 720)
        let at = CMTime(seconds: time ?? min(1.5, max(0, v.duration / 3)), preferredTimescale: 600)
        let cg = try? await gen.image(at: at).image
        let img = cg.map { NSImage(cgImage: $0, size: .zero) } ?? localThumb.flatMap { NSImage(contentsOf: $0) }
        guard let img = img else { return }
        if let d = cg.flatMap(Thumbs.jpeg) ?? localThumb.flatMap({ try? Data(contentsOf: $0) }) { try await send("PUT", "thumb/\(v.id)", body: d) }
        if let play = Thumbs.withPlayButton(img) { try await send("PUT", "thumb/\(v.id)?play=1", body: play) }
        if let gif = await Thumbs.gif(from: movie, start: time ?? min(1, max(0, v.duration / 4))) {
            try await send("PUT", "thumb/\(v.id)?gif=1", body: gif)
        }
    }

    /// Vidéo par morceaux de 10 Mo, 3 envois en parallèle (le débit d'un seul envoi plafonne), chaque morceau réessayé 3 fois.
    private func sendVideo(_ v: Video, _ web: URL, progress: @escaping (Double) -> Void) async throws {
        let created = try await send("POST", "create/\(v.id)")
        guard let uploadId = (try JSONSerialization.jsonObject(with: created) as? [String: Any])?["uploadId"] as? String else {
            throw err("réponse inattendue du serveur")
        }
        let q = uploadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadId
        let size = (try FileManager.default.attributesOfItem(atPath: web.path)[.size] as? Int) ?? 0
        let chunk = 10 * 1024 * 1024
        let count = max(1, (size + chunk - 1) / chunk)
        var parts = [[String: Any]](repeating: [:], count: count)
        var sent = 0
        try await withThrowingTaskGroup(of: (Int, [String: Any], Int).self) { group in
            var next = 0
            func add() {
                let n = next; next += 1
                group.addTask {
                    let h = try FileHandle(forReadingFrom: web)
                    defer { try? h.close() }
                    try h.seek(toOffset: UInt64(n * chunk))
                    let data = try h.read(upToCount: chunk) ?? Data()
                    let r = try await self.retry { try await self.send("PUT", "part/\(v.id)?uploadId=\(q)&n=\(n + 1)", body: data) }
                    guard let part = try JSONSerialization.jsonObject(with: r) as? [String: Any] else { throw self.err("morceau refusé") }
                    return (n, ["partNumber": part["partNumber"] ?? n + 1, "etag": part["etag"] ?? ""], data.count)
                }
            }
            for _ in 0..<min(3, count) { add() }
            while let (n, part, bytes) = try await group.next() {
                parts[n] = part
                sent += bytes
                progress(Double(sent) / Double(max(size, 1)))
                if next < count { add() }
            }
        }
        try await retry { try await self.send("POST", "complete/\(v.id)?uploadId=\(q)", body: try JSONSerialization.data(withJSONObject: ["parts": parts])) }
    }

    private func retry(_ f: () async throws -> Data) async throws -> Data {
        var last: Error?
        for i in 0..<3 {
            do { return try await f() } catch { last = error; try? await Task.sleep(nanoseconds: UInt64(1 + i * 2) * 1_000_000_000) }
        }
        throw last ?? err("envoi impossible")
    }

    /// Transcription calée sur le montage (coupes et accélérations comprises), comme le bouton .srt de l'éditeur.
    static func srt(for file: URL, built b: Renderer.Built) -> String? {
        guard let words = Captions.cached(for: file), !words.isEmpty else { return nil }
        let kept = words.filter { Renderer.isKept(($0.start + $0.end) / 2, b.segments) }
            .map { Captions.Word(text: $0.text, start: b.compTime($0.start), end: b.compTime($0.end)) }
        return kept.isEmpty ? nil : Captions.srt(words: kept)
    }

    func putMeta(_ v: Video) async throws {
        let body: [String: Any] = ["title": ShareTitle.make(title: v.title, firstName: v.firstName, company: v.company), "duration": v.duration, "created": ISO8601DateFormatter().string(from: v.created),
                                   "firstName": v.firstName ?? "", "company": v.company ?? "", "recordId": v.recordId ?? "",
                                   "sentAt": v.sentAt.map { ISO8601DateFormatter().string(from: $0) } ?? "", "requireEmail": v.requireEmail == true]
        try await send("PUT", "meta/\(v.id)", body: try JSONSerialization.data(withJSONObject: body))
    }

    func delete(_ id: String) async throws { try await send("DELETE", "video/\(id)") }

    func list() async throws -> [Remote] {
        let d = try await send("GET", "list")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date()
        }
        return try dec.decode([Remote].self, from: d)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard let endpoint = endpoint, let token = token, let url = URL(string: "\(endpoint)/api/\(path)") else {
            throw err("hébergement non configuré")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let (data, resp) = body != nil
            ? try await URLSession.shared.upload(for: req, from: body!)
            : try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw err("le serveur a répondu \(code) \(String(data: data, encoding: .utf8)?.prefix(120) ?? "")")
        }
        return data
    }

    fileprivate func err(_ m: String) -> NSError { NSError(domain: "X-Videos", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
}
