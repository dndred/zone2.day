# 02. Архитектура и стек

## 1. Общая схема

```
                    ┌──────────────── claude.ai / Claude Code ────────────────┐
                    │                 (MCP client, OAuth 2.1)                  │
                    └───────────────────────────┬──────────────────────────────┘
                                                │ HTTPS  https://api.zone2.day/mcp
┌─────────── Cloudflare ────────────┐           │
│ DNS zone2.day                      │◄──────────┘
│ Worker "edge-proxy" (api.zone2.day)│  /.well-known/*, /oauth/*, /mcp, /v1/*
└───────────────┬───────────────────┘
                │ fetch → https://<ref>.supabase.co/functions/v1/api/*
┌───────────────▼──────────── Supabase (Free) ─────────────────────────────┐
│ Edge Function "api" (Deno 2 + Hono)                                       │
│   ├─ oauth/*      OAuth 2.1 AS: DCR, PKCE, passkey login page             │
│   ├─ mcp          MCP Streamable HTTP (stateless)                         │
│   ├─ v1/*         Sync API для iOS (REST, OpenAPI)                        │
│   └─ jobs/*       вызываются pg_cron: импорт intervals.icu, пересчёты     │
│ Postgres          данные, журнал изменений, change feed для синка        │
│ Storage (S3 API)  дампы HealthKit, FIT, ряды, .zwo                        │
│ pg_cron + pg_net  расписание задач                                        │
└───────────────▲──────────────────────────────────────────────────────────┘
                │ HTTPS  /v1/sync, /v1/activities, /v1/strength-logs ...
┌───────────────┴──────────── iPhone ──────────────────────────────────────┐
│ Zone2 iOS (SwiftUI)                                                       │
│   GRDB (SQLite) ← источник для UI, офлайн                                 │
│   SyncEngine (pull по курсору + outbox)                                   │
│   HealthBridge (HealthKit read/write, observer, background delivery)      │
│   WorkoutBridge (WorkoutKit → WorkoutScheduler)                           │
│   WatchBridge (WatchConnectivity, фаза 2)                                 │
└───────────────┬──────────────────────────────────────────────────────────┘
                │ WorkoutKit (система)            │ WatchConnectivity (фаза 2)
┌───────────────▼─────────────────────────────────▼────────────────────────┐
│ Apple Watch Ultra 2                                                       │
│   Фаза 1: штатное «Тренировка» исполняет запланированные custom workouts  │
│   Фаза 2: Zone2 Watch — свой раннер (HKWorkoutSession) + сторож пульса    │
└──────────────────────────────────────────────────────────────────────────┘

Внешние: intervals.icu API (MyWhoosh FIT) · позже APNs, Strava API
```

## 2. Стек

| Слой | Выбор | Почему |
|---|---|---|
| Язык бэкенда | **TypeScript на Deno 2** | Один рантайм локально, в тестах и в Supabase Edge Functions; веб-стандартные API; npm-пакеты через `npm:` |
| HTTP | **Hono** | Работает в Deno/Node/Workers/Bun без изменений (переносимость) |
| MCP | **`@modelcontextprotocol/server` v2** (официальный SDK), Streamable HTTP, stateless; протоколы 2026-07-28 и 2025-era | Самая зрелая реализация удалённого MCP |
| Валидация/схемы | **Zod** → JSON Schema (MCP tools) и OpenAPI (Sync API) | Один источник правды для MCP, API и Swift-моделей |
| SQL/миграции | **`postgres` (postgres-js 3.4)** + SQL-миграции `supabase/migrations/*.sql` (`just db-push`) | Обычный Postgres; без ORM — SQL явный и переносимый; v4 драйвера пока несовместима с Deno |
| БД | **Postgres** (Supabase) | Стандартный, переносимый |
| Файлы | **Supabase Storage через S3 API** | Тот же код работает с R2/MinIO/S3 |
| Auth | Свой OAuth 2.1 AS + WebAuthn (`@simplewebauthn/server`) | Не зависим от Supabase Auth; claude.ai требует OAuth + DCR |
| FIT | `@garmin/fitsdk` (decode + encode) | Официальный SDK; проверяется спайком S3 |
| Edge-прокси | **Cloudflare Worker** на `api.zone2.day` | Контроль корня домена (`/.well-known`), стабильные URL при переезде |
| iOS | **Swift 6, SwiftUI; deployment target iOS 26, сборка Xcode 27 / SDK iOS 27, симулятор iOS 27** | Личное устройство, свежий SDK; target 26 — чтобы не зависеть от того, обновлён ли телефон |
| Локальная БД iOS | **GRDB** | Предсказуемее SwiftData, отлично тестируется, наблюдаемые запросы |
| API-клиент iOS | `swift-openapi-generator` из `schema/openapi.yaml` | Модели генерируются, а не пишутся руками |
| Часы | WorkoutKit (ф.1); SwiftUI watchOS app + HealthKit `HKWorkoutSession` (ф.2) | См. [06-watch](06-watch.md) |
| Проект Xcode | **XcodeGen** (`project.yml`) + локальные SPM-пакеты | Агент правит YAML и Swift, а не `.pbxproj` |
| Графики/карты | Swift Charts, MapKit | Нативно |

