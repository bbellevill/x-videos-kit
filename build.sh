#!/bin/bash
# Build de X-Videos : app barre de menus (écran + bulle caméra + micro → MP4).
# Usage : ./build.sh [install]   (install = copie dans ~/Applications et relance)
set -euo pipefail
cd "$(dirname "$0")"
# sources partagées par les tests (une seule liste : chaque nouveau fichier dont dépend Edit/Render s'ajoute ici)
EDIT_SRC="Sources/Edit.swift Sources/Look.swift Sources/CursorTracker.swift Sources/CaptureClock.swift"
RENDER_SRC="Sources/Render.swift Sources/Compositor.swift Sources/Silence.swift Sources/Captions.swift Sources/Montage.swift Sources/Audio.swift Sources/LookRender.swift Sources/Cutout.swift $EDIT_SRC"
# un test qui ne compile plus doit échouer, pas relancer son ancienne version (bug du 2026-10-10)
rm -f build/*-test
APP=build/X-Videos.app
# verrou : les réglages d'anciennes versions doivent se relire sans perte
mkdir -p build/tests && cp tests/settings-test.swift build/tests/main.swift
swiftc -swift-version 5 build/tests/main.swift $EDIT_SRC -framework Cocoa -o build/settings-test
./build/settings-test | tail -1
# verrou : lecture de la transcription Whisper, remplacements du dictionnaire, découpage en lignes
mkdir -p build/ctest && cp tests/captions-test.swift build/ctest/main.swift
swiftc -swift-version 5 build/ctest/main.swift Sources/Captions.swift -framework Cocoa -framework AVFoundation -o build/captions-test
./build/captions-test | tail -1
# verrou : caméra + silences coupés → montage valide (aperçu noir le 2026-10-10)
mkdir -p build/rtest && cp tests/render-test.swift build/rtest/main.swift
swiftc -swift-version 5 build/rtest/main.swift $RENDER_SRC -framework Cocoa -framework AVFoundation -framework Metal -framework Vision -o build/render-test 2>&1 | grep "error:" || true
./build/render-test tests/fixtures/silences-loom-2026-10-10.json | tail -1
# verrou : plan du montage (coupes, « euh », frappe, conversions de temps avec accélération, musique, .srt)
mkdir -p build/mgtest && cp tests/montage-test.swift build/mgtest/main.swift
swiftc -swift-version 5 build/mgtest/main.swift $RENDER_SRC -framework Cocoa -framework AVFoundation -framework Metal -framework Vision -o build/montage-test 2>&1 | grep "error:" || true
./build/montage-test | tail -1
# verrou : son et montage sur une vraie composition (débruitage, vitesses, musique, clics, aperçu AVPlayer, export 720p60)
mkdir -p build/sotest && cp tests/son-test.swift build/sotest/main.swift
swiftc -swift-version 5 build/sotest/main.swift $RENDER_SRC -framework Cocoa -framework AVFoundation -framework Metal -framework Vision -o build/son-test 2>&1 | grep "error:" || true
./build/son-test | tail -1
# verrou : image (formats, mises en page caméra, flou de mouvement, loupe, masques, annotations texte/flèche/cadre, touches, fonds, préréglages, aperçu ≥ 20 i/s)
mkdir -p build/ltest && cp tests/look-test.swift build/ltest/main.swift
swiftc -swift-version 5 build/ltest/main.swift $RENDER_SRC -framework Cocoa -framework AVFoundation -framework Metal -framework Vision -o build/look-test 2>&1 | grep "error:" || true
./build/look-test | tail -1
# verrou : looms personnalisés (prénom, point de coupe, phrase proposée)
mkdir -p build/ptest && cp tests/personalize-test.swift build/ptest/main.swift
swiftc -swift-version 5 build/ptest/main.swift Sources/Personalize.swift Sources/Captions.swift $EDIT_SRC -framework Cocoa -framework AVFoundation -o build/personalize-test 2>&1 | grep "error:" || true
./build/personalize-test | tail -1
# verrou : menu Édition (⌘A ⌘C ⌘V dans les champs de texte)
mkdir -p build/mtest && cp tests/menus-test.swift build/mtest/main.swift
swiftc -swift-version 5 build/mtest/main.swift Sources/Menus.swift -framework Cocoa -o build/menus-test 2>&1 | grep "error:" || true
./build/menus-test | tail -1
# verrou : le lien collé dit « Vidéo pour Prénom de chez Agence »
mkdir -p build/sttest && cp tests/sharetitle-test.swift build/sttest/main.swift
swiftc -swift-version 5 build/sttest/main.swift Sources/ShareTitle.swift -o build/sharetitle-test 2>&1 | grep "error:" || true
./build/sharetitle-test | tail -1
# verrou : pause / reprise (horodatages recalés), sauvegarde anti-crash, son du Mac, import
mkdir -p build/captest && cp tests/capture-test.swift build/captest/main.swift
swiftc -swift-version 5 build/captest/main.swift Sources/CaptureClock.swift Sources/CaptureWriter.swift Sources/MovieTools.swift Sources/Recovery.swift Sources/Edit.swift Sources/Look.swift Sources/CursorTracker.swift -framework Cocoa -framework AVFoundation -o build/capture-test 2>&1 | grep "error:" || true
./build/capture-test | tail -1
# verrou : choix de la capture (écran / fenêtre / zone), icônes du bureau masquées, réglages mémorisés
mkdir -p build/tgtest && cp tests/target-test.swift build/tgtest/main.swift
swiftc -swift-version 5 build/tgtest/main.swift Sources/CaptureOptions.swift -o build/target-test 2>&1 | grep "error:" || true
./build/target-test | tail -1
# verrou : journal des touches (.meta/<vidéo>.keys.json, format exact, rien de tapé n'est gardé)
mkdir -p build/ktest && cp tests/keys-test.swift build/ktest/main.swift
swiftc -swift-version 5 build/ktest/main.swift Sources/KeyLog.swift Sources/CaptureClock.swift -framework Cocoa -o build/keys-test 2>&1 | grep "error:" || true
./build/keys-test | tail -1
# verrou : vidéos bout à bout (ajout à la suite, retour en arrière) et audios importés posés sur la frise
mkdir -p build/astest && cp tests/assemble-test.swift build/astest/main.swift
swiftc -swift-version 5 build/astest/main.swift Sources/Assemble.swift $RENDER_SRC -framework Cocoa -framework AVFoundation -framework Metal -framework Vision -o build/assemble-test 2>&1 | grep "error:" || true
./build/assemble-test | tail -1
# verrou : dossiers + recherche de la bibliothèque (ancien index sans « folder » relu sans perte)
mkdir -p build/lbtest && cp tests/library-test.swift build/lbtest/main.swift
swiftc -swift-version 5 build/lbtest/main.swift Sources/Video.swift -o build/library-test 2>&1 | grep "error:" || true
./build/library-test | tail -1
# verrou : fond de la caméra (flou / noir) : le fond change, la personne reste intacte, masque réutilisé
mkdir -p build/cotest && cp tests/cutout-test.swift build/cotest/main.swift
swiftc -swift-version 5 build/cotest/main.swift Sources/Cutout.swift -framework Cocoa -framework Vision -framework CoreImage -o build/cutout-test 2>&1 | grep "error:" || true
./build/cutout-test tests/fixtures/camera-frame.jpg | tail -1
# verrou : effacement des traits dessinés à l'écran
mkdir -p build/drtest && cp tests/draw-test.swift build/drtest/main.swift
swiftc -swift-version 5 build/drtest/main.swift Sources/DrawLogic.swift -o build/draw-test 2>&1 | grep "error:" || true
./build/draw-test | tail -1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# verrou : « refaire les dernières secondes » → passage coupé au bon endroit (2026-10-14)
mkdir -p build/rwtest && cp tests/rewind-test.swift build/rwtest/main.swift
swiftc -swift-version 5 build/rwtest/main.swift Sources/CaptureClock.swift -o build/rewind-test 2>&1 | grep "error:" || true
./build/rewind-test | tail -1
# verrou : un export qui n'avance plus est annulé puis relancé (vidéo jamais en ligne le 2026-10-17)
mkdir -p build/sttest && cp tests/stall-test.swift build/sttest/main.swift
swiftc -swift-version 5 build/sttest/main.swift $RENDER_SRC -framework Cocoa -framework AVFoundation -framework Metal -framework Vision -o build/stall-test 2>&1 | grep "error:" || true
./build/stall-test | tail -1
# verrou : titre, résumé et chapitres lus dans la réponse de Haiku (2026-10-14)
mkdir -p build/smtest && cp tests/smart-test.swift build/smtest/main.swift
swiftc -swift-version 5 build/smtest/main.swift Sources/Smart.swift Sources/Captions.swift -framework Cocoa -framework AVFoundation -o build/smart-test 2>&1 | grep "error:" || true
./build/smart-test | tail -1
swiftc -O -swift-version 5 -parse-as-library Sources/*.swift \
  -framework Cocoa -framework AVFoundation -framework AVKit -framework ScreenCaptureKit -framework Carbon -framework UserNotifications -framework Metal \
  -o "$APP/Contents/MacOS/X-Videos"
cp app/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp app/AppIcon.icns "$APP/Contents/Resources/"
# Signature stable (certificat Apple Development) : sinon macOS oublie les autorisations à chaque build
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development:' | head -1 | awk '{print $2}')
codesign -s "${SIGN_ID:--}" --force --deep "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo ">> OK : $APP (signée : ${SIGN_ID:-ad hoc})"
if [ "${1:-}" = "install" ]; then
  pkill -x X-Videos 2>/dev/null && sleep 1 || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/X-Videos.app
  ditto --noextattr --noqtn "$APP" ~/Applications/X-Videos.app
  open ~/Applications/X-Videos.app
  echo ">> Installée et lancée : ~/Applications/X-Videos.app"
fi
