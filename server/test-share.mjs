// Test verrou de la page de partage : vitesse, commentaires, échappement, lien privé, transcription.
// Node pur, faux R2 en mémoire : `node server/test-share.mjs`
import worker from './src/index.js';
import assert from 'node:assert/strict';

class FakeBucket {
  m = new Map();
  ver = new Map(); // etag = numéro de version, pour les écritures conditionnelles (onlyIf) comme R2
  async put(k, v, o = {}) {
    const c = o.onlyIf;
    if (c?.etagMatches && c.etagMatches !== String(this.ver.get(k))) return null;
    if (c?.etagDoesNotMatch === '*' && this.m.has(k)) return null;
    this.m.set(k, typeof v === 'string' ? v : v ?? ''); this.ver.set(k, (this.ver.get(k) || 0) + 1);
    return { key: k };
  }
  async get(k) {
    if (!this.m.has(k)) return null;
    const v = this.m.get(k);
    return { size: String(v).length, etag: String(this.ver.get(k)), httpEtag: '"x"', body: String(v), json: async () => JSON.parse(v), text: async () => String(v) };
  }
  async head(k) { return this.m.has(k) ? { size: 1 } : null; }
  async delete(ks) { [].concat(ks).forEach((k) => this.m.delete(k)); }
  async list({ prefix }) { return { objects: [...this.m.keys()].filter((k) => k.startsWith(prefix)).map((key) => ({ key })), truncated: false }; }
}
const env = { BUCKET: new FakeBucket(), UPLOAD_TOKEN: 'tok' };
const ctx = { waitUntil: (p) => p };
const H = 'https://video.test';
const call = (path, init = {}) => worker.fetch(new Request(H + path, init), env, ctx);
const api = (path, init = {}) => call(path, { ...init, headers: { authorization: 'Bearer tok', ...(init.headers || {}) } });
const put = (id, body) => api(`/api/meta/${id}`, { method: 'PUT', body: JSON.stringify(body) });
const MOZ = { 'user-agent': 'Mozilla' };
let n = 0;
const ok = (name) => console.log(`ok ${++n} - ${name}`);

const PUB = 'abcdefghij1', PRIV = 'abcdefghij2';
await put(PUB, { title: 'Démo', duration: 120 });
await env.BUCKET.put(`v/${PUB}.mp4`, 'VIDEO');
await put(PRIV, { title: 'Secret', duration: 60, firstName: 'Julie', company: 'Studio Lumen', password: 'sésame' });
await env.BUCKET.put(`v/${PRIV}.mp4`, 'VIDEO');
await env.BUCKET.put(`t/${PRIV}.jpg`, 'IMG');

// 1. vitesse
// lien avec prénom-agence (2026-10-13) : même page, noms avec majuscule dans l'aperçu
await put(PUB, { firstName: 'khamis', company: 'kuroflow', title: 'Vidéo' });
{ const r = await call(`/v/${PUB}/khamis-kuroflow`, { headers: MOZ }); assert.equal(r.status, 200);
  const t = await r.text(); assert.ok(t.includes('Khamis, une vidéo pour Kuroflow'), 'majuscules dans le titre'); }
assert.equal((await call(`/v/${PUB}/a/b`, { headers: MOZ })).status, 404);
ok('lien /v/<id>/prenom-agence servi, noms en majuscule');
await put(PUB, { firstName: '', company: '' });

let html = await (await call(`/v/${PUB}`, { headers: MOZ })).text();
for (const l of ['×1<', '×1,25', '×1,5', '×2']) assert.ok(html.includes(l), `bouton ${l}`);
assert.ok(html.includes('data-speed="2"') && html.includes('xv-speed'));
ok('boutons de vitesse et mémorisation dans la page');