## 3. Окружения и домены

| Окружение | API | Supabase | Назначение |
|---|---|---|---|
| local | `http://localhost:8787` (+ `supabase start`) | локальный Docker | разработка, тесты |
| staging | `https://api-staging.zone2.day` | `zone2-staging`, ref `udlqrxzuzoygmulwptee`, eu-central-1 | проверка перед продом, эксперименты агента |
| prod | `https://api.zone2.day` | `zone2-prod`, ref `tyeizwhaiigkkvipdvlz`, eu-central-1 | реальные данные |

- Пароли БД — в 1Password, хранилище `dev tools`, записи `zone2-staging Supabase DB` / `zone2-prod Supabase DB` (тег `zone2.day`). Чтение: `op read "op://dev tools/zone2-prod Supabase DB/password"`.
- Cloudflare: зона `zone2.day` (NS `elijah`/`robin.ns.cloudflare.com`), Worker деплоится через `wrangler` (OAuth-вход).

- `zone2.day` (корень) — позже статическая страница / privacy policy.
- **WebAuthn rpID = `zone2.day`** — passkey работает на всех поддоменах и переживает смену хостинга.
- Edge Function в Supabase деплоится с `verify_jwt = false` (свой auth).

## 4. Edge-прокси (Cloudflare Worker)

Тонкий, без бизнес-логики:
- Проксирует `api.zone2.day/*` → `${ORIGIN}/functions/v1/api/*` (ORIGIN — переменная окружения).
- Сохраняет метод, заголовки, тело (стриминг), `X-Forwarded-*`.
- Ничего не кэширует для `/mcp`, `/oauth`, `/v1`.
- Переезд бэкенда = смена `ORIGIN`. Free tier: 100k запросов/сутки — с запасом.

## 5. Модули бэкенда

```
backend/src/
  app.ts                 # сборка Hono-приложения (без привязки к рантайму)
  entry/supabase.ts      # Deno.serve для Edge Function
  entry/local.ts         # локальный сервер / VPS
  config.ts              # env → типизированный конфиг
  domain/                # чистая логика без IO: зоны, резолв таргетов,
                         # интервалы, нагрузка, склейка активностей, генерация .zwo
  db/                    # drizzle schema, репозитории, миграции
  ports/                 # интерфейсы: BlobStore, Clock, PushSender, IntervalsClient
  adapters/              # s3-blob, apns (позже), intervals-http, fake-* для тестов
  auth/                  # oauth AS, DCR, PKCE, токены, passkey, страницы логина
  mcp/                   # сервер, регистрация tools по доменам, общие хелперы ответов
    tools/{context,profile,plan,activities,strength,health,events,notebook,export,debug}.ts
  sync/                  # REST /v1: sync feed, uploads, devices, client-logs
  ingest/                # HealthKit dump → activity; FIT → activity; merge
  jobs/                  # intervals poll, пересчёты, чистка
```

**Правила переносимости** (проверяются ревью и линтером импортов):
1. `domain/` не импортирует ничего, кроме `zod` и своих модулей.
2. Доступ к Supabase-специфике — только в `adapters/` и `entry/supabase.ts`.
3. Файлы — только через порт `BlobStore` (S3 API).
4. Задачи по расписанию — HTTP-эндпоинты `jobs/*`; кто их дёргает (pg_cron, cron на VPS, Cloud Scheduler) — конфигурация.
5. Никаких Supabase Realtime/RLS/Auth в логике: изоляция пользователей — в репозиториях по `user_id` (+ тесты).
6. **Data API Supabase (PostgREST) не используется.** Все таблицы — в схеме Postgres `zone2`, которая не входит в exposed-схемы; `auto_expose_new_tables = false`. Иначе таблицы в `public` были бы доступны по публичному anon-ключу.

## 6. Аутентификация

Один OAuth 2.1 Authorization Server для всех клиентов.

