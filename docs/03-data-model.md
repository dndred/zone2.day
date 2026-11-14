# 03. Модель данных

## 1. Соглашения

| Что | Формат |
|---|---|
| ID | UUID v7 (сортируемые по времени); клиент может генерировать сам (outbox, идемпотентность) |
| Дата плана | `YYYY-MM-DD` в часовом поясе атлета (`profile.timezone`) |
| Моменты времени | ISO 8601 UTC (`timestamptz`) |
| Длительность | секунды (int) |
| Дистанция | метры |
| Темп бега | сек/км; плавание — сек/100 м |
| Скорость | м/с (в рядах) |
| Пульс | уд/мин; мощность — Вт; каденс — шаг/мин (бег, полный), об/мин (вело) |
| Вес | кг |
| Тексты от AI | на языке атлета (`profile.locale`), с лимитами длины |
| Версионирование | у изменяемых сущностей `version int` (+1 на каждое изменение), `updated_at` |
| Удаление | мягкое (`deleted_at`) — нужно для синка (tombstones) и отката |

Все таблицы с пользовательскими данными содержат `user_id` (FK → `users`). Изоляция обеспечивается слоем репозиториев и покрыта тестами.

## 2. Сущности

### 2.1 Пользователи и доступ
- **users**: `id`, `created_at`, `invite_code_used`, `status`.
- **identities**: `id`, `user_id`, `kind` (`passkey` | `apple`), данные (credentialId, publicKey, signCount, transports | apple sub).
- **oauth_clients**: `client_id`, `name`, `redirect_uris[]`, `kind` (`dcr` | `first_party`), `created_at`.
- **oauth_grants**: коды авторизации (короткоживущие), refresh-токены (хэш, ротация, родитель), access-токены (хэш, TTL), `scopes[]`, `client_id`.
- **devices**: `id`, `user_id`, `platform`, `model`, `os`, `app_version`, `push_token?`, `last_seen_at`, `last_sync_cursor`, `capabilities` (healthkit, workoutkit…).
- **invites**: `code`, `created_by`, `used_by?`.

### 2.2 Профиль атлета — `profiles` (1:1 с user)
```jsonc
{
  "timezone": "Europe/Belgrade",
  "locale": "ru",                 // язык текстов AI; UI — по языку устройства
  "birthYear": 1985, "sex": "m", "heightCm": 180, "weightKg": 74,
  "run":  { "thresholdPaceSecPerKm": 255, "lthr": 172, "maxHr": 190, "restingHr": 48,
            "hrZones": [ /* 5 границ уд/мин */ ], "paceZones": [ /* сек/км */ ] },
  "bike": { "ftp": 230, "mywhooshFtp": 230, "lthr": 165, "maxHr": 185,
            "powerZones": [...], "hrZones": [...] },
  "swim": { "cssSecPer100m": 115, "poolLengthDefaultM": 25 },
  "zoneModel": { "hr": "lthr-5", "pace": "threshold-5", "power": "coggan-7" },
  "equipment": { "trainer": "X2MAX", "trainerApp": "MyWhoosh", "hrStrap": false, "powerMeter": false },
  "availability": { "notes": "..." },
  "hrGuard": { /* настройки сторожа пульса, см. 06-watch */ }
}
```
Каждое изменение порога пишется и в **metrics_history** (`kind`, `value`, `date`, `source`: `test|estimate|lab|self_report|device`), чтобы прошлые тренировки можно было пересчитать по действовавшим на тот момент порогам.

### 2.3 Запланированная тренировка — `planned_workouts`
| Поле | Описание |
|---|---|
| `id`, `user_id`, `version` | |
| `date`, `time?` | дата в TZ атлета; время — если несколько в день или важно |
| `sport` | `run` \| `bike` \| `swim` \| `strength` \| `other` |
| `sub_sport?` | `indoor_bike` \| `trail` \| `track` \| `treadmill` \| `pool` \| `open_water` … |
| `title` ≤80, `goal` ≤140, `notes` ≤1000 | goal — «что тренируем», notes — «как выполнять» |
| `key` | ключевая сессия |
| `tags[]` | контекст: `indoor`, `heat`, `race`, `test`, `group`, `commute`, `openwater`… |
| `structure` | дерево шагов (§3) или силовая структура (§4) |
| `estimate` | `{durationSec, distanceM, load}` — считает сервер |
| `execution` | `workoutkit` (по умолчанию) \| `zone2_watch` (ф.2) \| `mywhoosh` \| `none` |
| `matched_activity_id?` | связь с выполненной активностью |
| `status` (вычисляемое) | `planned` \| `done` \| `partial` \| `missed` \| `skipped` |
| `created_by`, `updated_by` | `ai:<client>` \| `user` \| `system` |
| `deleted_at?` | |