// 2. commentaires + échappement
const post = (id, body, extra = {}) => call(`/c/${id}`, { method: 'POST', headers: { 'content-type': 'application/json', ...extra }, body: JSON.stringify(body) });
let r = await post(PUB, { t: 42.26, name: 'Léa', text: 'Super passage' });
assert.equal(r.status, 201);
const xss = '<script>alert(1)</script><img src=x onerror=alert(2)>';
assert.equal((await post(PUB, { t: 10, name: '<b>x</b>', text: xss })).status, 201);
const list = await (await call(`/c/${PUB}`)).json();
assert.equal(list.length, 2);
assert.equal(list[0].t, 42.3);
assert.equal(list[1].text, xss);
assert.equal((await (await api(`/api/comments/${PUB}`)).json()).length, 2);
assert.equal((await call(`/api/comments/${PUB}`)).status, 401);
ok('ajout + lecture publique + lecture API privée (jeton requis)');
html = await (await call(`/v/${PUB}`, { headers: MOZ })).text();
assert.ok(!html.includes('<script>alert(1)'), 'pas de script brut dans la page');
assert.ok(!html.includes('<img src=x'), 'pas de balise brute');
assert.ok(html.includes('\\u003cscript>alert(1)'), 'données échappées dans le JSON embarqué');
assert.ok(!/innerHTML\s*=\s*[^'"]*c\.(text|name)/.test(html), 'commentaires jamais injectés en innerHTML');
assert.ok(html.includes('textContent=c.name'));
assert.equal((await call(`/c/${PUB}`)).headers.get('x-content-type-options'), 'nosniff');
ok('HTML échappé / texte inséré via textContent');
assert.equal((await post(PUB, { t: 1, text: 'x'.repeat(1001) })).status, 400);
assert.equal((await post(PUB, { t: 1, text: '   ' })).status, 400);
assert.equal((await post(PUB, { t: 9999, text: 'hors durée' })).status, 400);
assert.equal((await post(PUB, { t: 1, text: 'ok' }, { origin: 'https://evil.example' })).status, 403);
assert.equal((await post(PUB, { t: 10, name: '<b>x</b>', text: xss })).status, 409);
assert.equal((await call(`/c/${PUB}`, { method: 'POST', body: 'x'.repeat(9000) })).status, 413);
let limited = false;
for (let i = 0; i < 600 && !limited; i++) {
  const x = await post(PUB, { t: 5, text: 'c' + i });
  if (x.status === 429) limited = true; else assert.equal(x.status, 201);
}
assert.ok(limited, 'limite de commentaires atteinte');
assert.equal((await call(`/c/${PUB}`).then((x) => x.json())).length, 500);
ok('anti-abus : taille, vide, hors durée, origine, doublon, limite 500');

// 3. lien privé
const metaRaw = JSON.parse(env.BUCKET.m.get(`m/${PRIV}.json`));
assert.match(metaRaw.password, /^pbkdf2:[0-9a-f]{32}:[0-9a-f]{64}$/);
assert.ok(!JSON.stringify(metaRaw).includes('sésame'), 'mot de passe jamais en clair');
const lst = await (await api('/api/list')).json();
assert.ok(lst.every((x) => !('password' in x)) && lst.find((x) => x.id === PRIV).private === true);
ok('mot de passe stocké salé + haché, absent de /api/list');
for (const ua of ['Mozilla', 'facebookexternalhit']) {
  const t = await (await call(`/v/${PRIV}`, { headers: { 'user-agent': ua } })).text();
  assert.ok(t.includes('type="password"'));
  assert.ok(!/Secret|Julie|Lumen|og:image|\/t\/|\/f\//.test(t), 'rien de privé');
}
ok('page privée : demande le mot de passe, ni titre ni miniature (même pour les robots)');
for (const p of [`/f/${PRIV}.mp4`, `/t/${PRIV}.jpg`, `/c/${PRIV}`, `/s/${PRIV}.srt`]) assert.equal((await call(p)).status, 403, p);
assert.equal((await post(PRIV, { t: 1, text: 'non' })).status, 403);
ok('/f /t /c /s refusés sans cookie');
const form = (pw) => call(`/v/${PRIV}`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ pw }) });
assert.equal((await form('faux')).status, 401);
const good = await form('sésame');
assert.equal(good.status, 303);
const ck = good.headers.get('set-cookie');
assert.ok(/HttpOnly/.test(ck) && /SameSite=Lax/.test(ck) && /Secure/.test(ck));
const cookie = ck.split(';')[0];
assert.equal((await call(`/f/${PRIV}.mp4`, { headers: { cookie } })).status, 200);
assert.equal((await call(`/f/${PRIV}.mp4`, { headers: { cookie: cookie.slice(0, -2) + '00' } })).status, 403);
const page = await (await call(`/v/${PRIV}`, { headers: { cookie, ...MOZ } })).text();
assert.ok(page.includes('<video') && page.includes('Julie'));
ok('bon mot de passe -> cookie signé -> vidéo servie ; faux cookie refusé');
await put(PRIV, { password: 'autre' });
assert.equal((await call(`/f/${PRIV}.mp4`, { headers: { cookie } })).status, 403, 'ancien cookie invalidé');
await put(PRIV, { password: '' });
assert.ok(!('password' in JSON.parse(env.BUCKET.m.get(`m/${PRIV}.json`))));
assert.equal((await call(`/f/${PRIV}.mp4`)).status, 200);
ok('changer le mot de passe invalide les cookies ; chaîne vide retire la protection');

