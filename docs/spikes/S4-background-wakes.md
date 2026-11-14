# Спайк S4 — частота фоновых пробуждений без push

Старт: 2026-11-14 16:08 UTC (23:08 Барнаул). Устройство: iPhone 16 Pro, iOS 27.0.1. Сборка: debug, Personal Team.
Код: `ios/App/Spike/S4WakeMonitor.swift`, вкладка «S4». Журнал: `Documents/wakes.jsonl` (`just ios-pull Documents/wakes.jsonl`).

## Что пишется
Одна JSON-строка на пробуждение: `trigger` (`launch`, `foreground`, `bg.refresh`, `hk.workout`, `hk.steps`), состояние приложения, доступность сети (`GET /health` staging, мс).
Триггеры: `BGAppRefreshTask` (перепланируется на +30 мин при каждом запуске и уходе в фон), `HKObserverQuery` + background delivery (тренировки `.immediate`, шаги `.hourly`).

## Условия замера
- Обычная жизнь 3–5 дней; приложение **не смахивать** из переключателя (смахнутое приложение iOS не будит).
- Сигналы HK, совпадающие по времени с `launch`, — первичные срабатывания при регистрации, в статистику не идут.

## Критерий (из 09-roadmap)
Медианный интервал между фоновыми пробуждениями днём ≤ 1–2 ч.

## Находки по ходу
- `BGTaskScheduler.submit` до регистрации обработчика (в `App.init`) роняет приложение (`NSInternalInconsistencyException`). SwiftUI регистрирует `.backgroundTask` после `init` → планировать при `scenePhase == .active/.background` и в самом обработчике.

## Результат
_заполняется после замера_