### 2.4 Активность — `activities`
| Поле | Описание |
|---|---|
| `id`, `user_id`, `version` | |
| `sport`, `sub_sport`, `start_at`, `end_at`, `timezone` | |
| `sources[]` | `{kind: healthkit\|intervals\|fit_upload\|merged, externalId, device, app}` — дедупликация |
| `summary` | длительность (elapsed/moving), дистанция, набор, ср./макс. пульс, темп, мощность (avg/NP), каденс, калории, механика бега (GCT, VO, длина шага, мощность бега), бассейн (длина, гребки, SWOLF) |
| `laps[]` | круги/сегменты из источника (HKWorkoutEvent / FIT lap) |
| `intervals[]` | шаги, сопоставленные с планом (сервер): факт vs таргет, `compliance` |
| `zones` | время в зонах по пульсу/темпу/мощности + `basis` |
| `load` | нагрузка + `basis` (по мощности / пульсу / RPE) |
| `planned_workout_id?`, `compliance?` | общая оценка попадания |
| `title?`, `tags[]`, `coach_notes?` (markdown от AI ≤12000), `grade?` | |
| `health_export` | `not_needed` \| `pending` \| `written:<hk uuid>` \| `skipped_overlap` |
| `files[]` | → `activity_files` |

### 2.5 Файлы активности — `activity_files`
| `kind` | Что | Хранение |
|---|---|---|
| `healthkit_dump` | оригинальный дамп из HealthKit (JSON, gzip), без потерь | Storage |
| `fit_original` | оригинальный FIT из внешнего источника, байт в байт | Storage |
| `fit_generated` | FIT, собранный из дампа HealthKit (FIT SDK) | Storage |
| `streams` | нормализованные ряды 1 Гц, колонки (JSON+gzip; позже Parquet) | Storage |
| `zwo` (для planned) | экспорт для MyWhoosh | Storage / на лету |

Поля: `id`, `activity_id`, `kind`, `storage_key`, `bytes`, `sha256`, `created_at`. Отдача — только по подписанной ссылке с TTL 15 мин.

**Формат `streams`** (колоночный, выровнен по секундам от `start_at`):
```jsonc
{ "t0": "2026-11-15T07:02:11Z", "hz": 1,
  "channels": { "hr": [..], "speed": [..], "distance": [..], "power": [..], "cadence": [..],
                "altitude": [..], "lat": [..], "lon": [..], "gct": [..], "vo": [..], "strideLen": [..] },
  "gaps": [[startSec, endSec], ...] }
```

### 2.6 Силовые — `strength_sessions`, `strength_sets`, `exercises`
- **exercises**: `id`, `user_id`, `name`, `aliases[]`, `pattern?` (hinge/squat/push/pull/carry/core), `equipment?`. AI может склеивать дубли (`merge_exercises`).
- **strength_sessions**: `id`, `planned_workout_id?`, `date`, `hk_workout_uuid?` (если на часах писалась силовая — оттуда время и пульс), `notes?`.
- **strength_sets**: `id` (генерирует клиент), `session_id`, `exercise_id`, `order`, `set_index`, `planned` (`{reps, weightKg, rpe, holdSec?, distanceM?}`), `actual` (`{reps, weightKg, holdSec?, distanceM?}`), `rpe?`, `note?`, `logged_at`, `source` (`app` \| `ai`).
- Время подходов и отдыха **не логируется и не планируется**: зал хаотичен. `holdSec` — только для статики (планка), `distanceM` — для переносок. Длительность силовой — внутренняя оценка сервера (`estimate.durationSec`) для календаря и нагрузки, атлету как таргет не показывается.

