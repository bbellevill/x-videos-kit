import AVFoundation

/// Détection des silences dans la voix (comme « retirer les pauses » de Screen Studio).
/// Résultat mis en cache dans <dossier>/.meta/<vidéo>.silences.json.
enum Silence {
    struct Run: Codable { var start: Double; var end: Double }

    static let minSilence = 0.8      // une pause plus courte reste (respiration naturelle)
    static let keep = 0.2            // on garde 0,2 s de silence de chaque côté de la coupe

    static func cacheURL(_ video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".meta/\(video.lastPathComponent).silences.json")
    }

    /// Passages à couper (déjà réduits des marges), en temps source.
    static func cuts(for video: URL) async -> [Run] {
        if let d = try? Data(contentsOf: cacheURL(video)), let r = try? JSONDecoder().decode([Run].self, from: d) { return r }
        let runs = (try? await analyze(video)) ?? []
        try? FileManager.default.createDirectory(at: cacheURL(video).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(runs).write(to: cacheURL(video))
        return runs
    }

    private static func analyze(_ video: URL) async throws -> [Run] {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        // niveau (dB) par fenêtre de 50 ms
        let win = 800
        var levels: [Double] = []
        var acc = 0.0, count = 0
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let p = ptr else { continue }
            let n = len / 4
            p.withMemoryRebound(to: Float.self, capacity: n) { f in
                for i in 0..<n {
                    acc += Double(f[i] * f[i]); count += 1
                    if count == win { levels.append(10 * log10(max(acc / Double(win), 1e-10))); acc = 0; count = 0 }
                }
            }
        }
        guard levels.count > 20 else { return [] }
        // seuil adaptatif : entre le bruit de fond (10e centile) et la voix (90e centile)
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10], voice = sorted[sorted.count * 9 / 10]
        guard voice - floor > 12 else { return [] }          // pas assez de contraste : on ne coupe rien
        let threshold = floor + (voice - floor) * 0.3
        var runs: [Run] = []
        var startIdx: Int?
        for (i, l) in levels.enumerated() {
            if l < threshold { if startIdx == nil { startIdx = i } }
            else if let s = startIdx {
                append(&runs, s, i); startIdx = nil
            }
        }
        if let s = startIdx { append(&runs, s, levels.count) }
        return runs
    }

    private static func append(_ runs: inout [Run], _ s: Int, _ e: Int) {
        let a = Double(s) * 0.05, b = Double(e) * 0.05
        guard b - a >= minSilence else { return }
        runs.append(Run(start: a + keep, end: b - keep))
    }
}
