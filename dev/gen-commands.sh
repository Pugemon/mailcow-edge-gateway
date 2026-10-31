#!/usr/bin/env bash
# Справочник команд для сайта документации — вывод --help всех скриптов.
# Вызывается из make docs; результат (docs/commands.md) в git не хранится.
set -euo pipefail
cd "$(dirname "$0")/.."
export NO_COLOR=1

cat <<'MD'
# Справочник команд

Страница собирается из `--help` скриптов при сборке сайта (`make docs`), поэтому всегда
совпадает с кодом.

## Общее

| Флаг | Где | Что делает |
|---|---|---|
| `-c`, `--config FILE` | все установочные | файл настроек (по умолчанию `gateway.conf` / `backend.conf` в корне репозитория) |
| `--dry-run` | все установочные | показать план и diff, ничего не менять; root не нужен для рендера и diff |
| `--render DIR` | `gateway/install.sh`, `backend/install.sh` | записать готовые файлы в `DIR` — можно на рабочей машине |
| `-y`, `--yes` | `gateway/install.sh`, `gateway/setup-relay.sh`, `backend/install.sh` | не спрашивать подтверждение |
| `--version` | все | версия |

Коды возврата установочных скриптов: `0` — готово (или нечего менять), `1` — ошибка или отказ
от изменений, `2` — неверные аргументы. У `tools/` — свои коды, см. ниже.

Цвет (OK/WARN/FAIL, заголовки шагов) — только в терминале; переменная `NO_COLOR` его выключает.
MD

for s in gateway/install.sh gateway/setup-relay.sh backend/install.sh backend/issue-cert.sh \
  tools/check-tls.sh tools/check-relay.sh; do
  # Обратные кавычки — разметка Markdown, а не подстановка команды.
  # shellcheck disable=SC2016
  printf '\n## `%s`\n\n```text\n' "$s"
  "./$s" --help
  printf '```\n'
done
