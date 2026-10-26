import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// Fenêtre principale : bouton d'enregistrement + toutes les vidéos, chacune avec « Copier le lien » en un clic.
final class HomeModel: ObservableObject {
    @Published var cameraOn = true
    @Published var micID: String?
    var onStart: () -> Void = {}
    var onCamera: (Bool) -> Void = { _ in }
    var onMic: (String?) -> Void = { _ in }
    /// Réglages de tournage (mode, i/s, icônes, son du Mac) : mémorisés à chaque changement.
    @Published var options = CaptureOptions.load() { didSet { if options != oldValue { options.save() } } }
    @Published var notesOn = false
    var onNotes: () -> Void = {}
}

final class HomeWindow {
    let model = HomeModel()
    private var window: NSWindow?
    private var refresh: Timer?
    private let library: Library

    init(library: Library) { self.library = library }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "X-Videos"
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Theme.black
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HomeView(lib: library, model: model))
            w.center()
            w.setFrameAutosaveName("XVideosHome")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        library.refreshViews()
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.library.refreshViews()
        }
    }

    func hide() { window?.orderOut(nil) }
}

private let violet = Color(Theme.violet)
private let muted = Color(white: 0.6)
private let cardFill = Color(white: 0.075)
private let line = Color(Theme.border)

struct HomeView: View {
    @ObservedObject var lib: Library
    @ObservedObject var model: HomeModel
    private let mics = AppDelegate.microphones().map { ($0.uniqueID, $0.localizedName) }
    @State private var query = ""
    @State private var folder: String?       // nil = « Toutes »

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("X-Videos").font(.system(size: 26, weight: .bold))
                    Text("Enregistre, le lien est copié tout seul. Colle-le dans LinkedIn, Gmail ou Slack.")
                        .font(.system(size: 12)).foregroundColor(muted)
                }
                Spacer()
                Toggle("Caméra", isOn: Binding(get: { model.cameraOn }, set: { model.cameraOn = $0; model.onCamera($0) }))
                    .toggleStyle(.switch).tint(violet)
                Picker("", selection: Binding(get: { model.micID ?? "" },
                                              set: { let v = $0.isEmpty ? nil : $0; model.micID = v; model.onMic(v) })) {
                    Text("Micro par défaut").tag("")
                    ForEach(mics, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 190)
                Button(action: model.onStart) {
                    Label("Nouvel enregistrement", systemImage: "record.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Capsule().fill(violet))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .help("Raccourci depuis n'importe quelle app : ⌥⇧R")
            }
            .padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 12)

            CaptureOptionsBar(model: model, lib: lib)
                .padding(.horizontal, 28).padding(.bottom, 16)

            if let e = lib.lastError {
                HStack {
                    Text(e).font(.system(size: 12))
                    Spacer()
                    Button("OK") { lib.lastError = nil }.buttonStyle(.plain).foregroundColor(violet)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12)))
                .padding(.horizontal, 28).padding(.bottom, 12)
            }

            if lib.videos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "video.badge.plus").font(.system(size: 40)).foregroundColor(violet)
                    Text("Aucune vidéo pour l'instant").font(.system(size: 18, weight: .semibold))
                    Text("Clique sur « Nouvel enregistrement » (ou ⌥⇧R).\nÀ la fin, le lien de la vidéo est copié tout seul.")
                        .multilineTextAlignment(.center).foregroundColor(muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = LibraryFilter.apply(lib.videos, query: query, folder: folder)
                LibraryFilterBar(lib: lib, query: $query, folder: $folder)
                    .padding(.horizontal, 28).padding(.bottom, 14)
                if shown.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundColor(violet)
                        Text("Aucune vidéo ne correspond").font(.system(size: 18, weight: .semibold))
                        Text("Change la recherche ou choisis un autre dossier.").foregroundColor(muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 20)], spacing: 22) {
                            ForEach(shown) { v in VideoCard(v: v, lib: lib) }
                        }
                        .padding(.horizontal, 28).padding(.bottom, 28)
                    }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(Color(Theme.black))
        .foregroundColor(.white)
    }
}

/// Deuxième ligne : quoi filmer, 30/60 i/s, son du Mac, icônes du bureau, notes, import.
struct CaptureOptionsBar: View {
    @ObservedObject var model: HomeModel
    @ObservedObject var lib: Library

