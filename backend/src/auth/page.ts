// Server-rendered sign-in page for /oauth/authorize. No external scripts: WebAuthn JSON
// conversion is done inline so the page works without a CDN.

type Lang = "en" | "ru";

const STRINGS = {
  en: {
    title: "Sign in to zone2.day",
    wants: "wants to access your training data on zone2.day.",
    signIn: "Sign in with passkey",
    firstTime: "First time here?",
    invite: "Invite code",
    name: "Your name",
    create: "Create account with passkey",
    working: "Waiting for passkey…",
    unsupported: "This browser does not support passkeys.",
    failed: "Sign-in failed",
  },
  ru: {
    title: "Вход в zone2.day",
    wants: "запрашивает доступ к твоим тренировочным данным в zone2.day.",
    signIn: "Войти с passkey",
    firstTime: "Впервые здесь?",
    invite: "Инвайт-код",
    name: "Имя",
    create: "Создать аккаунт с passkey",
    working: "Жду passkey…",
    unsupported: "Этот браузер не поддерживает passkeys.",
    failed: "Не удалось войти",
  },
} as const;

export function pickLang(acceptLanguage: string | undefined): Lang {
  return /^\s*ru\b/i.test(acceptLanguage ?? "") ? "ru" : "en";
}

function esc(s: string): string {
  return s.replace(
    /[&<>"']/g,
    (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!,
  );
}

export function renderErrorPage(lang: Lang, message: string): string {
  const t = STRINGS[lang];
  return shell(lang, t.failed, `<h1>${esc(t.failed)}</h1><p class="err">${esc(message)}</p>`);
}

export function renderAuthorizePage(input: {
  lang: Lang;
  clientName: string;
  request: string;
  baseUrl: string;
}): string {
  const t = STRINGS[input.lang];
  const cfg = JSON.stringify({ request: input.request, base: input.baseUrl, t }).replace(
    /</g,
    "\\u003c",
  );
  const body = `
<h1>${esc(t.title)}</h1>
<p><strong>${esc(input.clientName)}</strong> ${esc(t.wants)}</p>
<button id="login" class="primary">${esc(t.signIn)}</button>
<details>
  <summary>${esc(t.firstTime)}</summary>
  <label>${
    esc(t.invite)
  }<input id="invite" autocomplete="off" autocapitalize="characters" spellcheck="false"></label>
  <label>${esc(t.name)}<input id="name" autocomplete="name" maxlength="60"></label>
  <button id="register">${esc(t.create)}</button>
</details>
<p id="status" role="status"></p>
<script>
const CFG = ${cfg};
const enc = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
const dec = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const status = document.getElementById("status");
const say = (msg, err) => { status.textContent = msg; status.className = err ? "err" : ""; };
async function post(path, body) {
  const r = await fetch(CFG.base + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error_description || j.error || ("HTTP " + r.status));
  return j;
}
async function login() {
  say(CFG.t.working);
  const { challengeId, options } = await post("/oauth/passkey/login/options", { request: CFG.request });
  const cred = await navigator.credentials.get({ publicKey: { ...options, challenge: dec(options.challenge),
    allowCredentials: (options.allowCredentials || []).map((c) => ({ ...c, id: dec(c.id) })) } });
  const response = { id: cred.id, rawId: enc(cred.rawId), type: cred.type,
    clientExtensionResults: cred.getClientExtensionResults(), authenticatorAttachment: cred.authenticatorAttachment,
    response: { clientDataJSON: enc(cred.response.clientDataJSON), authenticatorData: enc(cred.response.authenticatorData),
      signature: enc(cred.response.signature), userHandle: cred.response.userHandle ? enc(cred.response.userHandle) : undefined } };
  const { redirect } = await post("/oauth/passkey/login/verify", { request: CFG.request, challengeId, response });
  location.href = redirect;
}
async function register() {
  say(CFG.t.working);
  const invite = document.getElementById("invite").value, name = document.getElementById("name").value;
  const { challengeId, options } = await post("/oauth/passkey/register/options", { request: CFG.request, invite, name });
  const cred = await navigator.credentials.create({ publicKey: { ...options, challenge: dec(options.challenge),
    user: { ...options.user, id: dec(options.user.id) },
    excludeCredentials: (options.excludeCredentials || []).map((c) => ({ ...c, id: dec(c.id) })) } });
  const response = { id: cred.id, rawId: enc(cred.rawId), type: cred.type,
    clientExtensionResults: cred.getClientExtensionResults(), authenticatorAttachment: cred.authenticatorAttachment,
    response: { clientDataJSON: enc(cred.response.clientDataJSON), attestationObject: enc(cred.response.attestationObject),
      transports: cred.response.getTransports ? cred.response.getTransports() : [] } };
  const { redirect } = await post("/oauth/passkey/register/verify", { request: CFG.request, challengeId, response });
  location.href = redirect;
}
const guard = (fn) => () => fn().catch((e) => say(CFG.t.failed + ": " + e.message, true));
if (!window.PublicKeyCredential) say(CFG.t.unsupported, true);
document.getElementById("login").onclick = guard(login);
document.getElementById("register").onclick = guard(register);
</script>`;
  return shell(input.lang, t.title, body);
}

function shell(lang: Lang, title: string, body: string): string {
  return `<!doctype html>
<html lang="${lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${esc(title)}</title>
<style>
:root { color-scheme: light dark; --bg: #f6f7f9; --card: #fff; --fg: #111; --muted: #667; --accent: #1f7a5a; --err: #b42318; }
@media (prefers-color-scheme: dark) { :root { --bg: #0f1113; --card: #191c1f; --fg: #eee; --muted: #9aa; --accent: #3ccf91; --err: #ff8a7a; } }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--fg);
  font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; padding: 16px; }
main { width: 100%; max-width: 380px; background: var(--card); border-radius: 16px; padding: 28px 24px; box-shadow: 0 1px 3px #0002; }
h1 { font-size: 22px; margin: 0 0 8px; }
p { color: var(--muted); margin: 0 0 20px; }
button { width: 100%; font: inherit; font-weight: 600; padding: 12px; border-radius: 10px; border: 1px solid var(--accent);
  background: transparent; color: var(--accent); cursor: pointer; margin-top: 12px; }
button.primary { background: var(--accent); color: #fff; }
details { margin-top: 20px; } summary { cursor: pointer; color: var(--muted); }
label { display: block; margin-top: 12px; font-size: 14px; color: var(--muted); }
input { display: block; width: 100%; margin-top: 4px; font: inherit; padding: 10px; border-radius: 8px; border: 1px solid #8884;
  background: transparent; color: var(--fg); }
.err { color: var(--err); }
#status { margin: 16px 0 0; min-height: 1.5em; }
</style>
</head>
<body><main>${body}</main></body>
</html>`;
}