// 4. srt
assert.equal((await call(`/s/${PUB}.srt`)).status, 404);
assert.ok(!(await (await call(`/v/${PUB}`, { headers: MOZ })).text()).includes('Télécharger la transcription'));
const SRT = '1\n00:00:00,000 --> 00:00:02,000\nBonjour\n';
assert.equal((await api(`/api/srt/${PUB}`, { method: 'PUT', body: SRT })).status, 200);
assert.equal((await call(`/api/srt/${PUB}`, { method: 'PUT', body: SRT })).status, 401);
const s = await call(`/s/${PUB}.srt`);
assert.equal(s.status, 200);
assert.equal(await s.text(), SRT);
assert.ok((await (await call(`/v/${PUB}`, { headers: MOZ })).text()).includes('Télécharger la transcription'));
ok('srt : envoi par jeton, servi en public, lien affiché sur la page');

await api(`/api/video/${PUB}`, { method: 'DELETE' });
assert.ok(!env.BUCKET.m.has(`c/${PUB}.json`) && !env.BUCKET.m.has(`s/${PUB}.srt`));
ok('suppression de la vidéo efface commentaires et srt');

// 12. fiche Breakcold + date d'envoi (synchro des relances)
r = await put(PUB, { recordId: 'p97c2t193r84zmmhd61qnpktv98fp48w', sentAt: '2026-10-10T10:00:00Z' });
let me = (await (await api('/api/list')).json()).find((x) => x.id === PUB);
assert.equal(me.recordId, 'p97c2t193r84zmmhd61qnpktv98fp48w'); assert.equal(me.sentAt, '2026-10-10T10:00:00.000Z');
await put(PUB, { sentAt: '2026-10-12T10:00:00Z', recordId: 'pas valide !' });
me = (await (await api('/api/list')).json()).find((x) => x.id === PUB);
assert.equal(me.sentAt, '2026-10-10T10:00:00.000Z', 'la 1re date d envoi est gardée'); assert.equal(me.recordId, undefined, 'id invalide refusé');
html = await (await call(`/v/${PUB}`, { headers: MOZ })).text();
assert.ok(!html.includes('p97c2t193r84'), 'id Breakcold jamais dans la page publique');
ok('fiche Breakcold et date d envoi : stockées, validées, jamais publiques');

