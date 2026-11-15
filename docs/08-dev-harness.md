# 08. Обвязка для разработки силами AI

Цель: агент (Claude Code) сам собирает, запускает, проверяет и отлаживает **каждую** часть системы — бэкенд, MCP, iOS, часы, устройство в поле — без участия человека там, где это возможно.

## 1. Единая точка входа — `justfile`

| Команда | Что делает |
|---|---|
| `just bootstrap` | Проверка и установка зависимостей (deno, supabase CLI, xcodegen, wrangler), `.env` из `.env.example` |
| `just dev` | `supabase start` + локальный сервер API с hot reload на `:8787` |
| `just test-db-up` | Поднять тестовый Postgres (Docker, `localhost:54329`); каждый прогон тестов создаёт и удаляет свою временную базу с настоящими миграциями |
| `just db-push target=…` | Применить `supabase/migrations` к staging/prod |
| `just db-ro "<sql>"` | Read-only SQL к staging (через Supabase CLI, без пароля) |
| `just invite target=…` | Инвайт на регистрацию; код сохраняется в 1Password, не печатается |
| `just cache-secrets` | Закэшировать секреты staging в `.env.staging.local` (prod не кэшируется) |
| `just db-reset` | (позже) Пересоздать локальную БД, применить миграции, засеять фикстуры |
| `just db-migrate name=…` | Сгенерировать SQL-миграцию из схемы Drizzle |
| `just gen` | Zod → `schema/openapi.yaml` + `schema/mcp-tools.json`; генерация Swift-клиента |
| `just test` | Все тесты, кроме тех, что требуют устройство |
| `just test-backend` | `deno test` (юнит + интеграция с локальным Postgres) |
| `just test-mcp` | Контрактные тесты MCP + проверка снапшота инструментов |
| `just test-kit` | `swift test` для SPM-пакетов на macOS (быстро, без симулятора) |
| `just test-ios` | `xcodebuild test` в симуляторе (UI-тесты, снапшоты) |
| `just snapshots-update` | Перезаписать эталонные снапшоты UI (осознанно) |
| `just mcp <tool> '<json>'` | Вызвать MCP-инструмент на staging от служебного пользователя `smoke` (его данные изолированы от реальных) |
| `just smoke-token` | Один раз: создать пользователя `smoke` и долгоживущий токен (кэш в `.env.staging.local`) |
| `just mcp-snapshot-update` | Принять изменение контракта MCP в `schema/mcp-tools.json` (смотреть diff!) |
| `just ios-device` / `just ios-pull <path>` | Собрать/подписать/поставить/запустить на подключённом iPhone; забрать файл из контейнера приложения |
| `just mcp-inspect` | MCP Inspector против локального сервера |
| `just api method=… path=… env=…` | Вызов Sync API от имени тестового устройства |
| `just logs env=… since=…` | Логи Edge Function (Supabase) |
| `just client-logs env=… device=…` | Логи с устройства (через debug API) |
| `just deploy-staging` / `just deploy-prod` | Миграции → деплой функции → деплой прокси → смоук |
| `just smoke env=…` | Смоук: OAuth-метаданные, `get_context`, синк тестового устройства |
| `just ios-build` / `just ios-run` | Сборка; запуск в симуляторе с аргументами (`-ServerURL`, `-SeedFixture`) |
| `just ios-device` | Сборка и установка на телефон (`xcrun devicectl`, по кабелю или Wi-Fi) |
| `just resign` | Еженедельная переподпись: пересборка и установка iOS- и watch-приложений (Personal Team) |

## 2. Пирамида тестов

### Бэкенд (Deno)
- **Юнит, `domain/`:** резолв таргетов, зоны, круги, склейка активностей, генерация `.zwo`, FIT round-trip. Чистые функции, golden-фикстуры.
- **Интеграция:** репозитории и API на реальном Postgres (`supabase start` или `postgres` в Docker), каждая тестовая сессия — свой schema/transaction.
- **MCP-контракт:** in-memory transport SDK; снапшот списка инструментов и схем; golden-ответы; тест изоляции пользователей для каждого инструмента.
- **Auth:** полный OAuth-флоу (DCR → authorize с фейковым WebAuthn-аутентификатором → token → refresh → revoke).
- **Ingest:** реальные дампы HealthKit и FIT из `fixtures/` → ожидаемые summary, laps (golden JSON).

### iOS / watchOS
- **SPM-пакеты (`swift test` на macOS):** модели, GRDB store и миграции, SyncEngine (фейковый транспорт: лента, ошибки, 410, повторы), outbox, маппинг в WorkoutKit (через промежуточную модель), `StepEngine`, `HRGuard` (последовательности пульса → сигналы), форматтеры.
- **Snapshot-тесты (`swift-snapshot-testing`):** все компоненты и экраны в light/dark × Dynamic Type × en/ru. PNG в репозитории — **агент открывает их и видит UI**.
- **UI-тесты (XCUITest) в симуляторе:** смоук-сценарии с фикстурным сервером (`-ServerURL http://localhost:8787`, `-SeedFixture week1`).
- **HealthKit в симуляторе:** debug-сборка умеет записывать фикстурные тренировки в HealthKit симулятора (`-SeedHealthKit run_10k`), чтобы проверять экспорт целиком.
- **Что нельзя проверить без устройства:** WorkoutScheduler на реальных часах, фоновые пробуждения, GPS и пульс. Для этого — чек-листы ручной проверки и удалённые логи (ниже).

