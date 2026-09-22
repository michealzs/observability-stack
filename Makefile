# Day to day commands for the observability stack. Run "make" for the list.

COMPOSE ?= docker compose
PROMETHEUS_IMAGE ?= prom/prometheus:v3.14.0
CURL_IMAGE ?= curlimages/curl:8.22.0
NETWORK ?= observability-stack_monitoring
SERVICE ?=

.DEFAULT_GOAL := help
.PHONY: help up down restart ps logs config lint validate validate-prometheus validate-alertmanager reload ports

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'

up: ## Build the alertmanager image and start everything
	$(COMPOSE) up -d --build

down: ## Stop the stack (named volumes are kept)
	$(COMPOSE) down

restart: ## Restart one service (SERVICE=grafana) or all of them
	$(COMPOSE) restart $(SERVICE)

ps: ## Show service status and health
	$(COMPOSE) ps

logs: ## Follow logs (SERVICE=prometheus to filter)
	$(COMPOSE) logs -f --tail=200 $(SERVICE)

ports: ## Show which ports are published on the host
	@for s in grafana prometheus alertmanager; do printf '%-13s ' "$$s"; $(COMPOSE) port "$$s" $$(case $$s in grafana) echo 3000;; prometheus) echo 9090;; alertmanager) echo 9093;; esac) 2>/dev/null || echo "not published"; done

config: ## Validate the compose file with .env applied
	$(COMPOSE) config -q

lint: ## yamllint, shellcheck, rule and dashboard checks (no Docker needed)
	python3 -m yamllint -c .yamllint.yaml --strict .
	shellcheck scripts/*.sh alertmanager/*.sh
	python3 scripts/check_rules.py prometheus/rules/*.yml
	python3 scripts/check_dashboards.py grafana/dashboards/*.json

validate: config validate-prometheus validate-alertmanager ## Everything CI runs that needs Docker

validate-prometheus: ## promtool check config, check rules and test rules in the pinned image
	docker run --rm -v "$(CURDIR)/prometheus:/etc/prometheus:ro" --entrypoint promtool $(PROMETHEUS_IMAGE) check config /etc/prometheus/prometheus.yml
	docker run --rm -v "$(CURDIR)/prometheus:/etc/prometheus:ro" --entrypoint sh $(PROMETHEUS_IMAGE) -c 'promtool check rules /etc/prometheus/rules/*.yml'
	docker run --rm -v "$(CURDIR)/prometheus:/etc/prometheus:ro" --entrypoint sh $(PROMETHEUS_IMAGE) -c 'promtool test rules /etc/prometheus/tests/*.yml'

validate-alertmanager: ## Render the template with the values from .env and run amtool check-config
	$(COMPOSE) run --rm --build --no-deps alertmanager check

reload: ## Reload Prometheus and Alertmanager configuration without a restart
	docker run --rm --network $(NETWORK) $(CURL_IMAGE) -fsS -X POST http://prometheus:9090/-/reload
	docker run --rm --network $(NETWORK) $(CURL_IMAGE) -fsS -X POST http://alertmanager:9093/-/reload
	@echo "reloaded"
