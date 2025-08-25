#!/bin/bash
set -e

# Cores para melhor visualização
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
    echo -e "${BOLD}${CYAN}$1${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

print_error() {
    echo -e "${RED}[PROBLEMA]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_safe() {
    echo -e "${GREEN}✅ SEGURO:${NC} $1"
}

print_keep() {
    echo -e "${BLUE}🛡️  MANTER:${NC} $1"
}

print_check() {
    echo -e "${YELLOW}⚠️  VERIFICAR:${NC} $1"
}

clear
print_header "======================================================="
print_header "    ANÁLISE E LIMPEZA SEGURA - KUBERNETES           "
print_header "======================================================="
echo

# Verificar conectividade
if ! kubectl cluster-info &> /dev/null; then
    print_error "Não conectado ao cluster Kubernetes"
    exit 1
fi

print_info "Cluster: $(kubectl config current-context)"
echo

# Arrays para categorizar pods
declare -a safe_to_remove=()
declare -a keep_pods=()
declare -a check_pods=()
declare -a safe_deployments=()

NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE "^(kube-system|kube-public|kube-node-lease)$")

print_header "=== ANALISANDO TODOS OS RECURSOS ==="
echo

# Analisar pods
total_pods=0
for ns in $NAMESPACES; do
    kubectl get pods -n $ns --no-headers 2>/dev/null | while IFS= read -r line; do
        if [ -n "$line" ]; then
            pod_name=$(echo "$line" | awk '{print $1}')
            ready=$(echo "$line" | awk '{print $2}')
            status=$(echo "$line" | awk '{print $3}')
            restarts=$(echo "$line" | awk '{print $4}')
            age=$(echo "$line" | awk '{print $5}')
            
            case $status in
                "ContainerStatusUnknown"|"Unknown")
                    echo "$ns/$pod_name" >> /tmp/safe_pods
                    print_safe "$ns/$pod_name - $status (pod morto/órfão)"
                    ;;
                "Failed"|"Error")
                    echo "$ns/$pod_name" >> /tmp/safe_pods
                    print_safe "$ns/$pod_name - $status (falhou definitivamente)"
                    ;;
                "Completed")
                    echo "$ns/$pod_name" >> /tmp/safe_pods
                    print_safe "$ns/$pod_name - $status (job finalizado)"
                    ;;
                "CrashLoopBackOff")
                    # Verificar se está tentando há muito tempo
                    restart_count=$(echo "$restarts" | sed 's/[^0-9]//g')
                    if [ "$restart_count" -gt 10 ]; then
                        echo "$ns/$pod_name" >> /tmp/check_pods
                        print_check "$ns/$pod_name - $status (muitos restarts: $restarts) - VERIFICAR SE É CRÍTICO"
                    else
                        echo "$ns/$pod_name" >> /tmp/check_pods
                        print_check "$ns/$pod_name - $status - PODE SER PROBLEMA TEMPORÁRIO"
                    fi
                    ;;
                "Pending")
                    echo "$ns/$pod_name" >> /tmp/check_pods
                    print_check "$ns/$pod_name - $status (aguardando recursos)"
                    ;;
                "Running")
                    # Verificar se está realmente saudável
                    if [[ "$ready" == "1/1" ]] || [[ "$ready" == *"/"* && "${ready%/*}" == "${ready#*/}" ]]; then
                        echo "$ns/$pod_name" >> /tmp/keep_pods
                        print_keep "$ns/$pod_name - $status ($ready) - FUNCIONANDO"
                    else
                        echo "$ns/$pod_name" >> /tmp/check_pods
                        print_check "$ns/$pod_name - $status ($ready) - NEM TODOS OS CONTAINERS PRONTOS"
                    fi
                    ;;
                *)
                    echo "$ns/$pod_name" >> /tmp/check_pods
                    print_check "$ns/$pod_name - $status (status desconhecido)"
                    ;;
            esac
            ((total_pods++))
        fi
    done || true
done

