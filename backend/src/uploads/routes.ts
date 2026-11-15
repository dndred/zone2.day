// One-time upload page (/u/:token) behind MCP create_upload_link. No bearer: the URL token is the
// credential, so it is single-use and short-lived. The file is only stored here; the coach turns
// it into an activity with import_activity_file({uploadId}).
import { Hono } from "@hono/hono";
import { sha256 } from "../auth/crypto.ts";
import { esc, type Lang, pickLang, shell } from "../auth/page.ts";
import type { Config } from "../config.ts";
import type { AppDeps } from "../deps.ts";
import { fitToDump, InvalidFitError } from "../domain/fit.ts";
import type { AppEnv } from "../http.ts";
import { log } from "../log.ts";

export const MAX_FIT_BYTES = 25 * 1024 * 1024;

const STRINGS = {
  en: {
    title: "Upload a workout file",
    lead: "Pick the .fit file (e.g. the MyWhoosh export). Your coach imports it in the chat.",
    send: "Upload",
    done: "File received",
    back: "Go back to the chat and tell your coach it is uploaded.",
    used: "This link was already used. Ask your coach for a new one.",
    expired: "This link has expired. Ask your coach for a new one.",
    missing: "Link not found.",
    noFile: "Choose a file first.",
    tooLarge: "The file is larger than 25 MB.",
    bad: "This is not a valid FIT activity file",
  },
  ru: {
    title: "Загрузка файла тренировки",
    lead: "Выбери файл .fit (например, выгрузку MyWhoosh). Тренер импортирует его в чате.",
    send: "Загрузить",
    done: "Файл получен",
    back: "Вернись в чат и скажи тренеру, что файл загружен.",
    used: "Эта ссылка уже использована. Попроси у тренера новую.",
    expired: "Срок ссылки истёк. Попроси у тренера новую.",
    missing: "Ссылка не найдена.",
    noFile: "Сначала выбери файл.",
    tooLarge: "Файл больше 25 МБ.",
    bad: "Это не FIT-файл тренировки",
  },
} as const;

function page(lang: Lang, body: string) {
  return shell(lang, STRINGS[lang].title, body);
}

function message(lang: Lang, title: string, text: string, err = false) {
  return page(lang, `<h1>${esc(title)}</h1><p${err ? ' class="err"' : ""}>${esc(text)}</p>`);
}

function form(lang: Lang, error?: string) {
  const t = STRINGS[lang];
  return page(
    lang,
    `<h1>${esc(t.title)}</h1><p>${esc(t.lead)}</p>
${error ? `<p class="err">${esc(error)}</p>` : ""}
<form method="post" enctype="multipart/form-data">
  <input type="file" name="file" accept=".fit,application/vnd.ant.fit,application/octet-stream" required>
  <button class="primary" type="submit">${esc(t.send)}</button>
</form>`,
  );
}

export function uploadRoutes(_config: Config, deps: AppDeps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  async function find(token: string, lang: Lang) {
    const t = STRINGS[lang];
    const up = await deps.uploads.byToken(await sha256(token));
    if (!up) return { error: message(lang, t.title, t.missing, true), status: 404 as const };
    if (up.uploadedAt) return { error: message(lang, t.title, t.used, true), status: 410 as const };
    if (up.expiresAt <= deps.now()) {
      return { error: message(lang, t.title, t.expired, true), status: 410 as const };
    }
    return { up };
  }

  app.get("/u/:token", async (c) => {
    const lang = pickLang(c.req.header("accept-language"));
    const r = await find(c.req.param("token"), lang);
    c.header("cache-control", "no-store");
    c.header("referrer-policy", "no-referrer");
    if (!r.up) return c.html(r.error!, r.status);
    return c.html(form(lang));
  });

  app.post("/u/:token", async (c) => {
    const lang = pickLang(c.req.header("accept-language"));
    const t = STRINGS[lang];
    c.header("cache-control", "no-store");
    const r = await find(c.req.param("token"), lang);
    if (!r.up) return c.html(r.error!, r.status);
    const up = r.up;
    const len = Number(c.req.header("content-length") ?? 0);
    if (len > MAX_FIT_BYTES + 64 * 1024) return c.html(form(lang, t.tooLarge), 413);
    const body = await c.req.parseBody();
    const file = body.file;
    if (!(file instanceof File) || file.size === 0) return c.html(form(lang, t.noFile), 400);
    if (file.size > MAX_FIT_BYTES) return c.html(form(lang, t.tooLarge), 413);
    const bytes = new Uint8Array(await file.arrayBuffer());
    // Check now, so the athlete learns about a wrong file while still on the page.
    try {
      fitToDump(bytes, "check", deps.now());
    } catch (err) {
      if (err instanceof InvalidFitError) {
        return c.html(form(lang, `${t.bad}: ${err.message}`), 422);
      }
      throw err;
    }
    const key = `${up.userId}/uploads/${up.id}.fit`;
    await deps.blobs.put(key, bytes, "application/vnd.ant.fit");
    const done = await deps.uploads.markUploaded(up.id, {
      key,
      bytes: bytes.length,
      filename: file.name ? file.name.slice(0, 200) : null,
    });
    if (!done) return c.html(message(lang, t.title, t.used, true), 410);
    log("info", "upload.received", { userId: up.userId, uploadId: up.id, bytes: bytes.length });
    return c.html(message(lang, t.done, t.back));
  });

  return app;
}
