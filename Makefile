.DEFAULT_GOAL := create

pre:
	@kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
	@kubectl wait --namespace metallb-system \
		--for=condition=ready pod \
		--selector=app=metallb \
		--timeout=300s
	@kubectl apply -f manifests/
fixmetallb:
	@echo "Verificando se MetalLB já está instalado..."
	@if kubectl get namespace metallb-system >/dev/null 2>&1; then \
		echo "MetalLB já instalado, aplicando patch..."; \
	else \
		echo "Instalando MetalLB..."; \
		if [ -f metallb-native.yaml ]; then \
			echo "Usando arquivo local metallb-native.yaml"; \
			kubectl apply -f metallb-native.yaml; \
		else \
			echo "Baixando metallb-native.yaml..."; \
			curl -f -L -o metallb-native.yaml https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml && \
			kubectl apply -f metallb-native.yaml; \
		fi; \
		echo "Aguardando MetalLB iniciar..."; \
		kubectl wait --namespace metallb-system --for=condition=ready pod --selector=component=controller --timeout=90s; \
	fi
	@echo "Configurando speaker para não rodar no control-plane..."
	@kubectl patch daemonset speaker -n metallb-system --type='merge' -p='{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/control-plane","operator":"DoesNotExist"}]}]}}}}}}}' 2>/dev/null || true
	@echo "Aplicando configuração do MetalLB..."
	@kubectl apply -f metallb-config.yaml
	@echo "MetalLB configurado com sucesso!"	

helm:
	@helmfile apply

create:
	@kind create cluster --config config.yaml

up: create pre helm

destroy:
	@kind delete clusters kind

passwd:

	@echo "JENKINS:"
	@kubectl get secret -n jenkins jenkins -ojson | jq -r '.data."jenkins-admin-password"' | base64 -d
	@echo ""
	@echo "GITEA:"
	@echo "r8sA8CPHD9!bt6d | usuario: admin: wdMI3O3UQ7RoYCOdfRCU4r: usuario:jenkins RQ4CzHQgwLdgQRf
	@echo "SONARQUBE:"
	@echo "krE^NiQvTc@75G"
	@echo "ARGOCD:"
	@kubectl get secret -n argocd argocd-initial-admin-secret -ojson | jq -r '.data.password' | base64 -d

	.PHONY: help port-forward port-forward-jenkins port-forward-gitea stop-port-forward status logs

.PHONY: help port-forward port-forward-jenkins port-forward-gitea port-forward-harbor stop-port-forward status logs

# Variáveis
JENKINS_PORT := 8080
GITEA_PORT := 3000
HARBOR_PORT := 8081
BIND_ADDRESS := 0.0.0.0
LOG_DIR := /tmp

help: ## Mostra esta ajuda
	@echo "Comandos disponíveis:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

port-forward:
	@echo "Iniciando port-forwards..."
	@mkdir -p logs
	@kubectl port-forward -n jenkins svc/jenkins 8080:8080 --address=0.0.0.0 > logs/jenkins-pf.log 2>&1 &
	@echo "Port-forward Jenkins iniciado na porta 8080"
	@kubectl port-forward -n gitea svc/gitea-http 3000:3000 --address=0.0.0.0 > logs/gitea-pf.log 2>&1 &
	@echo "Port-forward Gitea iniciado na porta 3000"
	@kubectl port-forward -n harbor svc/harbor-portal 8081:80 --address=0.0.0.0 > logs/harbor-pf.log 2>&1 &
	@echo "Port-forward Harbor iniciado na porta 8081"
	@kubectl port-forward -n sonarqube svc/sonarqube-sonarqube 9000:9000 --address=0.0.0.0 > logs/sonarqube-pf.log 2>&1 &
	@echo "Port-forward sonarqube iniciado na porta 9000"
	@sleep 2
	@$(MAKE) status

port-forward-jenkins: ## Inicia apenas port-forward do Jenkins
	@echo "Iniciando port-forward do Jenkins..."
	@nohup kubectl port-forward -n jenkins svc/jenkins $(JENKINS_PORT):$(JENKINS_PORT) --address=$(BIND_ADDRESS) > $(LOG_DIR)/jenkins-pf.log 2>&1 &
	@echo "Port-forward Jenkins iniciado na porta $(JENKINS_PORT)"
	@sleep 2
	@ps aux | grep "[p]ort-forward.*jenkins"

port-forward-gitea: ## Inicia apenas port-forward do Gitea
	@echo "Iniciando port-forward do Gitea..."
	@nohup kubectl port-forward -n gitea svc/gitea-http $(GITEA_PORT):$(GITEA_PORT) --address=$(BIND_ADDRESS) > $(LOG_DIR)/gitea-pf.log 2>&1 &
	@echo "Port-forward Gitea iniciado na porta $(GITEA_PORT)"
	@sleep 2
	@ps aux | grep "[p]ort-forward.*gitea"

