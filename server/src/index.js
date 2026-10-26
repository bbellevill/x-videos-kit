// X-Videos : page de lecture publique (/v/<id>), fichiers (/f, /t) et API privée (/api, jeton Bearer).
// Objets R2 : v/<id>.mp4 (vidéo 1080p), t/<id>.jpg (miniature), t/<id>-play.jpg (miniature + bouton lecture),
// m/<id>.json (titre, durée, date, vues, mot de passe haché, résumé, chapitres, requireEmail), c/<id>.json (commentaires + réactions emoji horodatés),
// l/<id>.json (e-mails laissés avant de regarder), s/<id>.srt (transcription), agg/stats.json (cache 20 s des totaux de /api/list).
const ID = '([a-z0-9]{10,32})';
const BOTS = /bot|crawl|spider|facebookexternalhit|linkedin|slack|whatsapp|telegram|discord|preview|google|bing|embedly|skype|outlook|curl/i;

export default {
  async fetch(req, env, ctx) {
    B = brand(env);
    const url = new URL(req.url);
    const p = url.pathname;
    let m;
    if (p.startsWith('/api/')) {
      if (req.headers.get('authorization') !== `Bearer ${env.UPLOAD_TOKEN}`) return new Response('Non autorisé', { status: 401 });
      return api(req, env, url);
    }
    // /moi/<clé> (2026-10-13) : marque cet appareil (cookie) et cette connexion (IP) comme ceux de Baptiste : ses vues ne comptent plus
    if ((m = p.match(/^\/moi\/([a-f0-9]{24})$/))) return moi(req, env, ctx, m[1], url);
    // /v/<id>/<prenom-agence> (2026-10-13) : le nom du prospect se lit dans le lien collé (LinkedIn ne colle que le texte) ; la fin est ignorée
    if ((m = p.match(new RegExp(`^/v/${ID}(?:/[a-z0-9-]{1,80})?$`)))) return watch(req, env, ctx, m[1], url);
    if ((m = p.match(new RegExp(`^/e/${ID}$`))) && req.method === 'POST') return track(req, env, ctx, m[1], url);
    if ((m = p.match(new RegExp(`^/f/${ID}\\.mp4$`)))) return guarded(req, env, m[1], () => file(req, env, `v/${m[1]}.mp4`, 'video/mp4'), true);
    if ((m = p.match(new RegExp(`^/r/${ID}$`)))) return guarded(req, env, m[1], () => ready(env, m[1]));
    if ((m = p.match(new RegExp(`^/t/${ID}(-play)?\\.jpg$`)))) return guarded(req, env, m[1], () => thumb(req, env, m[1], m[2] ? 'play' : 'jpg'));
    if ((m = p.match(new RegExp(`^/t/${ID}\\.gif$`)))) return guarded(req, env, m[1], () => thumb(req, env, m[1], 'gif'));
    if ((m = p.match(new RegExp(`^/s/${ID}\\.srt$`)))) return guarded(req, env, m[1], () => srt(env, m[1]), true);
    if ((m = p.match(new RegExp(`^/c/${ID}$`)))) return guarded(req, env, m[1], () => comments(req, env, m[1], url), true);
    if (p === '/') return Response.redirect(B.site, 302);
    return new Response('Vidéo introuvable', { status: 404 });
  },
};

async function readMeta(env, id) {
  const o = await env.BUCKET.get(`m/${id}.json`);
  return o ? await o.json() : null;
}
const writeMeta = (env, id, meta) =>
  env.BUCKET.put(`m/${id}.json`, JSON.stringify(meta), { httpMetadata: { contentType: 'application/json' } });
const json = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json' } });

// --- Liens privés : mot de passe salé haché (SHA-256) dans la méta, cookie signé (HMAC) pour débloquer ---
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
const sha256 = async (s) => hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
// PBKDF2 100 000 tours (plafond de Cloudflare Workers) : « pbkdf2:sel:hash ». L'ancien « sel:hash » SHA-256 reste lu.
const PBKDF2_ITER = 100000;
async function pbkdf2(salt, pw) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(pw), 'PBKDF2', false, ['deriveBits']);
  return hex(await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: new TextEncoder().encode(salt), iterations: PBKDF2_ITER }, key, 256));
}
async function hashPassword(pw) {
  const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
  return `pbkdf2:${salt}:${await pbkdf2(salt, pw)}`;
}
function same(a, b) { // comparaison en temps constant
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function checkPassword(meta, pw) {
  const parts = String(meta.password || '').split(':');
  if (parts[0] === 'pbkdf2') return !!parts[2] && same(parts[2], await pbkdf2(parts[1], pw));
  const [salt, h] = parts;
  return !!h && same(h, await sha256(salt + pw));
}
// Essais de mot de passe (2026-10-26, revue sécurité) : chaque essai est compté AVANT de tester le mot de passe, par écriture
// conditionnelle R2 (etag) : deux essais simultanés ne peuvent pas lire le même compteur. 10 essais par connexion par quart d'heure ;
// au-delà de 50 essais sur la vidéo, seules les connexions qui ont déjà raté sont bloquées (un vrai destinataire passe toujours).
const PW_WINDOW = 15 * 60000, PW_MAX_IP = 10, PW_MAX_ALL = 50;
async function pwAttempt(env, id, req) {
  const ip = ipDe(req) || '?', key = `lk/${id}.json`;
  for (let i = 0; i < 5; i++) {
    const o = await env.BUCKET.get(key);
    let f = (o && (await o.json().catch(() => null))) || null;
    if (!f || !f.since || Date.now() - f.since >= PW_WINDOW) f = { since: Date.now(), all: 0, ips: {} };
    const mine = f.ips[ip] || 0;
    if (mine >= PW_MAX_IP || (f.all >= PW_MAX_ALL && mine > 0)) return false;
    f.all += 1; f.ips[ip] = mine + 1;
    const done = await env.BUCKET.put(key, JSON.stringify(f), { httpMetadata: { contentType: 'application/json' },
      onlyIf: o ? { etagMatches: o.etag } : { etagDoesNotMatch: '*' } });
    if (done) return true;
  }
  return false; // trop d'essais simultanés : refusé
}
async function hmac(env, msg) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(`xv:${env.COOKIE_SECRET || env.UPLOAD_TOKEN}`), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg)));
}
// lié au hash du mot de passe : changer le mot de passe invalide les anciens cookies
const sign = (env, id, meta) => hmac(env, `${id}.${meta.password}`);
// cookie « e-mail laissé » : xv_e_<id>
const emailCookie = (id) => `xv_e_${id}`;
async function emailOk(req, env, id, meta) {
  if (!meta?.requireEmail) return true;
  const c = (req.headers.get('cookie') || '').split(/;\s*/).find((x) => x.startsWith(emailCookie(id) + '='));
  return !!c && same(c.slice(emailCookie(id).length + 1), await hmac(env, `${id}.email`));
}
const cookieName = (id) => `xv_${id}`;
async function unlocked(req, env, id, meta) {
  if (!meta?.password) return true;
  const c = (req.headers.get('cookie') || '').split(/;\s*/).find((x) => x.startsWith(cookieName(id) + '='));
  return !!c && same(c.slice(cookieName(id).length + 1), await sign(env, id, meta));
}
// Fichiers annexes (/f, /t, /s, /c, /r) : refusés sans cookie valide si la vidéo est privée.
// La vidéo (/f), les sous-titres (/s) et les commentaires (/c) sont aussi refusés tant que l'e-mail demandé n'a pas été laissé ;
// les miniatures restent publiques (aperçus).
async function guarded(req, env, id, next, gateEmail = false) {
  const meta = await readMeta(env, id);
  if (meta?.password && !(await unlocked(req, env, id, meta))) return new Response('Lien privé', { status: 403, headers: { 'cache-control': 'no-store' } });
  if (gateEmail && !(await emailOk(req, env, id, meta))) return new Response('E-mail requis', { status: 403, headers: { 'cache-control': 'no-store' } });
  const r = await next();
  if (meta?.password) { r.headers.set('cache-control', 'private, no-store'); }
  return r;
}
const publicMeta = ({ password, ...m }) => ({ ...m, private: !!password }); // le hash ne sort jamais

