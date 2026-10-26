import Foundation

/// Looms personnalisés : on garde toute la vraie vidéo, et seule la phrase d'ouverture
/// (« Salut Julie, j'espère que tu as la forme… ») est redite avec ta voix copiée par VoiceStudio (local, gratuit).
/// La phrase générée finit pile là où la vraie voix reprend : même durée, la caméra, le curseur et les zooms restent calés.
enum Personalize {
    static let voiceStudio = URL(string: "http://localhost:3900")!
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Réglages d'une vidéo modèle, gardés dans .meta/<vidéo>.perso.json.
    struct Template: Codable, Equatable {
        var cut: Double            // la vraie voix reprend ici (milieu d'une pause)
        var said: String           // ce que tu dis avant la coupe (transcrit), sert de modèle de voix
        var opening: String        // phrase à générer ; {prénom} et {agence} sont remplacés
    }

    static func templateURL(_ video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).perso.json")
    }
    static func loadTemplate(_ video: URL) -> Template? {
        (try? Data(contentsOf: templateURL(video))).flatMap { try? JSONDecoder().decode(Template.self, from: $0) }
    }
    static func saveTemplate(_ t: Template, for video: URL) {
        try? JSONEncoder().encode(t).write(to: templateURL(video), options: .atomic)
    }

    // MARK: logique pure (testée dans tests/personalize-test.swift)

    static func fill(_ opening: String, firstName: String, company: String) -> String {
        opening.replacingOccurrences(of: "{prénom}", with: firstName)
            .replacingOccurrences(of: "{prenom}", with: firstName)
            .replacingOccurrences(of: "{agence}", with: company)
    }

    /// Où couper : la première pause (≥ 0,15 s) entre 2,5 et 8 s — le moins de voix générée possible. `levels` = niveau en dB toutes les `step` secondes.
    /// Seuil relatif comme Silence : bruit de fond + 30 % de l'écart avec la voix.
    static func pickCut(levels: [Double], step: Double) -> Double? {
        guard levels.count > 10 else { return nil }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10], voice = sorted[sorted.count * 9 / 10]
        let threshold = floor + (voice - floor) * 0.3
        var best: (a: Int, b: Int)?
        var start: Int?
        for i in 0...levels.count {
            let quiet = i < levels.count && levels[i] < threshold
            if quiet { if start == nil { start = i } }
            else if let s = start {
                let a = Double(s) * step, b = Double(i) * step
                if b - a >= 0.15, (a + b) / 2 >= 2.5, (a + b) / 2 <= 8 { best = (s, i); break }
                start = nil
            }
        }
        return best.map { Double($0.a + $0.b) / 2 * step }
    }

    /// Phrase de départ proposée : ce que tu as dit, en remplaçant le mot qui suit « Salut / Hello / Coucou » par {prénom}.
    static func suggestOpening(from said: String) -> String {
        let s = said.trimmingCharacters(in: .whitespaces)
        for hi in ["Salut", "Hello", "Coucou", "Bonjour", "Hey"] {
            if let r = s.range(of: "\(hi) ", options: .caseInsensitive) {
                let rest = s[r.upperBound...]
                let name = rest.prefix { $0.isLetter || $0 == "-" }
                if !name.isEmpty { return s.replacingCharacters(in: r.upperBound..<rest.index(rest.startIndex, offsetBy: name.count), with: "{prénom}") }
            }
        }
        // pas de salutation reconnue : on remplace la première phrase (souvent « Qu'est-ce qu'il dit Zizou ? »)
        if let end = s.firstIndex(where: { "?!.".contains($0) }), s.distance(from: s.startIndex, to: end) < 60 {
            let rest = s[s.index(after: end)...].trimmingCharacters(in: .whitespaces)
            return "Salut {prénom} ! " + rest
        }
        return "Salut {prénom} ! " + s
    }

    // MARK: étapes

    /// Prépare le modèle d'une vidéo (une seule fois) : point de coupe + transcription de l'ouverture.
    static func prepare(_ video: URL) async throws -> Template {
        if let t = loadTemplate(video) { return t }
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let levels = try await audioLevels(video, seconds: 10, step: 0.05)
        guard let cut = pickCut(levels: levels, step: 0.05) else { throw err("Pas de pause nette dans les 8 premières secondes : impossible de placer le prénom.") }
        let wav = tmp.appendingPathComponent("ref.wav")
        try await run(ffmpeg, ["-y", "-i", video.path, "-t", String(cut), "-vn", "-ac", "1", "-ar", "16000", wav.path])
        let said = try await whisper(wav)
        let t = Template(cut: cut, said: said, opening: suggestOpening(from: said))
        saveTemplate(t, for: video)
        return t
    }

    /// Crée la vidéo personnalisée à côté du modèle. Renvoie le nom du nouveau fichier.
    static func make(from video: URL, template t: Template, firstName: String, company: String,
                     status: @escaping (String) -> Void) async throws -> String {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        status("Ta voix se prépare…")
        try await ensureVoiceStudio()
        let ref = tmp.appendingPathComponent("ref.wav")
        try await run(ffmpeg, ["-y", "-i", video.path, "-t", String(t.cut), "-vn", "-ac", "1", "-ar", "24000",
                               "-af", "highpass=f=80,loudnorm=I=-18:TP=-2", ref.path])
        let text = fill(t.opening, firstName: firstName, company: company)
        status("« \(text) »")
        var head = tmp.appendingPathComponent("head.wav")
        for speed in ["1.0", "1.12", "1.25"] {
            try await generate(text: text, ref: ref, refText: t.said, speed: speed, to: tmp.appendingPathComponent("raw.wav"))
            head = tmp.appendingPathComponent("head-\(speed).wav")
            let trim = "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05"
            try await run(ffmpeg, ["-y", "-i", tmp.appendingPathComponent("raw.wav").path, "-af", "\(trim),areverse,\(trim),areverse", head.path])
            if try await duration(head) <= t.cut - 0.05 { break }
        }
        let headDur = try await duration(head)
        guard headDur <= t.cut - 0.05 else { throw err("La phrase est trop longue pour l'ouverture de cette vidéo (\(String(format: "%.1f", headDur)) s pour \(String(format: "%.1f", t.cut)) s) : raccourcis-la.") }

        status("Montage…")
        // même volume que la vraie voix qui suit
        let real = try await loudness(video, from: t.cut, length: 25)
        let gen = try await loudness(head, from: 0, length: 30)
        let gain = (real.isFinite && gen.isFinite) ? real - gen : 0
        let pad = Int(((t.cut + 0.06) - headDur) * 1000)
        let out = uniqueName(for: video, firstName: firstName)
        let dst = video.deletingLastPathComponent().appendingPathComponent(out)
        let graph = "[0]volume=\(gain)dB,aresample=48000,pan=stereo|c0=c0|c1=c0,adelay=\(pad)|\(pad),apad[h];[h]atrim=0:\(t.cut + 0.06)[h2];"
            + "[1:a]atrim=start=\(t.cut),asetpts=PTS-STARTPTS[r];[h2][r]acrossfade=d=0.06[a]"
        try await run(ffmpeg, ["-y", "-i", head.path, "-i", video.path, "-filter_complex", graph,
                               "-map", "1:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k", dst.path])

        // caméra, curseur et montage repris tels quels (même durée) ; silences et sous-titres se recalculent
        let meta = video.deletingLastPathComponent().appendingPathComponent(".meta")
        for ext in ["camera.mov", "rec.json", "cursor.json", "cursors", "edit.json"] {
            let a = meta.appendingPathComponent("\(video.lastPathComponent).\(ext)")
            let b = meta.appendingPathComponent("\(out).\(ext)")
            if FileManager.default.fileExists(atPath: a.path) { try? FileManager.default.removeItem(at: b); try FileManager.default.copyItem(at: a, to: b) }
        }
        if var rec = RecordingInfo.load(for: video), let cam = rec.cameraFile, !cam.isEmpty {
            rec.cameraFile = "\(out).camera.mov"; rec.save(for: dst)
        }
        return out
    }

    // MARK: outils

    static func uniqueName(for video: URL, firstName: String) -> String {
        let base = video.deletingPathExtension().lastPathComponent
        let clean = firstName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " }.trimmingCharacters(in: .whitespaces)
        var name = "\(base) \(clean.isEmpty ? "perso" : clean).mp4", n = 2
        while FileManager.default.fileExists(atPath: video.deletingLastPathComponent().appendingPathComponent(name).path) {
            name = "\(base) \(clean) \(n).mp4"; n += 1
        }
        return name
    }

    static func ensureVoiceStudio() async throws {
        if await healthy() { return }
        _ = try? await run("/usr/bin/open", ["-a", "VoiceStudio"])
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if await healthy() { return }
        }
        throw err("VoiceStudio ne répond pas (localhost:3900). Ouvre l'app VoiceStudio puis réessaie.")
    }

    private static func healthy() async -> Bool {
        var r = URLRequest(url: voiceStudio.appendingPathComponent("health")); r.timeoutInterval = 2
        return ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    private static func generate(text: String, ref: URL, refText: String, speed: String, to dst: URL) async throws {
        let boundary = "xv-\(UUID().uuidString)"
        var body = Data()
        func field(_ k: String, _ v: String) { body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
        for (k, v) in [("text", text), ("language", "French"), ("ref_text", refText), ("num_step", "32"), ("seed", "3"), ("speed", speed)] { field(k, v) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"ref_audio\"; filename=\"ref.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: ref))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var r = URLRequest(url: voiceStudio.appendingPathComponent("generate"))
        r.httpMethod = "POST"; r.timeoutInterval = 300
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: r, from: body)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.prefix(4) == Data("RIFF".utf8) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw err("VoiceStudio : \(msg ?? "génération impossible")")
        }
        try data.write(to: dst)
    }

    /// Niveau sonore (dB) par tranche de `step` secondes, sur les `seconds` premières secondes.
    static func audioLevels(_ video: URL, seconds: Double, step: Double) async throws -> [Double] {
        let rate = 16000, n = Int(Double(rate) * step)
        let raw = try await run(ffmpeg, ["-i", video.path, "-t", String(seconds), "-vn", "-ac", "1", "-ar", String(rate), "-f", "s16le", "-"])
        let samples: [Int16] = raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return stride(from: 0, to: samples.count - n, by: n).map { i in
            let ms = samples[i..<i + n].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(n)
            return 10 * log10(max(ms / (32768.0 * 32768.0), 1e-10))
        }
    }

    private static func loudness(_ file: URL, from: Double, length: Double) async throws -> Double {
        let out = try await run(ffmpeg, ["-ss", String(from), "-t", String(length), "-i", file.path, "-af", "loudnorm=print_format=json", "-f", "null", "-"], stderr: true)
        let s = String(decoding: out, as: UTF8.self)
        guard let r = s.range(of: "\"input_i\" : \""), let end = s[r.upperBound...].firstIndex(of: "\"") else { return .nan }
        return Double(s[r.upperBound..<end]) ?? .nan
    }

    private static func duration(_ file: URL) async throws -> Double {
        let out = try await run(ffmpeg, ["-i", file.path, "-f", "null", "-"], stderr: true)
        let s = String(decoding: out, as: UTF8.self)
        guard let r = s.range(of: "time=", options: .backwards) else { return 0 }
        let p = s[r.upperBound...].prefix(11).split(separator: ":").compactMap { Double($0) }
        return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : 0
    }

    private static func whisper(_ wav: URL) async throws -> String {
        guard let bin = Captions.whisperBinary, let model = Captions.model else { throw err("Whisper introuvable") }
        let out = try await run(bin, ["-m", model, "-f", wav.path, "-l", "fr", "-nt", "-np"])
        return String(decoding: out, as: UTF8.self).split(separator: "\n").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    static func run(_ bin: String?, _ args: [String], stderr: Bool = false) async throws -> Data {
        guard let bin = bin else { throw err("ffmpeg introuvable (brew install ffmpeg)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = bin.hasSuffix("ffmpeg") ? ["-hide_banner", "-nostdin"] + args : args
        let pipe = Pipe()
        if stderr { p.standardError = pipe; p.standardOutput = FileHandle.nullDevice }
        else { p.standardOutput = pipe; p.standardError = FileHandle.nullDevice }
        try p.run()
        let data = await withCheckedContinuation { (c: CheckedContinuation<Data, Never>) in
            DispatchQueue.global().async { let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); c.resume(returning: d) }
        }
        if p.terminationStatus != 0 && !stderr { throw err("\((bin as NSString).lastPathComponent) a échoué") }
        return data
    }

    private static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("xv-perso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func err(_ m: String) -> NSError { NSError(domain: "X-Videos", code: 10, userInfo: [NSLocalizedDescriptionKey: m]) }
}
