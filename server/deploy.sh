#!/bin/sh
# Met en ligne l'hébergement des vidéos X-Videos sur Cloudflare (adresse réglée dans wrangler.jsonc).
# 1re fois : crée le stockage R2, le jeton d'envoi (gardé dans ~/.config/x-videos/config.json) et la page.
# Ensuite : relancer ce script redéploie seulement le code.
set -e
cd "$(dirname "$0")"
# adresse des vidéos lue dans wrangler.jsonc (routes > pattern)
DOMAIN=$(grep -o '"pattern": *"[^"]*"' wrangler.jsonc | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
CFG="$HOME/.config/x-videos/config.json"

./test-events.sh   # verrou : pas de mise en ligne si des statistiques se perdent
npx wrangler r2 bucket create x-videos 2>&1 | grep -E "Created|already exists" || true
npx wrangler deploy

if [ ! -f "$CFG" ]; then
  mkdir -p "$(dirname "$CFG")"
  printf '{\n  "endpoint": "https://$DOMAIN",\n  "token": "%s"\n}\n' "$(openssl rand -hex 24)" > "$CFG"
  chmod 600 "$CFG"
fi
# le jeton de l'app et celui du serveur doivent être identiques
python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"],end="")' "$CFG" | npx wrangler secret put UPLOAD_TOKEN
echo "OK : https://$DOMAIN en ligne, jeton dans $CFG"