// --- Miniatures avec repli : l'app colle le GIF / l'image dans Gmail avant la fin de l'envoi.
// gif -> play.jpg -> jpg -> image fixe (rond violet + triangle blanc) ; play.jpg -> jpg. Tout repli est en no-store (le proxy d'images de Gmail ne le garde pas).
const PLACEHOLDER = Uint8Array.from(atob('R0lGODdh4AEOAYIAAI5z9ko3jwsKDAoKDAoKCwoKCgkKCgQGAiwAAAAA4AEOAUAI/wAJCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJsqXLlzBjypxJs6bNmzhz6tzJs6fPn0CDCh1KtKjRo0iTKl3KtKnTp1CjSp1KtarVq1izat3KtavXr2DDih1LtqzZs2hTChBg4MABAQHiAphLt67du3EFuH0rYEDav4ADC2R7IMDdw4gTK15sN4BeAYIjS3bKVgDjy5gza677eLLnzzj1Gt5MurTpxAHegl7N+qTo07BjywbA1m/r27gvvp7Nu3fm1JBzCx/OcIABy76TK0fcmbjz5wMHvF1OfTlw6Nix767O3XTt7ODBb//vTv7w9/Do0w8uXN76AQLB1cuff1CvgdHtETvmS7+/f41rBWhAW3sVOGCAa9n234IMNujggxBGKOGEFFZo4YUYZqjhhhx26OGHIIYo4ogklmjiiSimqOKKLLbo4oswxijjjDTWaOONOOao44489ujjj0AGKeSQRHLV1wBI9lXkkjKt5RZ++c2131pMVunQeFHClhqSVg5pHHJZltdclzY+FuaZdF1HZoz3oekmZwcouCaKX75pJ11jznkilneGeZ6edE7XZ5hqAspinYN2l6ehMVaW6GyLMsqjmY8etmV8kgK6VltwQclbXm5RmemopJZq6qmopqrqqqy26uqrsMb/KuustNZq66245qrrrrz26uuvwAYr7LDEFmvsscgmq+yyzDbr7LPQRivttNRWa+212Gar7bbcduvtt+CGm2GAxhV4wHEIOmluAQGKS6IABYTqaXKgHienuw8+Ni+aU2KKb3qUVmrpW/f+K1zAAl9WqMGs8Znwb6oxPBnCD2sZscRpOVyxxf5iHBaiGyu3sMdeaRzybCOTrBXFJ9N7scors9dydX/CfBXIMy8Xqc1TDcBuzjS/zHNVJgN9WspDU1W00aQRUEDSWy3NtMJCQ43Vz1N7V7XVWOGcNWM7cx21zF8P3LHYYUl9MtJol4Uk2S2ndlzboOkF96BT0u0cYXBF/7kff3rLN8CmbqEb176NHd7XXu0G7vjjkEcu+eSUV2755ZhnrvnmnHfu+eeghy766KSXbvrpqKeu+uqst+7667DHLvvstNdu++2456777rz37vvvwAcv/PDEF2/88cgnr/zyzDfv/PPQRy/99NRXb/312Gev/fbcd+/99+CHL/745F+fbl8Dpm8Au+mWD1SAexl++L7zJ8i4qO7HNLjdnfoG6gHsy59KnDQAubRnP3MToEj4hrj8pGZrCqzI4sCUKLmdLYIP0VfIwobBhLBsY8ApWAcLoraEsa2DHzTaCQVYwpZVZoQpLNsKw9dCFRqAACKk4d3KxhwD5LB7PhsAD/8zw8Ht1ZCHNfPeEYeYRCPucIiMmSH1pENBKELsgtZbohW3BMTjWFFrWJyeFr8oReiN8YtNtF6bvlgavfwwel5jIxEhKL04yvEyRYSeHe+4mDya8Yl8TEwaqXdGKJbxeTEMZGPoSL2nKRKPcepeIWXIyOpNMmtu/B4VH6mfSmYRkIE8pCVBKUdRfrKBZPSkE1E5RFNmL5GUDKP4LlmpQboPljlzpQ5ZGbItvTGCg1sj0ByTwBEmZHCkfNSljJnBt/DSTY/5JTPro0G8nUuW02QIZJzJL/tgM5sQUVffuvM3/IHzI4RzpgGP9jd0nVMl+5NOgc53vnU17p01SRI9uYRDz376858ADahAB0rQghr0oAhNqEIXytCGOvShEI2oRCdK0Ypa9KIYzahGN8rRjnr0oyANqUhHStKSmvSkKE2pSsUVEAA7'), (c) => c.charCodeAt(0));
const THUMBS = { gif: [['t/ID.gif', 'image/gif'], ['t/ID-play.jpg', 'image/jpeg'], ['t/ID.jpg', 'image/jpeg']], play: [['t/ID-play.jpg', 'image/jpeg'], ['t/ID.jpg', 'image/jpeg']], jpg: [['t/ID.jpg', 'image/jpeg']] };
async function thumb(req, env, id, kind) {
  const c = THUMBS[kind];
  for (let i = 0; i < c.length; i++) {
    const key = c[i][0].replace('ID', id);
    if (!(await env.BUCKET.head(key))) continue;
    const r = await file(req, env, key, c[i][1]);
    if (i) r.headers.set('cache-control', 'no-store'); // repli
    return r;
  }
  if (kind === 'gif') return new Response(PLACEHOLDER, { headers: { 'content-type': 'image/gif', 'cache-control': 'no-store', 'content-length': String(PLACEHOLDER.length) } });
  return new Response('Introuvable', { status: 404 });
}

