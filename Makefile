#!/usr/bin/make -f

SHELL := /bin/bash
PATH := $(HOME)/bin:$(PATH)
CONTEXT_FILE := .contexts.txt
NS ?= monitoring
PRINCIPAL ?= $(shell kubectl config current-context 2>/dev/null)

.PHONY: help setup-contexts get-ns deploy-monitoring connect-skupper grafana-config full-deploy cleanup start-loadtest

help:
	@echo "Comandos disponíveis:"
	@echo "  make setup-contexts [PRINCIPAL=nome]  - Lista clusters ativos e define o cluster principal"
	@echo "  make get-ns                           - Executa 'kubectl get ns' para cada cluster listado"
	@echo "  make deploy-monitoring [NS=namespace] - Instala o kube-prometheus-stack nos clusters"
	@echo "  make connect-skupper                  - Conecta os clusters via Skupper"
	@echo "  make grafana-config                   - Configura datasources do Grafana para clusters remotos"
	@echo "  make full-deploy                      - Executa todo o processo de deploy (setup + monitoring + skupper + grafana)"
	@echo "  make cleanup                          - Remove todos os recursos criados em todos os clusters"
	@echo "  make start-loadtest                   - Inicia testes de carga com K6 nos clusters (exceto principal)"
	@echo ""
	@echo "Variáveis padrão:"
	@echo "  NS=monitoring                         - Namespace usado para deploy"
	@echo "  PRINCIPAL=<contexto-atual>            - Cluster principal (auto-detectado)"
	@echo ""
	@echo "Exemplos:"
	@echo "  make setup-contexts                   # Usa contexto atual como principal"
	@echo "  make setup-contexts PRINCIPAL=minikube"
	@echo "  make deploy-monitoring NS=prod"
	@echo "  make full-deploy PRINCIPAL=aws NS=monitoring"

setup-contexts:
	@echo "Coletando clusters via kubectx..."
	@if ! command -v kubectx &> /dev/null; then \
		echo "Erro: kubectx não está instalado."; \
		exit 1; \
	fi
	@kubectx > .tmp_contexts
	@if grep -q "# principal" $(CONTEXT_FILE) 2>/dev/null; then \
		echo "Cluster principal já definido em $(CONTEXT_FILE): $$(grep '# principal' $(CONTEXT_FILE) | sed 's/ # principal//')"; \
	else \
		echo "Definindo cluster principal: $(PRINCIPAL)"; \
		if ! grep -q "^$(PRINCIPAL)$$" .tmp_contexts; then \
			echo "Erro: Cluster '$(PRINCIPAL)' não encontrado nos contextos do kubectx."; \
			echo "Contextos disponíveis:"; \
			cat .tmp_contexts; \
			echo "Use: make setup-contexts PRINCIPAL=nome-do-cluster"; \
			rm -f .tmp_contexts; \
			exit 1; \
		fi; \
		cat .tmp_contexts | sed "s/^$(PRINCIPAL)$$/$(PRINCIPAL) # principal/" > $(CONTEXT_FILE); \
		echo "Cluster principal configurado: $(PRINCIPAL)"; \
	fi
	@rm -f .tmp_contexts

get-ns:
	@if [ ! -f $(CONTEXT_FILE) ]; then \
		echo "Arquivo $(CONTEXT_FILE) não encontrado. Execute 'make setup-contexts' primeiro."; \
		exit 1; \
	fi
	@echo "Obtendo namespaces de todos os clusters listados:"
	@grep -v '^#' $(CONTEXT_FILE) | while read -r line; do \
		ctx=$$(echo $$line | sed 's/ #.*//'); \
		echo "Cluster: $$ctx"; \
		kubectl --context=$$ctx get ns || echo "Erro ao acessar $$ctx"; \
		echo "----------------------------"; \
	done

