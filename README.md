# kubemonitor-multicloud-hybrid
Kubernetes monitoring solution for hybrid and multicloud environments. Integrates Prometheus, Grafana, Skupper, and more. Centralized dashboard for unified visibility. Scalable and flexible.

## Descrição

Este repositório apresenta uma solução prática e extensível para o monitoramento de clusters Kubernetes distribuídos entre diferentes provedores de nuvem e ambientes on-premises. A proposta visa fornecer uma arquitetura unificada e segura, com foco em visibilidade centralizada e interoperabilidade entre clusters, utilizando ferramentas amplamente adotadas pela comunidade.

A solução é acompanhada de um `Makefile` que automatiza toda a configuração da stack de monitoramento, promovendo rapidez, consistência e reprodutibilidade.

## Funcionalidades

* Deploy automatizado do `kube-prometheus-stack` com Helm
* Interconexão de clusters via [Skupper](https://skupper.io/) para roteamento seguro entre redes
* Painel centralizado com o Grafana, integrando métricas de todos os clusters
* Comandos simplificados via `make`

## Ferramentas Utilizadas

* [Kubernetes](https://kubernetes.io/)
* [Prometheus](https://prometheus.io/)
* [Grafana](https://grafana.com/)
* [Helm](https://helm.sh/)
* [Skupper](https://skupper.io/)
* [Kubectx](https://github.com/ahmetb/kubectx)
* [K6](https://k6.io/) (opcional, para testes de carga)

## Estrutura de Diretórios

```
.
├── configs/
│   ├── helm/kube-prometheus-stack/
│   │   ├── values.yaml
│   │   └── values-pri.yaml
│   └── loadtest/
│       └── generate-keys.js
├── Makefile
└── README.md
```

## Pré-requisitos

* `kubectl` configurado com os contextos dos clusters
* `kubectx` instalado para listar e alternar entre contextos mais facilmente
* `Helm` instalado
* `Skupper CLI` instalado
* `make` instalado

## Guia Rápido

### 1. Definir os clusters disponíveis

```bash
make setup-contexts PRINCIPAL=<nome-do-cluster-principal>
```

Isso criará o arquivo `.contexts.txt`, marcando o cluster principal.

### 2. Verificar namespaces existentes, teste rapido para conferir os contexts

```bash
make get-ns
```

### 3. Instalar a stack de monitoramento

```bash
make deploy-monitoring
```

Instala o Prometheus e Grafana com configurações específicas para o cluster principal e os demais. É possivel adicionar sua propria configuração.

### 4. Conectar os clusters via Skupper

```bash
make connect-skupper
```

Garante comunicação segura entre os serviços Prometheus de todos os clusters com o cluster principal. Pode ser necessario alguma alteração caso sua configuração seja algo especifico.

### 5. Configurar datasources do Grafana

```bash
make grafana-config
```

Cria e aplica os datasources Prometheus no cluster principal automaticamente.

### 6. Executar a implantação completa

```bash
make full-deploy
```

Executa todos os passos anteriores de forma automatizada.

### 7. Executar testes de carga (opcional)

```bash
make start-loadtest
```

Executa scripts K6 nos clusters secundários para simular tráfego e avaliar o comportamento do sistema.

Para que o teste seja funcional, é necessário realizar o deploy prévio da aplicação **[Giropops Senhas](https://github.com/StuxxNet/pick-esquenta/tree/main/app)** nos clusters participantes, já que o script utilizado (`generate-keys.js`) foi adaptado com base nesse sistema.

> Observação: Este repositório foi inspirado e estruturado com base no projeto [StuxxNet/pick-esquenta](https://github.com/StuxxNet/pick-esquenta), do qual herda a abordagem automatizada de setup multicluster com Makefile, além da integração com o K6.


### 8. Remover os recursos implantados

```bash
make cleanup
```

Remove todos os componentes implantados, tokens e configurações auxiliares.

## Configurações

* `configs/helm/kube-prometheus-stack/values.yaml`: configuração base para clusters secundários
* `values-pri.yaml`: configuração personalizada para o cluster principal

## Se tudo ocorrer como esperado

Ao final da implantação, o Grafana no cluster principal apresentará múltiplos datasources (um para cada cluster conectado), permitindo a visualização unificada de métricas em tempo real de todos os ambientes monitorados.


## Contribuição

Contribuições são bem-vindas. Sinta-se à vontade para abrir *issues*, propor melhorias ou enviar *pull requests*.