// vues de Baptiste exclues (2026-10-13) : /moi/<clé> pose un cookie et retient la connexion (IP)
{
  const { createHash } = await import('node:crypto');
  const cle = createHash('sha256').update('tok:moi').digest('hex').slice(0, 24);
  const nb = async () => (await (await api('/api/list?fresh=1')).json()).find((v) => v.id === PUB)?.views || 0;
  const avant = await nb();
  assert.equal((await call(`/moi/${'0'.repeat(24)}`)).status, 404, 'mauvaise clé refusée');
  const r = await call(`/moi/${cle}?v=${PUB}`, { headers: { 'cf-connecting-ip': '1.2.3.4' } });
  assert.equal(r.status, 303); const ck = r.headers.get('set-cookie').split(';')[0];
  await new Promise((ok) => setTimeout(ok, 20));
  await call(`/v/${PUB}`, { headers: { ...MOZ, cookie: ck } });
  await call(`/e/${PUB}?t=p50`, { method: 'POST', headers: { ...MOZ, cookie: ck } });
  await call(`/v/${PUB}`, { headers: { ...MOZ, 'cf-connecting-ip': '1.2.3.4' } });
  await new Promise((ok) => setTimeout(ok, 20));
  assert.equal(await nb(), avant, 'vues et lecture de Baptiste non comptées');
  await call(`/v/${PUB}`, { headers: { ...MOZ, 'cf-connecting-ip': '9.9.9.9' } });
  await new Promise((ok) => setTimeout(ok, 20));
  const v = (await (await api('/api/list?fresh=1')).json()).find((x) => x.id === PUB);
  assert.equal(v.views, avant + 1, 'vue du prospect comptée');
  assert.ok(v.firstView && v.lastView, 'heure de la 1re et de la dernière vue');
  ok('vues de Baptiste exclues (cookie + connexion), vue du prospect comptée et datée');
}
// 13. lien utilisable avant la fin de l'envoi
const EARLY = 'abcdefghij3';
await put(EARLY, { title: 'Pas encore', duration: 90, firstName: 'Léo' });
await env.BUCKET.put(`t/${EARLY}.jpg`, 'IMG');
html = await (await call(`/v/${EARLY}`, { headers: MOZ })).text();
assert.ok(html.includes('Ta vidéo arrive') && html.includes('id="wait"') && html.includes('background-image:url(/t/' + EARLY + '.jpg)'));
assert.ok(/<video id="v"[^>]* hidden>/.test(html) && !html.includes(`src="/f/${EARLY}.mp4"`) && html.includes('poster="/t/'));
assert.ok(html.includes('og:image') && !html.includes('og:video'), 'og:image oui, og:video non');
assert.ok(html.includes(`/r/${EARLY}`) && html.includes('3000'));
let rr = await call(`/r/${EARLY}`);
assert.deepEqual(await rr.json(), { ready: false }); assert.equal(rr.headers.get('cache-control'), 'no-store');
await env.BUCKET.put(`v/${EARLY}.mp4`, 'VIDEO');
assert.deepEqual(await (await call(`/r/${EARLY}`)).json(), { ready: true });
html = await (await call(`/v/${EARLY}`, { headers: MOZ })).text();
assert.ok(!html.includes('id="wait"') && html.includes(`src="/f/${EARLY}.mp4"`) && html.includes('og:video'));
const LOCKED = 'abcdefghij4';
await put(LOCKED, { title: 'x', password: 'pw' });
assert.equal((await call(`/r/${LOCKED}`)).status, 403);
ok('vidéo pas encore arrivée : bloc d attente, /r/<id> no-store, og:video seulement si prête, /r respecte le mot de passe');

// 13b. repli des miniatures (Gmail colle le GIF avant son envoi)
const TH = 'abcdefghij5';
await put(TH, { title: 'th' });
let g = await call(`/t/${TH}.gif`);
assert.equal(g.status, 200); assert.equal(g.headers.get('content-type'), 'image/gif'); assert.equal(g.headers.get('cache-control'), 'no-store');
assert.equal((await call(`/t/${TH}-play.jpg`)).status, 404);
await env.BUCKET.put(`t/${TH}.jpg`, 'JPG');
g = await call(`/t/${TH}.gif`);
assert.equal(await g.text(), 'JPG'); assert.equal(g.headers.get('cache-control'), 'no-store'); assert.equal(g.headers.get('content-type'), 'image/jpeg');
g = await call(`/t/${TH}-play.jpg`);
assert.equal(await g.text(), 'JPG'); assert.equal(g.headers.get('cache-control'), 'no-store');
await env.BUCKET.put(`t/${TH}-play.jpg`, 'PLAY');
assert.equal(await (await call(`/t/${TH}.gif`)).text(), 'PLAY');
g = await call(`/t/${TH}-play.jpg`);
assert.equal(await g.text(), 'PLAY'); assert.equal(g.headers.get('cache-control'), 'public, max-age=86400');
await env.BUCKET.put(`t/${TH}.gif`, 'GIF');
g = await call(`/t/${TH}.gif`);
assert.equal(await g.text(), 'GIF'); assert.equal(g.headers.get('cache-control'), 'public, max-age=86400');
ok('/t gif -> play.jpg -> jpg -> image fixe ; repli en no-store, vrai fichier en cache normal');