// --- Vidéo prête ? Le lien est copié avant la fin de l'envoi : la page interroge /r/<id> toutes les 3 s ---
async function ready(env, id) {
  return new Response(JSON.stringify({ ready: !!(await env.BUCKET.head(`v/${id}.mp4`)) }), { headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
}

// --- Transcription : s/<id>.srt ---
async function srt(env, id) {
  const o = await env.BUCKET.get(`s/${id}.srt`);
  if (!o) return new Response('Introuvable', { status: 404 });
  return new Response(o.body, { headers: { 'content-type': 'application/x-subrip; charset=utf-8', 'content-disposition': `attachment; filename="transcription-${id}.srt"`, 'x-content-type-options': 'nosniff' } });
}

// --- Commentaires et réactions horodatés : c/<id>.json = tableau [{id, t, name, text, at}] (+ emoji pour une réaction) ---
const EMOJIS = ['👍', '❤️', '😂', '😮', '🔥', '👏'];
const emojiOf = (e) => EMOJIS.find((x) => x.replace(/\uFE0F/g, '') === String(e ?? '').replace(/\uFE0F/g, ''));
const MAX_COMMENTS = 500, MAX_TEXT = 1000, MAX_NAME = 40;
const clean = (s) => String(s ?? '').replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').trim();
async function readComments(env, id) {
  const o = await env.BUCKET.get(`c/${id}.json`);
  const a = o ? await o.json() : [];
  return Array.isArray(a) ? a : [];
}
async function comments(req, env, id, url) {
  const nosniff = { 'x-content-type-options': 'nosniff', 'cache-control': 'no-store' };
  if (req.method === 'GET') return new Response(JSON.stringify(await readComments(env, id)), { headers: { 'content-type': 'application/json', ...nosniff } });
  if (req.method !== 'POST') return json({ error: 'méthode non permise' }, 405);
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== url.host) return json({ error: 'origine refusée' }, 403);
  const raw = await req.text();
  if (raw.length > 8000) return json({ error: 'trop long' }, 413);
  let b;
  try { b = JSON.parse(raw); } catch { return json({ error: 'JSON invalide' }, 400); }
  const emoji = b?.emoji === undefined || b?.emoji === '' ? '' : emojiOf(b.emoji);
  if (emoji === undefined) return json({ error: 'emoji non permis' }, 400);
  const text = emoji ? '' : clean(b?.text).slice(0, MAX_TEXT + 1);
  if (!text && !emoji) return json({ error: 'commentaire vide' }, 400);
  if (text.length > MAX_TEXT) return json({ error: `max ${MAX_TEXT} caractères` }, 400);
  const meta = await readMeta(env, id);
  if (!meta) return json({ error: 'vidéo introuvable' }, 404);
  const t = Number(b?.t);
  if (!Number.isFinite(t) || t < 0 || t > (meta.duration ? meta.duration + 1 : 86400)) return json({ error: 'seconde invalide' }, 400);
  const list = await readComments(env, id);
  if (list.length >= MAX_COMMENTS) return json({ error: 'limite de commentaires atteinte' }, 429);
  const name = emoji ? '' : clean(b?.name).slice(0, MAX_NAME);
  const last = list[list.length - 1];
  if (last && last.text === text && last.name === name && (last.emoji || '') === emoji && last.t === Math.round(t * 10) / 10) return json({ error: 'doublon' }, 409);
  const item = { id: Math.random().toString(36).slice(2, 10), t: Math.round(t * 10) / 10, name, text };
  if (emoji) item.emoji = emoji;
  list.push({ ...item, at: new Date().toISOString() });
  await env.BUCKET.put(`c/${id}.json`, JSON.stringify(list), { httpMetadata: { contentType: 'application/json' } });
  return json(list, 201);
}

async function api(req, env, url) {
  const [, action, id] = url.pathname.split('/').filter(Boolean); // ["api", action, id]
  if (id && !new RegExp(`^${ID}$`).test(id)) return json({ error: 'id invalide' }, 400);
  const key = `v/${id}.mp4`;

  if (action === 'list' && req.method === 'GET') {
    const out = [];
    let cursor;
    do {
      const l = await env.BUCKET.list({ prefix: 'm/', cursor });
      for (const o of l.objects) {
        const meta = await (await env.BUCKET.get(o.key))?.json();
        if (meta) out.push(publicMeta(meta));
      }
      cursor = l.truncated ? l.cursor : undefined;
    } while (cursor);
    const st = await stats(env, url.searchParams.get('fresh') === '1');
    // anciennes vues stockées dans la méta (avant le journal d'événements) + événements
    return json(out.map((m) => {
      const s = st[m.id] || {};
      return { ...m, views: (m.views || 0) + (s.views || 0), plays: (m.plays || 0) + (s.plays || 0),
        pct: Math.max(m.pct || 0, s.pct || 0), ctaClicks: (m.ctaClicks || 0) + (s.ctaClicks || 0),
        lastView: [m.lastView, s.lastView].filter(Boolean).sort().pop() || null, lastCta: s.lastCta || m.lastCta || null,
        firstView: s.firstView || m.lastView || null, lieu: s.lieu || null,
        reactions: s.reactions || 0, comments: s.comments || 0, emails: s.emails || [] };
    }));
  }
  if (action === 'create' && req.method === 'POST') {
    const mpu = await env.BUCKET.createMultipartUpload(key, { httpMetadata: { contentType: 'video/mp4' } });
    return json({ uploadId: mpu.uploadId });
  }
  if (action === 'part' && req.method === 'PUT') {
    const mpu = env.BUCKET.resumeMultipartUpload(key, url.searchParams.get('uploadId'));
    return json(await mpu.uploadPart(Number(url.searchParams.get('n')), req.body));
  }
  if (action === 'complete' && req.method === 'POST') {
    const mpu = env.BUCKET.resumeMultipartUpload(key, url.searchParams.get('uploadId'));
    const { parts } = await req.json();
    await mpu.complete(parts);
    return json({ ok: true });
  }
  if (action === 'thumb' && req.method === 'PUT') {
    if (url.searchParams.get('gif')) {
      await env.BUCKET.put(`t/${id}.gif`, req.body, { httpMetadata: { contentType: 'image/gif' } });
      return json({ ok: true });
    }
    const suffix = url.searchParams.get('play') ? '-play' : '';
    await env.BUCKET.put(`t/${id}${suffix}.jpg`, req.body, { httpMetadata: { contentType: 'image/jpeg' } });
    return json({ ok: true });
  }
  if (action === 'meta' && req.method === 'PUT') {
    const old = (await readMeta(env, id)) || { id, views: 0, lastView: null };
    const body = await req.json();
    const meta = {
      ...old,
      id,
      title: String(body.title ?? old.title ?? 'Vidéo').slice(0, 200),
      duration: body.duration ?? old.duration,
      created: body.created ?? old.created,
      firstName: body.firstName !== undefined ? String(body.firstName).slice(0, 60) : old.firstName,
      company: body.company !== undefined ? String(body.company).slice(0, 80) : old.company,
    };
    // fiche Breakcold du prospect et date d'envoi du lien : servent à la synchro des relances (10/10)
    if (body.recordId !== undefined) {
      if (body.recordId && /^[a-z0-9]{10,40}$/.test(body.recordId)) meta.recordId = body.recordId; else delete meta.recordId;
    }
    if (body.sentAt !== undefined && !old.sentAt && !Number.isNaN(Date.parse(body.sentAt))) meta.sentAt = new Date(body.sentAt).toISOString();
    // password : texte en clair reçu une seule fois, stocké haché ; chaîne vide = protection retirée
    if (body.password !== undefined) {
      const pw = String(body.password).slice(0, 200);
      if (pw) meta.password = await hashPassword(pw);
      else delete meta.password;
    }
    // demander l'e-mail avant de regarder (booléen)
    if (body.requireEmail !== undefined) { if (body.requireEmail === true) meta.requireEmail = true; else delete meta.requireEmail; }
    // résumé (≤ 600 car.) et chapitres (≤ 30, triés, titres ≤ 80 car.) ; vide = retiré
    if (body.summary !== undefined) { const t = clean(body.summary).slice(0, 600); if (t) meta.summary = t; else delete meta.summary; }
    if (body.chapters !== undefined) {
      const ch = (Array.isArray(body.chapters) ? body.chapters : []).map((c) => ({ t: Math.round(Number(c?.t) * 10) / 10, title: clean(c?.title).slice(0, 80) }))
        .filter((c) => Number.isFinite(c.t) && c.t >= 0 && c.title).sort((a, b) => a.t - b.t).slice(0, 30);
      if (ch.length) meta.chapters = ch; else delete meta.chapters;
    }
    await writeMeta(env, id, meta);
    return json(publicMeta(meta));
  }
  if (action === 'comments' && req.method === 'GET') return json(await readComments(env, id));
  if (action === 'srt' && req.method === 'PUT') {
    const txt = await req.text();
    if (!txt.trim() || txt.length > 2_000_000) return json({ error: 'srt vide ou trop gros' }, 400);
    await env.BUCKET.put(`s/${id}.srt`, txt, { httpMetadata: { contentType: 'application/x-subrip; charset=utf-8' } });
    return json({ ok: true });
  }
  if (action === 'video' && req.method === 'DELETE') {
    await env.BUCKET.delete([key, `t/${id}.jpg`, `t/${id}-play.jpg`, `t/${id}.gif`, `m/${id}.json`, `c/${id}.json`, `l/${id}.json`, `s/${id}.srt`, `lk/${id}.json`]);
    const ev = await env.BUCKET.list({ prefix: `e/${id}/` });
    if (ev.objects.length) await env.BUCKET.delete(ev.objects.map((o) => o.key));
    return json({ ok: true });
  }
  return json({ error: 'action inconnue' }, 404);
}

// Sert un fichier R2 avec prise en charge des requêtes partielles (Range), indispensable à la lecture vidéo sur Safari.
async function file(req, env, key, type) {
  const r = (req.headers.get('range') || '').match(/bytes=(\d*)-(\d*)/);
  const opts = {};
  if (r) {
    if (r[1] !== '') opts.range = r[2] !== '' ? { offset: +r[1], length: +r[2] - +r[1] + 1 } : { offset: +r[1] };
    else if (r[2] !== '') opts.range = { suffix: +r[2] };
  }
  const obj = await env.BUCKET.get(key, opts);
  if (!obj) return new Response('Introuvable', { status: 404 });
  const h = new Headers({ 'content-type': type, 'accept-ranges': 'bytes', 'cache-control': 'public, max-age=86400', etag: obj.httpEtag });
  if (opts.range) {
    const off = opts.range.suffix !== undefined ? obj.size - opts.range.suffix : opts.range.offset;
    const len = opts.range.length ?? obj.size - off;
    h.set('content-range', `bytes ${off}-${off + len - 1}/${obj.size}`);
    h.set('content-length', String(len));
    return new Response(obj.body, { status: 206, headers: h });
  }
  h.set('content-length', String(obj.size));
  return new Response(obj.body, { headers: h });
}

// Suivi léger : lecture, 25/50/75/100 % regardés, clic sur « Réserver ». Les robots ne comptent pas.
// Chaque événement est un objet séparé : deux événements simultanés ne peuvent plus s'écraser.
// la fin de la clé porte le pays et la ville du visiteur (savoir que c'est bien le prospect, et quand relancer)
const lieu = (req) => {
  const cf = (req && req.cf) || {};
  const ville = String(cf.city || '').normalize('NFD').replace(/[^A-Za-z]/g, '').slice(0, 24);
  return `${String(cf.country || '').replace(/[^A-Z]/g, '').slice(0, 2)}-${ville}`;
};
const logEvent = (env, id, type, req) =>
  env.BUCKET.put(`e/${id}/${Date.now()}-${type}-${Math.random().toString(36).slice(2, 8)}-${lieu(req)}`, '');

// Vues de Baptiste exclues (2026-10-13) : cookie posé par /moi/<clé>, ou IP vue avec ce cookie depuis moins de 30 jours.
const moiCle = async (env) => (await sha256(`${env.UPLOAD_TOKEN}:moi`)).slice(0, 24);
const ipDe = (req) => req.headers.get('cf-connecting-ip') || '';
async function estMoi(req, env) {
  const c = (req.headers.get('cookie') || '').split(/;\s*/).find((x) => x.startsWith('xv_moi='));
  if (c && same(c.slice(7), await moiCle(env))) return true;
  const ip = ipDe(req);
  if (!ip) return false;
  const ips = (await (await env.BUCKET.get('moi/ips.json'))?.json().catch(() => ({}))) || {};
  return !!ips[ip] && Date.now() - ips[ip] < 30 * 86400000;
}
async function retenirIp(req, env) {
  const ip = ipDe(req);
  if (!ip) return;
  const ips = (await (await env.BUCKET.get('moi/ips.json'))?.json().catch(() => ({}))) || {};
  if (ips[ip] && Date.now() - ips[ip] < 86400000) return; // une écriture par jour au plus
  const now = Date.now();
  for (const k of Object.keys(ips)) if (now - ips[k] > 30 * 86400000) delete ips[k];
  ips[ip] = now;
  await env.BUCKET.put('moi/ips.json', JSON.stringify(ips));
}
async function moi(req, env, ctx, cle, url) {
  if (!same(cle, await moiCle(env))) return new Response('Introuvable', { status: 404 });
  ctx.waitUntil(retenirIp(req, env));
  const v = url.searchParams.get('v') || '';
  const secure = url.protocol === 'https:' ? '; Secure' : '';
  const headers = { 'cache-control': 'no-store', 'set-cookie': `xv_moi=${cle}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax${secure}` };
  if (new RegExp(`^${ID}$`).test(v)) return new Response(null, { status: 303, headers: { ...headers, location: `/v/${v}` } });
  return new Response('<!doctype html><meta charset="utf-8"><title>X-Videos</title><body style="font:16px system-ui;background:#0a0a0b;color:#fff;padding:24px">Cet appareil est reconnu : tes vues ne comptent plus dans les statistiques.', { headers: { ...headers, 'content-type': 'text/html; charset=utf-8' } });
}

// Anti-rafale (cache du centre Cloudflare) : le même événement depuis la même connexion n'est compté qu'une fois par 10 s.
async function rafale(id, type, req) {
  if (typeof caches === 'undefined' || !caches.default) return false;
  const k = new Request(`https://rl.invalid/${id}/${type}/${encodeURIComponent(ipDe(req) || '?')}`);
  if (await caches.default.match(k)) return true;
  await caches.default.put(k, new Response('1', { headers: { 'cache-control': 'max-age=10' } }));
  return false;
}
async function track(req, env, ctx, id, url) {
  if (BOTS.test(req.headers.get('user-agent') || '')) return new Response(null, { status: 204 });
  const type = url.searchParams.get('t') || '';
  if (!/^(play|p25|p50|p75|p100|cta|site|rdv)$/.test(type)) return new Response(null, { status: 400 });
  const meta = await readMeta(env, id);
  if (!meta) return new Response(null, { status: 404 });
  if (!(await unlocked(req, env, id, meta)) || !(await emailOk(req, env, id, meta))) return new Response(null, { status: 403 });
  if (await estMoi(req, env)) { ctx.waitUntil(retenirIp(req, env)); return new Response(null, { status: 204 }); }
  if (await rafale(id, type, req)) return new Response(null, { status: 204 });
  ctx.waitUntil(logEvent(env, id, type, req));
  return new Response(null, { status: 204 });
}

// Totaux par vidéo (événements + nombre de réactions / commentaires + e-mails), mis en cache 20 s dans agg/stats.json
// pour que des appels rapprochés de /api/list ne relisent pas tout. ?fresh=1 force le recalcul.
const STATS_TTL = 20000;
async function stats(env, fresh) {
  if (!fresh) {
    const c = await (await env.BUCKET.get('agg/stats.json'))?.json().catch(() => null);
    if (c && Date.now() - c.at < STATS_TTL) return c.data;
  }
  const data = await computeStats(env);
  await env.BUCKET.put('agg/stats.json', JSON.stringify({ at: Date.now(), data }), { httpMetadata: { contentType: 'application/json' } });
  return data;
}
async function computeStats(env) {
  const out = {};
  let cursor;
  do {
    const l = await env.BUCKET.list({ prefix: 'e/', cursor });
    for (const o of l.objects) {
      const [, id, name] = o.key.split('/');
      const [ts, type, , pays, ville] = name.split('-');
      const s = (out[id] ||= { views: 0, plays: 0, pct: 0, ctaClicks: 0, siteClicks: 0, rdvVus: 0, firstView: null, lastView: null, lastCta: null, lieu: null });
      const iso = new Date(Number(ts)).toISOString();
      if (type === 'view') {
        s.views++;
        if (!s.firstView || iso < s.firstView) s.firstView = iso;
        if (!s.lastView || iso > s.lastView) { s.lastView = iso; s.lieu = pays ? [ville, pays].filter(Boolean).join(', ') : null; }
      }
      else if (type === 'play') s.plays++;
      else if (type === 'cta') { s.ctaClicks++; if (!s.lastCta || iso > s.lastCta) s.lastCta = iso; }
      else if (type === 'site') s.siteClicks = (s.siteClicks || 0) + 1;  // « Voir notre site » (23/10)
      else if (type === 'rdv') s.rdvVus = (s.rdvVus || 0) + 1;  // calendrier affiche a l'ecran (23/10)
      else if (type[0] === 'p') s.pct = Math.max(s.pct, Number(type.slice(1)));
    }
    cursor = l.truncated ? l.cursor : undefined;
  } while (cursor);
  for (const [pre, fill] of [['c/', (s, a) => { s.reactions = a.filter((x) => x.emoji).length; s.comments = a.length - s.reactions; }], ['l/', (s, a) => { s.emails = a; }]]) {
    do {
      const l = await env.BUCKET.list({ prefix: pre, cursor });
      for (const o of l.objects) {
        const a = await (await env.BUCKET.get(o.key))?.json().catch(() => []);
        if (Array.isArray(a)) fill((out[o.key.slice(2, -5)] ||= { views: 0, plays: 0, pct: 0, ctaClicks: 0, lastView: null, lastCta: null }), a);
      }
      cursor = l.truncated ? l.cursor : undefined;
    } while (cursor);
  }
  return out;
}

// Marque de l'entreprise : réglée dans wrangler.jsonc (vars), valeurs par défaut sinon.
let B = {};
const brand = (env) => ({
  name: env.BRAND_NAME || 'X-Videos', site: env.BRAND_SITE || 'https://example.com', color: env.BRAND_COLOR || '#7b5bf4',
  colorHover: env.BRAND_COLOR_HOVER || env.BRAND_COLOR || '#6a4be0', author: env.AUTHOR_NAME || '',
  cal: env.CALENDAR_URL || '', cta: env.CTA_LABEL || 'Réserver 15 min',
});

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const fmt = (s) => (s ? `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, '0')}` : '');

const safeJson = (x) => JSON.stringify(x).replace(/</g, '\\u003c').replace(/\u2028|\u2029/g, ' '); // sûr dans un <script>

// Carte centrée (mot de passe ou e-mail). `head` = balises d'aperçu éventuelles (jamais pour le mot de passe).
function gatePage({ id, title, h1, text, input, button, error, head = '', status = 200, poster = '' }) {
  return new Response(`<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>${title}</title><meta name="robots" content="noindex">${head}
<style>:root{--violet:${B.color}}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0a0a0b;color:#fff;font-family:Inter,system-ui,sans-serif;padding:16px}
form{width:100%;max-width:420px;border:1px solid #2a2a30;border-radius:14px;padding:24px;background:#0a0a0b}.pv{position:relative;aspect-ratio:16/9;border-radius:10px;overflow:hidden;margin:0 0 18px;background:#111 center/cover no-repeat}.pv:after{content:'';position:absolute;inset:0;background:rgba(10,10,11,.35)}.pv i{position:absolute;z-index:1;left:50%;top:50%;width:56px;height:56px;margin:-28px 0 0 -28px;border-radius:50%;background:var(--violet)}.pv i:after{content:'';position:absolute;left:22px;top:17px;border-left:18px solid #fff;border-top:11px solid transparent;border-bottom:11px solid transparent}h1{font-size:20px;margin:0 0 6px}p{color:#9a9aa3;margin:0 0 16px;font-size:14px}
input{width:100%;padding:12px 14px;border-radius:10px;border:1px solid #2a2a30;background:#111;color:#fff;font:inherit;margin-bottom:12px}
button{width:100%;background:var(--violet);color:#fff;border:0;border-radius:999px;font:inherit;font-weight:600;padding:12px;cursor:pointer}button:hover{background:${B.colorHover}}.err{color:#ff8a8a;font-size:14px;margin:0 0 12px}</style></head><body>
<form method="post" action="/v/${id}">${poster ? `<div class="pv" style="background-image:url(${poster})"><i></i></div>` : ''}<h1>${h1}</h1><p>${text}</p>${error ? `<p class="err">${error}</p>` : ''}
${input}<button type="submit">${button}</button></form></body></html>`,
    { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-robots-tag': 'noindex' } });
}
// Page demandant le mot de passe : aucune miniature, aucun titre, aucune balise d'aperçu (les robots ne voient rien).
const lockedPage = (id, error) => gatePage({ id, title: 'Vidéo privée', h1: 'Vidéo privée', text: 'Entre le mot de passe reçu avec le lien.', error: error && (error === true ? 'Mot de passe incorrect.' : error), status: error === true ? 401 : error ? 429 : 200,
  input: '<input type="password" name="pw" placeholder="Mot de passe" autocomplete="current-password" autofocus required>', button: 'Voir la vidéo' });

// Balises d'aperçu (LinkedIn, Gmail, Slack) : titre + image toujours ; og:video seulement si la vidéo existe.
const ogTags = (base, id, ogTitle, info, withVideo) => `<meta property="og:type" content="video.other">
<meta property="og:title" content="${ogTitle}">
<meta property="og:description" content="${info}">
<meta property="og:image" content="${base}/t/${id}-play.jpg">
<meta property="og:image:width" content="1280"><meta property="og:image:height" content="720">${withVideo ? `
<meta property="og:video" content="${base}/f/${id}.mp4"><meta property="og:video:type" content="video/mp4">` : ''}
<meta name="twitter:card" content="summary_large_image">`;
const mmss = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
const EMAIL_RE = /^[^\s@<>"',;]{1,64}@[^\s@<>"',;]{1,190}\.[^\s@<>"',;]{2,}$/;

async function watch(req, env, ctx, id, url) {
  const meta = await readMeta(env, id);
  if (!meta) return new Response('Vidéo introuvable', { status: 404 });
  const secure = url.protocol === 'https:' ? '; Secure' : '';
  if (meta.password && !(await unlocked(req, env, id, meta))) {
    if (req.method === 'POST') {
      if (!(await pwAttempt(env, id, req))) return lockedPage(id, 'Trop d\'essais. Réessaie dans 15 minutes.');
      const pw = String((await req.formData().catch(() => new FormData())).get('pw') || '');
      if (!(await checkPassword(meta, pw))) return lockedPage(id, true);
      return new Response(null, { status: 303, headers: { location: `/v/${id}`, 'cache-control': 'no-store',
        'set-cookie': `${cookieName(id)}=${await sign(env, id, meta)}; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax${secure}` } });
    }
    return lockedPage(id, false);
  }
  const base = url.hostname === 'localhost' ? url.origin : `https://${url.host}`;
  // majuscule au début (« khamis » saisi en minuscules donnait « khamis, une vidéo pour kuroflow »)
  const cap = (x) => x.charAt(0).toLocaleUpperCase('fr') + x.slice(1);
  const first = esc(cap(String(meta.firstName || '').trim()));
  const company = esc(cap(String(meta.company || '').trim()));
  const title = esc(meta.title || 'Vidéo');
  // aperçu du lien personnalisé : « Julie, une vidéo pour Studio Lumen »
  const ogTitle = first && company ? `${first}, une vidéo pour ${company}` : first ? `${first}, une vidéo pour toi` : title;
  const info = `${[B.author, B.name].filter(Boolean).map(esc).join(' · ')}${meta.duration ? ' · ' + fmt(meta.duration) : ''}`;
  // e-mail demandé avant de regarder : le titre et l'aperçu restent visibles (partage joli), seul le lecteur est caché
  if (meta.requireEmail && !(await emailOk(req, env, id, meta))) {
    let error = '';
    if (req.method === 'POST') {
      const email = String((await req.formData().catch(() => new FormData())).get('email') || '').trim().toLowerCase();
      if (EMAIL_RE.test(email) && email.length <= 254) {
        const o = await env.BUCKET.get(`l/${id}.json`);
        const leads = o ? await o.json().catch(() => []) : [];
        if (Array.isArray(leads) && !leads.some((x) => x.email === email) && leads.length < 200) {
          const lieu = [req.cf?.city, req.cf?.country].filter(Boolean).join(', ');
          leads.push({ email, at: new Date().toISOString(), lieu });
          await env.BUCKET.put(`l/${id}.json`, JSON.stringify(leads), { httpMetadata: { contentType: 'application/json' } });
        }
        return new Response(null, { status: 303, headers: { location: `/v/${id}`, 'cache-control': 'no-store',
          'set-cookie': `${emailCookie(id)}=${await hmac(env, `${id}.email`)}; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax${secure}` } });
      }
      error = 'Cet e-mail ne semble pas valide.';
    }
    return gatePage({ id, title: ogTitle, h1: first ? `${first}, ta vidéo t'attend` : 'Ta vidéo t\'attend', text: `Laisse ton e-mail pour la regarder${company ? ` : une vidéo pour ${company}` : ''}.`, poster: `/t/${id}.jpg`, error, status: error ? 400 : 200, head: '\n' + ogTags(base, id, ogTitle, info, false),
      input: '<input type="email" name="email" placeholder="ton@email.com" autocomplete="email" autofocus required maxlength="254">', button: 'Voir la vidéo' });
  }
  const [cmts, hasSrt, hasVideo, hasThumb] = await Promise.all([readComments(env, id), env.BUCKET.head(`s/${id}.srt`).then((o) => !!o),
    env.BUCKET.head(`v/${id}.mp4`).then((o) => !!o), env.BUCKET.head(`t/${id}.jpg`).then((o) => !!o)]);
  // une vue = un humain ; les robots d'aperçu (LinkedIn, Slack, Gmail…) ne comptent pas
  // et pas Baptiste lui-même (cookie /moi ou sa connexion)
  if (!BOTS.test(req.headers.get('user-agent') || '')) {
    if (await estMoi(req, env)) ctx.waitUntil(retenirIp(req, env));
    else ctx.waitUntil(logEvent(env, id, 'view', req));
  }
  const chapters = Array.isArray(meta.chapters) ? meta.chapters : [];
  // Reservation tracee (23/10, Baptiste : « tracker le lien du cal.com dans les videos ») : metadata[lead_ref]=video-<id> revient
  // dans le webhook et le releve Cal.com, ce qui relie le rendez-vous a la video et donc a la fiche du CRM (champ video_xtablo).
  const calSrc = `${B.cal}?embed=true&theme=dark&layout=month_view&metadata%5Blead_ref%5D=video-${id}&utm_source=video&utm_campaign=${id}` +
    (meta.firstName ? `&name=${encodeURIComponent(cap(String(meta.firstName).trim()))}` : '');
  const page = `<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${ogTitle}</title>
<meta name="robots" content="noindex">
${ogTags(base, id, ogTitle, info, hasVideo)}
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Plus+Jakarta+Sans:wght@700&display=swap" rel="stylesheet" media="print" onload="this.media='all'">
<style>
:root{--bg:#0a0a0b;--line:#2a2a30;--muted:#9a9aa3;--violet:${B.color};--violet-h:${B.colorHover}}
*{box-sizing:border-box}[hidden]{display:none!important}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:#fff;font-family:Inter,system-ui,sans-serif}
header{display:flex;align-items:center;justify-content:space-between;gap:12px;max-width:1100px;margin:0 auto;padding:20px 16px}
.logo{font-family:'Plus Jakarta Sans',sans-serif;font-weight:700;font-size:20px;color:#fff;text-decoration:none;letter-spacing:-.02em}
main{max-width:1100px;margin:0 auto;padding:0 16px 48px}
h1{font-family:'Plus Jakarta Sans',sans-serif;font-size:clamp(22px,3.4vw,32px);margin:4px 0 16px;letter-spacing:-.02em}
h1 mark{background:var(--violet);color:#fff;padding:0 .2em;border-radius:6px}
.sum{color:var(--muted);font-size:15px;line-height:1.5;margin:-6px 0 16px;overflow-wrap:anywhere;white-space:pre-wrap}
video{width:100%;border-radius:14px;border:1px solid var(--line);background:#000;display:block}
#wait{position:relative;aspect-ratio:16/9;border-radius:14px;border:1px solid var(--line);background:#000 center/cover no-repeat;display:grid;place-items:center;padding:12px;overflow:hidden}#wait:before{content:'';position:absolute;inset:0;background:rgba(10,10,11,.72)}
#wait div{position:relative;text-align:center}#wait b{display:block;font-family:'Plus Jakarta Sans',sans-serif;font-size:clamp(20px,3vw,28px);font-weight:700;margin-bottom:4px}#wait span{color:var(--muted);font-size:14px}
#wait i{display:block;width:14px;height:14px;border-radius:50%;background:var(--violet);margin:0 auto 10px;animation:pulse 1.2s ease-in-out infinite}
@keyframes pulse{50%{transform:scale(1.7);opacity:.45}}
.meta{color:var(--muted);font-size:14px;margin-top:12px}
.cta{display:inline-flex;align-items:center;gap:8px;background:var(--violet);color:#fff;text-decoration:none;font-weight:600;font-size:15px;padding:12px 20px;border-radius:999px;white-space:nowrap}
.cta:hover{background:var(--violet-h)}
.ghost{color:var(--muted);text-decoration:none;font-size:14px}.ghost:hover{color:#fff}
.row{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:14px;margin-top:18px}
#rdv{margin-top:44px;border-top:1px solid var(--line);padding-top:32px}
#rdv h2{font-family:'Plus Jakarta Sans',sans-serif;font-size:22px;margin:0 0 6px}
#rdv p{color:var(--muted);margin:0 0 18px}
#rdv iframe{width:100%;height:720px;border:1px solid var(--line);border-radius:14px;background:#111}
#speed{display:flex;gap:6px;align-items:center;margin-top:12px;flex-wrap:wrap}#speed span{color:var(--muted);font-size:13px;margin-right:2px}
#speed button{background:none;border:1px solid var(--line);color:#fff;border-radius:999px;font:inherit;font-size:13px;font-weight:500;padding:6px 12px;cursor:pointer;min-width:44px}
#speed button.on{background:var(--violet);border-color:var(--violet)}
#rx{display:flex;gap:6px;margin-top:12px;flex-wrap:wrap}
#rx button{position:relative;background:none;border:1px solid var(--line);border-radius:999px;font-size:18px;line-height:1;width:44px;height:36px;cursor:pointer;padding:0}#rx button:hover{border-color:var(--violet)}
#rx .fl{position:absolute;left:50%;top:0;margin-left:-9px;pointer-events:none;animation:fl .9s ease-out forwards}
@keyframes fl{to{transform:translateY(-64px) scale(1.5);opacity:0}}
#chap{margin-top:12px}#chap button{display:flex;gap:10px;width:100%;text-align:left;background:none;border:0;border-top:1px solid var(--line);color:#fff;font:inherit;font-size:14px;padding:9px 0;cursor:pointer;overflow-wrap:anywhere}
#chap button:hover span{color:var(--violet)}#chap b{flex:none;color:var(--violet);font-weight:600;min-width:42px}
#track{position:relative;height:22px;margin-top:8px;background:#17171b;border-radius:7px}
#track i{position:absolute;top:4px;width:4px;height:14px;margin-left:-2px;border-radius:2px;background:var(--violet);cursor:pointer;padding:0;border:0}
#track u{position:absolute;top:0;width:2px;height:100%;margin-left:-1px;background:#fff;opacity:.35;text-decoration:none}
#track span{position:absolute;top:3px;margin-left:-8px;font-size:12px;line-height:16px;cursor:pointer}
#cm{margin-top:28px}#cm h2{font-family:'Plus Jakarta Sans',sans-serif;font-size:18px;margin:0 0 12px}
#cmf{display:grid;grid-template-columns:1fr;gap:8px;margin-bottom:16px}
#cmf input,#cmf textarea{width:100%;padding:10px 12px;border-radius:10px;border:1px solid var(--line);background:#111;color:#fff;font:inherit;font-size:14px}
#cmf textarea{min-height:70px;resize:vertical}#cmf button{justify-self:start;background:var(--violet);color:#fff;border:0;border-radius:999px;font:inherit;font-weight:600;font-size:14px;padding:10px 18px;cursor:pointer}
#cmf button:hover{background:var(--violet-h)}#cms{color:var(--muted);font-size:13px;min-height:18px}
.cmi{display:flex;gap:10px;padding:10px 0;border-top:1px solid var(--line);font-size:14px;line-height:1.45}
.cmi button{flex:none;background:none;border:1px solid var(--violet);color:#fff;border-radius:999px;font:inherit;font-size:12px;padding:2px 9px;cursor:pointer;height:fit-content}
.cmi b{font-weight:600;margin-right:6px}.cmi div{min-width:0;overflow-wrap:anywhere;white-space:pre-wrap}
.hd{display:flex;align-items:center;gap:10px}.site{display:inline-flex;align-items:center;color:#fff;text-decoration:none;font-weight:600;font-size:15px;padding:11px 18px;border:1px solid #3a3a42;border-radius:999px;white-space:nowrap}.site:hover{border-color:#fff}
#go{position:fixed;left:50%;bottom:24px;z-index:6;display:flex;align-items:center;gap:10px;background:#fff;color:#0a0a0b;text-decoration:none;font-weight:600;font-size:15px;padding:12px 18px 12px 20px;border-radius:999px;box-shadow:0 10px 30px rgba(0,0,0,.45);opacity:0;transform:translate(-50%,16px);pointer-events:none;transition:opacity .35s ease,transform .35s cubic-bezier(.2,.8,.2,1)}
#go.on{opacity:1;transform:translate(-50%,0);pointer-events:auto}#go svg{animation:dn 1.4s ease-in-out infinite}
@keyframes dn{0%,100%{transform:translateY(-2px)}50%{transform:translateY(4px)}}
@keyframes ng{0%,100%{transform:scale(1)}50%{transform:scale(1.04);box-shadow:0 0 0 6px rgba(123,91,244,.35)}}
#rdv.flash iframe{box-shadow:0 0 0 2px var(--violet),0 0 40px rgba(123,91,244,.35);transition:box-shadow .6s}
@media (prefers-reduced-motion:reduce){#go{transition:none}#go svg,.sticky.nudge{animation:none}}
.vw{position:relative}#fin{position:absolute;inset:0;border-radius:14px;background:rgba(10,10,11,.86);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;text-align:center;padding:16px;animation:fi .35s ease-out}#fin b{font-family:'Plus Jakarta Sans',sans-serif;font-size:clamp(20px,3vw,30px)}#fin span{color:var(--muted);margin-bottom:6px}#revoir{background:none;border:0;color:var(--muted);font:inherit;font-size:14px;cursor:pointer;text-decoration:underline}@keyframes fi{from{opacity:0}}
.rs{display:flex;flex-wrap:wrap;gap:8px 18px;list-style:none;padding:0;margin:-6px 0 18px;color:#d6d6dc;font-size:14px}.rs li:before{content:'✓ ';color:var(--violet);font-weight:700}
.sticky{display:none}
@media (max-width:640px){header .cta{display:none}.site{padding:9px 14px;font-size:14px}#go{display:none}.sticky.nudge{animation:ng 1.6s ease-in-out 3}.sticky{display:flex;position:fixed;left:16px;right:16px;bottom:16px;justify-content:center;z-index:5}main{padding-bottom:96px}}
</style></head><body>
<header><a class="logo" href="${esc(B.site)}">${esc(B.name)}</a><nav class="hd"><a class="site" href="${esc(B.site)}/?utm_source=video&amp;utm_campaign=${id}" target="_blank" rel="noopener" data-site>Voir notre site</a><a class="cta" href="#rdv" data-cta>${esc(B.cta)}</a></nav></header>
<main>
<h1>${first ? `Salut ${first}${company ? `, une vidéo pour <mark>${company}</mark>` : ''}` : title}</h1>
${meta.summary ? `<p class="sum">${esc(meta.summary)}</p>\n` : ''}<div class="vw"><video id="v" controls playsinline preload="metadata"${hasThumb ? ` poster="/t/${id}.jpg"` : ''}${hasVideo ? ` src="/f/${id}.mp4"` : ' hidden'}></video>
<div id="fin" hidden><b>${first ? `${first}, ton portail est prêt.` : 'Ton portail est prêt.'}</b><span>15 min pour le voir sur tes vrais projets.</span><a class="cta" href="#rdv" data-cta>Choisir mon créneau</a><button type="button" id="revoir">Revoir la vidéo</button></div></div>
${hasVideo ? '' : `<div id="wait"${hasThumb ? ` style="background-image:url(/t/${id}.jpg)"` : ''} role="status"><div><i></i><b>Ta vidéo arrive…</b><span>Elle se lance toute seule dans quelques secondes.</span></div></div>\n`}<div id="track" aria-label="Commentaires sur la durée"></div>
<div id="rx" role="group" aria-label="Réagir à cet instant">${EMOJIS.map((e) => `<button type="button" data-e="${e}" aria-label="Réagir ${e}">${e}</button>`).join('')}</div>
<div id="speed" role="group" aria-label="Vitesse de lecture"><span>Vitesse</span>${[['1', '×1'], ['1.25', '×1,25'], ['1.5', '×1,5'], ['2', '×2']].map(([v, l]) => `<button type="button" data-speed="${v}" aria-pressed="false">${l}</button>`).join('')}</div>
${chapters.length ? `<div id="chap" aria-label="Chapitres">${chapters.map((c) => `<button type="button" data-t="${c.t}"><b>${mmss(c.t)}</b><span>${esc(c.title)}</span></button>`).join('')}</div>\n` : ''}<div class="row"><div class="meta">${info}${hasSrt ? ` · <a class="ghost" href="/s/${id}.srt" download>Télécharger la transcription</a>` : ''}</div><div style="display:flex;gap:18px;align-items:center"><a class="ghost" href="${esc(B.site)}">Découvrir ${esc(B.name)}</a><a class="cta" href="#rdv" data-cta>${esc(B.cta)}</a></div></div>
<section id="rdv"><h2>On en parle 15 minutes ?</h2><p>Choisis un créneau : je te montre ton portail sur tes vrais projets${company ? `, pour ${company}` : ''}.</p><ul class="rs"><li>15 min en visio</li><li>Sans engagement</li><li>Ton portail à ta marque, prêt à tester</li></ul>
<iframe loading="lazy" src="${esc(calSrc)}" title="${esc(B.cta)}"></iframe></section>
<section id="cm"><h2>Commentaires</h2>
<form id="cmf" autocomplete="off"><input name="name" maxlength="40" placeholder="Prénom (facultatif)"><textarea name="text" maxlength="1000" placeholder="Ton commentaire sur ce passage…" required></textarea>
<button type="submit" id="cmb">Commenter à 0:00</button><div id="cms" role="status"></div></form><div id="cml"></div></section>

</main>
<a class="cta sticky" href="#rdv" data-cta>${esc(B.cta)}</a>
<a id="go" href="#rdv" data-cta aria-hidden="true" tabindex="-1">Choisis ton créneau juste en dessous<svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M8 2v11m0 0-4.5-4.5M8 13l4.5-4.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></a>
<script>
(function(){var u='/e/${id}?t=',sent={},v=document.getElementById('v');
function ping(t){if(sent[t])return;sent[t]=1;try{navigator.sendBeacon(u+t)}catch(e){fetch(u+t,{method:'POST',keepalive:true})}}
v.addEventListener('play',function(){ping('play')});
v.addEventListener('timeupdate',function(){if(!v.duration)return;var p=v.currentTime/v.duration*100;[25,50,75].forEach(function(s){if(p>=s)ping('p'+s)});});
v.addEventListener('ended',function(){ping('p100')});
document.querySelectorAll('[data-cta]').forEach(function(a){a.addEventListener('click',function(){ping('cta')})});
document.querySelectorAll('[data-site]').forEach(function(a){a.addEventListener('click',function(){ping('site')})});
// invitation a descendre vers le calendrier (23/10) : apres la moitie de la video, a la fin, ou 25 s sur la page ; cachee des que le calendrier est a l'ecran
var go=document.getElementById('go'),rdv=document.getElementById('rdv'),vu=false;
var st=document.querySelector('.sticky');
function montre(){if(vu||!go)return;if(st)st.classList.add('nudge');go.classList.add('on');go.removeAttribute('aria-hidden');go.removeAttribute('tabindex')}
function cache(){if(!go)return;go.classList.remove('on');go.setAttribute('aria-hidden','true');go.setAttribute('tabindex','-1')}
v.addEventListener('timeupdate',function(){if(v.duration&&v.currentTime/v.duration>=.5)montre()});v.addEventListener('ended',montre);
var fin=document.getElementById('fin');v.addEventListener('ended',function(){if(fin)fin.hidden=false});v.addEventListener('play',function(){if(fin)fin.hidden=true});
var rv=document.getElementById('revoir');if(rv)rv.addEventListener('click',function(){fin.hidden=true;v.currentTime=0;v.play().catch(function(){})});setTimeout(montre,25000);
if('IntersectionObserver' in window&&rdv)new IntersectionObserver(function(es){es.forEach(function(e){if(e.isIntersecting){vu=true;cache();ping('rdv');rdv.classList.add('flash');setTimeout(function(){rdv.classList.remove('flash')},1600)}})},{threshold:.25}).observe(rdv);
// vitesse de lecture, mémorisée
var speeds=[1,1.25,1.5,2],cur=1,sb=document.querySelectorAll('[data-speed]');
try{cur=+localStorage.getItem('xv-speed')||1}catch(e){}if(speeds.indexOf(cur)<0)cur=1;
function setSpeed(s){cur=s;v.playbackRate=s;sb.forEach(function(b){var on=+b.dataset.speed===s;b.classList.toggle('on',on);b.setAttribute('aria-pressed',on)});try{localStorage.setItem('xv-speed',s)}catch(e){}}
sb.forEach(function(b){b.addEventListener('click',function(){setSpeed(+b.dataset.speed)})});
v.addEventListener('loadedmetadata',function(){v.playbackRate=cur});v.addEventListener('play',function(){v.playbackRate=cur});setSpeed(cur);
document.addEventListener('keydown',function(e){if(/INPUT|TEXTAREA/.test((e.target||{}).tagName||''))return;var i=speeds.indexOf(cur);
if(e.key==='>'&&i<3)setSpeed(speeds[i+1]);else if(e.key==='<'&&i>0)setSpeed(speeds[i-1])});
// vidéo pas encore arrivée : on interroge /r/<id> toutes les 3 s puis on branche la source (sans recharger : la vue n'est comptée qu'une fois)
if(!v.hasAttribute('src')){var wt=document.getElementById('wait'),n=0,iv=setInterval(function(){if(++n>1200){clearInterval(iv);return}
fetch('/r/${id}',{cache:'no-store'}).then(function(r){return r.json()}).then(function(j){if(!j.ready)return;clearInterval(iv);v.src='/f/${id}.mp4';v.hidden=false;if(wt)wt.hidden=true;v.load()})['catch'](function(){})},3000)}
// commentaires, réactions et chapitres horodatés (texte inséré via textContent : jamais de HTML)
var C=${safeJson(cmts)},CH=${safeJson(chapters)},DUR=${Number(meta.duration) || 0},tr=document.getElementById('track'),cl=document.getElementById('cml'),cb=document.getElementById('cmb'),cs=document.getElementById('cms');
function fm(s){s=Math.floor(s);return Math.floor(s/60)+':'+('0'+s%60).slice(-2)}
function jump(t){if(!v.hasAttribute('src'))return;v.currentTime=t;v.play().catch(function(){})}
function render(){var d=v.duration||DUR;tr.innerHTML='';cl.innerHTML='';
function pos(t){return (d?Math.min(100,t/d*100):0)+'%'}
CH.forEach(function(h){var k=document.createElement('u');k.style.left=pos(h.t);k.title=fm(h.t)+' · '+h.title;tr.appendChild(k)});
C.slice().sort(function(a,b){return a.t-b.t}).forEach(function(c){
if(c.emoji){var e=document.createElement('span');e.textContent=c.emoji;e.style.left=pos(c.t);e.title=fm(c.t);e.onclick=function(){jump(c.t)};tr.appendChild(e);return}
var m=document.createElement('i');m.style.left=pos(c.t);m.title=fm(c.t)+' · '+(c.name||'Anonyme');m.onclick=function(){jump(c.t)};tr.appendChild(m);
var r=document.createElement('div');r.className='cmi';var b=document.createElement('button');b.type='button';b.textContent=fm(c.t);b.onclick=function(){jump(c.t)};
var w=document.createElement('div'),n=document.createElement('b');n.textContent=c.name||'Anonyme';w.appendChild(n);w.appendChild(document.createTextNode(c.text));r.appendChild(b);r.appendChild(w);cl.appendChild(r)})}
v.addEventListener('loadedmetadata',render);render();
document.querySelectorAll('[data-t]').forEach(function(b){b.addEventListener('click',function(){jump(+b.dataset.t)})});
function tick(){cb.textContent='Commenter à '+fm(v.currentTime||0)}v.addEventListener('timeupdate',tick);v.addEventListener('seeked',tick);
function post(body){return fetch('/c/${id}',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})
.then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.error||'Erreur');return j})})}
document.getElementById('rx').addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('button[data-e]');if(!b)return;
var f=document.createElement('span');f.className='fl';f.textContent=b.dataset.e;b.appendChild(f);setTimeout(function(){f.remove()},900);
post({t:v.currentTime||0,emoji:b.dataset.e}).then(function(j){C=j;render()})['catch'](function(){})});
document.getElementById('cmf').addEventListener('submit',function(e){e.preventDefault();var f=e.target;cb.disabled=true;cs.textContent='';
post({t:v.currentTime||0,name:f.name.value,text:f.text.value})
.then(function(j){C=j;f.text.value='';render();cs.textContent='Commentaire ajouté.'})
.catch(function(x){cs.textContent=x.message})['finally'](function(){cb.disabled=false})});})();
</script>
</body></html>`;
  return new Response(page, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
}
