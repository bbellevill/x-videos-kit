import AVFoundation
import CoreText
import CoreImage

/// Sous-titres automatiques : la voix est transcrite en local par Whisper (le même moteur et le même modèle que Dictée),
/// mot par mot avec leur instant, puis regroupée en lignes courtes. Résultat mis en cache dans .meta/<vidéo>.captions.json.
enum Captions {
    struct Word: Codable, Equatable { var text: String; var start: Double; var end: Double }
    struct Line { var words: [Word]; var start: Double; var end: Double }

    static func cacheURL(_ video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).captions.json")
    }

    /// Mots déjà transcrits (nil si la transcription n'a pas encore tourné).
    static func cached(for video: URL) -> [Word]? {
        guard let d = try? Data(contentsOf: cacheURL(video)) else { return nil }
        return try? JSONDecoder().decode([Word].self, from: d)
    }

    /// Mots transcrits ; lance Whisper si besoin (une seule fois par vidéo, même si plusieurs écrans le demandent).
    static func words(for video: URL) async -> [Word] {
        if let c = cached(for: video) { return c }
        return await Store.shared.run(video)
    }

    private actor Store {
        static let shared = Store()
        private var tasks: [URL: Task<[Word], Never>] = [:]
        func run(_ video: URL) async -> [Word] {
            if let t = tasks[video] { return await t.value }
            let t = Task.detached(priority: .userInitiated) { () -> [Word] in
                guard let w = try? await Captions.transcribe(video) else { return [] }
                try? FileManager.default.createDirectory(at: cacheURL(video).deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(w).write(to: cacheURL(video))
                return w
            }
            tasks[video] = t
            let r = await t.value
            tasks[video] = nil
            return r
        }
    }

    // MARK: Whisper

    static var whisperBinary: String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var model: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Library/Application Support/Dictee/models/ggml-large-v3-turbo-q5_0.bin",
                "\(home)/.cache/whisper/ggml-large-v3-turbo.bin"].first { FileManager.default.fileExists(atPath: $0) }
    }
    static var available: Bool { whisperBinary != nil && model != nil }

    private static func transcribe(_ video: URL) async throws -> [Word] {
        guard let bin = whisperBinary, let model = model else { throw err("Whisper introuvable") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("a.wav")
        guard try await writeWav(video, to: wav) else { return [] }          // pas de son : pas de sous-titres
        let dict = Vocab.load()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", model, "-f", wav.path, "-l", "fr", "-ojf", "-of", tmp.appendingPathComponent("out").path, "-np"]
            + (dict.words.isEmpty ? [] : ["--prompt", dict.words.joined(separator: ", ")])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        let data = try Data(contentsOf: tmp.appendingPathComponent("out.json"))
        return dict.apply(parse(data))
    }

    /// JSON complet de whisper-cli → mots (un jeton qui commence par une espace ouvre un nouveau mot).
    static func parse(_ data: Data) -> [Word] {
        struct Out: Decodable { let transcription: [Seg] }
        struct Seg: Decodable { let offsets: Off; let tokens: [Tok] }
        struct Tok: Decodable { let text: String; let offsets: Off }
        struct Off: Decodable { let from: Int; let to: Int }
        guard let out = try? JSONDecoder().decode(Out.self, from: data) else { return [] }
        var words: [Word] = []
        for seg in out.transcription {
            var cur: Word?
            for t in seg.tokens where !t.text.hasPrefix("[_") && !t.text.isEmpty {
                let a = Double(t.offsets.from) / 1000, b = Double(t.offsets.to) / 1000
                if t.text.hasPrefix(" ") || cur == nil {
                    if let c = cur { words.append(c) }
                    cur = Word(text: t.text.trimmingCharacters(in: .whitespaces), start: a, end: b)
                } else {
                    cur!.text += t.text; cur!.end = b
                }
            }
            if let c = cur { words.append(c) }
        }
        return words.filter { !$0.text.isEmpty }
    }

    /// Lignes de sous-titres : courtes (≤ 32 caractères), coupées aux pauses et à la ponctuation.
    static func lines(_ words: [Word]) -> [Line] {
        var lines: [Line] = []
        var cur: [Word] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            lines.append(Line(words: cur, start: f.start, end: l.end)); cur = []
        }
        for w in words {
            if let last = cur.last {
                let len = cur.map(\.text.count).reduce(0, +) + cur.count + w.text.count
                if len > 32 || w.start - last.end > 0.7 || ".?!".contains(last.text.last ?? " ") || cur.count >= 7 { flush() }
            }
            cur.append(w)
        }
        flush()
        // la ligne reste un peu affichée après le dernier mot, sans chevaucher la suivante
        for i in lines.indices {
            let next = i + 1 < lines.count ? lines[i + 1].start : .infinity
            lines[i].end = min(lines[i].end + 0.5, next)
        }
        return lines
    }

    /// Fichier de sous-titres .srt (lignes courtes, numérotées, temps hh:mm:ss,mmm).
    static func srt(words: [Word]) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return lines(words).enumerated().map { i, l in
            "\(i + 1)\n\(ts(l.start)) --> \(ts(l.end))\n\(l.words.map(\.text).joined(separator: " "))\n"
        }.joined(separator: "\n")
    }

    /// Mots du dictionnaire de Dictée (aident Whisper) et remplacements (« x tableau » → « XTablo »).
    struct Vocab {
        var words: [String] = []
        var replacements: [String: String] = [:]

        static func load() -> Vocab {
            let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dictee/dictionary.json")
            guard let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return Vocab() }
            return Vocab(words: j["words"] as? [String] ?? [], replacements: j["replacements"] as? [String: String] ?? [:])
        }

        func apply(_ words: [Word]) -> [Word] {
            func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let rules = replacements.map { (k, v) in (k.split(separator: " ").map { norm(String($0)) }, v) }.sorted { $0.0.count > $1.0.count }
            var out: [Word] = []
            var i = 0
            outer: while i < words.count {
                for (keys, value) in rules where !keys.isEmpty && i + keys.count <= words.count {
                    if (0..<keys.count).allSatisfy({ norm(words[i + $0].text) == keys[$0] }) {
                        let last = words[i + keys.count - 1]
                        let trail = String(last.text.reversed().prefix { $0.isPunctuation }.reversed())
                        out.append(Word(text: value + trail, start: words[i].start, end: last.end))
                        i += keys.count
                        continue outer
                    }
                }
                out.append(words[i]); i += 1
            }
            return out
        }
    }

    /// Piste son → WAV 16 kHz mono 16 bits (le format attendu par Whisper).
    private static func writeWav(_ video: URL, to dst: URL) async throws -> Bool {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return false }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        var pcm = Data()
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            if let p = ptr { pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: len)) }
        }
        guard pcm.count > 16000 else { return false }
        var h = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); h.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        h.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        try (h + pcm).write(to: dst)
        return true
    }

    private static func err(_ m: String) -> NSError { NSError(domain: "X-Videos", code: 4, userInfo: [NSLocalizedDescriptionKey: m]) }
}