    var body: some View {
        HStack(spacing: 14) {
            Picker("", selection: $model.options.mode) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            .help("Écran entier, une seule fenêtre, ou une zone dessinée à la souris")
            Picker("", selection: $model.options.fps) {
                Text("30 i/s").tag(30); Text("60 i/s").tag(60)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            .help("60 images par seconde : mouvements plus fluides, fichier plus lourd")
            Picker("", selection: $model.options.systemAudio) {
                ForEach(SystemAudio.allCases, id: \.self) { Text($0 == .off ? "Son du Mac : non" : "Son du Mac : \($0.label.lowercased())").tag($0) }
            }
            .labelsHidden().frame(width: 220)
            .help("Enregistre aussi le son de l'ordinateur (vidéo, musique, appel)")
            Toggle("Masquer les icônes du bureau", isOn: $model.options.hideDesktopIcons)
                .toggleStyle(.checkbox).font(.system(size: 12))
            Spacer()
            Button { model.onNotes() } label: {
                Label("Notes", systemImage: model.notesOn ? "note.text.badge.plus" : "note.text").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundColor(model.notesOn ? violet : .white)
            .help("Notes de présentation : toujours visibles pour toi, jamais filmées")
            Button { importVideos() } label: {
                Label("Importer", systemImage: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Ajouter une vidéo MP4 ou MOV déjà sur ton Mac")
        }
        .tint(violet)
    }

    private func importVideos() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = true
        p.message = "Choisis les vidéos à ajouter à ta bibliothèque"
        p.prompt = "Importer"
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        if p.urls.count > 1 {
            // plusieurs vidéos : les mettre bout à bout en une seule, ou les garder séparées
            let a = NSAlert()
            a.messageText = "Mettre ces \(p.urls.count) vidéos bout à bout ?"
            a.informativeText = "Une seule vidéo, dans l'ordre de ta sélection, à monter ensuite dans l'éditeur."
            a.addButton(withTitle: "Une seule vidéo")
            a.addButton(withTitle: "Séparément")
            if a.runModal() == .alertFirstButtonReturn { lib.importAssembled(p.urls); return }
        }
        lib.importFiles(p.urls)
    }
}

/// Recherche (titre, prénom, agence) + pastilles « Toutes · dossiers · + Dossier ».
struct LibraryFilterBar: View {
    @ObservedObject var lib: Library
    @Binding var query: String
    @Binding var folder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(muted)
                TextField("Chercher un titre, un prénom, une agence", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(muted) }
                        .buttonStyle(.plain).help("Effacer la recherche")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.12)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Toutes", on: folder == nil) { folder = nil }
                    ForEach(lib.folderNames, id: \.self) { n in
                        chip(n, on: folder == n) { folder = n }
                    }
                    chip("+ Dossier", on: false, dashed: true) {
                        if let n = Library.askFolderName(), let made = lib.addFolder(n) { folder = made }
                    }
                }
            }
        }
        // un dossier qui n'existe plus ne doit pas laisser une grille vide
        .onChange(of: lib.folderNames) { _, names in if let f = folder, !names.contains(f) { folder = nil } }
    }

    private func chip(_ title: String, on: Bool, dashed: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? violet : Color(white: 0.14)))
                .overlay(Capsule().stroke(dashed ? line : Color.clear, lineWidth: 1))
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

struct VideoCard: View {
    let v: Video
    @ObservedObject var lib: Library
    @State private var title = ""
    @State private var hover = false
    @State private var personalizing = false

