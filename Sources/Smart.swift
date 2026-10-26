import Foundation
import CryptoKit

/// Titre, résumé et chapitres tirés de la transcription (2026-10-14, parité Loom AI) : Claude Haiku via la CLI `claude`
/// (abonnement déjà en place, ~3 s, presque gratuit). Résultat en cache dans <dossier>/.meta/<vidéo>.smart.json,
/// recalculé seulement si la transcription change. En cas d'échec : rien, la vidéo part quand même.
enum Smart {
    struct Chapter: Codable, Equatable { var t: Double; var title: String }
    struct Result: Codable, Equatable {
        var title: String
        var summary: String
        var chapters: [Chapter]
        var key: String? = nil      // empreinte de la transcription
    }

    static func cacheURL(_ video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).smart.json")
    }

    /// Transcription compacte avec repères [secondes] toutes les ~8 s : ce que lit Haiku.
    static func transcript(_ words: [Captions.Word]) -> String {
        var out = "", last = -9.0
        for w in words {
            if w.start - last >= 8 { out += "\n[\(Int(w.start))] "; last = w.start }
            out += w.text + " "
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lit la réponse de Haiku (JSON éventuellement entouré de texte) et la nettoie : chapitres triés, bornés, 1er à 0.
    static func parse(_ text: String, duration: Double) -> Result? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              var r = try? JSONDecoder().decode(Result.self, from: Data(text[a...b].utf8)) else { return nil }
        r.title = String(r.title.trimmingCharacters(in: CharacterSet(charactersIn: " \"«»\n")).prefix(80))
        r.summary = String(r.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        var seen = Set<Int>()
        r.chapters = r.chapters
            .map { Chapter(t: max(0, min($0.t, max(0, duration - 1))), title: String($0.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))) }
            .filter { !$0.title.isEmpty && seen.insert(Int($0.t)).inserted }
            .sorted { $0.t < $1.t }
        if !r.chapters.isEmpty { r.chapters[0].t = 0 }
        if r.chapters.count < 2 { r.chapters = [] }      // un seul chapitre n'aide personne
        r.chapters = Array(r.chapters.prefix(8))
        return r.title.isEmpty && r.summary.isEmpty ? nil : r
    }

    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Chapitres en temps SOURCE (comme les mots) ; l'envoi les recale sur le montage.
    static func analyze(video: URL, words: [Captions.Word], duration: Double) async -> Result? {
        let text = transcript(words)
        guard text.count > 80, let claude = claudePath() else { return nil }
        let key = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let d = try? Data(contentsOf: cacheURL(video)), let r = try? JSONDecoder().decode(Result.self, from: d), r.key == key { return r }
        let prompt = """
        Voici la transcription d'une courte vidéo de prospection (repères [secondes]). Réponds UNIQUEMENT par un JSON : \
        {"title": titre de 3 à 7 mots en français, sans guillemets ni emoji, "summary": une phrase de 25 mots max qui dit \
        au spectateur ce qu'il va voir, tutoiement, "chapters": 2 à 6 objets {"t": seconde de début tirée des repères, \
        "title": 2 à 5 mots}} ; le 1er chapitre commence à 0.
        """
        let out: String? = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claude)
                p.arguments = ["-p", "--model", "haiku", "--setting-sources", "", "--strict-mcp-config", "--tools", "", "--no-session-persistence", prompt]
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                let inp = Pipe(), outp = Pipe()
                p.standardInput = inp; p.standardOutput = outp; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { c.resume(returning: nil); return }
                inp.fileHandleForWriting.write(Data(text.utf8)); try? inp.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
                let data = outp.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); killer.cancel()
                c.resume(returning: p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
            }
        }
        guard let o = out, var r = parse(o, duration: duration) else { return nil }
        r.key = key
        try? FileManager.default.createDirectory(at: cacheURL(video).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(r).write(to: cacheURL(video))
        return r
    }
}
