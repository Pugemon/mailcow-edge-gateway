# mailcow-edge-gateway — цели для разработки. Установка на серверы — gateway/install.sh и
# backend/install.sh (см. документацию), отдельной цели install нет: узлы ставятся по-разному.

SHELL := /bin/bash
SHELLCHECK ?= shellcheck
MKDOCS ?= mkdocs
RENDER_DIR ?= render

SCRIPTS := lib/common.sh gateway/install.sh gateway/setup-relay.sh backend/install.sh \
           backend/issue-cert.sh tools/check-tls.sh tools/check-relay.sh \
           tests/run.sh tests/validate-configs.sh dev/gen-commands.sh
SH_TEMPLATES := backend/templates/mailcow-cert-reload.sh.tmpl
PY := tests/fake_smtp.py

.DEFAULT_GOAL := help
.PHONY: help test lint validate render docs docs-serve clean

help: ## список целей
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  make %-11s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

test: ## тесты: библиотека, рендер шаблонов, планы --dry-run, tools (без root и сети)
	@bash tests/run.sh

lint: ## bash -n, shellcheck и py_compile
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	@sh -n $(SH_TEMPLATES)
	$(SHELLCHECK) $(SCRIPTS) $(SH_TEMPLATES)
	@PYTHONPYCACHEPREFIX="$${TMPDIR:-/tmp}/meg-pycache" python3 -m py_compile $(PY)
	@echo "lint: OK"

validate: ## haproxy -c и nft -c на отрендеренных примерах (nft — от root: sudo make validate)
	@bash tests/validate-configs.sh

render: ## отрендерить примеры конфигов в render/gateway и render/backend (RENDER_DIR=...)
	@gateway/install.sh -c examples/gateway.conf --render $(RENDER_DIR)/gateway
	@backend/install.sh -c examples/backend.conf --render $(RENDER_DIR)/backend

docs/commands.md: dev/gen-commands.sh lib/common.sh gateway/*.sh backend/*.sh tools/*.sh
	@bash dev/gen-commands.sh > $@

docs: docs/commands.md ## собрать сайт документации в site/ (mkdocs build --strict)
	$(MKDOCS) build --strict

docs-serve: docs/commands.md ## сайт документации на http://127.0.0.1:8000 с автообновлением
	$(MKDOCS) serve

clean: ## удалить site/, render/ и сгенерированный справочник команд
	rm -rf site $(RENDER_DIR) docs/commands.md
