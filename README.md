# X-Videos

Enregistre ton écran + ta caméra sur Mac, monte la vidéo automatiquement, et envoie un lien de partage
(page de lecture à ta marque, avec bouton de prise de rendez-vous et statistiques de vues). Équivalent de Loom, hébergé chez toi.

Deux morceaux :

| Morceau | Où il tourne | Dossier |
|---|---|---|
| L'app d'enregistrement et de montage | ton Mac (macOS 14 ou plus) | `Sources/`, `build.sh` |
| L'hébergement des vidéos + la page de lecture | Cloudflare (Workers + R2) | `server/` |

## Adapter à ton entreprise : un seul fichier

Tout ce qui concerne ta marque est dans **`server/wrangler.jsonc`** :

- `routes > pattern` : l'adresse de tes vidéos (ex. `video.monentreprise.fr`)
- `vars` : nom, site, couleur des boutons, ton nom, ton lien Cal.com, texte du bouton

Rien d'autre à toucher dans le code.

## Comptes nécessaires

| Service | Pourquoi | Prix |
|---|---|---|
| Cloudflare | héberger les vidéos (R2) et la page | gratuit jusqu'à 10 Go de vidéos, puis ~0,015 $/Go/mois |
| Un nom de domaine sur Cloudflare | l'adresse `video.tondomaine.fr` | celui que tu as déjà (à transférer ou ajouter sur Cloudflare) |
| Cal.com | le bouton de rendez-vous sous la vidéo | gratuit |
| Claude Code (optionnel) | titre, résumé et chapitres automatiques | ton abonnement Claude |

## Installation

1. **Hébergement** (sur n'importe quel ordinateur avec Node.js) :
   ```sh
   cd server
   npx wrangler login            # connexion au compte Cloudflare
   ./deploy.sh                   # crée le stockage, met la page en ligne, crée le jeton d'envoi
   ```
   Le jeton est enregistré dans `~/.config/x-videos/config.json`. **Ce fichier doit être sur le Mac qui enregistre.**

2. **App** (sur le Mac) :
   ```sh
   brew install ffmpeg whisper-cpp     # montage + sous-titres
   ./build.sh install                  # compile, teste, installe dans ~/Applications et lance
   ```
   Au premier lancement, macOS demande l'accès à l'écran, la caméra et le micro : tout accepter.

3. **Sous-titres** : télécharger le modèle Whisper dans `~/.cache/whisper/ggml-large-v3-turbo.bin`
   (https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin).

## Optionnel : relier une vidéo à un contact

Mets tes contacts dans `~/.config/x-videos/contacts.json` :
```json
{ "data": [ { "id": "c1", "displayName": "Julie Martin", "fields": { "company_name": "Studio Lumen" } } ] }
```
La page de la vidéo affichera alors « Julie, une vidéo pour Studio Lumen ».

## Mettre à jour la page après un changement

`cd server && ./deploy.sh` (les tests tournent avant, rien ne part s'ils échouent).