# Verificar pods órfãos
echo
print_info "Verificando pods órfãos (sem controlador)..."
for ns in $NAMESPACES; do
    kubectl get pods -n $ns -o jsonpath='{range .items[?(@.metadata.ownerReferences==null)]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | while read pod_path status_orphan; do
        if [ -n "$pod_path" ]; then
            # Só adiciona órfãos se não estão rodando perfeitamente
            if [ "$status_orphan" != "Running" ]; then
                echo "$pod_path" >> /tmp/safe_pods
                print_safe "$pod_path - Pod órfão ($status_orphan)"
            else
                echo "$pod_path" >> /tmp/check_pods
                print_check "$pod_path - Pod órfão mas Running - VERIFICAR SE PRECISA"
            fi
        fi
    done || true
done

echo
print_header "=== ANALISANDO DEPLOYMENTS COM PROBLEMAS ==="
echo

for ns in $NAMESPACES; do
    kubectl get deployments -n $ns --no-headers 2>/dev/null | while read dep ready uptodate available age; do
        if [ -n "$dep" ]; then
            # Deployments sem pods funcionando
            if [[ "$ready" == "0/"* ]] || [[ "$available" == "0" ]]; then
                echo "$ns/$dep" >> /tmp/safe_deployments
                print_safe "Deployment $ns/$dep ($ready) - SEM PODS FUNCIONANDO"
            else
                print_keep "Deployment $ns/$dep ($ready) - OK"
            fi
        fi
    done || true
done

echo
print_header "======================================================="
print_header "                    RESUMO DA ANÁLISE                 "
print_header "======================================================="

# Contar recursos
safe_pods_count=$([ -f /tmp/safe_pods ] && sort -u /tmp/safe_pods | wc -l || echo "0")
check_pods_count=$([ -f /tmp/check_pods ] && sort -u /tmp/check_pods | wc -l || echo "0")
keep_pods_count=$([ -f /tmp/keep_pods ] && sort -u /tmp/keep_pods | wc -l || echo "0")
safe_dep_count=$([ -f /tmp/safe_deployments ] && sort -u /tmp/safe_deployments | wc -l || echo "0")

print_success "SEGUROS PARA REMOÇÃO: $safe_pods_count pods + $safe_dep_count deployments"
print_warning "PRECISAM VERIFICAÇÃO: $check_pods_count pods"  
print_info "MANTER (funcionando): $keep_pods_count pods"

if [ "$safe_pods_count" -gt 0 ] || [ "$safe_dep_count" -gt 0 ]; then
    echo
    print_header "=== RECURSOS SEGUROS PARA REMOÇÃO ==="
    
    if [ -f /tmp/safe_pods ] && [ -s /tmp/safe_pods ]; then
        echo
        print_info "PODS seguros para remover:"
        sort -u /tmp/safe_pods | while read pod_path; do
            echo "  🗑️  $pod_path"
        done
    fi
    
    if [ -f /tmp/safe_deployments ] && [ -s /tmp/safe_deployments ]; then
        echo
        print_info "DEPLOYMENTS seguros para remover:"
        sort -u /tmp/safe_deployments | while read dep_path; do
            echo "  📦 $dep_path"
        done
    fi
    
    echo
    print_header "======================================================="
    echo -e "${BOLD}${YELLOW}ATENÇÃO: Esta ação removerá permanentemente os recursos listados acima!${NC}"
    echo
    echo -e "${BOLD}Deseja prosseguir com a remoção dos recursos SEGUROS? ${RED}(digite 'SIM' para confirmar)${NC}: "
    read -r confirmation
    
    if [ "$confirmation" = "SIM" ]; then
        echo
        print_header "=== INICIANDO REMOÇÃO SEGURA ==="
        echo
        
        removed_count=0
        
        # Remover pods seguros
        if [ -f /tmp/safe_pods ] && [ -s /tmp/safe_pods ]; then
            print_info "Removendo pods seguros..."
            sort -u /tmp/safe_pods | while read pod_path; do
                if [ -n "$pod_path" ]; then
                    ns=$(echo "$pod_path" | cut -d'/' -f1)
                    pod_name=$(echo "$pod_path" | cut -d'/' -f2)
                    
                    echo "  🗑️  Removendo: $pod_path"
                    if kubectl delete pod "$pod_name" -n "$ns" --grace-period=30 2>/dev/null; then
                        print_success "    ✅ $pod_path removido"
                        ((removed_count++))
                    else
                        print_warning "    ⚠️  $pod_path já foi removido ou não existe"
                    fi
                fi
            done
        fi
        
        # Remover deployments seguros
        if [ -f /tmp/safe_deployments ] && [ -s /tmp/safe_deployments ]; then
            print_info "Removendo deployments seguros..."
            sort -u /tmp/safe_deployments | while read dep_path; do
                if [ -n "$dep_path" ]; then
                    ns=$(echo "$dep_path" | cut -d'/' -f1)
                    dep_name=$(echo "$dep_path" | cut -d'/' -f2)
                    
                    echo "  📦 Removendo: $dep_path"
                    if kubectl delete deployment "$dep_name" -n "$ns" 2>/dev/null; then
                        print_success "    ✅ $dep_path removido"
                        ((removed_count++))
                    else
                        print_warning "    ⚠️  $dep_path já foi removido ou não existe"
                    fi
                fi
            done
        fi
        
        echo
        print_header "======================================================="
        print_success "LIMPEZA CONCLUÍDA!"
        print_info "Recursos processados para remoção: $((safe_pods_count + safe_dep_count))"
        print_header "======================================================="
        
        if [ "$check_pods_count" -gt 0 ]; then
            echo
            print_warning "PRÓXIMOS PASSOS:"
            print_info "Ainda existem $check_pods_count recursos que precisam de verificação manual."
            print_info "Execute 'kubectl get pods --all-namespaces' para verificar o estado atual."
        fi
        
    else
        print_info "Operação cancelada pelo usuário."
    fi
    
