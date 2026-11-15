# 04. MCP-сервер

Endpoint: `https://api.zone2.day/mcp` (Streamable HTTP, stateless). Auth: OAuth 2.1 (scope `mcp`), см. [02-architecture §6](02-architecture.md#6-аутентификация).

## 1. Принципы

Взяты из разбора blocks.zone и адаптированы.

1. **Один стартовый вызов.** `get_context` даёт всю картину одним запросом. Description прямо говорит: «вызывай первым в разговоре».
2. **Сервер даёт готовые числа.** Зоны, нагрузку, интервалы, попадание в план сервер считает сам и отдаёт с `howToRead`, `basis`, `confidence`, `caveats`, чтобы модели не приходилось делать это каждый раз. Запретов нет: сырые данные (ряды, FIT) доступны, модель может посчитать по-своему, когда это нужно.
3. **Запись сразу, но с откатом.** Карточек подтверждения нет: подтверждение — это разговор в чате. Каждая мутация пишет `change_log` и возвращает `changeId`; `revert_change(changeId)` откатывает. Пакетные операции поддерживают `dryRun: true`.
4. **`why` на изменениях плана** (≤200 символов, язык атлета). Нужен для журнала и для следующего чата, который не помнит предыдущий.
5. **Read-before-write.** Description указывает, откуда брать числа: вес — из `get_exercise_history`, таргет — из профиля или истории интервалов, правка тренировки — после `get_planned_workout`. Нет данных — `null` или RPE, а не выдуманное круглое число.
6. **Компактность.** Около 40 инструментов с единым словарём параметров. Длинные ответы пагинируются (`cursor`). Ряды — с прореживанием (downsampling).
7. **Description каждого инструмента** содержит: когда звать, когда не звать (и что вместо), откуда брать входные числа, как читать ответ, применяется ли запись сразу.
8. **Язык.** Человекочитаемые поля (title, goal, notes, why, coach_notes, блокнот) — на языке атлета. Служебные (`howToRead`) — на английском.
9. **Ошибки — полезные.** Валидация возвращает путь поля, причину и подсказку («`target.low` > `target.high`; поменяй местами»). Частичных записей нет: пакет либо целиком, либо ничего.
10. **Доверие к модели.** Искусственных лимитов на действия модели нет (число ключевых сессий, горизонт планирования и т.п.). Ограничения — только на корректность данных и размер запросов.

## 2. Общие соглашения

- Единицы и форматы — [03-data-model §1](03-data-model.md#1-соглашения).
- Каждый ответ содержит `now: { date, time, weekday, timezone }` атлета: модели не нужно гадать о дате.
- Мутации возвращают `{ changeId, entity, id, version, delivery? }`.
- Списки: `limit` (по умолчанию 20, максимум 100) + `cursor`.
- Временные окна: `from`/`to` включительно, даты атлета.

## 3. Каталог инструментов

Обозначения: **R** — чтение, **W** — запись (сразу, с журналом), **D** — debug (только scope `debug`).

### 3.1 Контекст
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `get_context` | R | `days?` (по умолчанию 14) | Сейчас (дата и TZ); профиль с порогами и зонами в абсолютных единицах; план от вчера до +7 дней со статусами и доставкой; 14 дней план-vs-факт; последние активности с заметками; недельная нагрузка за 12 недель; метрики восстановления за 14 дней и базлайны; старты (принятые и идеи — раздельно); **шапка текущей и следующей недели** + 2–3 последних `review`; **открытые записи журнала** (с `due`, без `closed_at`); **закреплённые страницы блокнота целиком** (с общим лимитом и предупреждением) и индекс остальных; недавние изменения плана (кто, что, `why`); расхождение пояса устройства с эффективным; состояние интеграций и устройств |

### 3.2 Профиль
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `get_profile` | R | — | Профиль целиком: пороги, зоны (границы и модель), оборудование, настройки сторожа пульса |
| `update_profile` | W | частичный патч (всё опционально), `why` | Пороги (число или диапазон `{low, high, basis}`), зоны (в т.ч. `custom` с явными границами), вес, домашний пояс и **поездки** (`travel[]`), оборудование, `mywhooshFtp`, `hrGuard`. Изменение порогов → новая версия будущих тренировок с относительными таргетами. Новые числа — только после согласия атлета |
| `get_metric_history` | R | `kinds?`, `from?`, `to?` | История порогов и измерений с `source` |
| `log_metric` | W | `items[{date, kind, value, source, note?}]` ≤20 | Измерение (тест, лаборатория, оценка). Профиль не меняет: для этого есть `update_profile` |

### 3.3 План
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `get_plan` | R | `from`, `to` (≤62 дня), `include?` (`structure`) | **Недели** (title, header, review) → дни → тренировки (id, order, sport, title, goal, key, estimate, status, delivery, last_change), старты, записи журнала, связанные активности |
| `upsert_week` | W | `weekStart` (понедельник), `title?`, `header?`, `review?`, `notebookRefs?`, `why?` | Шапка недели (вектор, что заморожено, правила) и её итог |
| `get_planned_workout` | R | `id` | Полная структура + `resolved` таргеты + статус доставки + история версий (кратко) |
| `plan_workouts` | W | `items[]` ≤40 (`date, order?, sport, title, goal, notes?, key?, tags?, notebookRefs?, structure \| templateId, execution?`), `why`, `dryRun?` | Создать тренировки. Пакет — атомарный. «Зал A/B» до появления шаблонов — через `copy_planned_workouts` |
| `update_planned_workout` | W | `id`, патч (`date` = перенос, `order`, `structure`, `title`, `goal`, `notes`, `key`, `tags`, `notebookRefs`, `execution`, `skipped: {reason} \| null`), `why` | Правка на месте; перенос — через `date`; **пропуск — `skipped` с причиной**. Замена тренировки — удалить и создать новую |
| `update_planned_workouts` | W | `edits[]` 2–80, `why`, `dryRun?` | Массовая однотипная правка |
| `delete_planned_workouts` | W | `ids[]` ≤40, `why` | Удаление (мягкое, откатывается) |
| `copy_planned_workouts` | W | `ids[]` или `fromDate`/`toDate`, `shiftDays` или `toDates[]`, `why` | «Повтори прошлую неделю» |
| `get_changes` | R | `since?`, `entity?`, `limit?` | Журнал изменений: кто, когда, что, `why`, `changeId` |
| `revert_change` | W | `changeId`, `why` | Откатить изменение (и зависимые, если есть — с предупреждением) |
| `get_delivery_status` | R | `ids?` или `from`/`to` | По каждой тренировке и версии: `synced` на телефон (когда, какое устройство), `scheduled_watch`, ошибки, время последнего синка устройства. Справочный инструмент: зовётся, когда атлет спрашивает или что-то пошло не так, а не после каждой записи плана |

### 3.4 Шаблоны (библиотека) — фаза 2
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `search_templates` | R | `query?`, `sport?`, `tags?`, `durationMin?`/`durationMax?` | Свои шаблоны тренировок |
| `save_template` | W | `title`, `sport`, `structure`, `tags?`, `notes?` | Сохранить в библиотеку (из `plan_workouts` можно ссылаться через `templateId`) |

### 3.5 Активности
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `list_activities` | R | `from?`, `to?`, `sport?`, `limit?`, `cursor?` | Список со сводкой и связью с планом |
| `get_activity` | R | `id`, `detail?` (`summary` \| `full`, по умолчанию `full`) | Сводка (GAP, погода), официальный результат, sRPE, слова атлета, круги (темп и каденс по времени в движении), привязанная тренировка плана с таргетами в абсолютных единицах — **рядом, без автоматического сопоставления** (D41), зоны (+`basis`), нагрузка (+`basis`), Pw:HR / декаплинг по автоматически найденным ровным участкам, механика бега, бассейн (чистый темп и темп с остановками + `confidence`), обувь, трасса, источники и файлы, `howToRead` |
| `get_activity_streams` | R | `id`, `channels?` (в т.ч. `gapSpeed`), `fromSec?`, `toSec?`, `bucketSec?` (1–600) или `maxPoints?` (≤600) | Ряды в CSV или колонками; по умолчанию около 300 точек на окно; zoom через `fromSec`/`toSec` |
| `get_activity_file` | R | `id`, `kind` (`fit` \| `fit_original` \| `healthkit_dump` \| `streams`) | Подписанная ссылка (TTL 15 мин), размер, sha256. Для Claude Code и скриптов |
| `get_activity_fit` | R | `id`, `messages?` (`session`, `lap`, `record`, `event`, `device_info`…), `limit?` | FIT, раскодированный в JSON (для чат-клиентов без доступа к бинарным файлам). `record` — с прореживанием |
| `update_activity` | W | `id`, `title?`, `tags?`, `coachNotes?` (markdown ≤12000, `append?`), `athleteNotes?` (слова атлета, `append?`), `rpe?` (1–10), `official?` (`{timeSec, distanceM, note}`), `gearId?`, `grade?` (A–E), `plannedWorkoutId?` (связать или отвязать) | Разбор AI, слова атлета, sRPE, официальный результат, обувь, теги (контекст + грунт: `asphalt`, `trail`, `sand`, `snow`, `ice`, `mud`, `track`, `treadmill`), связь с планом |
| `create_activity` | W | `sport`, `start`, `durationSec`, `distanceM?`, `title?`, `athleteNotes?`, `rpe?`, `tags?`, `gearId?`, `why?` | Активность со слов атлета (`source: manual`) — когда записи нет |
| `import_activity_file` | W | `url` или `uploadId` (файл FIT/GPX), `title?`, `tags?` | Импорт файла (`fit_upload` / `gpx_upload`); FIT сохраняется байт в байт |
| `edit_activity_data` | W | `id`, `mode` (`trim` \| `split` \| `merge` \| `move` \| `revert`), параметры режима, `why` | Исправление записи; последствия пересчитывает сервер |

### 3.6 Силовые
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `get_strength_log` | R | `from?`, `to?`, `exercise?` | Подход за подходом: план vs факт, заметки, пропуски |
| `get_exercise_history` | R | `exercise`, `sessions?` (2–20) | Прогрессия упражнения: лучший подход, e1RM (оценка), RPE vs план, перерывы. **Единственный источник для веса** в новых планах |
| `update_strength_log` | W | `sessionId`, `sets[]` (патч), `why` | Исправление лога (например, атлет в чате сказал, что ошибся) |
| `merge_exercises` | W | `names[]`, `into`, `why` | Склеить одно движение, записанное под разными именами |
| `log_strength_session` | W | `date`, `plannedWorkoutId?`, `sets[]` (`exercise, reps, weightKg, holdSec?, rpe?, note?`), `notes?`, `why?` | Силовая задним числом (перенос весов из Notion, сессия со слов атлета) |

### 3.7 Здоровье и восстановление
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `get_daily_metrics` | R | `from`, `to`, `kinds?` | HRV (SDNN), пульс покоя, сон, вес, VO2max + базлайны 7/28 дней, z-score, `howToRead` |
| `get_load` | R | `from`, `to`, `groupBy?` (`day` \| `week`), `sport?` | Фаза 1: **объём по видам спорта** (время, дистанция) + **sRPE × минуты** по дням и неделям, `basis`. TSS-подобная модель — позже |
| `get_efficiency_trend` | R | `sport`, `metric` (`pace_at_hr` \| `power_at_hr`), `hr?` (уд/мин или коридор), `from`, `to` | Тренд эффективности по ровным участкам (темп/мощность при заданном пульсе, GAP для бега) — **главный трекер базового периода**; с `basis` и числом участков |
| `get_zone_distribution` | R | `from`, `to`, `sport?`, `metric?` | Распределение по зонам (поляризация), `basis` |

### 3.8 Старты
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `list_events` | R | `status?` (по умолчанию все, кроме `cancelled`), `includePast?` | Старты и идеи стартов; неточные даты — окном `date_from`…`date_to` + `date_text`; пояс старта |
| `upsert_event` | W | `id?` + поля события (см. [03-data-model §2.8](03-data-model.md#28-старты--events)) | Создать или изменить; идея → решение = смена `status`, уточнение даты = смена `date_precision` |
| `delete_event` | W | `id`, `why` | Удалить (откатывается) |

`notes` старта — markdown ≤20 000 (план, раскладка, питание); у старта — `notebookRefs`, `courseId`, `timezone`.

### 3.8a Журнал атлета
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `list_journal` | R | `from?`, `to?`, `tags?`, `open?` | Записи: симптомы, дни без активности, снаряжение, посадка, открытые вопросы |
| `write_journal` | W | `id?`, `date`, `text`, `tags?`, `activityId?`, `eventId?`, `gearId?`, `due?`, `close?` | Создать / изменить / закрыть запись. Запись с `due` без закрытия остаётся открытой и всплывает в `get_context` |

### 3.8b Снаряжение и трассы
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `list_gear` | R | `includeRetired?` | Обувь с пробегом (начальный + активности) |
| `upsert_gear` | W | `id?`, `name`, `kind?`, `initialDistanceM?`, `defaultForSport?`, `retired?` | Завести/изменить пару; пара по умолчанию привязывается к новым активностям |
| `list_courses` | R | — | Трассы |
| `upsert_course` | W | `id?`, `name`, `gpx` (`url`/`uploadId`), `segments?`, `notebookRefs?` | Трасса из GPX с кругами и участками |
| `get_course_history` | R | `id`, `from?`, `to?` | Визиты трассы: время участков по визитам (год к году) |

### 3.9 Блокнот AI
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `list_notebook` | R | — | Индекс: slug, title, pinned, размер, `updated_at` |
| `read_notebook` | R | `slug` | Страница целиком |
| `write_notebook` | W | `slug`, `title?`, `content`, `mode` (`replace` \| `append` \| `patch`), `pinned?`, `why?` | Создать или изменить. `patch` — замена фрагмента `find` → `replace` |
| `delete_notebook` | W | `slug`, `why` | Удалить (откатывается) |

Рекомендуемые страницы (описаны в description, AI создаёт сам): `athlete` (кто атлет, цели, ограничения — pinned), `principles` (принципы тренировки атлета — pinned), `health` (травмы, болезни — pinned), `fuel` (питание на тренировках и стартах), `season` (мысли о сезоне и стартах), `agreements` (о чём договорились с атлетом). Короткие датированные заметки — в журнале, не в блокноте.

Закрепить можно любую страницу; при превышении общего лимита закреплённого `write_notebook` и `get_context` предупреждают. Блокнот синхронизируется в приложение и читается там офлайн.

### 3.10 Экспорт и интеграции
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `export_workout` | R | `plannedWorkoutId`, `format` (`zwo`; позже `fit`) | Подписанная ссылка на файл + предупреждение, если `mywhooshFtp` ≠ `bike.ftp`. `.zwo` — **только для тренировок с мощностными таргетами** |
| `get_integrations` | R | — | Статус intervals.icu (последний импорт, ошибки); позже Strava |
| `connect_integration` | W | `kind` (`intervals_icu`), `athleteId`, `apiKey` | Подключить интеграцию: ключ хранится у пользователя в `integrations` (шифрование на уровне хранения). Альтернатива — поле в приложении (Profile → Connections) |
| `run_import` | W | `source` (`intervals_icu`), `since?` | Принудительный импорт сейчас |

### 3.11 Debug (scope `debug`; не выдаётся claude.ai по умолчанию)
| Tool | Тип | Параметры | Назначение |
|---|---|---|---|
| `debug_devices` | D | — | Устройства: версия, последний синк, курсор, outbox, разрешения, запланированное на часах |
| `debug_client_logs` | D | `deviceId?`, `since?`, `level?`, `category?`, `limit?` | Логи с устройств |
| `debug_sync_feed` | D | `since?`, `limit?` | Сырые записи ленты синка |
| `debug_request_log` | D | `since?`, `path?`, `status?` | Последние запросы к API с ошибками |
| `debug_force_resync` | D | `deviceId` | Пометить устройство для полного ресинка |
| `debug_sql` | D | `query` (только SELECT, таймаут, лимит строк) | Только staging и local |

## 4. Форма ответа (пример `get_activity`, сокращено)

```jsonc
{
  "now": { "date": "2026-11-15", "time": "19:40", "weekday": "Sun", "timezone": "Europe/Belgrade" },
  "activity": {
    "id": "…", "sport": "run", "start": "2026-11-15T07:02:11Z", "title": "Morning Run",
    "summary": { "durationSec": 4206, "distanceM": 10420, "avgHr": 141, "avgPaceSecPerKm": 404 },
    "laps": [
      { "index": 0, "kind": "segment", "durationSec": 1200, "movingSec": 1185, "distanceM": 3010, "paceSecPerKm": 394, "avgHr": 138, "cadence": 164 },
      { "index": 1, "kind": "segment", "durationSec": 12, "movingSec": 12, "distanceM": 68, "paceSecPerKm": 176, "maxHr": 166, "cadence": 192 }
    ],
    "zones": { "hr": [ … ], "basis": "hr: zones from LTHR 172 (profile 2026-10-01)" },
    "drift": { "hrDecouplingPct": 3.1, "basis": "first vs second half of steady steps only" }
  },
  "plan": { "id": "…", "title": "10 km + 6×10–12 s hill", "structure": { "steps": [ … ] } }, // таргеты в абсолютных единицах
  "howToRead": ["… nothing is matched to the plan automatically: compare plan.structure with laps and streams yourself"],
  "files": [ { "kind": "fit_generated" }, { "kind": "healthkit_dump" } ]
}
```

## 5. Типовые сценарии

1. **Начало разговора** → `get_context` → ответ, дальше точечные вызовы.
2. **Разбор тренировки** → `get_activity` → (`get_activity_streams` / `get_activity_fit` при необходимости) → `update_activity(coachNotes, grade)` → при необходимости `write_notebook(log)`.
3. **План на неделю** → `get_context` → `get_load` / `get_daily_metrics` → `get_exercise_history` для силовых → `plan_workouts(why)`. Доставка идёт сама; `get_delivery_status` — только если атлет спросит.
4. **Тренировка на станке** → `plan_workouts(execution: "mywhoosh")` → `export_workout(zwo)` → ссылка атлету.
5. **Обновление порогов** → тест в активности → `get_activity` → предложить атлету → `update_profile(why)` + `log_metric`.
6. **Ошибка AI** → `get_changes` → `revert_change`.

## 6. Тестирование MCP

- **Снапшот контракта:** список инструментов, их JSON Schema и descriptions сохраняются в `schema/mcp-tools.json`. Тест падает при любом изменении, и изменение надо осознанно принять (`just mcp-snapshot-update`).
- **Контрактные тесты** через in-memory transport SDK: каждый tool вызывается на фикстурах, golden-ответы.
- **Изоляция:** у каждого tool есть тест «пользователь B не видит данных A».
- **Агентный смоук:** `tools/mcp-cli` вызывает инструменты на local/staging с персональным токеном (см. [08-dev-harness](08-dev-harness.md)).
