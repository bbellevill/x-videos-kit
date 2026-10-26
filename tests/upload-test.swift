// Test d'intégration : envoie une vraie vidéo via Uploader vers le serveur local (wrangler dev).
// Usage : X_VIDEOS_CONFIG=... ./upload-test fichier.mp4 miniature.jpg
// Verrou du 2026-10-14 (« les liens se copient en 3 heures ») : la page et les aperçus doivent exister en moins de 5 s,
// AVANT le montage et l'envoi de la vidéo ; la vidéo envoyée en morceaux parallèles doit se relire en entier.
import Cocoa
import AVFoundation
let args = CommandLine.arguments
let up = Uploader()
guard up.isConfigured else { print("ÉCHEC : config absente"); exit(1) }
let dur = CMTimeGetSeconds(AVURLAsset(url: URL(fileURLWithPath: args[1])).duration)
let v = Video(id: Library.newID(), file: "test.mp4", title: "Test d'envoi", created: Date(), duration: dur)
let t0 = Date()
var ready: Double?
var code: Int32 = 0
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        try await up.upload(v, file: URL(fileURLWithPath: args[1]), thumb: URL(fileURLWithPath: args[2])) { p in
            if p >= 0.04, ready == nil { ready = Date().timeIntervalSince(t0) }
        }
        let l = try await up.list()
        let base = up.endpoint!
        let (gif, _) = try await URLSession.shared.data(from: URL(string: "\(base)/t/\(v.id).gif")!)
        let asset = AVURLAsset(url: URL(string: "\(base)/f/\(v.id).mp4")!)
        let online = try await asset.load(.duration).seconds
        if !l.contains(where: { $0.id == v.id }) { print("ÉCHEC : absente de la liste"); code = 1 }
        else if (ready ?? 99) > 5 { print("ÉCHEC : page prête en \(ready ?? -1) s (max 5 s)"); code = 1 }
        else if gif.count < 1000 { print("ÉCHEC : GIF absent"); code = 1 }
        else if online < 1 { print("ÉCHEC : vidéo en ligne illisible"); code = 1 }
        else { print(String(format: "OK page prête en %.1f s, vidéo en ligne en %.1f s (%.0f s lisibles) id=%@", ready!, Date().timeIntervalSince(t0), online, v.id)) }
        try? await up.delete(v.id)
    } catch { print("ÉCHEC : \(error.localizedDescription)"); code = 1 }
    sem.signal()
}
while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
exit(code)
