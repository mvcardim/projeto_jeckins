
#!/bin/bash
# Script: reparar-replica-gitea-postgresql-ha.sh
# Objetivo: Recriar o pod e PVC corrompido do PostgreSQL HA (replica -1)
# Namespace: gitea

NAMESPACE="gitea"
REPLICA="gitea-postgresql-ha-postgresql-1"
PRIMARY="gitea-postgresql-ha-postgresql-0"

echo "=== [1/6] Verificando pods atuais no namespace $NAMESPACE ==="
kubectl get pods -n $NAMESPACE -o wide

echo
echo "=== [2/6] Verificando PVCs existentes ==="
kubectl get pvc -n $NAMESPACE | grep gitea-postgresql-ha-postgresql

PVC_NAME=$(kubectl get pvc -n $NAMESPACE -o name | grep "data-$REPLICA" | awk -F'/' '{print $2}')

if [ -z "$PVC_NAME" ]; then
  echo "❌ Não foi encontrado PVC para $REPLICA. Abortando."
  exit 1
fi

echo
echo "PVC do replica problemático encontrado: $PVC_NAME"
echo
echo "=== [3/6] Conferindo status do primário ($PRIMARY) ==="
kubectl get pod $PRIMARY -n $NAMESPACE

echo
echo "Verificando logs recentes do primário..."
kubectl logs $PRIMARY -n $NAMESPACE --tail=20 | tail -n 10

read -p "✅ Se o primário está Running e saudável, pressione ENTER para continuar (Ctrl+C para cancelar)..."

echo
echo "=== [4/6] Excluindo pod quebrado ($REPLICA)... ==="
kubectl delete pod $REPLICA -n $NAMESPACE --ignore-not-found

sleep 5

echo
echo "=== [5/6] Excluindo PVC ($PVC_NAME)... ==="
kubectl delete pvc $PVC_NAME -n $NAMESPACE --ignore-not-found

echo
echo "PVC removido. O StatefulSet criará um novo PVC e o pod $REPLICA será refeito automaticamente."
echo "Acompanhe abaixo a recriação dos pods:"
kubectl get pods -n $NAMESPACE -w &
WATCH_PID=$!

echo
echo "⏳ Aguardando o pod $REPLICA entrar em Running..."
while true; do
  STATUS=$(kubectl get pod $REPLICA -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$STATUS" == "Running" ]]; then
    echo
    echo "✅ Pod $REPLICA agora está Running!"
    break
  fi
  sleep 10
done

kill $WATCH_PID 2>/dev/null

echo
echo "=== [6/6] Reiniciando Pgpool para limpar failovers antigos ==="
PGPOOL_POD=$(kubectl get pods -n $NAMESPACE -o name | grep gitea-postgresql-ha-pgpool | head -n 1)
if [ -n "$PGPOOL_POD" ]; then
  echo "Reiniciando $PGPOOL_POD ..."
  kubectl delete $PGPOOL_POD -n $NAMESPACE --ignore-not-found
else
  echo "⚠️ Nenhum pod Pgpool encontrado para reiniciar."
fi

echo
echo "✅ Finalizado! Verifique o estado geral:"
echo "kubectl get pods -n $NAMESPACE"
echo
echo "Todos os pods devem aparecer como Running."
