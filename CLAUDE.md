# zone2.day — инструкции для агента

Личное фитнес-приложение, управляемое AI-тренером через MCP. Бэкенд (Deno + Hono + Postgres на Supabase за Cloudflare-прокси `api.zone2.day`), офлайн iOS-приложение (SwiftUI + GRDB), Apple Watch (WorkoutKit, позже свой раннер).

## Документация — читать перед работой над областью
- [docs/01-requirements.md](docs/01-requirements.md) — требования и ключевые сценарии
- [docs/02-architecture.md](docs/02-architecture.md) — архитектура, стек, правила переносимости, структура репо
- [docs/03-data-model.md](docs/03-data-model.md) — сущности, структура тренировки, единицы
- [docs/04-mcp.md](docs/04-mcp.md) — принципы и каталог MCP-инструментов
- [docs/05-sync.md](docs/05-sync.md) — синхронизация, outbox, доставка на часы, ingest
- [docs/06-watch.md](docs/06-watch.md) — часы, WorkoutKit, раннер, сторож пульса
- [docs/07-ios-app.md](docs/07-ios-app.md) — UX/UI
- [docs/08-dev-harness.md](docs/08-dev-harness.md) — команды, тесты, отладка
- [docs/09-roadmap.md](docs/09-roadmap.md) — фазы и задачи
- [docs/10-risks-decisions.md](docs/10-risks-decisions.md) — риски, решения, открытые вопросы

## Жёсткие правила
1. **Офлайн-first:** UI на iOS читает только из GRDB. Сеть — только в SyncEngine/outbox.
2. **Переносимость бэкенда:** `backend/src/domain` без IO; Supabase-специфика только в `adapters/` и `entry/supabase.ts`; файлы только через `BlobStore`.
3. **Изоляция пользователей:** каждый запрос в репозитории фильтруется по `user_id`; новый MCP-инструмент → тест изоляции.
4. **Контракт MCP:** изменения инструментов → `just test-mcp` + осознанное обновление `schema/mcp-tools.json`; descriptions по правилам [docs/04-mcp.md §1](docs/04-mcp.md#1-принципы).
5. **Единицы:** SI (сек, м, уд/мин, Вт, кг), темп — сек/км; даты плана — в TZ атлета.
6. **Prod не трогать** (деплой, запросы, миграции) без явной просьбы пользователя.
7. Xcode-проект генерируется XcodeGen из `ios/project.yml` — `.pbxproj` руками не правим.
8. UI-тексты — через String Catalog (en базовый, ru); не хардкодить строки.

## Команды
`just test` · `just dev` · `just gen` · `just mcp tool=… args='…' env=local` · `just ios-run` · `just snapshots-update` · полный список — [docs/08-dev-harness.md](docs/08-dev-harness.md).

## Definition of Done
Тесты рядом с кодом и зелёный `just test`; снапшоты UI просмотрены; миграции применяются с нуля; доки в `docs/` обновлены при изменении поведения.
