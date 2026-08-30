#!/usr/bin/env bash
#
# import_sql.sh
#
# Le arquivos .sql de um diretorio (por padrao, o diretorio atual; gerados
# por mysqldump, um por tabela, ja com DROP TABLE IF EXISTS + CREATE TABLE
# + INSERTs), ordena por tamanho em ordem crescente e importa cada um para
# o banco de dados informado. Como cada arquivo ja tem o DROP/CREATE, cada
# tabela e apagada e recriada so de importar; FOREIGN_KEY_CHECKS fica
# desligado durante a importacao para o DROP nao esbarrar em FK de outra
# tabela (ex: uma tabela pivo que referencia outra do mesmo dump).
#
# Uso:
#   ./import_sql.sh -d nome_do_banco [-f diretorio] [-h host] [-P porta] [-u usuario] [-p]
#
# Exemplos:
#   ./import_sql.sh -d meubanco
#   ./import_sql.sh -d meubanco -f ./dump_roles -h 127.0.0.1 -P 3306 -u root -p
#
# Se -p for passado sem senha, o script pedira a senha de forma interativa
# (nao aparece no historico do shell nem no `ps`).

set -euo pipefail

DB=""
DUMP_DIR="."
DB_HOST="localhost"
DB_PORT="3306"
DB_USER="root"
ASK_PASS="false"
MYSQL_PASS=""

usage() {
    echo "Uso: $0 -d <banco> [-f <diretorio>] [-h <host>] [-P <porta>] [-u <usuario>] [-p]"
    exit 1
}

while getopts "d:f:h:P:u:p" opt; do
    case "$opt" in
        d) DB="$OPTARG" ;;
        f) DUMP_DIR="$OPTARG" ;;
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

if [[ ! -d "$DUMP_DIR" ]]; then
    echo "Erro: diretorio '$DUMP_DIR' nao existe"
    exit 1
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

# Lista os arquivos .sql do diretorio ordenados por tamanho crescente
mapfile -t FILES < <(find "$DUMP_DIR" -maxdepth 1 -type f -iname "*.sql" -printf '%s %p\n' | sort -n | cut -d' ' -f2-)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Nenhum arquivo .sql encontrado em '$DUMP_DIR'."
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

    if {
        echo "SET FOREIGN_KEY_CHECKS=0;"
        cat "$f"
        echo "SET FOREIGN_KEY_CHECKS=1;"
    } | mysql "${MYSQL_ARGS[@]}" "$DB" >>"$LOG_FILE" 2>&1; then
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
