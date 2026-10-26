# Prompt à donner à Claude Code

Ouvre Claude Code **sur ton Mac** (l'app d'enregistrement ne se compile que sur Mac) et colle le texte ci-dessous.

---

Je veux installer X-Videos (un Loom maison) pour mon entreprise, de bout en bout, à mon nom et à ma marque.
Code : https://github.com/bbellevill/x-videos-kit

1. Clone le dépôt dans ~/x-videos puis lis README.md. Crée ensuite MON propre dépôt GitHub privé et pousse-y le code :
   c'est ma version, je la fais évoluer seul.
2. Pose-moi en une seule fois les questions dont tu as besoin : nom de l'entreprise, site, mon prénom et nom,
   mon lien de prise de rendez-vous (aide-moi à créer un compte Cal.com gratuit si je n'en ai pas),
   l'adresse voulue pour les vidéos (ex. video.monsite.fr) et mon design : couleurs (hex), logo, police, ton des textes.
   Si je n'ai pas de charte, regarde mon site et propose-m'en une.
3. Marque et adresse : remplis `server/wrangler.jsonc` (routes + vars).
4. Design : adapte à ma charte la page de lecture (CSS dans `server/src/index.js` : couleurs, police, logo, textes des boutons
   et de la page) et la couleur de l'app (`Sources/UI.swift`, Theme). Montre-moi la page en local
   (`npx wrangler dev`) avec une fausse vidéo, et ajuste jusqu'à ce que je valide.
5. Hébergement : vérifie que j'ai un compte Cloudflare et que mon domaine y est ajouté ; sinon guide-moi pas à pas
   (bouton exact à cliquer, vérification après chaque étape). Puis `npx wrangler login` et `server/deploy.sh`.
   Vérifie que `https://<mon adresse>` répond.
6. App : installe Homebrew s'il manque, puis ffmpeg et whisper-cpp, télécharge le modèle Whisper (voir README),
   et lance `./build.sh install`. Tous les tests doivent afficher OK.
7. Essai complet : je tourne 10 secondes, on envoie, et tu ouvres le lien pour me montrer la page à ma marque.
8. Pousse toutes mes modifications sur mon dépôt GitHub, puis résume : ce qui est installé, où est le jeton
   (`~/.config/x-videos/config.json`, à ne jamais partager) et combien ça coûte par mois.
