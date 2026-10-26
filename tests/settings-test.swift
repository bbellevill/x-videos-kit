// Verrou (bug du 2026-10-09) : un fichier de réglages écrit par une ancienne version doit se relire
// sans perdre ce qu'il contient, et les nouveaux réglages prennent leur valeur par défaut.
import Foundation
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  ÉCHEC \(what)"); if !ok { fails += 1 } }

let old = #"{"trimStart":1.5,"trimEnd":0,"autoZoom":true,"background":"noir","padding":0.08,"radius":18,"showCamera":true,"zooms":[{"start":4,"end":8,"scale":2}]}"#
let e = try? JSONDecoder().decode(EditSettings.self, from: Data(old.utf8))
check(e != nil, "ancien fichier relu")
check(e?.trimStart == 1.5 && e?.background == "noir" && e?.padding == 0.08, "valeurs conservées")
check(e?.zooms?.count == 1 && e?.zooms?.first?.scale == 2, "zooms conservés")
check(e?.removeSilences == true && e?.cursorScale == 1.6 && e?.captions == true, "nouveaux réglages par défaut")
let partial = try? JSONDecoder().decode(EditSettings.self, from: Data(#"{"background":"blanc"}"#.utf8))
check(partial?.background == "blanc" && partial?.autoZoom == true, "fichier presque vide")
let rec = try? JSONDecoder().decode(RecordingInfo.self, from: Data(#"{"cameraFile":"a.mov"}"#.utf8))
check(rec?.cameraFile == "a.mov" && rec?.bubbleSize == 0.17, "infos de tournage partielles")
let back = try? JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(e!))
check(back == e, "aller-retour identique")
// son et montage (2026-10-10) : absents des anciens fichiers → valeurs par défaut
check(e?.noiseReduction == true && e?.removeFillers == true && e?.speedUpTyping == true && e?.clickSounds == false, "son : réglages par défaut")
check(e?.cuts == nil && e?.speedRanges == nil && e?.music == nil && e?.musicVolume == 0.12, "coupes, vitesses, musique par défaut")
check(e?.captionStyle == "pastille" && e?.exportHeight == 1080 && e?.exportFPS == 30, "style des sous-titres et qualité d'export par défaut")
var full = EditSettings()
full.cuts = [CutRange(start: 1, end: 2)]; full.speedRanges = [SpeedRange(start: 3, end: 5, speed: 4)]
full.music = "lofi.mp3"; full.musicVolume = 0.2; full.clickSounds = true; full.captionStyle = "karaoke"
full.exportHeight = 2160; full.exportFPS = 60; full.noiseReduction = false; full.removeFillers = false; full.speedUpTyping = false
check((try? JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(full))) == full, "nouveaux réglages : aller-retour identique")
let odd = try? JSONDecoder().decode(EditSettings.self, from: Data(#"{"background":"noir","cuts":"abîmé","speedRanges":[{"start":1,"end":2}]}"#.utf8))
check(odd?.background == "noir" && odd?.cuts == nil && odd?.speedRanges?.first?.speed == 2, "coupe abîmée ignorée, vitesse ×2 par défaut")
// réglages « image » (2026-10-10) : absents = défauts, présents = relus, masque abîmé = ignoré sans tout perdre
check(e?.aspect == "16:9" && e?.cameraLayout == "bulle" && e?.cameraIntroOutro == 0 && e?.hideCameraInSilence == false
      && e?.cameraLook == "naturel" && e?.cameraSharpen == 0 && e?.faceTracking == false && e?.motionBlur == 0.5
      && e?.masks == nil && e?.showKeys == false && e?.backgroundImage == nil && e?.shadow == 1 && e?.reelsGuides == true,
      "réglages image absents : valeurs par défaut")
let img = #"{"background":"image","backgroundImage":"/tmp/f.png","aspect":"9:16","cameraLayout":"cote-a-cote","cameraIntroOutro":2,"hideCameraInSilence":true,"cameraLook":"chaud","cameraSharpen":0.4,"faceTracking":true,"motionBlur":0,"showKeys":true,"shadow":0.3,"reelsGuides":false,"masks":[{"x":0.1,"y":0.2,"w":0.3,"h":0.1,"start":1,"end":3,"kind":"projecteur"}],"zooms":[{"start":1,"end":3,"scale":2,"kind":"loupe"},{"start":5,"end":7}]}"#
let n = try? JSONDecoder().decode(EditSettings.self, from: Data(img.utf8))
check(n?.aspect == "9:16" && n?.cameraLayout == "cote-a-cote" && n?.cameraIntroOutro == 2 && n?.hideCameraInSilence == true
      && n?.cameraLook == "chaud" && n?.cameraSharpen == 0.4 && n?.faceTracking == true && n?.motionBlur == 0 && n?.showKeys == true
      && n?.shadow == 0.3 && n?.reelsGuides == false && n?.backgroundImage == "/tmp/f.png", "réglages image relus")
check(n?.masks?.first?.kind == "projecteur" && n?.masks?.first?.end == 3, "masques relus")
check(n?.zooms?.first?.isLoupe == true && n?.zooms?.last?.isLoupe == false && n?.zooms?.last?.scale == 1.8, "type de zoom (loupe) relu, ancien zoom = classique")
check((try? JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(n!))) == n, "aller-retour identique (réglages image)")
let broken = try? JSONDecoder().decode(EditSettings.self, from: Data(#"{"background":"noir","masks":"abîmé","aspect":"1:1"}"#.utf8))
check(broken?.background == "noir" && broken?.aspect == "1:1" && broken?.masks == nil, "masques illisibles : le reste est gardé")
check(n?.renderSize() == CGSize(width: 1080, height: 1920) && EditSettings().renderSize(short: 720) == CGSize(width: 1280, height: 720), "taille de rendu selon le format")
let oldZoom = #"{"start":1,"end":2,"scale":2}"#
check(String(data: try! JSONEncoder().encode(try! JSONDecoder().decode(ZoomSegment.self, from: Data(oldZoom.utf8))), encoding: .utf8)?.contains("kind") == false,
      "zoom classique écrit sans champ « kind » (lisible par l'ancienne version)")
let preset = try? JSONDecoder().decode(StylePreset.self, from: Data(#"{"name":"Vieux","background":"blanc"}"#.utf8))
check(preset?.name == "Vieux" && preset?.background == "blanc" && preset?.aspect == "16:9", "préréglage partiel relu")
// annotations (2026-10-14) : ancien réglage sans annotations relu intact, annotations relues, abîmées = ignorées sans tout perdre
check(e?.annotations == nil && n?.annotations == nil, "annotations absentes (ancien .edit.json) : nil")
let ann = #"{"background":"noir","annotations":[{"kind":"fleche","x":0.1,"y":0.2,"x2":0.6,"y2":0.7,"start":1,"end":4},{"kind":"texte","x":0.5,"y":0.5,"text":"Ici","start":2,"end":5},{"x":0.3}]}"#
let na = try? JSONDecoder().decode(EditSettings.self, from: Data(ann.utf8))
check(na?.background == "noir" && na?.annotations?.count == 3 && na?.annotations?[0].kind == "fleche" && na?.annotations?[0].x2 == 0.6
      && na?.annotations?[1].text == "Ici" && na?.annotations?[2].kind == "texte" && na?.annotations?[2].end == 3, "annotations relues, champs absents = défauts")
check((try? JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(na!))) == na, "aller-retour identique (annotations)")
let badAnn = try? JSONDecoder().decode(EditSettings.self, from: Data(#"{"background":"noir","annotations":"abîmé","aspect":"1:1"}"#.utf8))
check(badAnn?.background == "noir" && badAnn?.aspect == "1:1" && badAnn?.annotations == nil, "annotations illisibles : le reste est gardé")
var moved = Annotation(kind: "cadre", x: 0.2, y: 0.2, x2: 0.4, y2: 0.4, start: 0, end: 3)
moved.translate(dx: 5, dy: -5)
check(abs(moved.x2 - 1) < 1e-9 && abs(moved.x - 0.8) < 1e-9 && moved.y == 0 && abs(moved.y2 - 0.2) < 1e-9, "déplacement gardé dans l'écran filmé")
// fond de la caméra (2026-10-14) : absent = « aucun », présent = relu, aller-retour, préréglage ancien sans le champ
check(e?.cameraBackground == "aucun", "fond de la caméra : « aucun » par défaut")
let cb = try? JSONDecoder().decode(EditSettings.self, from: Data(#"{"cameraBackground":"flou","cameraLook":"chaud"}"#.utf8))
check(cb?.cameraBackground == "flou" && cb?.cameraLook == "chaud", "fond de la caméra « flou » relu")
check((try? JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(cb!))) == cb, "aller-retour identique (fond de la caméra)")
check(preset?.cameraBackground == "aucun", "ancien préréglage : fond de la caméra « aucun »")
let preset2 = StylePreset(name: "Flou", from: cb!)
var applied = EditSettings(); preset2.apply(to: &applied)
check(applied.cameraBackground == "flou", "préréglage : le fond de la caméra est enregistré et réappliqué")
print(fails == 0 ? "OK : réglages relus sans perte" : "ÉCHEC : \(fails) test(s)")
exit(fails == 0 ? 0 : 1)