    private var subtitle: String {
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: "fr_FR")
        var s = rel.localizedString(for: v.created, relativeTo: Date()).capitalizedFirst
        if v.uploaded {
            s += v.views == 0 ? " · pas encore vue" : " · vue \(v.views) fois"
            if let p = v.pct, p > 0 { s += " · \(p) % regardé" }
            if (v.ctaClicks ?? 0) > 0 { s += " · a cliqué Réserver" }
        } else {
            s += " · pas encore envoyée"
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Group {
                    if let img = NSImage(contentsOf: lib.thumbURL(of: v)) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(white: 0.12))
                    }
                }
                .frame(height: 165).frame(maxWidth: .infinity).clipped()
                if hover {
                    Circle().fill(violet).frame(width: 52, height: 52)
                        .overlay(Image(systemName: "play.fill").font(.system(size: 20)).foregroundColor(.white).offset(x: 2))
                }
                VStack { Spacer(); HStack { Spacer()
                    Text(Library.fmt(v.duration))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                } }.padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { lib.play(v) }
            .help("Ouvrir le montage : zooms, fond, coupes")

            TextField("Titre", text: $title, onCommit: { lib.rename(v, to: title) })
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .help("Clique pour renommer : c'est le titre que verra ton prospect")
            if let f = v.firstName {
                Text("Pour \(f)\(v.company.map { " · \($0)" } ?? "")").font(.system(size: 12, weight: .medium)).foregroundColor(violet)
            }
            Text(subtitle).font(.system(size: 12)).foregroundColor(muted).lineLimit(2)

            Group {
                HStack(spacing: 4) {
                    icon("wand.and.stars", "Montage : zooms, fond, coupes") { lib.play(v) }
                    Button { lib.copyLink(v) } label: {
                        Label("Copier le lien", systemImage: "link")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Capsule().fill(violet))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    icon("person.crop.circle.badge.plus", "Personnaliser pour un prospect : ta voix dit son prénom au début") { personalizing = true }
                    Spacer(minLength: 0)
                    Menu {
                        Menu("Ranger dans") {
                            ForEach(lib.folderNames, id: \.self) { n in
                                Button(v.folder == n ? "✓ \(n)" : n) { lib.move(v, toFolder: n) }
                            }
                            Button("Nouveau dossier…") {
                                if let n = Library.askFolderName(), let made = lib.addFolder(n) { lib.move(v, toFolder: made) }
                            }
                            if v.folder != nil { Divider(); Button("Sortir du dossier") { lib.move(v, toFolder: nil) } }
                        }
                        // actions secondaires rangées ici (2026-10-14) : « Copier le lien » ne doit jamais être tronqué
                        if v.uploaded { Button { lib.openPage(v) } label: { Label("Ouvrir la page du prospect", systemImage: "safari") } }
                        Button { lib.copyFile(v) } label: { Label("Copier le fichier (pièce jointe)", systemImage: "doc.on.doc") }
                        Button("Montrer dans le Finder") { lib.reveal(v) }
                        Divider()
                        Button("Supprimer", role: .destructive) { lib.delete(v) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12))
                            .frame(width: 26, height: 28)
                            .background(Capsule().fill(Color(white: 0.14)))
                            .foregroundColor(.white)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Plus : ranger, Finder, supprimer")
                }
            }
            if let p = lib.progress[v.id] { UploadLine(p: p) }
            if let f = lib.flash[v.id] {
                Text(f).font(.system(size: 12, weight: .semibold)).foregroundColor(violet)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(line, lineWidth: 1))
        .sheet(isPresented: $personalizing) { PersonalizeSheet(v: v, lib: lib, open: $personalizing) }
        .onAppear { title = v.title }
        .onChange(of: v.title) { _, new in title = new }
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12))
                .frame(width: 26, height: 28)
                .background(Capsule().fill(Color(white: 0.14)))
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Fenêtre « Personnaliser » : prénom + agence → nouvelle vidéo où ta voix (copiée) dit la phrase d'ouverture.
struct PersonalizeSheet: View {
    let v: Video
    @ObservedObject var lib: Library
    @Binding var open: Bool
    @State private var firstName = ""
    @State private var company = ""
    @State private var recordId: String?
    @State private var opening = ""
    @State private var template: Personalize.Template?
    @State private var status = "Analyse du début de la vidéo…"
    @State private var busy = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Personnaliser pour un prospect").font(.system(size: 18, weight: .bold))
            Text("Toute ta vidéo est gardée. Seule la phrase d'ouverture est redite avec ta voix, avec son prénom.")
                .font(.system(size: 12)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField("Prénom", text: $firstName).textFieldStyle(.roundedBorder)
                TextField("Agence", text: $company).textFieldStyle(.roundedBorder)
            }
            ProspectPicker(query: "\(firstName) \(company)", linkedId: recordId) { p in
                recordId = p?.id
                if let p = p { if firstName.isEmpty { firstName = p.firstName }; if company.isEmpty { company = p.company } }
            }
            if let t = template {
                Text("Dans la vidéo, tu dis : « \(t.said) »").font(.system(size: 12)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
                Text("Phrase d'ouverture ({prénom} et {agence} sont remplacés)").font(.system(size: 12, weight: .semibold))
                TextField("", text: $opening, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            }
            if let e = error { Text(e).font(.system(size: 12, weight: .semibold)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            else if busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.system(size: 12)).foregroundColor(muted) } }
            HStack {
                Spacer()
                Button("Annuler") { open = false }.keyboardShortcut(.cancelAction)
                Button("Créer la vidéo") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || template == nil || firstName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 520)
        .task {
            do {
                let t = try await Personalize.prepare(lib.url(of: v))
                template = t; opening = t.opening; busy = false
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }

    private func create() {
        guard var t = template else { return }
        t.opening = opening
        Personalize.saveTemplate(t, for: lib.url(of: v))      // la phrase retouchée resservira pour le prochain prospect
        let f = firstName.trimmingCharacters(in: .whitespaces), c = company.trimmingCharacters(in: .whitespaces)
        busy = true; error = nil
        Task { @MainActor in
            do {
                let file = try await Personalize.make(from: lib.url(of: v), template: t, firstName: f, company: c) { s in
                    Task { @MainActor in status = s }
                }
                lib.addPersonalized(file: file, from: v, firstName: f, company: c, recordId: recordId)
                open = false
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