/// Dessin d'une ligne de sous-titre, en 3 styles :
/// « pastille » texte blanc gras sur pastille noire, mot prononcé surligné en couleur de la marque ;
/// « karaoke » pastille, mots déjà dits en blanc, à venir en gris, mot prononcé en violet ;
/// « minimal » texte blanc ombré, sans fond ni surlignage.
/// Les images sont mises en cache (une par ligne et par mot actif) : le rendu image par image reste léger.
final class CaptionLayer {
    static let styles: [(id: String, name: String)] = [("pastille", "Pastille"), ("karaoke", "Karaoké"), ("minimal", "Minimal")]
    private let lines: [Captions.Line]
    private let fontSize: CGFloat
    private let bottomY: CGFloat
    private let centerX: CGFloat
    private let style: String
    private var cache: [Int: CIImage] = [:]
    private let lock = NSLock()

    init(words: [Captions.Word], renderSize: CGSize, bottomY: CGFloat, style: String = "pastille") {
        lines = Captions.lines(words)
        self.style = style
        fontSize = (renderSize.height * 0.042).rounded()
        self.bottomY = bottomY
        centerX = renderSize.width / 2
    }

    var isEmpty: Bool { lines.isEmpty }

    func image(at t: Double) -> CIImage? {
        guard let li = lines.firstIndex(where: { t >= $0.start && t < $0.end }) else { return nil }
        let line = lines[li]
        let active = line.words.lastIndex { $0.start <= t } ?? 0
        let key = li * 64 + active
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        guard let img = draw(line, active: active) else { return nil }
        let placed = img.transformed(by: CGAffineTransform(translationX: (centerX - img.extent.width / 2).rounded(), y: bottomY.rounded()))
        cache[key] = placed
        return placed
    }

    private func draw(_ line: Captions.Line, active: Int) -> CIImage? {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)!
        var text = ""
        var ranges: [NSRange] = []
        for (i, w) in line.words.enumerated() {
            if i > 0 { text += " " }
            ranges.append(NSRange(location: (text as NSString).length, length: (w.text as NSString).length))
            text += w.text
        }
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let violet = CGColor(red: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255, alpha: 1)
        let attr = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ])
        if style == "karaoke" {
            let color = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            for (i, r) in ranges.enumerated() where i > active { attr.addAttribute(color, value: CGColor(red: 1, green: 1, blue: 1, alpha: 0.45), range: r) }
            attr.addAttribute(color, value: violet, range: ranges[active])
        }
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let tw = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let padX = fontSize * 0.55, padY = fontSize * 0.32
        let w = ceil(tw + 2 * padX), h = ceil(ascent + descent + 2 * padY)
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if style == "minimal" {
            // texte seul, ombre douce pour rester lisible sur tous les fonds
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.25, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.85))
        } else {
            // pastille
            ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 0.82))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: fontSize * 0.4, cornerHeight: fontSize * 0.4, transform: nil))
            ctx.fillPath()
        }
        if style == "pastille" {
            // mot prononcé : aplat violet derrière le mot
            let r = ranges[active]
            let x0 = CTLineGetOffsetForStringIndex(ctLine, r.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(ctLine, r.location + r.length, nil)
            let hl = CGRect(x: padX + x0 - fontSize * 0.16, y: padY - descent * 0.6, width: x1 - x0 + fontSize * 0.32, height: ascent + descent * 1.2)
            ctx.setFillColor(violet)
            ctx.addPath(CGPath(roundedRect: hl, cornerWidth: fontSize * 0.18, cornerHeight: fontSize * 0.18, transform: nil))
            ctx.fillPath()
        }
        ctx.textPosition = CGPoint(x: padX, y: padY + descent)

        CTLineDraw(ctLine, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
