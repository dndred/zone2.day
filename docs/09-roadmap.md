# 09. План работ

Фазы идут по порядку; внутри фазы задачи сгруппированы в эпики. У каждой фазы есть критерий готовности — сквозной сценарий из [01-requirements §7](01-requirements.md#7-ключевые-сценарии-acceptance).

Обозначения: 🧪 спайк (проверка риска, результат — вывод и решение) · 🛠 разработка · 👤 нужен атлет (устройство, улица, аккаунт).

---

## Фаза 0 — Каркас и спайки рисков

Цель: снять главные технические риски до того, как строить на них, и получить рабочий каркас для агента.

### 0.1 Каркас 🛠
- [ ] Монорепо по структуре из [02-architecture §8](02-architecture.md#8-структура-репозитория), `git init`, `.gitignore`, `.env.example`.
- [ ] `justfile` с базовыми командами (`bootstrap`, `dev`, `test`, `gen`).
- [ ] Backend-скелет: Hono `app.ts`, `entry/local.ts`, `entry/supabase.ts`, конфиг, логирование, `/health`.
- [ ] Supabase: проекты `zone2-staging` и `zone2-prod`, `supabase/config.toml`, функция `api` (`verify_jwt=false`).
- [ ] Cloudflare: Worker `edge-proxy` на `api.zone2.day` и `api-staging.zone2.day`.
- [ ] iOS-скелет: `project.yml` (iOS-приложение; часы позже), пакеты `Zone2Kit`, `Zone2UI`, `HealthBridge`, `WorkoutBridge`; `swift test` работает.
- [ ] `tools/mcp-cli` — вызов MCP-инструментов из терминала.

### 0.2 Спайки
| # | Риск | Как проверяем | Критерий успеха | План Б |
|---|---|---|---|---|
| **S1** 👤 | HealthKit и WorkoutKit на бесплатной Personal Team | Мини-приложение на телефоне: разрешения HealthKit, чтение последней тренировки, `WorkoutScheduler.schedule` для бега с HR-алертом, вело и **бассейна** | Тренировки видны в «Тренировке» на Ultra 2, HealthKit читается | Попросить друга добавить в его команду (Developer) |
| **S2** | claude.ai находит OAuth через прокси на `api.zone2.day` + Edge Function | Минимальный AS (DCR, authorize с passkey, token) + MCP с инструментом `ping`; подключить коннектор в claude.ai (web и mobile) | `ping` вызывается из claude.ai | Supabase Auth OAuth server или перенос API на Cloud Run |
| **S3** | Дамп HealthKit → FIT | Экспорт реальной пробежки, `@garmin/fitsdk` encode → decode → сверка; загрузка FIT в intervals.icu как внешний валидатор | Файл валиден, ряды и круги совпадают | Своя минимальная реализация FIT-энкодера |
| **S4** 👤 | Частота фоновых пробуждений без push | Debug-сборка логирует каждое пробуждение (BGAppRefresh, HK observer) на сервер; 3–5 дней обычной жизни | Медианный интервал между пробуждениями днём ≤ 1–2 ч | Ускорить переход на платный аккаунт (push) |
| **S5** | intervals.icu отдаёт оригинальный FIT заездов MyWhoosh | Атлет подключает MyWhoosh → intervals.icu; скрипт с API-ключом скачивает файл | Оригинальный FIT с мощностью и каденсом | Strava-стримы + генерация FIT |
| **S6** 👤 | Своё приложение на часах: `HKWorkoutSession` в фоне 2+ часа, haptics в фоне, Action Button | Минимальный watch-раннер с сторожем-заглушкой | Сессия живёт 2 ч, сигналы приходят при погашенном экране | Пересмотреть ф.2 (сторож только в пресетах и т.п.) |
| **S7** | Лимиты Edge Function (CPU 2 с) на разбор FIT/дампа | Профилирование ingest часовой и трёхчасовой тренировки | < 1 с CPU | Тяжёлый ingest — в фоновую задачу по частям или на устройстве |

S6 можно провести в начале фазы 2, остальные — до фазы 1.

**Готово, когда:** все спайки фазы 0 дали ответ, решения записаны в [10-risks-decisions](10-risks-decisions.md), каркас собирается, `just test` зелёный.

---

## Фаза 1 — MVP: «план в часах, факт в базе»

### 1.1 Бэкенд: основа 🛠
- [ ] Схема БД и миграции: users, identities, oauth, devices, profiles, metrics_history, planned_workouts, activities, activity_files, strength_*, exercises, daily_metrics, events, notebook_pages, change_log, sync_feed, deliveries, integrations, client_logs, request_log.
- [ ] Auth: OAuth 2.1 AS (DCR, PKCE, refresh rotation, revoke), passkey-регистрация по инвайту, страница входа (en/ru), first-party client для iOS.
- [ ] Репозитории с изоляцией по `user_id` + change_log + sync_feed в одной транзакции.
- [ ] Domain: структура тренировки (Zod), валидация, резолв таргетов, оценки длительности и нагрузки, зоны.

### 1.2 MCP 🛠
- [ ] Сервер, регистрация инструментов, общие хелперы (`now`, ошибки, `howToRead`), снапшот-тест.
- [ ] `get_context`; профиль; план (`plan_workouts`, `update_*`, `delete`, `copy`, `get_changes`, `revert_change`, `get_delivery_status`); старты; блокнот.
- [ ] Активности: `list`, `get` (summary + laps + intervals), `streams`, `file`, `fit`, `update_activity`.
- [ ] Силовые: `get_strength_log`, `get_exercise_history`, `update_strength_log`, `merge_exercises`.
- [ ] Здоровье: `get_daily_metrics`, `get_load`, `get_zone_distribution`.
- [ ] Экспорт `.zwo`, интеграции, debug-инструменты.
- [ ] Descriptions по правилам; ревью descriptions «глазами модели» в живом чате.

### 1.3 Ingest и интеграции 🛠
- [ ] HealthKit dump → streams, laps, сопоставление с планом, интервалы, compliance, зоны, нагрузка, FIT.
- [ ] FIT → activity; склейка с HealthKit-активностью по времени.
- [ ] intervals.icu: хранение ключа (шифрование), job `intervals-poll` (pg_cron), дедупликация, `health_export`.

### 1.4 Sync API 🛠
- [ ] `GET /v1/sync` (снимок + инкремент, 410), `GET /v1/activities/{id}/streams`, `POST` activities/uploads/commit, daily-metrics, strength-logs, deliveries, client-logs, devices.
- [ ] OpenAPI → Swift-клиент (`just gen`).

### 1.5 iOS: данные 🛠
- [ ] Вход (`ASWebAuthenticationSession`, Keychain), регистрация устройства.
- [ ] GRDB-схема и миграции, SyncEngine (pull + apply), outbox, триггеры: foreground, BGAppRefresh, HK observers, BGProcessing.
- [ ] HealthBridge: разрешения, экспорт дампа тренировки, суточные метрики (+бэкфилл 180 дней), запись внешних активностей в Health.
- [ ] WorkoutBridge: маппинг структуры → WorkoutKit, `WorkoutScheduleReconciler`, delivery acks.
- [ ] Клиентские логи и отчёты о состоянии устройства.

### 1.6 iOS: UI 🛠👤
- [ ] **Макеты** Today, Planned workout, Completed, Gym → согласование с атлетом.
- [ ] Zone2UI: цвета, компоненты, снапшоты.
- [ ] Экраны: Today, Calendar, Planned workout, Completed/Activity, Activities, Gym mode, Profile, Debug.
- [ ] Share `.zwo`, «Open in Workout app».
- [ ] Локализация en/ru.

### 1.7 Эксплуатация 🛠
- [ ] `just deploy-*`, `just smoke`, `just resign` + launchd-задача раз в неделю.
- [ ] Бэкапы: еженедельный `pg_dump` в Storage (у free-плана Supabase нет бэкапов).
- [ ] Импорт истории: последние N месяцев тренировок из HealthKit (бэкфилл), чтобы AI сразу видел контекст.

**Готово, когда** (👤 в реальной жизни, неделя тренировок):
сценарии 1–4 из [01-requirements §7](01-requirements.md#7-ключевые-сценарии-acceptance) проходят; AI в claude.ai планирует неделю, тренировки сами появляются на часах, выполненные — в базе с разбором; лог зала доходит до AI; заезды MyWhoosh приходят с оригинальным FIT.

---

## Фаза 2 — Часы и полировка

- [ ] 🧪 S6 (если не сделан раньше).
- [ ] Watch-приложение: Today, раннер (`HKWorkoutSession`, GPS, шаги, сегменты), **сторож пульса** (пакет `HRGuard` + настройки), пресеты.
- [ ] Доставка плана на часы через WatchConnectivity; `execution: zone2_watch`.
- [ ] Паритет записи со штатным приложением (тест на улице) 👤.
- [ ] Виджеты (экран блокировки и домой), усложнение на циферблате.
- [ ] Аналитика: рекорды, оценка порогов по данным (с `confidence`), прогрессия интервалов.
- [ ] Шаблоны тренировок (`save_template` / `search_templates`).

**Готово, когда:** сценарий 5 (лёгкий бег под сторожем 2+ часа) проходит; Pulsalarm удалён с часов.

---

## Фаза 3 — Платный аккаунт и интеграции

Старт — когда появится Apple Developer Program.
- [ ] Push: APNs (token auth), silent + видимый + Notification Service Extension, App Group для общей БД.
- [ ] Sign in with Apple как привязанная идентичность.
- [ ] TestFlight; подпись на год вместо еженедельной.
- [ ] Хаб → Strava: загрузка FIT наших активностей; отключение прямых выгрузок MyWhoosh → Strava и Health → Strava.
- [ ] Трансляция пульса с часов в MyWhoosh (iPhone как BLE-пульсометр).
- [ ] 🧪 Автозагрузка `.zwo` в MyWhoosh (помощник на Mac) — если позволяют правила MyWhoosh.
- [ ] Открытая вода.

**Готово, когда:** изменение плана в чате появляется на телефоне за секунды даже у закрытого приложения.

---

## Порядок ближайших шагов
1. Каркас 0.1 (агент, без участия атлета).
2. S2 и S3 (агент) параллельно с S1 и S5 (атлет: телефон, intervals.icu).
3. S4 запускается как можно раньше: ему нужны дни реальной жизни.
4. Решения по спайкам → корректировка документов → фаза 1.
