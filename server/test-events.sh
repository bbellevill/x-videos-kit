#!/bin/sh
# Verrou : envoie une vue + 5 événements EN MÊME TEMPS au serveur local et vérifie qu'aucun n'est perdu.
# (Bug du 2026-10-09 : deux écritures simultanées de la méta s'écrasaient.)
cd "$(dirname "$0")"
printf 'UPLOAD_TOKEN=testtoken\n' > .dev.vars
npx wrangler dev --local --port 8799 >/dev/null 2>&1 &
B=http://localhost:8799; A="Authorization: Bearer testtoken"; ID=verrou$(date +%s)
# on attend que le serveur de test réponde vraiment (jusqu'à 60 s), au lieu d'un délai fixe
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' -H "$A" $B/api/list)" = "200" ]; do
  i=$((i + 1)); [ $i -gt 60 ] && { echo "ÉCHEC : le serveur de test n'a pas démarré"; pkill -f "wrangler dev --local --port 8799"; exit 1; }
  sleep 1
done
curl -s -X PUT -H "$A" -d '{"title":"t","duration":4}' $B/api/meta/$ID >/dev/null
# rafale simultanée ; on n'attend que les curl (pas le serveur lancé plus haut)
PIDS=""
curl -s -A Mozilla/5.0 -o /dev/null $B/v/$ID & PIDS="$PIDS $!"
for t in play p25 p50 p75 cta; do curl -s -A Mozilla/5.0 -X POST -o /dev/null "$B/e/$ID?t=$t" & PIDS="$PIDS $!"; done
for p in $PIDS; do wait $p; done; sleep 1
R=$(curl -s -H "$A" "$B/api/list?fresh=1" | python3 -c "import sys,json;v=[x for x in json.load(sys.stdin) if x['id']=='$ID'][0];print(v['views'],v['plays'],v['pct'],v['ctaClicks'])")
# Verrou (23/10) : la page garde le lien Cal.com trace (rendez-vous relie a la video, donc a la fiche CRM) et le bouton du site
P=$(curl -s -A Mozilla/5.0 "$B/v/$ID")
echo "$P" | grep -q "metadata%5Blead_ref%5D=video-$ID" || { echo "ÉCHEC : lien Cal.com sans lead_ref"; pkill -f "wrangler dev --local --port 8799"; exit 1; }
echo "$P" | grep -q "data-site" || { echo "ÉCHEC : bouton Voir notre site absent"; pkill -f "wrangler dev --local --port 8799"; exit 1; }
curl -s -X DELETE -H "$A" $B/api/video/$ID >/dev/null
pkill -f "wrangler dev --local --port 8799"
if [ "$R" = "1 1 75 1" ]; then echo "OK : aucun événement perdu"; else echo "ÉCHEC : obtenu '$R', attendu '1 1 75 1'"; exit 1; fi