### 2.7 Метрики здоровья — `daily_metrics`
`date`, `resting_hr`, `hrv_sdnn_ms` (Apple хранит SDNN, не RMSSD — указываем явно), `sleep` (`{totalMin, deepMin, remMin, coreMin, awakeMin, inBedStart, inBedEnd}`), `weight_kg`, `vo2max`, `respiratory_rate?`, `source`, `sample_refs`. Upsert по `(user_id, date)`.

### 2.8 Старты — `events`
| Поле | Описание |
|---|---|
| `id`, `name`, `sport` | `run` \| `trail` \| `triathlon` \| `duathlon` \| `bike` \| `brevet` \| `swim` \| `other` |
| `status` | `idea` (интересно, решения нет) \| `planned` (решил ехать) \| `registered` \| `done` \| `dnf` \| `cancelled` |
| `date_precision` | `day` \| `month_part` (начало/середина/конец месяца) \| `month` \| `season` \| `year` |
| `date_from`, `date_to` | окно, в котором старт может быть; при `day` — одна и та же дата |
| `date_text?` | как сказал атлет: «начало июня 2027» |
| `start_time?` | когда известна точная дата |
| `distance_m?` / `format?` | например `200 km`, `sprint`, `olympic`, `70.3` |
| `priority?` | A/B/C — для `planned`/`registered` |
| `goal?`, `location?`, `url?`, `notes?` (markdown) | |
| `result?` (`{timeSec, place, notes}`), `activity_id?` | |

Пример: `{ "name": "Brevet 200", "sport": "brevet", "status": "idea", "date_precision": "month_part", "date_from": "2027-06-01", "date_to": "2027-06-10", "date_text": "начало июня 2027", "distance_m": 200000 }`.
В UI и `get_context` идеи показываются отдельно от принятых стартов; обратный отсчёт — только для стартов с точной датой.

### 2.9 Блокнот AI — `notebook_pages`
`id`, `slug` (уникален в пределах пользователя), `title`, `content` (markdown ≤20000), `pinned` (попадает в `get_context` целиком), `version`, `updated_at`, `updated_by`. История версий — в `change_log`.

### 2.10 Журнал изменений — `change_log`
Аудит и откат для всего, что пишет AI или пользователь:
`id`, `user_id`, `at`, `actor` (`ai:claude.ai` / `ai:claude-code` / `user:app` / `system:<job>`), `tool` (имя MCP tool или эндпоинта), `entity`, `entity_id`, `op` (`create|update|delete`), `before` (jsonb), `after` (jsonb), `why?` (≤200), `reverted_by?`.

### 2.11 Лента синхронизации — `sync_feed`
Источник для `GET /v1/sync`: `seq bigserial`, `user_id`, `entity`, `entity_id`, `version`, `op` (`upsert|delete`), `at`. Пишется в той же транзакции, что и изменение. Курсор клиента — последний `seq`.

### 2.12 Доставка — `deliveries`
`planned_workout_id`, `version`, `device_id`, `stage` (`synced` \| `scheduled_watch` \| `failed`), `at`, `detail?`. Отчёты присылает iOS; используется в `get_delivery_status` и в debug.

### 2.13 Интеграции — `integrations`
`kind` (`intervals_icu`; позже `strava`), `status`, `credentials` (зашифрованы ключом из секретов), `cursor` (до какого момента импортировано), `last_run_at`, `last_error?`.

### 2.14 Диагностика — `client_logs`
Батчи логов с устройств: `device_id`, `at`, `level`, `category`, `message`, `context` (jsonb). Хранение 14 дней.

## 3. Структура циклической тренировки (`structure` для run/bike/swim)