| Эндпоинт | Назначение |
|---|---|
| `/.well-known/oauth-protected-resource` (+ `/mcp` вариант) | метаданные ресурса MCP |
| `/.well-known/oauth-authorization-server` | метаданные AS |
| `POST /oauth/register` | Dynamic Client Registration (claude.ai) |
| `GET /oauth/authorize` | страница входа: passkey (WebAuthn), согласие |
| `POST /oauth/token` | code+PKCE(S256) → access/refresh, ротация refresh |
| `POST /oauth/revoke` | отзыв |

- **Клиенты**: claude.ai (DCR), iOS-приложение (предзарегистрированный public client, `ASWebAuthenticationSession`, callback `zone2://oauth/callback`), Claude Code (DCR или персональный токен).
- **Токены**: непрозрачные случайные строки, в БД — SHA-256. Access 1 ч, refresh 90 дней со скользящей ротацией.
- **Повтор старого refresh** (каждый токен помнит `parent_hash` — refresh, под который выдан):
  - ≤ 60 с после ротации, цепочка жива → гонка двух запросов клиента: выдаём ещё одну пару, ничего не отзываем;
  - позже, но ничего из выданного под этот токен не использовано → ответ потерян (iOS усыпила приложение в фоне посреди запроса): неполученная пара удаляется, выдаётся новая (`oauth.refresh_recovered`);
  - преемник уже использован → кража или сломанный клиент: отзываем всю цепочку (`oauth.refresh_reuse`), клиент входит заново.
- iOS хранит токены в Keychain и заменяет запись через `SecItemUpdate` (не delete+add — между ними токены можно потерять).
- **Scopes**: `mcp` (инструменты AI), `app` (Sync API), `debug` (debug-инструменты, только для dev).
- **Регистрация пользователя**: инвайт-код → создание passkey. Позже — привязка Sign in with Apple.

## 7. Основные потоки данных

1. **План → часы.** MCP `plan_workouts` → Postgres (+ change log, + запись в change feed) → [фаза 3: push] → iOS SyncEngine тянет изменения → GRDB → WorkoutBridge планирует на часы → iOS отправляет `delivery ack` → AI видит статус. Подробно: [05-sync](05-sync.md).
2. **Тренировка → база.** Часы → HealthKit → HKObserverQuery будит iOS → экспорт дампа → outbox → `POST /v1/activities` → ingest: ряды, круги, интервалы, привязка к плану, FIT → Storage.
3. **MyWhoosh → база → Health.** MyWhoosh → intervals.icu → job `intervals-poll` → оригинальный FIT → ingest → merge с пульсом часов → change feed → iOS пишет в Health (если там нет).
4. **План → MyWhoosh.** Сервер генерирует `.zwo` → iOS «Share» / ссылка в чате → AirDrop → workout.mywhoosh.com.

## 8. Структура репозитория

```
/
  README.md  CLAUDE.md  justfile  .env.example
  docs/                       # эта документация
  schema/                     # сгенерированные openapi.yaml, mcp-tools.json (снапшот)
  backend/                    # Deno-проект (deno.json), src/, tests/
  supabase/                   # config.toml, functions/api/index.ts (импорт backend), migrations/
  edge-proxy/                 # Cloudflare Worker (wrangler.toml)
  ios/
    project.yml               # XcodeGen
    App/                      # iOS-таргет (тонкий)
    Watch/                    # watchOS-таргет (ф.1.5 — компаньон станка, ф.2 — раннер)
    Packages/                 # один SPM-пакет Zone2Core, модули — его targets
      Package.swift
      Sources/Zone2Kit/       # модели, API-клиент, GRDB store, SyncEngine, форматирование
      Sources/Zone2UI/        # дизайн-система, компоненты, экраны (+ Localizable.xcstrings); snapshot-тесты
      Sources/HealthBridge/   # (S1) HealthKit: чтение/запись, формат дампа
      Sources/WorkoutBridge/  # (S1) маппинг структуры → WorkoutKit
      Sources/HRGuard/        # (ф.2) машина состояний сторожа пульса
      Sources/TrainerKit/     # станок по BLE FTMS и пульсометр: разбор данных, RideRecorder (1 Гц → дамп); позже Control Point
    Shared/WorkoutLink.swift  # сообщения часы ↔ iPhone в зеркальной сессии (S9)
    Ride/                     # zone2 Ride — оверлей заезда на Mac (D51), `just ride`
      Tests/…                 # `swift test` на macOS
  fixtures/                   # дампы HealthKit, FIT, ожидаемые результаты
  tools/                      # скрипты: mcp-cli, resign, seed, генераторы; ble-scout (сканер станка)
```
