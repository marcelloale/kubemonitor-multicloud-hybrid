#!/usr/bin/make -f

SHELL := /bin/bash
CONTEXT_FILE := .contexts.txt
NS ?= monitoring

.PHONY: help setup-contexts get-ns deploy-monitoring connect-skupper grafana-config full-deploy cleanup start-loadtest

help:
        @echo "Comandos disponíveis:"
        @echo "  make setup-contexts [PRINCIPAL=nome]  - Lista clusters ativos e define o cluster principal"
        @echo "  make get-ns                           - Executa 'kubectl get ns' para cada cluster listado"
        @echo "  make deploy-monitoring [NS=namespace] - Instala o kube-prometheus-stack nos clusters"
        @echo "  make connect-skupper                              - Conecta os kube-prometheus-stack nos clusters"

setup-contexts:
        @echo "Coletando clusters via kubectx..."
        @if ! command -v kubectx &> /dev/null; then \
                echo "Erro: kubectx não está instalado."; exit 1; \
        fi
        @kubectx > .tmp_contexts
        @if [ -z "$(PRINCIPAL)" ]; then \
                if grep -q "# principal" $(CONTEXT_FILE) 2>/dev/null; then \
                        echo "Cluster principal já definido em $(CONTEXT_FILE): $$(grep '# principal' $(CONTEXT_FILE) | sed 's/ # principal//')"; \
                else \
                        echo "Nenhum cluster principal definido."; \
                        echo "Use: make setup-contexts PRINCIPAL=nome-do-cluster"; \
                        rm -f .tmp_contexts; \
                        exit 1; \
                fi \
        else \
                if grep -q "^$(PRINCIPAL)$$" .tmp_contexts; then \
                        cat .tmp_contexts | sed "s/^$(PRINCIPAL)$$/$(PRINCIPAL) # principal/" > $(CONTEXT_FILE); \
                        echo "Cluster principal definido: $(PRINCIPAL)"; \
                else \
                        echo "Cluster '$(PRINCIPAL)' não encontrado nos contextos do kubectx."; \
                        rm -f .tmp_contexts; \
                        exit 1; \
                fi \
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
        grep -v '^#' $(CONTEXT_FILE) | while read -r line; do \
                ctx=$$(echo $$line | sed 's/ #.*//'); \
                is_principal=$$(echo $$line | grep -q "# principal" && echo "true" || echo "false"); \
                echo "Instalando Skupper no cluster $$ctx..."; \
                kubectl --context=$$ctx create ns $(NS) --dry-run=client -o yaml | kubectl --context=$$ctx apply -f -; \
                if [ "$$is_principal" = "true" ]; then \
                        skupper init --context $$ctx --namespace $(NS); \
                        echo "Skupper inicializado no cluster principal ($$ctx), aguardando links."; \
                else \
                        skupper init --context $$ctx --namespace $(NS) --ingress none; \
                        token_file=".skupper-tokens/$$ctx-token.yaml"; \
                        echo "Gerando token no cluster principal para $$ctx"; \
                        skupper token create $$token_file --context $$principal --namespace $(NS); \
                        echo "Linkando $$ctx ao cluster principal ($$principal)"; \
                        skupper link create $$token_file --context $$ctx --namespace $(NS); \
                        echo "Expondo serviço 'kube-prometheus-stack-prometheus' no $$ctx via Skupper..."; \
                        skupper expose service kube-prometheus-stack-prometheus \
                                --port 9090 --address prometheus-$$ctx \
                                --context $$ctx --namespace $(NS); \
                fi; \
                echo "Skupper configurado no cluster: $$ctx"; \
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
                        cat > $$datasource_dir/$$file <<EOF
apiVersion: 1
datasources:
  - name: Prometheus ($$ctx)
    type: prometheus
    access: proxy
    url: http://prometheus-$$ctx.$(NS).svc.cluster.local:9090
    isDefault: false
EOF
                fi; \
        done; \
        echo "Aplicando ConfigMaps no cluster principal ($$principal)"; \
        kubectl --context=$$principal -n $(NS) delete configmap grafana-datasources --ignore-not-found; \
        kubectl --context=$$principal -n $(NS) create configmap grafana-datasources \
                --from-file=$$datasource_dir; \
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
                        kubectl --context=$$ctx -n $(NS) run k6-loadtest --rm -i --restart=Never \
                                --image grafana/k6 -- \
                                run -o experimental-prometheus-rw \
                                --tag testid=exec-$$(date +"%d-%m-%y:%H:%M:%S") \
                                /configs/loadtest/generate-keys.js || echo "Erro ao rodar K6 no $$ctx"; \
                fi \
        done
        @echo "Testes de carga iniciados."