else
    print_success "Nenhum recurso problemático encontrado para remoção!"
    print_info "Seu cluster está em bom estado."
fi

# Limpeza dos arquivos temporários
rm -f /tmp/safe_pods /tmp/check_pods /tmp/keep_pods /tmp/safe_deployments

echo#!/bin/bash
set -e

# Cores para melhor visualização
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
    echo -e "${BOLD}${CYAN}$1${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

print_error() {
    echo -e "${RED}[PROBLEMA]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_safe() {
    echo -e "${GREEN}✅ SEGURO:${NC} $1"
}

print_keep() {
    echo -e "${BLUE}🛡️  MANTER:${NC} $1"
}

print_check() {
    echo -e "${YELLOW}⚠️  VERIFICAR:${NC} $1"
}

clear
print_header "======================================================="
print_header "    ANÁLISE E LIMPEZA SEGURA - KUBERNETES           "
print_header "======================================================="
echo

# Verificar conectividade
if ! kubectl cluster-info &> /dev/null; then
    print_error "Não conectado ao cluster Kubernetes"
    exit 1
fi

print_info "Cluster: $(kubectl config current-context)"
echo

# Arrays para categorizar pods
declare -a safe_to_remove=()
declare -a keep_pods=()
declare -a check_pods=()
declare -a safe_deployments=()

NAMESPACES=$(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -vE "^(kube-system|kube-public|kube-node-lease)$")

print_header "=== ANALISANDO TODOS OS RECURSOS ==="
echo