// 14. réactions emoji
const RX = 'abcdefghij6';
await put(RX, { title: 'rx', duration: 100 });
await env.BUCKET.put(`v/${RX}.mp4`, 'V');
r = await post(RX, { t: 12.34, emoji: '🔥' });
assert.equal(r.status, 201);
let rl = await r.json();
assert.deepEqual({ ...rl[0], id: 0, at: 0 }, { id: 0, t: 12.3, name: '', text: '', emoji: '🔥', at: 0 });
assert.equal((await post(RX, { t: 5, emoji: '❤' })).status, 201, 'variante sans sélecteur acceptée');
assert.equal((await post(RX, { t: 5, emoji: '💩' })).status, 400);
assert.equal((await post(RX, { t: 5, emoji: '❤️' })).status, 409, 'doublon');
assert.equal((await post(RX, { t: 7, name: 'Zoé', text: 'Un vrai commentaire' })).status, 201);
html = await (await call(`/v/${RX}`, { headers: MOZ })).text();
for (const e of ['👍', '❤️', '😂', '😮', '🔥', '👏']) assert.ok(html.includes(`data-e="${e}"`), e);
assert.ok(html.includes('c.emoji') && html.includes('id="rx"'));
const lr = (await (await api('/api/list?fresh=1')).json()).find((x) => x.id === RX);
assert.equal(lr.reactions, 2); assert.equal(lr.comments, 1);
ok('réactions : stockées dans c/<id>.json, emoji filtré, doublon refusé, comptées par /api/list');

// 15. e-mail avant de regarder
const EM = 'abcdefghij7';
await put(EM, { title: 'Secret perso', duration: 50, firstName: 'Ana', requireEmail: true });
await env.BUCKET.put(`v/${EM}.mp4`, 'V'); await env.BUCKET.put(`t/${EM}.jpg`, 'I');
for (const ua of ['Mozilla', 'facebookexternalhit']) {
  const t = await (await call(`/v/${EM}`, { headers: { 'user-agent': ua } })).text();
  assert.ok(t.includes('ta vidéo t') && t.includes('Laisse ton e-mail') && t.includes('type="email"') && t.includes('Voir la vidéo'));
  assert.ok(t.includes('og:image') && t.includes('Ana, une vidéo pour toi') && !t.includes('<video') && !t.includes('og:video'));
}
assert.equal((await call(`/f/${EM}.mp4`)).status, 403);
assert.equal((await call(`/t/${EM}-play.jpg`)).status, 200, 'miniature publique pour les aperçus');
const emailForm = (email) => call(`/v/${EM}`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ email }) });
assert.equal((await emailForm('pas un mail')).status, 400);
assert.equal(env.BUCKET.m.has(`l/${EM}.json`), false);
const eg = await emailForm('Ana@Studio.fr');
assert.equal(eg.status, 303);
const ec = eg.headers.get('set-cookie');
assert.ok(ec.startsWith(`xv_e_${EM}=`) && /Max-Age=2592000/.test(ec) && /HttpOnly/.test(ec));
await emailForm('ana@studio.fr');
const leads = JSON.parse(env.BUCKET.m.get(`l/${EM}.json`));
assert.equal(leads.length, 1); assert.equal(leads[0].email, 'ana@studio.fr'); assert.ok(leads[0].at && 'lieu' in leads[0]);
const eck = ec.split(';')[0];
html = await (await call(`/v/${EM}`, { headers: { cookie: eck, ...MOZ } })).text();
assert.ok(html.includes('<video') && html.includes('og:video'));
assert.equal((await call(`/f/${EM}.mp4`, { headers: { cookie: eck } })).status, 200);
assert.equal((await call(`/f/${EM}.mp4`, { headers: { cookie: eck.slice(0, -2) + '00' } })).status, 403);
assert.deepEqual((await (await api('/api/list?fresh=1')).json()).find((x) => x.id === EM).emails.map((x) => x.email), ['ana@studio.fr']);
// mot de passe prioritaire sur l'e-mail
await put(EM, { password: 'mdp' });
const t2 = await (await call(`/v/${EM}`, { headers: MOZ })).text();
assert.ok(t2.includes('type="password"') && !t2.includes('type="email"'));
await api(`/api/video/${EM}`, { method: 'DELETE' });
assert.ok(!env.BUCKET.m.has(`l/${EM}.json`));
await put(EM, { title: 'bis', requireEmail: true }); await put(EM, { requireEmail: false });
assert.ok(!('requireEmail' in JSON.parse(env.BUCKET.m.get(`m/${EM}.json`))));
ok('e-mail : porte (aperçu gardé), validation, cookie 30 j, sans doublon, /f fermé, mot de passe prioritaire, suppression');

