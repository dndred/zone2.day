# 09. План работ

Фазы идут по порядку; внутри фазы задачи сгруппированы в эпики. У каждой фазы есть критерий готовности — сквозной сценарий из [01-requirements §7](01-requirements.md#7-ключевые-сценарии-acceptance).

Обозначения: 🧪 спайк (проверка риска, результат — вывод и решение) · 🛠 разработка · 👤 нужен атлет (устройство, улица, аккаунт).

---

## Фаза 0 — Каркас и спайки рисков

Цель: снять главные технические риски до того, как строить на них, и получить рабочий каркас для агента.

### 0.1 Каркас 🛠
- [x] Монорепо по структуре из [02-architecture §8](02-architecture.md#8-структура-репозитория), `git init`, `.gitignore`, `.env.example`. Репозиторий: github.com/dndred/zone2.day (публичный).
- [x] `justfile`: `bootstrap`, `dev`, `test`, `ci`, `deploy*`, `smoke`, `ios-*`, `secret` (`gen` — с появлением схем).
- [x] Backend-скелет: Hono `app.ts`, `entry/local.ts`, `entry/supabase.ts`, конфиг (Zod), JSON-логи, request id, `/health`, JSON 404/500.
- [x] Supabase: проекты `zone2-staging` и `zone2-prod`, `supabase/config.toml`, функция `api` (`verify_jwt=false`) задеплоена в staging.
- [x] Cloudflare: Worker `edge-proxy` на `api-staging.zone2.day` (staging). Prod (`api.zone2.day`) — по явной команде.
- [x] iOS-скелет: `project.yml`, пакет `Zone2Core` (`Zone2Kit`, `Zone2UI`, en/ru), приложение показывает статус сервера; `swift test` и сборка под симулятор работают. `HealthBridge`/`WorkoutBridge` — в S1.
- [x] `just mcp <tool> '<json>'` — вызов MCP-инструментов на staging от служебного пользователя `smoke` (`just smoke-token`).
- [x] Среда симулятора iOS 27 (для запуска приложения и UI-тестов в симуляторе; target приложения — iOS 26).

### 0.2 Спайки
| # | Риск | Как проверяем | Критерий успеха | План Б |
|---|---|---|---|---|
| **S1** ✅ ([отчёт](spikes/S1-healthkit-workoutkit.md)) | HealthKit и WorkoutKit на бесплатной Personal Team | Мини-приложение на телефоне: разрешения HealthKit, чтение последней тренировки, `WorkoutScheduler.schedule` для бега с HR-алертом, вело и **бассейна**; требует ли `schedule(_:at:)` час или хватает даты | Тренировки видны в «Тренировке» на Ultra 2, HealthKit читается | Попросить друга добавить в его команду (Developer) |
| **S2** ✅ web (mobile закрыт без проверки — мобильным AI атлет почти не пользуется) | claude.ai находит OAuth через прокси на `api.zone2.day` + Edge Function | Минимальный AS (DCR, authorize с passkey, token) + MCP с инструментом `ping`; подключить коннектор в claude.ai (web и mobile) | `ping` вызывается из claude.ai | Supabase Auth OAuth server или перенос API на Cloud Run |
| **S3** ✅ ([отчёт](spikes/S3-dump-to-fit.md)); ⏳ 👤 внешняя проверка в intervals.icu | Дамп HealthKit → FIT | Экспорт реальной пробежки, `@garmin/fitsdk` encode → decode → сверка; загрузка FIT в intervals.icu как внешний валидатор | Файл валиден, ряды и круги совпадают | Своя минимальная реализация FIT-энкодера |
| **S4** ✅ с оговоркой: медиана 0,5 ч, но бывают дневные дыры по 4–10 ч и пусто ночью ([отчёт](spikes/S4-background-wakes.md)) | Частота фоновых пробуждений без push | Debug-сборка логирует каждое пробуждение (BGAppRefresh, HK observer) на сервер; 3–5 дней обычной жизни | Медианный интервал между пробуждениями днём ≤ 1–2 ч | Ускорить переход на платный аккаунт (push) |
| **S5** ⏸ заморожен (D48: станок — своё приложение) | intervals.icu отдаёт оригинальный FIT заездов MyWhoosh | Атлет подключает MyWhoosh → intervals.icu; скрипт с API-ключом скачивает файл | Оригинальный FIT с мощностью и каденсом | Strava-стримы + генерация FIT |
| **S6** 👤 | Своё приложение на часах: `HKWorkoutSession` в фоне 2+ часа, haptics в фоне, Action Button | Минимальный watch-раннер с сторожем-заглушкой | Сессия живёт 2 ч, сигналы приходят при погашенном экране | Пересмотреть ф.2 (сторож только в пресетах и т.п.) |
| **S8** ✅ ([отчёт](spikes/S8-ftms-trainer.md)); ⏳ 👤 данные при вращении | Станок ThinkRider X2Max по BLE: стандартный FTMS или закрытый протокол | `just ble-scout`: сервисы, характеристики, уведомления | FTMS Indoor Bike Data с мощностью и каденсом; Control Point для ERG | Закрытый протокол / Nordic UART родного приложения |
| **S9** ⛔ заблокирован: Xcode не сопрягается с часами (R14); код готов | Компаньон на часах для станка: Personal Team, `startWatchApp`, зеркальная сессия (задержка пульса), чужие сэмплы мощности в live-builder часов | Минимальный watch-таргет + экран станка на iPhone ([11-trainer §7](11-trainer.md#7-спайк-s9--зеркальная-сессия-и-чужие-сэмплы)) | Пульс на iPhone ≤2 с; в Health одна тренировка с пульсом и мощностью | Запись с iPhone из своего лога (D50) |
| **S7** | Лимиты Edge Function (CPU 2 с) на разбор FIT/дампа | Профилирование ingest часовой и трёхчасовой тренировки | < 1 с CPU | Тяжёлый ingest — в фоновую задачу по частям или на устройстве |

S6 можно провести в начале фазы 2, остальные — до фазы 1.

**Готово, когда:** все спайки фазы 0 дали ответ, решения записаны в [10-risks-decisions](10-risks-decisions.md), каркас собирается, `just test` зелёный.

---

## Фаза 1 — MVP: «план в часах, факт в базе»

### 1.1 Бэкенд: основа 🛠
- [x] Документы (D35): profile (+ поездки), week, planned_workout, event, journal, notebook_page + change_log + sync_feed.
- [ ] Схема БД и миграции: devices, metrics_history, activities, activity_files, strength_*, exercises, daily_metrics, events, journal, gear, notebook_pages, change_log, sync_feed, deliveries, integrations, client_logs, request_log. (Auth-таблицы — готовы в S2.)
- [x] Auth: OAuth 2.1 AS (DCR, PKCE, refresh rotation, revoke), passkey-регистрация по инвайту, страница входа (en/ru). Осталось: first-party client для iOS.
- [x] Часовые пояса: эффективный пояс даты (дом + поездки) — `domain/time.ts`, используется в MCP.
- [ ] Репозитории с изоляцией по `user_id` + change_log + sync_feed в одной транзакции.
- [x] Domain: структура тренировки (Zod), валидация, резолв %-таргетов (пороги-диапазоны → середина + basis), частичные оценки. Осталось: оценки по истории атлета (с активностями), нагрузка.

### 1.2 MCP 🛠
- [x] Сервер, регистрация инструментов, общие хелперы (`now`, ошибки, `howToRead`), снапшот-тест (`schema/mcp-tools.json`).
- [x] `get_context`; профиль; недели (`upsert_week`); план (`plan_workouts`, `update_planned_workout` с `skipped`, `delete`, `copy`, `get_changes`, `revert_change`); старты; блокнот (лимит закреплённого); журнал — **22 инструмента на staging**.
- [x] `get_delivery_status`.
- [ ] `update_planned_workouts` (массовая правка), снаряжение.
- [x] Активности: `list_activities`, `get_activity` (сводка, круги, погода, план), `get_activity_streams`; статусы плана done/skipped/missed/planned.
- [x] Круги с темпом/каденсом по времени в движении, мощностью, пульсом; план рядом с таргетами в абсолютных единицах (без автосопоставления, D41).
- [ ] Активности: ~~GAP~~ ✓, `get_activity_file`/`get_activity_fit`, `update_activity` (слова атлета, sRPE, официальный результат, обувь), ~~`create_activity`~~ ✓, `import_activity_file` (FIT ✓ через `create_upload_link`; GPX, `url` — позже).
- [x] Силовые: `get_strength_log`, `get_exercise_history` (e1RM, план vs факт, перерывы), `update_strength_log`, `merge_exercises`, `log_strength_session` (перенос из Notion); `POST /v1/strength-sessions`; сессии в ленте синка.
- [x] Аналитика (D44): `get_load` (объём + sRPE×мин + HR-нагрузка), `get_zone_distribution` (зоны при чтении, поляризация), `get_efficiency_trend` (темп/мощность при пульсе по ровным участкам), GAP и декаплинг в `get_activity`.
- [x] Здоровье: `get_daily_metrics` (пульс покоя, HRV, сон, дыхание, температура запястья, вес, VO2max против базы 28 дней, флаги), `recovery` в `get_context`.
- [x] Экспорт `.zwo`: `export_workout` (ссылка на 24 ч + XML, FTP MyWhoosh, рампы/ERG/IntervalsT, D46).
- [ ] Интеграции, debug-инструменты.
- [ ] Descriptions по правилам; ревью descriptions «глазами модели» в живом чате.

### 1.3 Ingest и интеграции 🛠
- [x] HealthKit dump (контракт `fixtures/healthkit/contract-v1.json`) → сводка, круги, погода, сопоставление с планом, дубли (копии Strava), оригинал в Storage.
- [x] Удаления из Health → мягкое удаление.
- [x] GAP, гистограммы для зон, ровные участки, декаплинг (`summary.analysis`, D44).
- [ ] Обувь по умолчанию.
- [x] Генерация FIT из дампа (`dumpToFit`, S3, D47). Осталось: отдавать через `get_activity_file kind=fit` / `get_activity_fit`.
- [ ] ⏸ (D48) FIT MyWhoosh → запись в Health приложением; склейка с записью часов.
- [ ] ⏸ (D48) intervals.icu: хранение ключа (шифрование), job `intervals-poll` (pg_cron), дедупликация, `health_export`.

### 1.4 Sync API 🛠
- [x] `GET /v1/sync` (снимок −90…+60 дней + инкремент, 410, `resolved` у тренировок, переразрешение после смены профиля).
- [x] `GET /v1/activities/{id}/streams`, `POST /v1/deliveries`, `POST /v1/strength-sessions`.
- [x] `POST /v1/daily-metrics`.
- [ ] `POST` client-logs, devices.
- [ ] OpenAPI → Swift-клиент (`just gen`).

### 1.5 iOS: данные 🛠
- [x] Вход (`ASWebAuthenticationSession`, passkey, Keychain, refresh). Регистрация устройства — позже.
- [x] GRDB (`record` = JSON сущностей ленты + `sync_state`), SyncEngine (pull страницами, 410 → ресинк), триггеры: foreground, pull-to-refresh, BGAppRefresh, после выгрузки тренировок.
- [x] Доставка на часы: `WorkoutBridge` (план → `CustomWorkout`), отбор «сегодня…+7», сверка `WorkoutScheduler` по id из содержимого, статус «На часах» в UI.
- [x] Outbox (GRDB, backoff 30 с…6 ч, 4xx — пауза на сутки) и отчёт о доставке → `devices`/`deliveries` на сервере, `get_delivery_status`, `delivery` в `get_plan`.
- [ ] BGProcessing, HK observers → pull.
- [x] Экспорт тренировок: разрешения, anchored query (новые + удалённые), дамп, очередь, **бэкфилл всей истории** (≈700 тренировок, ~255 КБ/шт в gzip).
- [x] Суточные метрики: бэкфилл за год, последние 8 дней на каждом синке, observer сна (05-sync §8).
- [ ] Запись внешних активностей в Health.
- [x] Фоновая отправка: экспорт дампов в gzip-файлы → **фоновая URLSession** (досылает при свёрнутом/выгруженном приложении), `beginBackgroundTask` при уходе с экрана. Экспорт требует разблокированного телефона (HealthKit зашифрован при блокировке), поэтому `BGProcessingTask` для бэкфилла не используется.
- [ ] Клиентские логи и отчёты о состоянии устройства.

### 1.6 iOS: UI 🛠👤
- [ ] **Макеты** Today, Planned workout, Completed, Gym → согласование с атлетом.
- [ ] Zone2UI: цвета, компоненты, снапшоты.
- [x] Первая версия экранов: Today (шапка недели, карточки по `order`, план и факт в одной карточке, ближайшие дни, обратный отсчёт до старта), Calendar (недели −8…+6, объём недели, журнал), Planned workout (профиль структуры, шаги с абсолютными таргетами, силовая), Activity (ручные интервалы первыми, сводка, сплиты, заметки), Activities, Profile (аккаунт, Health, синк, debug). Демо-режим `-DemoFeed fixtures/sync/demo-feed.json`.
- [x] Gym mode: подходы из плана, тап = как в плане, правка веса/повторов/удержания, добавить подход, заметка к упражнению; офлайн в GRDB, отправка через outbox снимком сессии; экран не гаснет.
- [x] Последнее изменение плана с `why` на карточке и в тренировке; блокнот офлайн (markdown); графики пульса, темпа/скорости и мощности (Swift Charts) с подсветкой ручных интервалов — ряды кэшируются в GRDB (`GET /v1/activities/{id}/streams`).
- [ ] Экраны дальше: карта трека, зоны, снапшот-тесты.
- [ ] Share `.zwo`, «Open in Workout app».
- [ ] Локализация en/ru.

### 1.7 Эксплуатация 🛠
- [x] `just deploy`, `just smoke`; prod запущен 2026-11-15 (с нуля, вручную из чистого дерева).
- [ ] `just resign` + launchd-задача раз в неделю.
- [x] Бэкапы prod: еженедельно на Mac (`just backup`, launchd); облачной копии пока нет.
- [x] Две копии приложения на телефоне: zone2 (prod) и zone2 stg (staging).
- [ ] Импорт истории: **вся история** HealthKit (бэкфилл, без заранее сгенерированных FIT для старых), замер объёма Storage.
- [ ] Перенос истории весов из Notion через `log_strength_session` (AI в чате) 👤.

**Готово, когда** (👤 в реальной жизни, неделя тренировок):
сценарии 1–4 из [01-requirements §7](01-requirements.md#7-ключевые-сценарии-acceptance) проходят; AI в claude.ai планирует неделю, тренировки сами появляются на часах, выполненные — в базе с разбором; лог зала доходит до AI; заезды на станке доходят до AI с мощностью и пульсом (пока — FIT MyWhoosh вручную, после ф.1.5 — своё приложение).

---

## Фаза 1.5 — Свой станок ([11-trainer](11-trainer.md))

Цель: заезд на станке без MyWhoosh и HeartCast — план на экране iPhone, пульс с наших часов, одна запись в Health. Этап A1 можно делать параллельно с фазой 1.

### A0. Mac + HeartCast (D51) 🛠
- [x] `TrainerKit`: разбор FTMS `2AD2`, Cycling Power `2A63`, Heart Rate `2A37`; `RideRecorder` (1 Гц, 3 с, NP, дамп); тесты на байтах из S8 и HeartCast.
- [x] Оверлей zone2 Ride на Mac (`just ride`): поверх всех окон и полноэкранного видео, автоподключение к станку и HeartCast, запись → `~/zone2/rides/*.json`, `just ride-fit` → FIT.
- [x] 👤 Первый заезд (2026-11-20, 1 ч): цифры правдоподобны, FIT открывается.
- [x] Вход (passkey), план из синка, выбор велотренировки, шаги на оверлее (`StepPlayer`: цель, отсчёт, следующий шаг, подсветка цифр) (D52).
- [x] Загрузка заезда на сервер с привязкой к выбранной тренировке; запись `day.zone2.ride` вытесняет копию HeartCast.
- [x] Запись заезда в Apple Health с iPhone (`RideImport`, `GET /v1/activities/{id}/dump`).
- [ ] 👤 Заезд по плану: шаги переключаются вовремя, тренировка в Fitness с мощностью и пульсом, план done в чате.

### A1. Станок → экран 🛠
- [x] `TrainerKit`: разбор FTMS `2AD2` и Cycling Power `2A63`, golden-байты из S8 (A0).
- [ ] Привязка станка (скан один раз, дальше `retrievePeripherals` по сохранённому id), автопереподключение, debug-экран с возможностями станка.
- [ ] Плеер структуры по времени (общий `StepEngine` с будущим раннером): таймер шага, open-шаги, пауза, пропуск шага.
- [ ] Экран «Станок» (Zone2UI, en/ru, снапшоты): мощность 3 с / пульс / каденс против целей, профиль тренировки, экран не гаснет.
- [ ] Лог 1 Гц в GRDB.
- [ ] `execution: zone2_trainer` в домене, MCP (`plan_workouts` description) и `schema/mcp-tools.json`; кнопка «Start on trainer».
- [ ] 👤 Заезд с экрана iPhone, сверка средних с MyWhoosh.

### A2. Компаньон на часах 🛠👤
- [ ] 🧪 S9.
- [ ] watchOS-таргет в `project.yml`, подпись Personal Team, установка вместе с iOS.
- [ ] `WorkoutLink` (сообщения часы ↔ iPhone), запуск с iPhone (`startWatchApp`), `HKWorkoutSession` indoor cycling + зеркалирование.
- [ ] Пульс на экране iPhone; мощность, каденс, скорость и шаги (`segment`) — в builder часов; метаданные `zone2.plannedWorkoutId`.
- [ ] Минимальный экран на часах: пульс, мощность, шаг, время.
- [ ] 👤 Заезд → Health → сервер → разбор в чате; HeartCast удалён.

### A3. Запасной путь 🛠
- [ ] Запись `HKWorkout` с iPhone из лога 1 Гц, если часов нет.

### B. ERG 🛠
- [ ] Control Point: request control, целевая мощность по шагу (рампы по секундам), поправка ±5 Вт, сброс цели при каденсе < 50.

**Готово, когда:** сценарий 4 из [01-requirements §7](01-requirements.md#7-ключевые-сценарии-acceptance) проходит без MyWhoosh и HeartCast; `zone2_trainer` — режим по умолчанию для станка.

---

## Фаза 2 — Часы и полировка

- [ ] 🧪 S6 (если не сделан раньше).
- [ ] Watch-приложение: Today, раннер (`HKWorkoutSession`, GPS, шаги, сегменты), **сторож пульса** (пакет `HRGuard` + настройки), пресеты.
- [ ] Доставка плана на часы через WatchConnectivity; `execution: zone2_watch`.
- [ ] Паритет записи со штатным приложением (тест на улице) 👤.
- [ ] Виджеты (экран блокировки и домой), усложнение на циферблате.
- [ ] Аналитика: рекорды, оценка порогов по данным (с `confidence`), прогрессия интервалов.
- [ ] Шаблоны тренировок (`save_template` / `search_templates`); до них «Зал A/B» — через `copy_planned_workouts`.
- [ ] Трассы (`courses`): GPX, участки, автоузнавание, сравнение визитов.
- [ ] Экран старта в приложении (план, раскладка, питание офлайн) — низкий приоритет.

**Готово, когда:** сценарий 5 (лёгкий бег под сторожем 2+ часа) проходит; Pulsalarm удалён с часов.

---

## Фаза 3 — Платный аккаунт и интеграции

Старт — когда появится Apple Developer Program.
- [ ] Push: APNs (token auth), silent + видимый + Notification Service Extension, App Group для общей БД.
- [ ] Sign in with Apple как привязанная идентичность.
- [ ] TestFlight; подпись на год вместо еженедельной.
- [ ] Хаб → Strava: загрузка FIT наших активностей; отключение прямых выгрузок MyWhoosh → Strava и Health → Strava.
- [ ] ~~Трансляция пульса с часов в MyWhoosh~~ — отменено (D49), см. ф.1.5.
- [ ] ~~🧪 Автозагрузка `.zwo` в MyWhoosh~~ — не нужна (D48).
- [ ] Открытая вода.

**Готово, когда:** изменение плана в чате появляется на телефоне за секунды даже у закрытого приложения.

---

## Порядок ближайших шагов
1. Каркас 0.1 (агент, без участия атлета).
2. S2 и S3 (агент) параллельно с S1 и S5 (атлет: телефон, intervals.icu).
3. S4 запускается как можно раньше: ему нужны дни реальной жизни.
4. Решения по спайкам → корректировка документов → фаза 1.
5. С 2026-11-20 параллельно фазе 1: станок A1 (агент; 👤 — данные S8 при вращении), затем S9 и A2 (👤 часы).