deploy-monitoring:
	@if [ ! -f $(CONTEXT_FILE) ]; then \
		echo "Arquivo $(CONTEXT_FILE) não encontrado. Execute 'make setup-contexts' primeiro."; \
		exit 1; \
	fi
	@echo "Verificando repositório Helm..."
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	@helm repo update
	@echo "Iniciando instalação do kube-prometheus-stack nos clusters..."
	@echo "Namespace utilizado: $(NS)"
	@grep -v '^#' $(CONTEXT_FILE) | while read -r line; do \
		ctx=$$(echo $$line | sed 's/ #.*//'); \
		is_principal=$$(echo $$line | grep -q "# principal" && echo "true" || echo "false"); \
		chart_path="configs/helm/kube-prometheus-stack"; \
		values_file="$$chart_path/values.yaml"; \
		if [ "$$is_principal" = "true" ]; then \
			values_file="$$chart_path/values-pri.yaml"; \
		fi; \
		release_name="kube-prometheus-stack-$$ctx"; \
		echo "Instalando no cluster: $$ctx (Release: $$release_name)"; \
		kubectl --context=$$ctx create ns $(NS) --dry-run=client -o yaml | kubectl --context=$$ctx apply -f -; \
		helm upgrade --install $$release_name prometheus-community/kube-prometheus-stack \
			--kube-context $$ctx \
			--namespace $(NS) \
			--create-namespace \
			-f $$values_file \
			--wait; \
		echo "Deploy concluído em $$ctx"; \
		echo "----------------------------"; \
	done

connect-skupper:
	@if [ ! -f $(CONTEXT_FILE) ]; then \
		echo "Arquivo $(CONTEXT_FILE) não encontrado. Execute 'make setup-contexts' primeiro."; \
		exit 1; \
	fi
	@mkdir -p .skupper-tokens
	@echo "Inicializando conexão Skupper entre os clusters..."
	@principal=$$(grep "# principal" $(CONTEXT_FILE) | sed 's/ # principal//'); \
	echo "Inicializando Skupper no cluster principal ($$principal) primeiro..."; \
	kubectl --context=$$principal create ns $(NS) --dry-run=client -o yaml | kubectl --context=$$principal apply -f -; \
	skupper init --context $$principal --namespace $(NS); \
	echo "Aguardando Skupper ficar pronto no cluster principal..."; \
	kubectl --context=$$principal -n $(NS) wait --for=condition=Ready pod -l app=skupper-router --timeout=120s; \
	echo "Skupper pronto no cluster principal. Configurando clusters secundários..."; \
	grep -v '^#' $(CONTEXT_FILE) | while read -r line; do \
		ctx=$$(echo $$line | sed 's/ #.*//'); \
		is_principal=$$(echo $$line | grep -q "# principal" && echo "true" || echo "false"); \
		if [ "$$is_principal" = "false" ]; then \
			echo "Configurando Skupper no cluster secundário: $$ctx"; \
			kubectl --context=$$ctx create ns $(NS) --dry-run=client -o yaml | kubectl --context=$$ctx apply -f -; \
			skupper init --context $$ctx --namespace $(NS) --ingress none; \
			echo "Aguardando Skupper ficar pronto em $$ctx..."; \
			kubectl --context=$$ctx -n $(NS) wait --for=condition=Ready pod -l app=skupper-router --timeout=120s; \
			token_file=".skupper-tokens/$$ctx-token.yaml"; \
			echo "Gerando token no cluster principal para $$ctx"; \
			skupper token create $$token_file --context $$principal --namespace $(NS); \
			sleep 5; \
			echo "Linkando $$ctx ao cluster principal ($$principal)"; \
			skupper link create $$token_file --context $$ctx --namespace $(NS); \
			echo "Aguardando link ficar ativo..."; \
			sleep 10; \
			echo "Expondo serviço 'kube-prometheus-stack-prometheus' no $$ctx via Skupper..."; \
			skupper expose statefulset prometheus-kube-prometheus-stack-$$ctx-prometheus \
				--port 9090 --address prometheus-$$ctx \
				--context $$ctx --namespace $(NS); \
			echo "Skupper configurado no cluster: $$ctx"; \
		fi; \
		echo "----------------------------"; \
	done