# Analisar pods
total_pods=0
for ns in $NAMESPACES; do
    kubectl get pods -n $ns --no-headers 2>/dev/null | while IFS= read -r line; do
        if [ -n "$line" ]; then
            pod_name=$(echo "$line" | awk '{print $1}')
            ready=$(echo "$line" | awk '{print $2}')
            status=$(echo "$line" | awk '{print $3}')
            restarts=$(echo "$line" | awk '{print $4}')
            age=$(echo "$line" | awk '{print $5}')
            
            case $status in
                "ContainerStatusUnknown"|"Unknown")
                    echo "$ns/$pod_name" >> /tmp/safe_pods
                    print_safe "$ns/$pod_name - $status (pod morto/órfão)"
                    ;;
                "Failed"|"Error")
                    echo "$ns/$pod_name" >> /tmp/safe_pods
                    print_safe "$ns/$pod_name - $status (falhou definitivamente)"
                    ;;
                "Completed")
                    echo "$ns/$pod_name" >> /tmp/safe_pods
                    print_safe "$ns/$pod_name - $status (job finalizado)"
                    ;;
                "CrashLoopBackOff")
                    # Verificar se está tentando há muito tempo
                    restart_count=$(echo "$restarts" | sed 's/[^0-9]//g')
                    if [ "$restart_count" -gt 10 ]; then
                        echo "$ns/$pod_name" >> /tmp/check_pods
                        print_check "$ns/$pod_name - $status (muitos restarts: $restarts) - VERIFICAR SE É CRÍTICO"
                    else
                        echo "$ns/$pod_name" >> /tmp/check_pods
                        print_check "$ns/$pod_name - $status - PODE SER PROBLEMA TEMPORÁRIO"
                    fi
                    ;;
                "Pending")
                    echo "$ns/$pod_name" >> /tmp/check_pods
                    print_check "$ns/$pod_name - $status (aguardando recursos)"
                    ;;
                "Running")
                    # Verificar se está realmente saudável
                    if [[ "$ready" == "1/1" ]] || [[ "$ready" == *"/"* && "${ready%/*}" == "${ready#*/}" ]]; then
                        echo "$ns/$pod_name" >> /tmp/keep_pods
                        print_keep "$ns/$pod_name - $status ($ready) - FUNCIONANDO"
                    else
                        echo "$ns/$pod_name" >> /tmp/check_pods
                        print_check "$ns/$pod_name - $status ($ready) - NEM TODOS OS CONTAINERS PRONTOS"
                    fi
                    ;;
                *)
                    echo "$ns/$pod_name" >> /tmp/check_pods
                    print_check "$ns/$pod_name - $status (status desconhecido)"
                    ;;
            esac
            ((total_pods++))
        fi
    done || true
done

# Verificar pods órfãos
echo
print_info "Verificando pods órfãos (sem controlador)..."
for ns in $NAMESPACES; do
    kubectl get pods -n $ns -o jsonpath='{range .items[?(@.metadata.ownerReferences==null)]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | while read pod_path status_orphan; do
        if [ -n "$pod_path" ]; then
            # Só adiciona órfãos se não estão rodando perfeitamente
            if [ "$status_orphan" != "Running" ]; then
                echo "$pod_path" >> /tmp/safe_pods
                print_safe "$pod_path - Pod órfão ($status_orphan)"
            else
                echo "$pod_path" >> /tmp/check_pods
                print_check "$pod_path - Pod órfão mas Running - VERIFICAR SE PRECISA"
            fi
        fi
    done || true
done

echo
print_header "=== ANALISANDO DEPLOYMENTS COM PROBLEMAS ==="
echo

for ns in $NAMESPACES; do
    kubectl get deployments -n $ns --no-headers 2>/dev/null | while read dep ready uptodate available age; do
        if [ -n "$dep" ]; then
            # Deployments sem pods funcionando
            if [[ "$ready" == "0/"* ]] || [[ "$available" == "0" ]]; then
                echo "$ns/$dep" >> /tmp/safe_deployments
                print_safe "Deployment $ns/$dep ($ready) - SEM PODS FUNCIONANDO"
            else
                print_keep "Deployment $ns/$dep ($ready) - OK"
            fi
        fi
    done || true
done

echo
print_header "======================================================="
print_header "                    RESUMO DA ANÁLISE                 "
print_header "======================================================="

# Contar recursos
safe_pods_count=$([ -f /tmp/safe_pods ] && sort -u /tmp/safe_pods | wc -l || echo "0")
check_pods_count=$([ -f /tmp/check_pods ] && sort -u /tmp/check_pods | wc -l || echo "0")
keep_pods_count=$([ -f /tmp/keep_pods ] && sort -u /tmp/keep_pods | wc -l || echo "0")
safe_dep_count=$([ -f /tmp/safe_deployments ] && sort -u /tmp/safe_deployments | wc -l || echo "0")