## 3. Наблюдаемость

- **Бэкенд:** структурированные JSON-логи (`requestId`, `userId`-хэш, `tool`, длительность, ошибка). Таблица `request_log` (7 дней) для `debug_request_log`.
- **Устройство:** `Logger` (OSLog) + кольцевой буфер в GRDB → батчи в `POST /v1/client-logs` при каждом синке. Категории: `sync`, `outbox`, `health`, `workoutkit`, `bg`, `ui`. Агент читает через `just client-logs` или MCP `debug_client_logs`.
- **Отчёты состояния устройства** при каждом синке: версия, разрешения, курсор, размер outbox, запланированное на часах, последние фоновые пробуждения → `devices` → `debug_devices`.
- **Спайк S4** использует этот же канал для измерения частоты фоновых пробуждений.

## 4. Инструменты агента

- **Claude Code** в репозитории + `CLAUDE.md` (правила, команды, ссылки на доки).
- **MCP-серверы для агента (в `.mcp.json`):**
  - сам MCP zone2.day на local и staging (со scope `debug`) — агент пользуется продуктом так же, как AI-тренер;
  - Supabase MCP (только staging/local, read-only там, где возможно) — SQL, логи, состояние проекта;
  - iOS Simulator (встроенный инструмент среды) — запуск, скриншоты, тапы;
  - XcodeBuildMCP (опционально) — сборка, тесты, логи симулятора.
- **Фикстуры:** `fixtures/healthkit/*.json.gz`, `fixtures/fit/*.fit` — реальные тренировки атлета (с его согласия, GPS можно сдвигать), плюс синтетический генератор `tools/gen-workout`.

## 5. Окружения и секреты

- `.env.example` — список переменных без значений; `.env.local` — локальные (не коммитится).
- Секреты staging и prod — в `supabase secrets` и `wrangler secret`; ключ шифрования интеграций, соль хэшей токенов, инвайт-коды.
- **Все секреты разработчика — в 1Password**, хранилище `dev tools`, тег `zone2.day`: пароли БД, персональный dev-токен (scope `mcp debug`) для `just mcp`, ключ шифрования интеграций и т.п. Скрипты читают их через `op read "op://dev tools/<item>/<field>"` (CLI `op` работает через интеграцию с приложением 1Password). Репозиторий публичный — секретов в файлах нет.
- Агент **не трогает prod** без явной просьбы: деплой и запросы к prod — только по команде пользователя.

## 6. Рабочий цикл агента (Definition of Done для задачи)

1. Код + тесты рядом (юнит или контракт).
2. `just test` зелёный; при изменении UI — снапшоты обновлены и просмотрены.
3. При изменении MCP — обновлён снапшот `schema/mcp-tools.json`, descriptions соответствуют [04-mcp](04-mcp.md).
4. При изменении схемы БД — миграция, `just db-reset` проходит.
5. Изменено поведение — обновлены доки в `docs/`.
6. Для изменений, затрагивающих устройство, — пункт в чек-листе ручной проверки и логи нужной категории.

## 7. CI/CD (GitHub Actions, `.github/workflows/ci.yml`)

- **Каждый push и PR:** `deno check`, `deno lint`, `deno fmt --check`, все тесты бэкенда и прокси на Postgres 17 (service-контейнер, как в Supabase).
- **Push в `main` → деплой staging** после зелёных тестов: `supabase db push` (миграции), сборка бандла в Docker на раннере, деплой функции с вшитой версией (`BUILD_VERSION` = sha), смоук: `/health` должен отдать этот sha.
- **Миграции данных** (D40) — **пока запускаются вручную**, не на каждый пуш: `just job data-migrations` или ручной запуск workflow `ci` с галкой `data_migrations` (`gh workflow run ci -f data_migrations=true`). Вызывается `POST /jobs/data-migrations` пачками, пока `remaining` не станет 0. Это пересчёт производных данных при изменении кода (например, сводок активностей из сохранённых оригиналов при росте `SUMMARY_VERSION`). Каждая миграция идемпотентна и сама знает, что устарело; новые добавляются в `backend/src/jobs/data_migrations.ts`. Вручную: `just job data-migrations`.
- **Секреты репозитория:** `SUPABASE_ACCESS_TOKEN` (персональный токен Supabase для CI), `STAGING_DB_PASSWORD`, `STAGING_JOB_SECRET`. Ставятся `just gh-secrets`.
- Рантайм-секреты функции (ключ подписи и т.п.) CI не трогает — `just deploy-secrets` при изменении.
- Prod — позже, ручным запуском (`workflow_dispatch`) с GitHub Environment `production`.
- **iOS в CI не собирается — по решению**: установка на телефон всё равно только локальная (`just ios-device`, Personal Team). Проверки — локально: `just test-kit`, `just ios-build`.