grafana-config:
	@if [ ! -f $(CONTEXT_FILE) ]; then \
		echo "Arquivo $(CONTEXT_FILE) não encontrado. Execute 'make setup-contexts' primeiro."; \
		exit 1; \
	fi
	@echo "Criando ConfigMap de datasources para Grafana no cluster principal..."
	@principal=$$(grep "# principal" $(CONTEXT_FILE) | sed 's/ # principal//'); \
	datasource_dir="configs/grafana-datasources"; \
	mkdir -p $$datasource_dir; \
	grep -v '^#' $(CONTEXT_FILE) | while read -r line; do \
		ctx=$$(echo $$line | sed 's/ #.*//'); \
		is_principal=$$(echo $$line | grep -q "# principal" && echo "true" || echo "false"); \
		if [ "$$is_principal" = "false" ]; then \
			file="datasource-$$ctx.yaml"; \
			echo "Gerando $$file"; \
			echo "apiVersion: v1" > $$datasource_dir/$$file; \
			echo "kind: ConfigMap" >> $$datasource_dir/$$file; \
			echo "metadata:" >> $$datasource_dir/$$file; \
			echo "  name: datasource-$$ctx" >> $$datasource_dir/$$file; \
			echo "  labels:" >> $$datasource_dir/$$file; \
			echo "    grafana_datasource: \"1\"" >> $$datasource_dir/$$file; \
			echo "data:" >> $$datasource_dir/$$file; \
			echo "  datasource-$$ctx.yaml: |-" >> $$datasource_dir/$$file; \
			echo "    apiVersion: 1" >> $$datasource_dir/$$file; \
			echo "    datasources:" >> $$datasource_dir/$$file; \
			echo "      - name: Prometheus-$$ctx" >> $$datasource_dir/$$file; \
			echo "        type: prometheus" >> $$datasource_dir/$$file; \
			echo "        access: proxy" >> $$datasource_dir/$$file; \
			echo "        url: http://prometheus-$$ctx.$(NS).svc.cluster.local:9090" >> $$datasource_dir/$$file; \
			echo "        isDefault: false" >> $$datasource_dir/$$file; \
		fi; \
	done; \
	echo "Aplicando ConfigMaps no cluster principal ($$principal)"; \
	kubectl --context=$$principal -n $(NS) delete configmap grafana-datasources --ignore-not-found; \
	kubectl --context=$$principal -n $(NS) apply -f configs/grafana-datasources; \
	echo "Datasources configurados."


full-deploy:
	@$(MAKE) setup-contexts
	@$(MAKE) deploy-monitoring
	@$(MAKE) connect-skupper
	@$(MAKE) grafana-config

cleanup:
	@if [ ! -f $(CONTEXT_FILE) ]; then \
		echo "Arquivo $(CONTEXT_FILE) não encontrado."; \
		exit 1; \
	fi
	@echo "Limpando recursos em todos os clusters..."
	@grep -v '^#' $(CONTEXT_FILE) | while read -r line; do \
		ctx=$$(echo $$line | sed 's/ #.*//'); \
		echo "Deletando namespace $(NS) no cluster $$ctx..."; \
		kubectl --context=$$ctx delete ns $(NS) --ignore-not-found; \
	done
	@rm -rf .skupper-tokens configs/grafana-datasources
	@echo "Cleanup completo."

start-loadtest:
	@if [ ! -f $(CONTEXT_FILE) ]; then \
		echo "Arquivo $(CONTEXT_FILE) não encontrado."; \
		exit 1; \
	fi
	@echo "Iniciando teste de carga com K6 nos clusters (exceto o principal)..."
	@principal=$$(grep "# principal" $(CONTEXT_FILE) | sed 's/ # principal//'); \
	grep -v '^#' $(CONTEXT_FILE) | while read -r line; do \
		ctx=$$(echo $$line | sed 's/ #.*//'); \
		if [ "$$ctx" != "$$principal" ]; then \
			echo "Executando teste no cluster $$ctx"; \
			cat configs/loadtest/stress-test.js | kubectl --context=$$ctx -n $(NS) run k6-loadtest --rm -i --restart=Never \
				--image grafana/k6 -- \
				run -o experimental-prometheus-rw \
				--tag testid=exec-$$(date +"%d-%m-%y:%H:%M:%S") \
				-e CLUSTER_CONTEXT=$$ctx \
				-e NAMESPACE=$(NS) \
				- || echo "Erro ao rodar K6 no $$ctx"; \
		fi \
	done
	@echo "Testes de carga iniciados."
