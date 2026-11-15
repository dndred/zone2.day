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

Все таблицы живут в схеме Postgres **`zone2`** (не `public`: см. [02-architecture §5, правило 6](02-architecture.md#5-модули-бэкенда)).

Все таблицы с пользовательскими данными содержат `user_id` (FK → `users`). Изоляция обеспечивается слоем репозиториев и покрыта тестами.

### 1.1 Часовые пояса
Старт в другом поясе — норма (дом UTC+7, СПб/Казань UTC+3, Нови-Сад UTC+2). Механизм:
- `profile.timezone` — домашний пояс; `profile.travel[]` — периоды поездок `{from, to, timezone}`.
- **Эффективный пояс даты** = пояс поездки, покрывающей дату, иначе домашний. Дата плана, «сегодня» в `get_context`, границы суток для метрик и время запланированной на часах тренировки считаются в эффективном поясе этой даты.
- У старта свой `timezone` (место старта); AI заводит поездку при планировании выезда.
- Устройство сообщает текущий пояс при синке; если он не совпадает с эффективным, `get_context` подсвечивает расхождение (AI предлагает добавить поездку).
- Активности хранят UTC + пояс записи (из HealthKit).

## 2. Сущности

### 2.1 Пользователи и доступ
Реализовано в `supabase/migrations/20261114120000_auth.sql`:
- **users**: `id`, `display_name`, `created_at`.
- **invites**: `code_hash` (sha256 нормализованного кода), `note`, `expires_at`, `used_by?`, `used_at?`.
- **passkeys**: `id` (credential id), `user_id`, `public_key`, `counter`, `transports[]`, `device_type`, `backed_up`, `last_used_at`. Позже рядом — идентичность Sign in with Apple.
- **webauthn_challenges**: одноразовые челленджи регистрации/входа (TTL 5 мин).
- **oauth_clients**: `client_id`, `client_secret_hash?`, `client_name`, `redirect_uris[]`, `token_endpoint_auth_method`, `kind` (`dcr` | `first_party`).
- **oauth_codes**: хэш кода, клиент, пользователь, `redirect_uri`, PKCE-челлендж, `scopes[]`, `resource`, TTL 10 мин, одноразовый.
- **oauth_tokens**: хэш, `kind` (`access` 1 ч | `refresh` 90 дн), `scopes[]`, `resource`, `family_id` (повторное использование refresh → отзыв всей семьи).

Будет: **devices**: `id`, `user_id`, `platform`, `model`, `os`, `app_version`, `push_token?`, `timezone` (текущий пояс устройства), `last_seen_at`, `last_sync_cursor`, `capabilities`.

### 2.2 Профиль атлета — `profiles` (1:1 с user)
```jsonc
{
  "timezone": "Asia/Barnaul",     // домашний пояс
  "travel": [                     // поездки: пояс на период (см. §1.1 «Часовые пояса»)
    { "from": "2027-05-28", "to": "2027-06-04", "timezone": "Europe/Moscow", "note": "СПб, старт" }
  ],
  "locale": "ru",                 // язык текстов AI; UI — по языку устройства
  "birthYear": 1985, "sex": "m", "heightCm": 180, "weightKg": 74,
  "run":  { "thresholdPaceSecPerKm": null,          // неизвестно — оценки по истории (§2.3)
            "lthr": { "low": 156, "high": 162,       // порог диапазоном + основание
                      "basis": "отрезки 8–10 мин; прикидка 5 км давала 165–171" },
            "maxHr": 190, "restingHr": 48,
            "hrZones": [ /* границы уд/мин */ ], "paceZones": [ /* сек/км */ ] },
  "bike": { "ftp": 230, "mywhooshFtp": 230, "lthr": 165, "maxHr": 185,
            "powerZones": [...], "hrZones": [...] },
  "swim": { "cssSecPer100m": 115, "poolLengthDefaultM": 25 },
  "zoneModel": { "hr": "custom", "pace": "threshold-5", "power": "coggan-7" },
               // custom = явные границы из hrZones/paceZones/powerZones (договорены с атлетом по ощущениям)
  "equipment": { "trainer": "X2MAX", "trainerApp": "MyWhoosh", "hrStrap": false, "powerMeter": false },
  "availability": { "notes": "..." },
  "hrGuard": { /* настройки сторожа пульса, см. 06-watch */ }
}
```
Любой порог может быть числом или диапазоном `{low, high, basis}`. Место жительства и прочее — в тексте профиля (`availability.notes` / блокнот), отдельных полей нет.

Каждое изменение порога пишется и в **metrics_history** (`kind`, `value`, `date`, `source`: `test|estimate|lab|self_report|device`), чтобы прошлые тренировки можно было пересчитать по действовавшим на тот момент порогам.

### 2.3 Запланированная тренировка — `planned_workouts`
| Поле | Описание |
|---|---|
| `id`, `user_id`, `version` | |
| `date`, `order` | дата (в эффективном поясе дня, §1.1); `order` — порядок внутри дня («зал → бег сразу после»). Время не храним: оно плавает |
| `sport` | `run` \| `bike` \| `swim` \| `strength` \| `other` |
| `sub_sport?` | `indoor_bike` \| `trail` \| `track` \| `treadmill` \| `pool` \| `open_water` … |
| `title` ≤80, `goal` ≤140, `notes` ≤1000 | goal — «что тренируем», notes — «как выполнять» |
| `key` | ключевая сессия |
| `tags[]` | контекст: `indoor`, `heat`, `race`, `test`, `group`, `commute`, `openwater`… |
| `structure` | дерево шагов (§3) или силовая структура (§4) |
| `estimate` | `{durationSec, distanceM, load}` — считает сервер. Без порогов (нет CSS/FTP) — по истории атлета (его реальные темпы/мощности в похожих шагах), а не по «стандартным» значениям |
| `notebook_refs[]` | ссылки на страницы блокнота (несколько) |
| `last_change` | `{at, why}` — последний `why` из журнала изменений; показывается на карточке («изменено 10.11: …») |
| `execution` | `workoutkit` (по умолчанию) \| `zone2_watch` (ф.2) \| `mywhoosh` \| `none` |
| `matched_activity_id?` | связь с выполненной активностью |
| `skipped?` | `{reason, at}` — **явный** пропуск, ставит AI с причиной |
| `status` | `skipped` — если задан `skipped`; иначе вычисляется: `planned` \| `done` \| `partial` \| `missed`. Замена тренировки = удалить одну и создать другую |
| `created_by`, `updated_by` | `ai:<client>` \| `user` \| `system` |
| `deleted_at?` | |

### 2.4 Активность — `activities`
| Поле | Описание |
|---|---|
| `id`, `user_id`, `version` | |
| `sport`, `sub_sport`, `start_at`, `end_at`, `timezone` | |
| `sources[]` | `{kind: healthkit\|intervals\|fit_upload\|gpx_upload\|manual\|merged, externalId, device, app}` — дедупликация |
| `summary` | длительность (elapsed/moving), дистанция, набор, ср./макс. пульс, темп, **GAP** (темп с поправкой на уклон), мощность (avg/NP), каденс (темп и каденс — по времени в движении: стояние на старте и светофоры не разбавляют; бег — шаги/мин, вело — об/мин без нулей наката), калории, механика бега (GCT, VO, длина шага, мощность бега), **погода** из метаданных HealthKit (температура, влажность, ветер), бассейн (длина, гребки, SWOLF, **чистый темп отдельно от времени с остановками** — с `confidence`, часы ненадёжно режут отрезки) |
| `official?` | официальный результат: `{timeSec, distanceM, note}` — для стартов и прикидок (часы ошибаются в дистанции на +0.8–1.3% и во времени) |
| `rpe?` | sRPE 1–10 (со слов атлета) |
| `athlete_notes?` | слова атлета: самочувствие, контекст, ошибки записи — записывает AI из чата, отдельно от `coach_notes` |
| `gear_id?` | обувь (по умолчанию — пара по умолчанию для вида спорта; AI может поправить) |
| `course_id?` | трасса (узнаётся автоматически) |
| `laps[]` | круги/сегменты из источника (HKWorkoutEvent / FIT lap): дистанция, время в движении, темп/скорость и каденс по времени в движении, пульс ср./макс., мощность. С планом **не сопоставляются** (D41) |
| `zones` | время в зонах по пульсу/темпу/мощности + `basis` |
| `load` | нагрузка + `basis` (по мощности / пульсу / RPE) |
| `planned_workout_id?` | связь с тренировкой плана (по дате и виду спорта); оценку выполнения даёт AI, глядя на план и круги рядом |
| `title?`, `tags[]`, `coach_notes?` (markdown от AI ≤12000), `grade?` | теги: контекст (`race`, `test`, `indoor`…) и **грунт** (`asphalt`, `trail`, `sand`, `snow`, `ice`, `mud`, `track`, `treadmill`); словарь — в description MCP |
| `deleted_at?`, `deleted_reason?` | удалена/скрыта: например, удалена в Health (§05 «Удаления из Health») |
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
  "channels": { "hr": [..], "speed": [..], "gapSpeed": [..], "distance": [..], "power": [..], "cadence": [..],
                "altitude": [..], "lat": [..], "lon": [..], "gct": [..], "vo": [..], "strideLen": [..] },
  "gaps": [[startSec, endSec], ...] }
```

### 2.6 Силовые — `strength_sessions`, `strength_sets`, `exercises`
- **exercises**: `id`, `user_id`, `name`, `aliases[]`, `pattern?` (hinge/squat/push/pull/carry/core), `equipment?`. AI может склеивать дубли (`merge_exercises`).
- **strength_sessions**: `id`, `planned_workout_id?`, `date`, `hk_workout_uuid?` (если на часах писалась силовая — оттуда время и пульс), `notes?`.
- **strength_sets**: `id` (генерирует клиент), `session_id`, `exercise_id`, `order`, `set_index`, `planned` (`{reps, weightKg, rpe, holdSec?, distanceM?}`), `actual` (`{reps, weightKg, holdSec?, distanceM?}`), `rpe?`, `note?`, `logged_at`, `source` (`app` \| `ai`).
- Сессия с подходами может быть создана **задним числом через MCP** (`source: ai`) — перенос истории весов из Notion.
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
| `goal?`, `url?`, `notes?` (markdown ≤20000: план, раскладка, питание) | место — в тексте (`name`/`notes`) |
| `timezone?` | пояс места старта (Нови-Сад, СПб…) |
| `course_id?`, `notebook_refs[]` | трасса; страницы блокнота |
| `result?` (`{timeSec, place, notes}`), `activity_id?` | |

Пример: `{ "name": "Brevet 200", "sport": "brevet", "status": "idea", "date_precision": "month_part", "date_from": "2027-06-01", "date_to": "2027-06-10", "date_text": "начало июня 2027", "distance_m": 200000 }`.
В UI и `get_context` идеи показываются отдельно от принятых стартов; обратный отсчёт — только для стартов с точной датой.

### 2.9 Блокнот AI — `notebook_pages`
`id`, `slug` (уникален в пределах пользователя), `title`, `content` (markdown ≤20000), `pinned` (попадает в `get_context` целиком; закрепить можно любую страницу), `version`, `updated_at`, `updated_by`. История версий — в `change_log`.
- **Синхронизируется в приложение** и доступен офлайн как база знаний (список в Profile, рендер markdown).
- **Общий лимит на закреплённые страницы** в `get_context` (по умолчанию 40 000 символов); при превышении `write_notebook` и `get_context` возвращают предупреждение.

### 2.9a Недели — `weeks`
`week_start` (понедельник, уникален в пределах пользователя), `title` (одна строка: «БАЗА — неделя 1»), `header` (markdown: вектор, что заморожено, правила недели), `review` (markdown: итог недели), `notebook_refs[]`, `version`. Пишет AI (`upsert_week`).

### 2.9b Журнал атлета — `journal`
Одна сущность для всего, что не активность: дни без тренировок, симптомы, изменения посадки и снаряжения, открытые вопросы со сроком.
`id`, `date`, `text` (markdown ≤4000), `tags[]` (`migraine`, `soreness`, `pain`, `illness`, `sleep`, `stress`, `travel`, `gear`, `bike-fit`…), `activity_id?`, `event_id?`, `gear_id?`, `due?` (дата), `closed_at?`, `version`.
Запись с `due` и без `closed_at` — **открытая**: `get_context` показывает её сам. В приложении — в дне Calendar.

### 2.9c Снаряжение — `gear`
`id`, `kind` (`shoes`; поле на будущее), `name`, `initial_distance_m` (перенос из Strava), `default_for_sport?` (`run` / `trail`…), `retired_at?`, `notes?`. Пробег = начальный + сумма привязанных активностей (считает сервер).

### 2.9d Трассы — `courses`
`id`, `name`, `gpx` (файл в Storage), `laps?` (круг), `segments[]` (`{name, startM, endM}`), `notebook_refs[]`. Активности на трассе узнаются автоматически (совпадение трека); время участков сравнивается между визитами; трасса привязывается к старту.

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
| Строки Postgres на активность | ~5–20 КБ (summary, laps) | Postgres |

Примерно 1 тренировка в день → ~0.3 ГБ файлов в год (лимит free — 1 ГБ), Postgres — десятки МБ в год (лимит — 500 МБ).

**Бэкфилл — вся история HealthKit** (тренер сравнивает год к году на одной трассе). Оценка: N лет × ~300 тренировок × (дамп ~250 КБ + streams ~100 КБ) ≈ 0.1 ГБ/год истории без FIT. Для старых тренировок `fit_generated` не создаём заранее — генерируем по запросу (`get_activity_file`) и не храним. Если история большая (5+ лет) — дампы старше 2 лет храним в сжатом виде без дублирующих рядов, либо переезжаем на R2 (10 ГБ free). Точный объём меряем в спайке S3 на реальном экспорте.
