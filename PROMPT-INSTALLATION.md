# Prompt à donner à Claude Code

Copie le texte ci-dessous dans Claude Code, ouvert dans ce dossier, **sur ton Mac**
(l'app d'enregistrement ne se compile que sur Mac ; l'hébergement, lui, peut se faire de n'importe où).

---

Lis README.md. Je veux installer X-Videos pour mon entreprise, de bout en bout.

1. Pose-moi d'abord, en une seule fois, les questions dont tu as besoin : nom de l'entreprise, site, couleur principale (hex),
   mon prénom et nom, mon lien Cal.com (sinon aide-moi à en créer un), et l'adresse voulue pour les vidéos (ex. video.monsite.fr).
2. Remplis `server/wrangler.jsonc` avec mes réponses. Ne modifie rien d'autre dans le code.
3. Vérifie que j'ai un compte Cloudflare et que mon domaine y est ajouté. Sinon, guide-moi pour créer le compte et ajouter le domaine
   (dis-moi exactement sur quel bouton cliquer, et vérifie après chaque étape).
4. Lance `npx wrangler login`, puis `server/deploy.sh`. Vérifie que `https://<mon adresse>` répond.
5. Installe ffmpeg et whisper-cpp avec Homebrew (installe Homebrew s'il manque), télécharge le modèle Whisper (voir README).
6. Lance `./build.sh install` et vérifie que tous les tests affichent OK.
7. Fais un essai complet : je tourne 10 secondes, on envoie, et tu ouvres le lien pour me montrer la page à ma marque.
8. Termine par un résumé : ce qui est installé, où est le jeton (`~/.config/x-videos/config.json`, à ne jamais partager),
   et combien ça coûte par mois.