```jsonc
{
  "schema": 1,
  "poolLengthM": 25,                     // только для бассейна
  "steps": [                             // Node[] ; Node = Step | Repeat ; ≤60 узлов
    {
      "type": "step",
      "id": "s1",                        // стабильный в пределах тренировки
      "kind": "warmup",                  // warmup | work | recovery | rest | cooldown | drill
      "label": "Easy",                   // ≤60, язык атлета
      "duration": { "type": "distance", "m": 3500 },
                  // | { "type": "time", "sec": 600 }
                  // | { "type": "open" }  — без заданной длины: шаг идёт, пока не нажмёшь Lap
                  //                         (или до конца тренировки, если шаг последний)
      "target": {                        // главный таргет — то, по чему ведут часы
        "metric": "hr",                  // hr | pace | power | speed | cadence | rpe
        "low": 125, "high": 145,
        "unit": "abs"                    // abs | pct_threshold (темп/мощность/CSS/LTHR)
      },
      "secondary": [                     // информационные, показываются мельче
        { "metric": "pace", "low": 360, "high": 380, "unit": "abs" }
      ],
      "guard": { "metric": "hr", "low": 125, "high": 145 },  // сторож (ф.2); по умолчанию = target, если metric=hr
      "cadence": { "low": 170, "high": 180 },
      "swim": { "stroke": "free", "mode": "swim", "equipment": ["pullbuoy"] },
      "note": "Relax shoulders"          // ≤120
    },
    {
      "type": "repeat", "id": "r1", "count": 6,
      "steps": [
        { "type": "step", "id": "r1s1", "kind": "work", "label": "Hill sprint",
          "duration": { "type": "time", "sec": 12 },
          "target": { "metric": "rpe", "low": 9, "high": 10 } },
        { "type": "step", "id": "r1s2", "kind": "recovery", "label": "Walk down",
          "duration": { "type": "time", "sec": 105 },
          "target": { "metric": "hr", "high": 140, "unit": "abs" } }
      ]
    },
    {
      "type": "step", "id": "s3", "kind": "cooldown", "label": "Easy as you feel",
      "duration": { "type": "open" },              // open goal: время не задано
      "target": { "metric": "hr", "high": 145, "unit": "abs" },
      "note": "10–20 min, by feel"
    }
  ]
}
```

**Open-шаги** — обычный случай: разминка «пока не разогреешься», заминка «по самочувствию», лёгкий бег без объёма, пресеты под сторожем пульса. Для оценок (время, нагрузка) у open-шага может быть необязательная подсказка `"estimateSec": 900` — она не уходит на часы как цель.

**Резолв таргетов.** В базе таргет может быть относительным (`pct_threshold`). Сервер при каждой выдаче клиенту добавляет `resolved` (абсолютные значения по текущему профилю). Часы получают только абсолютные значения. Изменение порогов → новая версия всех будущих тренировок с относительными таргетами → они переезжают на часы.

## 4. Структура силовой (`structure` для strength)

```jsonc
{
  "schema": 1,
  "items": [
    { "type": "exercise", "id": "e1", "exercise": "Romanian deadlift",
      "sets": 2, "reps": 8, "weightKg": 55, "rpe": 6,
      "note": "50–60 kg, straps, 3 s eccentric" },
    { "type": "exercise", "id": "e2", "exercise": "Bulgarian split squat",
      "sets": 2, "reps": 8, "weightKg": null, "rpe": 6, "perSide": true,
      "note": "Lighter dumbbells than 2×16" },     // weightKg null = «по ощущениям»
    { "type": "exercise", "id": "e3", "exercise": "Plank", "sets": 3, "holdSec": 45 },   // статика
    { "type": "superset", "id": "ss1", "rounds": 3,
      "items": [ { "exercise": "Pallof press", "reps": 10, "perSide": true },
                 { "exercise": "Reverse fly", "reps": 18, "weightKg": 15 } ] }
  ]
}
```
Допускается и развёрнутая форма — разные веса и повторы по подходам: `"setList": [{ "reps": 8, "weightKg": 50 }, { "reps": 8, "weightKg": 55 }]`.

## 5. Хранение и объёмы (оценка на одного пользователя)

| Данные | Размер | Где |
|---|---|---|
| Активность: дамп HK (gzip) | 100–400 КБ/час | Storage |
| FIT | 50–200 КБ/час | Storage |
| streams | 50–150 КБ/час | Storage |
| Строки Postgres на активность | ~5–20 КБ (summary, laps, intervals) | Postgres |

Примерно 1 тренировка в день → ~0.3 ГБ файлов в год (лимит free — 1 ГБ), Postgres — десятки МБ в год (лимит — 500 МБ). При приближении к лимиту: Parquet для рядов, удаление `fit_generated` (восстанавливается из дампа), либо переезд на хранилище R2.