port-forward-harbor: ## Inicia apenas port-forward do Harbor
	@echo "Iniciando port-forward do Harbor..."
	@nohup kubectl port-forward -n harbor svc/harbor $(HARBOR_PORT):80 --address=$(BIND_ADDRESS) > $(LOG_DIR)/harbor-pf.log 2>&1 &
	@echo "Port-forward Harbor iniciado na porta $(HARBOR_PORT)"
	@sleep 2
	@ps aux | grep "[p]ort-forward.*harbor"

stop-port-forward: ## Para todos os port-forwards
	@echo "Parando port-forwards..."
	@-pkill -f "port-forward.*jenkins" 2>/dev/null || true
	@-pkill -f "port-forward.*gitea" 2>/dev/null || true
	@-pkill -f "port-forward.*harbor" 2>/dev/null || true
	@echo "Port-forwards parados!"

restart-port-forward: stop-port-forward port-forward ## Reinicia os port-forwards

status: ## Verifica status dos port-forwards
	@echo "=== Status dos Port-Forwards ==="
	@echo ""
	@echo "Jenkins:"
	@ps aux | grep "[p]ort-forward.*jenkins" || echo "  ❌ Não está rodando"
	@echo ""
	@echo "Gitea:"
	@ps aux | grep "[p]ort-forward.*gitea" || echo "  ❌ Não está rodando"
	@echo ""
	@echo "Harbor:"
	@ps aux | grep "[p]ort-forward.*harbor" || echo "  ❌ Não está rodando"
	@echo ""
	@echo "=== Portas em uso ==="
	@ss -tulpn 2>/dev/null | grep -E "$(JENKINS_PORT)|$(GITEA_PORT)|$(HARBOR_PORT)" || echo "  Nenhuma porta encontrada"

logs: ## Mostra logs dos port-forwards
	@echo "=== Logs Jenkins ==="
	@tail -20 $(LOG_DIR)/jenkins-pf.log 2>/dev/null || echo "Sem logs do Jenkins"
	@echo ""
	@echo "=== Logs Gitea ==="
	@tail -20 $(LOG_DIR)/gitea-pf.log 2>/dev/null || echo "Sem logs do Gitea"
	@echo ""
	@echo "=== Logs Harbor ==="
	@tail -20 $(LOG_DIR)/harbor-pf.log 2>/dev/null || echo "Sem logs do Harbor"

logs-follow: ## Acompanha logs em tempo real
	@echo "Acompanhando logs (Ctrl+C para sair)..."
	@tail -f $(LOG_DIR)/jenkins-pf.log $(LOG_DIR)/gitea-pf.log $(LOG_DIR)/harbor-pf.log

test-connection: ## Testa conectividade dos serviços
	@echo "=== Testando Conectividade ==="
	@echo ""
	@echo "Jenkins (porta $(JENKINS_PORT)):"
	@curl -s -o /dev/null -w "  Status: %{http_code}\n" http://localhost:$(JENKINS_PORT) || echo "  ❌ Falha na conexão"
	@echo ""
	@echo "Gitea (porta $(GITEA_PORT)):"
	@curl -s -o /dev/null -w "  Status: %{http_code}\n" http://localhost:$(GITEA_PORT) || echo "  ❌ Falha na conexão"
	@echo ""
	@echo "Harbor (porta $(HARBOR_PORT)):"
	@curl -s -o /dev/null -w "  Status: %{http_code}\n" http://localhost:$(HARBOR_PORT) || echo "  ❌ Falha na conexão"

get-jenkins-password: ## Obtém senha inicial do Jenkins
	@echo "Senha inicial do Jenkins:"
	@kubectl exec -it jenkins-0 -n jenkins -- cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo "❌ Erro ao obter senha"

urls: ## Mostra URLs de acesso
	@echo "=== URLs de Acesso ==="
	@echo ""
	@echo "Jenkins:  http://172.16.0.134:$(JENKINS_PORT)"
	@echo "Gitea:    http://172.16.0.134:$(GITEA_PORT)"
	@echo "Harbor:   http://172.16.0.134:$(HARBOR_PORT)"
	@echo ""

clean-logs: ## Limpa arquivos de log
	@echo "Limpando logs..."
	@rm -f $(LOG_DIR)/jenkins-pf.log $(LOG_DIR)/gitea-pf.log $(LOG_DIR)/harbor-pf.log
	@echo "Logs limpos!"