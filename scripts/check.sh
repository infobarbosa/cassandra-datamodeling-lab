#!/bin/bash
# Valida o ambiente do laboratório: container no ar, saudável e com as
# 4 tabelas respondendo. Uso: ./scripts/check.sh [nome-do-container]
set -uo pipefail

CONTAINER="${1:-cassandra-bf}"
FAIL=0

ok()   { echo "  [OK]   $1"; }
erro() { echo "  [ERRO] $1"; FAIL=1; }

echo "== Verificando o ambiente do laboratório =="

if ! command -v docker >/dev/null 2>&1; then
    erro "docker não encontrado no PATH"
    exit 1
fi
ok "docker disponível"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    erro "container '$CONTAINER' não existe. Rode o Módulo 0 do README."
    exit 1
fi

STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)
if [ "$STATUS" = "healthy" ]; then
    ok "container '$CONTAINER' está healthy"
else
    erro "container '$CONTAINER' está '$STATUS' (aguarde ou verifique 'docker logs $CONTAINER')"
    exit 1
fi

check_query() {
    local desc="$1" query="$2" expected="$3"
    local result
    result=$(docker exec "$CONTAINER" cqlsh -e "$query" 2>/dev/null)
    if echo "$result" | grep -q "$expected"; then
        ok "$desc"
    else
        erro "$desc"
    fi
}

check_query "keyspace bolsa_familia existe" \
    "DESCRIBE KEYSPACES;" "bolsa_familia"

check_query "pagamentos_por_nis responde (NIS com 10 parcelas)" \
    "SELECT count(*) FROM bolsa_familia.pagamentos_por_nis WHERE nis = '26913139991';" "10"

check_query "pagamentos_por_municipio responde (Pedra Lavrada-PB)" \
    "SELECT nome FROM bolsa_familia.pagamentos_por_municipio WHERE uf = 'PB' AND cd_municipio = '2123' LIMIT 1;" "(1 rows)"

check_query "pagamentos_por_municipio_valor responde (São Paulo-SP)" \
    "SELECT valor_parcela FROM bolsa_familia.pagamentos_por_municipio_valor WHERE uf = 'SP' AND cd_municipio = '7107' LIMIT 1;" "(1 rows)"

check_query "pagamentos_por_uf responde (BA)" \
    "SELECT nis FROM bolsa_familia.pagamentos_por_uf WHERE uf = 'BA' LIMIT 1;" "(1 rows)"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✅ Ambiente pronto para o laboratório."
else
    echo "❌ Há problemas no ambiente. Revise o Módulo 0 do README."
    exit 1
fi
