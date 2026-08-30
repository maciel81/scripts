#!/usr/bin/env bash
#
# import_sql.sh
#
# Le todos os arquivos .sql do diretorio atual (gerados por mysqldump,
# um por tabela), ordena por tamanho em ordem crescente e importa
# cada um para o banco de dados informado.
#
# Uso:
#   ./import_sql.sh -d nome_do_banco [-h host] [-P porta] [-u usuario] [-p]
#
# Exemplos:
#   ./import_sql.sh -d meubanco
#   ./import_sql.sh -d meubanco -h 127.0.0.1 -P 3306 -u root -p
#
# Se -p for passado sem senha, o script pedira a senha de forma interativa
# (nao aparece no historico do shell nem no `ps`).

set -euo pipefail

DB=""
DB_HOST="localhost"
DB_PORT="3306"
DB_USER="root"
ASK_PASS="false"
MYSQL_PASS=""

usage() {
    echo "Uso: $0 -d <banco> [-h <host>] [-P <porta>] [-u <usuario>] [-p]"
    exit 1
}

while getopts "d:h:P:u:p" opt; do
    case "$opt" in
        d) DB="$OPTARG" ;;
        h) DB_HOST="$OPTARG" ;;
        P) DB_PORT="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        p) ASK_PASS="true" ;;
        *) usage ;;
    esac
done

if [[ -z "$DB" ]]; then
    echo "Erro: informe o banco de dados com -d <banco>"
    usage
fi

if [[ "$ASK_PASS" == "true" ]]; then
    read -rsp "Senha do MySQL para o usuario '$DB_USER': " MYSQL_PASS
    echo
fi

# Monta os argumentos de conexao do mysql
MYSQL_ARGS=(-h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER")
if [[ -n "$MYSQL_PASS" ]]; then
    MYSQL_ARGS+=(-p"$MYSQL_PASS")
fi

# Verifica se o banco existe / consegue conectar
if ! mysql "${MYSQL_ARGS[@]}" -e "USE \`$DB\`;" 2>/tmp/mysql_check_err; then
    echo "Erro ao conectar ou acessar o banco '$DB':"
    cat /tmp/mysql_check_err
    rm -f /tmp/mysql_check_err
    exit 1
fi
rm -f /tmp/mysql_check_err

# Lista os arquivos .sql do diretorio atual ordenados por tamanho crescente
mapfile -t FILES < <(find . -maxdepth 1 -type f -iname "*.sql" -printf '%s %p\n' | sort -n | cut -d' ' -f2-)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Nenhum arquivo .sql encontrado no diretorio atual."
    exit 0
fi

echo "Banco de destino: $DB ($DB_HOST:$DB_PORT, usuario: $DB_USER)"
echo "Encontrados ${#FILES[@]} arquivo(s) .sql. Ordem de importacao (menor -> maior):"
for f in "${FILES[@]}"; do
    tamanho=$(du -h "$f" | cut -f1)
    echo "  - $f ($tamanho)"
done
echo

LOG_FILE="import_sql_$(date +%Y%m%d_%H%M%S).log"
echo "Log detalhado em: $LOG_FILE"
echo

OK=0
FAIL=0
FAILED_FILES=()

for f in "${FILES[@]}"; do
    nome=$(basename "$f")
    inicio=$(date +%s)
    echo -n "Importando $nome ... "

    if mysql "${MYSQL_ARGS[@]}" "$DB" < "$f" >>"$LOG_FILE" 2>&1; then
        fim=$(date +%s)
        echo "OK ($(( fim - inicio ))s)"
        OK=$((OK + 1))
    else
        fim=$(date +%s)
        echo "FALHOU ($(( fim - inicio ))s) - veja detalhes em $LOG_FILE"
        FAIL=$((FAIL + 1))
        FAILED_FILES+=("$nome")
    fi
done

echo
echo "=== Resumo ==="
echo "Sucesso: $OK"
echo "Falhas:  $FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Arquivos que falharam:"
    for f in "${FAILED_FILES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

echo "Importacao concluida com sucesso."