// 16. résumé et chapitres
const CP = 'abcdefghij8';
await put(CP, { title: 'cp', duration: 200, summary: '  <b>Voici</b> le résumé ' + 'x'.repeat(700),
  chapters: [{ t: 42, title: 'Le portail <i>client</i>' }, { t: 0, title: 'Intro' }, { t: -1, title: 'non' }, { t: 5, title: '   ' }, { t: 'a', title: 'non' }, { t: 100, title: 'y'.repeat(120) }] });
const cm = JSON.parse(env.BUCKET.m.get(`m/${CP}.json`));
assert.equal(cm.summary.length, 600); assert.deepEqual(cm.chapters.map((c) => c.t), [0, 42, 100]); assert.equal(cm.chapters[2].title.length, 80);
await put(CP, { chapters: Array.from({ length: 40 }, (_, i) => ({ t: i, title: 'c' + i })) });
assert.equal(JSON.parse(env.BUCKET.m.get(`m/${CP}.json`)).chapters.length, 30);
await put(CP, { summary: '  <b>Voici</b> le résumé', chapters: [{ t: 42, title: 'Le portail <i>client</i>' }, { t: 0, title: 'Intro' }] });
html = await (await call(`/v/${CP}`, { headers: MOZ })).text();
assert.ok(html.includes('class="sum"') && html.includes('&lt;b&gt;Voici&lt;/b&gt;') && !html.includes('<b>Voici'));
assert.ok(html.includes('<b>0:42</b><span>Le portail &lt;i&gt;client&lt;/i&gt;</span>') && html.includes('data-t="42"'));
assert.ok(html.indexOf('id="chap"') > html.indexOf('id="speed"'), 'chapitres sous la vitesse');
const plain = await (await call(`/v/${PUB}`, { headers: MOZ })).text();
assert.ok(!plain.includes('class="sum"') && !plain.includes('id="chap"'), 'rien si vides');
await put(CP, { summary: '', chapters: [] });
html = await (await call(`/v/${CP}`, { headers: MOZ })).text();
assert.ok(!html.includes('class="sum"') && !html.includes('id="chap"'));
ok('résumé et chapitres : nettoyés, bornés, échappés, absents si vides');

// 17. /api/list rapide (cache 20 s des totaux)
const SP = 'abcdefghij0';
await put(SP, { title: 'sp' });
await api('/api/list?fresh=1');
await env.BUCKET.put(`e/${SP}/${Date.now()}-view-aaaaaa`, '');
let sp = (await (await api('/api/list')).json()).find((x) => x.id === SP);
assert.equal(sp.views, 0, 'servi depuis le cache');
const agg = JSON.parse(env.BUCKET.m.get('agg/stats.json'));
agg.at -= 25000; env.BUCKET.m.set('agg/stats.json', JSON.stringify(agg));
sp = (await (await api('/api/list')).json()).find((x) => x.id === SP);
assert.equal(sp.views, 1, 'recalculé après 20 s');
ok('/api/list : totaux en cache 20 s (agg/stats.json), recalcul après, ?fresh=1 force');