print_success "SEGUROS PARA REMOÇÃO: $safe_pods_count pods + $safe_dep_count deployments"
print_warning "PRECISAM VERIFICAÇÃO: $check_pods_count pods"  
print_info "MANTER (funcionando): $keep_pods_count pods"

if [ "$safe_pods_count" -gt 0 ] || [ "$safe_dep_count" -gt 0 ]; then
    echo
    print_header "=== RECURSOS SEGUROS PARA REMOÇÃO ==="
    
    if [ -f /tmp/safe_pods ] && [ -s /tmp/safe_pods ]; then
        echo
        print_info "PODS seguros para remover:"
        sort -u /tmp/safe_pods | while read pod_path; do
            echo "  🗑️  $pod_path"
        done
    fi
    
    if [ -f /tmp/safe_deployments ] && [ -s /tmp/safe_deployments ]; then
        echo
        print_info "DEPLOYMENTS seguros para remover:"
        sort -u /tmp/safe_deployments | while read dep_path; do
            echo "  📦 $dep_path"
        done
    fi
    
    echo
    print_header "======================================================="
    echo -e "${BOLD}${YELLOW}ATENÇÃO: Esta ação removerá permanentemente os recursos listados acima!${NC}"
    echo
    echo -e "${BOLD}Deseja prosseguir com a remoção dos recursos SEGUROS? ${RED}(digite 'SIM' para confirmar)${NC}: "
    read -r confirmation
    
    if [ "$confirmation" = "SIM" ]; then
        echo
        print_header "=== INICIANDO REMOÇÃO SEGURA ==="
        echo
        
        removed_count=0
        
        # Remover pods seguros
        if [ -f /tmp/safe_pods ] && [ -s /tmp/safe_pods ]; then
            print_info "Removendo pods seguros..."
            sort -u /tmp/safe_pods | while read pod_path; do
                if [ -n "$pod_path" ]; then
                    ns=$(echo "$pod_path" | cut -d'/' -f1)
                    pod_name=$(echo "$pod_path" | cut -d'/' -f2)
                    
                    echo "  🗑️  Removendo: $pod_path"
                    if kubectl delete pod "$pod_name" -n "$ns" --grace-period=30 2>/dev/null; then
                        print_success "    ✅ $pod_path removido"
                        ((removed_count++))
                    else
                        print_warning "    ⚠️  $pod_path já foi removido ou não existe"
                    fi
                fi
            done
        fi
        
        # Remover deployments seguros
        if [ -f /tmp/safe_deployments ] && [ -s /tmp/safe_deployments ]; then
            print_info "Removendo deployments seguros..."
            sort -u /tmp/safe_deployments | while read dep_path; do
                if [ -n "$dep_path" ]; then
                    ns=$(echo "$dep_path" | cut -d'/' -f1)
                    dep_name=$(echo "$dep_path" | cut -d'/' -f2)
                    
                    echo "  📦 Removendo: $dep_path"
                    if kubectl delete deployment "$dep_name" -n "$ns" 2>/dev/null; then
                        print_success "    ✅ $dep_path removido"
                        ((removed_count++))
                    else
                        print_warning "    ⚠️  $dep_path já foi removido ou não existe"
                    fi
                fi
            done
        fi
        
        echo
        print_header "======================================================="
        print_success "LIMPEZA CONCLUÍDA!"
        print_info "Recursos processados para remoção: $((safe_pods_count + safe_dep_count))"
        print_header "======================================================="
        
        if [ "$check_pods_count" -gt 0 ]; then
            echo
            print_warning "PRÓXIMOS PASSOS:"
            print_info "Ainda existem $check_pods_count recursos que precisam de verificação manual."
            print_info "Execute 'kubectl get pods --all-namespaces' para verificar o estado atual."
        fi
        
    else
        print_info "Operação cancelada pelo usuário."
    fi
    
else
    print_success "Nenhum recurso problemático encontrado para remoção!"
    print_info "Seu cluster está em bom estado."
fi

# Limpeza dos arquivos temporários
rm -f /tmp/safe_pods /tmp/check_pods /tmp/keep_pods /tmp/safe_deployments

echo