// 21. revue sécurité du 2026-10-26
{
  // sous-titres et commentaires fermés tant que l'e-mail demandé n'est pas laissé
  const G = 'abcdefghsec1';
  await put(G, { title: 'g', requireEmail: true });
  await env.BUCKET.put(`s/${G}.srt`, '1\n00:00:00,000 --> 00:00:01,000\nsecret\n');
  for (const q of [`/s/${G}.srt`, `/c/${G}`]) assert.equal((await call(q)).status, 403, q);
  assert.equal((await post(G, { t: 1, text: 'non' })).status, 403);
  // ancien mot de passe (sel:sha256) toujours accepté
  const L = 'abcdefghsec2';
  await put(L, { title: 'l' });
  const salt = '00112233445566778899aabbccddeeff';
  const h = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(salt + 'ancien')))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const mm = JSON.parse(env.BUCKET.m.get(`m/${L}.json`)); mm.password = `${salt}:${h}`; env.BUCKET.m.set(`m/${L}.json`, JSON.stringify(mm));
  const pw = (id, v, ip = '1.1.1.1') => call(`/v/${id}`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', 'cf-connecting-ip': ip }, body: new URLSearchParams({ pw: v }) });
  assert.equal((await pw(L, 'ancien')).status, 303, 'ancien format lu');
  // 10 essais ratés par connexion -> bloqué, même avec le bon mot de passe ; une autre connexion passe encore
  const R = 'abcdefghsec3';
  await put(R, { title: 'r', password: 'bon' });
  for (let i = 0; i < 10; i++) assert.equal((await pw(R, 'faux' + i)).status, 401);
  const bl = await pw(R, 'bon');
  assert.equal(bl.status, 429); assert.ok((await bl.text()).includes('Trop d'));
  assert.equal((await pw(R, 'bon', '2.2.2.2')).status, 303);
  // au-delà de 50 essais sur la vidéo : les connexions qui ont raté sont bloquées, un nouveau destinataire passe encore
  const T = 'abcdefghsec4';
  await put(T, { title: 't', password: 'bon' });
  for (let i = 0; i < 50; i++) await pw(T, 'x', `9.9.${Math.floor(i / 5)}.${i % 5}`);
  assert.equal((await pw(T, 'bon', '9.9.0.0')).status, 429, 'connexion qui a raté bloquée');
  assert.equal((await pw(T, 'bon', '7.7.7.7')).status, 303, 'vrai destinataire jamais bloqué par les autres');
  // 20 essais simultanés depuis la même connexion : 10 comptés au plus, aucun ne se perd
  const S = 'abcdefghsec5';
  await put(S, { title: 's', password: 'bon' });
  const rs = await Promise.all(Array.from({ length: 20 }, (_, i) => pw(S, 'z' + i, '5.5.5.5')));
  assert.ok(rs.filter((r) => r.status === 401).length <= 10, 'jamais plus de 10 essais testés');
  assert.ok(JSON.parse(env.BUCKET.m.get(`lk/${S}.json`)).ips['5.5.5.5'] <= 10);
  // la fenêtre de 15 min passée, on peut réessayer
  const lk = JSON.parse(env.BUCKET.m.get(`lk/${T}.json`)); lk.since -= 16 * 60000; env.BUCKET.m.set(`lk/${T}.json`, JSON.stringify(lk));
  assert.equal((await pw(T, 'bon', '9.9.0.0')).status, 303);
  await api(`/api/video/${T}`, { method: 'DELETE' });
  assert.ok(!env.BUCKET.m.has(`lk/${T}.json`), 'compteur effacé avec la vidéo');
  // statistiques : vidéo inconnue refusée, vidéo privée ou à e-mail refusée sans cookie
  const nbEv = (id) => [...env.BUCKET.m.keys()].filter((k) => k.startsWith(`e/${id}/`)).length;
  assert.equal((await call(`/e/abcdefghzzzz?t=play`, { method: 'POST', headers: MOZ })).status, 404);
  assert.equal(nbEv('abcdefghzzzz'), 0);
  assert.equal((await call(`/e/${R}?t=play`, { method: 'POST', headers: MOZ })).status, 403);
  assert.equal((await call(`/e/${G}?t=play`, { method: 'POST', headers: MOZ })).status, 403);
  assert.equal(nbEv(R) + nbEv(G), 0);
}
ok('sécurité : /s et /c fermés sans e-mail, PBKDF2 + ancien format lu, 10 essais/connexion, 50/vidéo sans bloquer un nouveau destinataire, compteur atomique, stats refusées sur vidéo inconnue ou fermée');
console.log(`\n${n} groupes OK`);
