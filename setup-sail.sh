#!/usr/bin/env bash
#
# setup-sail.sh
# ---------------------------------------------------------------------------
# Automatiza a configuração do Laravel Sail para um projeto, replicando o
# setup feito manualmente: Sail + Redis, runtime PHP em serversideup/php
# (Alpine + PHP-FPM + Nginx, no lugar do template padrão do Sail em Ubuntu +
# "php artisan serve"), Horizon + Scheduler como serviços do s6-overlay na
# mesma imagem, e integração opcional com Traefik para acesso via domínio
# (ex: meuprojeto.localhost) em vez de portas.
#
# Por que serversideup/php em vez do runtime padrão do Sail: imagem bem mais
# enxuta (Alpine + só as extensões que o projeto realmente usa, em vez do
# conjunto genérico do Sail), Nginx+PHP-FPM nativos em vez do servidor de
# desenvolvimento do PHP, e mais próximo do que se usaria em produção. Ver
# documentacao/projetos/multas/pdsait/infraestrutura/docker.md para o
# histórico completo da migração (feita primeiro à mão no pdsait, depois
# incorporada aqui).
#
# COMO USAR
#   1. Copie este arquivo para a raiz do seu projeto Laravel (onde fica o
#      artisan e o composer.json).
#   2. Dê permissão de execução:      chmod +x setup-sail.sh
#   3. Rode:                          ./setup-sail.sh
#
# O script é interativo: ele pergunta o que você quer habilitar e usa
# valores padrão sensatos (basta apertar Enter). É seguro rodar mais de uma
# vez no mesmo projeto — ele detecta o que já está configurado e pula essas
# etapas (idempotente).
#
# PRÉ-REQUISITOS
#   - Docker e Docker Compose já instalados e funcionando (docker info OK)
#   - Projeto Laravel existente (composer.json e artisan na pasta atual)
#   - Se for usar a opção de Traefik, o container do Traefik "compartilhado"
#     deve estar rodando à parte (docker network create traefik + docker
#     compose up -d na pasta dele). Veja o bloco de instruções que este
#     script imprime ao final caso a rede "traefik" ainda não exista.
# ---------------------------------------------------------------------------

set -euo pipefail

# Versão da imagem serversideup/php a usar (tag fixa, não flutuante — ver
# https://serversideup.net/open-source/docker-php/docs/getting-started/all-tags).
# Fixar a versão evita que um rebuild futuro puxe uma imagem diferente sem
# aviso. Verificada e testada em 2026-08 (v4.5.1). Ao atualizar, teste antes
# de aplicar em todos os projetos.
SERVERSIDEUP_PHP_IMAGE_VERSION="v4.5.1"

# --------------------------- Funções utilitárias ---------------------------

info()  { printf '\033[1;34m[info]\033[0m %s\n' "$1"; }
ok()    { printf '\033[1;32m[ok]\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m[atenção]\033[0m %s\n' "$1"; }
fail()  { printf '\033[1;31m[erro]\033[0m %s\n' "$1"; exit 1; }

ask_yes_no() {
    # ask_yes_no "pergunta" "default(s/n)"
    local prompt="$1" default="${2:-s}" answer
    if [ "$default" = "s" ]; then
        read -r -p "$prompt [S/n]: " answer || true
        answer="${answer:-s}"
    else
        read -r -p "$prompt [s/N]: " answer || true
        answer="${answer:-n}"
    fi
    case "$answer" in
        [sSyY]*) return 0 ;;
        *) return 1 ;;
    esac
}

sanitize_name() {
    # minúsculas, espaços/underscores viram hífen, remove tudo que não for
    # letra/número/hífen
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-'
}

port_in_use() {
    # retorna 0 (sucesso) se a porta TCP já estiver em uso no host — inclui
    # portas publicadas por outros containers Docker.
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -qE "[:.]${p}([[:space:]]|$)"
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && { exec 3>&-; return 0; } || return 1
    fi
}

free_port() {
    # a partir de um palpite, devolve a próxima porta TCP livre.
    local p="$1"
    while port_in_use "$p"; do p=$(( p + 1 )); done
    echo "$p"
}

# ------------------------------ Pré-checagens -------------------------------

[ -f composer.json ] && [ -f artisan ] || \
    fail "Rode este script na raiz de um projeto Laravel (onde estão o composer.json e o artisan)."

command -v docker >/dev/null 2>&1 || \
    fail "Docker não encontrado. Instale o Docker antes de continuar."

docker info >/dev/null 2>&1 || \
    fail "Docker não está acessível (permissão ou serviço parado). Rode 'docker info' para diagnosticar."

ok "Pré-checagens OK: projeto Laravel detectado e Docker acessível."

# Detecta o alias antigo "sail='[ -f sail ] && sh sail || sh vendor/bin/sail'".
# Em distros como o Linux Mint/Ubuntu, /bin/sh é o Dash, que não suporta a
# sintaxe (read -ra + herestring <<<) usada pelo script sail para processar
# SAIL_FILES — isso faz o override do Traefik ser ignorado silenciosamente,
# sem nenhum erro visível.
if [ -f "$HOME/.bashrc" ] && grep -qE "alias sail=.*sh sail.*sh vendor/bin/sail" "$HOME/.bashrc"; then
    warn "Encontrei um alias 'sail' no ~/.bashrc usando 'sh' em vez de 'bash'."
    warn "Isso quebra silenciosamente o SAIL_FILES (usado pela integração com Traefik)."
    if ask_yes_no "Corrigir o alias no ~/.bashrc agora (trocar sh por bash)?"; then
        sed -i "s#alias sail=.*#alias sail='[ -f sail ] \&\& bash sail || bash vendor/bin/sail'#" "$HOME/.bashrc"
        ok "Alias corrigido. Rode 'source ~/.bashrc' (ou abra um terminal novo) para aplicar."
    fi
fi

# ------------------------------ Nome do projeto -----------------------------

DEFAULT_NAME="$(sanitize_name "$(basename "$PWD")")"
read -r -p "Nome do projeto para usar como serviço/domínio [$DEFAULT_NAME]: " PROJECT_INPUT
PROJECT="$(sanitize_name "${PROJECT_INPUT:-$DEFAULT_NAME}")"
SERVICE_NAME="${PROJECT}.test"

info "Usando '${SERVICE_NAME}' como nome do serviço no compose.yaml e domínio local."

# ------------------------------- Instalar Sail ------------------------------

if ! grep -q '"laravel/sail"' composer.json; then
    info "Instalando laravel/sail..."
    composer require laravel/sail --dev
else
    ok "laravel/sail já está no composer.json."
fi

SAIL_FRESH_INSTALL=0
if [ ! -f compose.yaml ] && [ ! -f docker-compose.yml ]; then
    SAIL_FRESH_INSTALL=1
fi

# Pergunta primeiro SE o projeto usa banco de dados — só entra nas perguntas
# de motor/container/host quando a resposta é sim. Isso evita perguntar
# host/senha de um banco que o projeto nem vai usar.
CURRENT_DB_CONNECTION=""
[ -f .env ] && CURRENT_DB_CONNECTION="$(grep '^DB_CONNECTION=' .env | head -1 | cut -d= -f2- || true)"

DB_ENGINE="none"
WANT_DB_CONTAINER=0
DB_HOST_VALUE=""
if ask_yes_no "Este projeto usa banco de dados?" "s"; then
    DB_ENGINE_DEFAULT="${CURRENT_DB_CONNECTION:-mysql}"
    case "$DB_ENGINE_DEFAULT" in
        mysql|pgsql|sqlite) ;;
        *) DB_ENGINE_DEFAULT="mysql" ;;
    esac

    read -r -p "Qual banco de dados este projeto usa? (mysql/pgsql/sqlite) [${DB_ENGINE_DEFAULT}]: " DB_ENGINE_INPUT
    case "${DB_ENGINE_INPUT:-$DB_ENGINE_DEFAULT}" in
        mysql)                     DB_ENGINE="mysql" ;;
        pgsql|postgres|postgresql) DB_ENGINE="pgsql" ;;
        sqlite)                    DB_ENGINE="sqlite" ;;
        *) fail "Banco de dados '${DB_ENGINE_INPUT}' não suportado — use 'mysql', 'pgsql' ou 'sqlite'." ;;
    esac
    info "Usando '${DB_ENGINE}' como banco de dados deste projeto."

    # sqlite roda como arquivo local (sem servidor) — container/host só fazem
    # sentido pra mysql/pgsql.
    if [ "$DB_ENGINE" = "mysql" ] || [ "$DB_ENGINE" = "pgsql" ]; then
        if ask_yes_no "Instalar ${DB_ENGINE} em container Docker? (responda não se já usa um banco nativo no host)" "n"; then
            WANT_DB_CONTAINER=1
        else
            WANT_DB_CONTAINER=0
        fi

        if [ "$WANT_DB_CONTAINER" -eq 0 ]; then
            CURRENT_DB_HOST=""
            [ -f .env ] && CURRENT_DB_HOST="$(grep '^DB_HOST=' .env | head -1 | cut -d= -f2- || true)"
            DB_HOST_DEFAULT="${CURRENT_DB_HOST:-host.docker.internal}"
            read -r -p "Endereço do banco de dados (DB_HOST) — host.docker.internal se for nesta máquina, ou outro endereço [${DB_HOST_DEFAULT}]: " DB_HOST_INPUT
            DB_HOST_VALUE="${DB_HOST_INPUT:-$DB_HOST_DEFAULT}"
        fi
    fi
else
    info "Pulando configuração de banco de dados."
fi

# Mesma lógica pro Redis: só pergunta container/host/senha se o projeto de
# fato for usar Redis.
CURRENT_REDIS_HOST=""
[ -f .env ] && CURRENT_REDIS_HOST="$(grep '^REDIS_HOST=' .env | head -1 | cut -d= -f2- || true)"

WANT_REDIS_CONTAINER=0
REDIS_HOST_VALUE=""
USE_REDIS=0
if ask_yes_no "Este projeto usa (ou vai usar) Redis?" "s"; then
    USE_REDIS=1

    if ask_yes_no "Instalar Redis em container Docker? (responda não se já usa um Redis nativo no host)" "n"; then
        WANT_REDIS_CONTAINER=1
    else
        WANT_REDIS_CONTAINER=0
    fi

    if [ "$WANT_REDIS_CONTAINER" -eq 0 ]; then
        REDIS_HOST_DEFAULT="${CURRENT_REDIS_HOST:-host.docker.internal}"
        read -r -p "Endereço do Redis (REDIS_HOST) — host.docker.internal se for nesta máquina, ou outro endereço [${REDIS_HOST_DEFAULT}]: " REDIS_HOST_INPUT
        REDIS_HOST_VALUE="${REDIS_HOST_INPUT:-$REDIS_HOST_DEFAULT}"
    fi
else
    info "Pulando configuração de Redis."
fi

if [ "$SAIL_FRESH_INSTALL" -eq 1 ]; then
    SAIL_SERVICES=""
    [ "$WANT_DB_CONTAINER" -eq 1 ] && SAIL_SERVICES="${DB_ENGINE}"
    if [ "$WANT_REDIS_CONTAINER" -eq 1 ]; then
        if [ -n "$SAIL_SERVICES" ]; then
            SAIL_SERVICES="${SAIL_SERVICES},redis"
        else
            SAIL_SERVICES="redis"
        fi
    fi
    [ -z "$SAIL_SERVICES" ] && SAIL_SERVICES="none"

    info "Rodando o instalador do Sail (php artisan sail:install --with=${SAIL_SERVICES})..."
    php artisan sail:install --with="${SAIL_SERVICES}"
else
    ok "Sail já parece estar instalado (compose.yaml/docker-compose.yml já existe)."
fi

COMPOSE_FILE="compose.yaml"
[ -f "$COMPOSE_FILE" ] || COMPOSE_FILE="docker-compose.yml"

# Reconcilia um serviço de banco/cache (mysql ou redis) contra a resposta do
# usuário: adiciona via 'sail:add' se faltar, ou remove o bloco do compose e
# aponta pro host se ele optou por usar a versão nativa.
reconcile_service() {
    local service="$1" want_container="$2" host_env_var="$3"
    local host_value="${4:-host.docker.internal}"
    local block_exists=0

    grep -qE "^\s{4}${service}:" "$COMPOSE_FILE" && block_exists=1

    if [ "$want_container" -eq 1 ] && [ "$block_exists" -eq 0 ]; then
        info "Adicionando o serviço ${service} a uma instalação Sail existente (php artisan sail:add ${service})..."
        php artisan sail:add "${service}"
        ok "Serviço ${service} adicionado."

    elif [ "$want_container" -eq 0 ] && [ "$block_exists" -eq 1 ]; then
        info "Removendo o serviço '${service}' de ${COMPOSE_FILE} (você optou por ${service} externo/nativo)..."
        awk -v svc="$service" '
            BEGIN { skip = 0 }
            $0 == "    " svc ":" { skip = 1; next }
            skip == 1 {
                if ($0 ~ /^    [A-Za-z0-9_.-]+:$/ || $0 ~ /^[A-Za-z0-9_.-]+:$/) {
                    skip = 0
                } else {
                    next
                }
            }
            { print }
        ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"

        sed -i "/^\s*- ${service}\$/d" "$COMPOSE_FILE"

        ok "Serviço ${service} removido do ${COMPOSE_FILE}."

        if [ -f .env ]; then
            if grep -q "^${host_env_var}=" .env; then
                sed -i "s/^${host_env_var}=.*/${host_env_var}=${host_value}/" .env
            else
                echo "${host_env_var}=${host_value}" >> .env
            fi
            ok "${host_env_var} ajustado para ${host_value} no .env."
        fi

    elif [ "$want_container" -eq 1 ] && [ "$block_exists" -eq 1 ]; then
        ok "${service} em container já está configurado."
    else
        ok "Sem serviço ${service} em container — usando ${service} externo/nativo, como esperado."
    fi
}

# Se o projeto já tinha OUTRO motor configurado no compose (ex: você está
# trocando de mysql para pgsql, ou de mysql para sqlite/none, num projeto já
# existente), remove o bloco antigo antes de reconciliar o motor escolhido
# agora.
for DB_OTHER_ENGINE in mysql pgsql; do
    if [ "$DB_OTHER_ENGINE" != "$DB_ENGINE" ] && grep -qE "^\s{4}${DB_OTHER_ENGINE}:" "$COMPOSE_FILE" 2>/dev/null; then
        info "Encontrei o serviço '${DB_OTHER_ENGINE}' no compose — removendo, já que você selecionou '${DB_ENGINE}' agora..."
        reconcile_service "$DB_OTHER_ENGINE" 0 "DB_HOST" "$DB_HOST_VALUE"
    fi
done

if [ "$DB_ENGINE" = "mysql" ] || [ "$DB_ENGINE" = "pgsql" ]; then
    reconcile_service "$DB_ENGINE" "$WANT_DB_CONTAINER" "DB_HOST" "$DB_HOST_VALUE"

    # reconcile_service só grava DB_HOST quando remove um bloco existente do
    # compose (transição container -> host). Numa instalação nova já optando
    # por banco no host, esse bloco nunca existiu, então DB_HOST nunca era
    # gravado — grava aqui de forma explícita, cobrindo os dois casos.
    if [ "$WANT_DB_CONTAINER" -eq 0 ] && [ -n "$DB_HOST_VALUE" ] && [ -f .env ]; then
        if grep -q '^DB_HOST=' .env; then
            sed -i "s/^DB_HOST=.*/DB_HOST=${DB_HOST_VALUE}/" .env
        else
            echo "DB_HOST=${DB_HOST_VALUE}" >> .env
        fi
        ok "DB_HOST=${DB_HOST_VALUE} configurado no .env."
    fi
fi

# "none" (sem banco) não mexe em DB_CONNECTION/DB_DATABASE — deixa o que já
# estiver no .env (ou nada, num projeto novo) como está.
if [ -f .env ] && [ "$DB_ENGINE" != "none" ]; then
    if grep -q '^DB_CONNECTION=' .env; then
        sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=${DB_ENGINE}/" .env
    else
        echo "DB_CONNECTION=${DB_ENGINE}" >> .env
    fi
    ok "DB_CONNECTION=${DB_ENGINE} configurado no .env."

    if [ "$DB_ENGINE" = "sqlite" ]; then
        SQLITE_PATH="database/database.sqlite"
        if [ ! -f "$SQLITE_PATH" ]; then
            mkdir -p "$(dirname "$SQLITE_PATH")"
            touch "$SQLITE_PATH"
            ok "Arquivo ${SQLITE_PATH} criado."
        fi
        if grep -q '^DB_DATABASE=' .env; then
            sed -i "s#^DB_DATABASE=.*#DB_DATABASE=${SQLITE_PATH}#" .env
        else
            echo "DB_DATABASE=${SQLITE_PATH}" >> .env
        fi
        ok "DB_DATABASE=${SQLITE_PATH} configurado no .env."
    else
        CURRENT_DB_DATABASE="$(grep '^DB_DATABASE=' .env | head -1 | cut -d= -f2- || true)"
        read -r -p "Nome do banco de dados (DB_DATABASE) [${CURRENT_DB_DATABASE:-laravel}]: " DB_DATABASE_INPUT
        DB_DATABASE_VALUE="${DB_DATABASE_INPUT:-${CURRENT_DB_DATABASE:-laravel}}"
        if grep -q '^DB_DATABASE=' .env; then
            sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_DATABASE_VALUE}/" .env
        else
            echo "DB_DATABASE=${DB_DATABASE_VALUE}" >> .env
        fi
        ok "DB_DATABASE=${DB_DATABASE_VALUE} configurado no .env."
    fi
fi

if [ "$WANT_DB_CONTAINER" -eq 0 ] && [ -f .env ] && { [ "$DB_ENGINE" = "mysql" ] || [ "$DB_ENGINE" = "pgsql" ]; }; then
    DB_BIND_HINT="bind-address 0.0.0.0 no my.cnf/mysqld.cnf, e permissão '@%' para o usuário"
    [ "$DB_ENGINE" = "pgsql" ] && DB_BIND_HINT="listen_addresses='*' no postgresql.conf, e uma linha liberando o host em pg_hba.conf"

    warn "Os valores padrão 'sail'/'password' só existem no banco em container —"
    warn "informe as credenciais do seu ${DB_ENGINE} nativo abaixo (Enter mantém o"
    warn "valor atual do .env)."
    warn "Garanta também que o banco do host aceita conexões externas (${DB_BIND_HINT})."

    CURRENT_DB_USERNAME="$(grep '^DB_USERNAME=' .env | head -1 | cut -d= -f2- || true)"
    read -r -p "Usuário do banco no host (DB_USERNAME) [${CURRENT_DB_USERNAME:-sail}]: " DB_USERNAME_INPUT
    DB_USERNAME_VALUE="${DB_USERNAME_INPUT:-${CURRENT_DB_USERNAME:-sail}}"
    if grep -q '^DB_USERNAME=' .env; then
        sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USERNAME_VALUE}/" .env
    else
        echo "DB_USERNAME=${DB_USERNAME_VALUE}" >> .env
    fi
    ok "DB_USERNAME=${DB_USERNAME_VALUE} configurado no .env."

    read -r -s -p "Senha do banco no host (DB_PASSWORD, Enter para deixar em branco): " DB_PASSWORD_INPUT
    echo
    if [ -n "$DB_PASSWORD_INPUT" ]; then
        # Usa grep -v + append em vez de sed, para não ter problema com
        # caracteres especiais (/, &, #, etc.) que a senha possa conter.
        grep -v '^DB_PASSWORD=' .env > .env.tmp || true
        mv .env.tmp .env
        echo "DB_PASSWORD=${DB_PASSWORD_INPUT}" >> .env
        ok "DB_PASSWORD configurado no .env."
    else
        info "Nenhuma senha informada — DB_PASSWORD não foi alterado no .env."
    fi
fi

reconcile_service "redis" "$WANT_REDIS_CONTAINER" "REDIS_HOST" "$REDIS_HOST_VALUE"

# reconcile_service só grava REDIS_HOST quando remove um bloco existente do
# compose (transição container -> host). Numa instalação nova já optando por
# Redis no host, esse bloco nunca existiu, então REDIS_HOST nunca era
# gravado — grava aqui de forma explícita, cobrindo os dois casos.
if [ "$WANT_REDIS_CONTAINER" -eq 0 ] && [ -n "$REDIS_HOST_VALUE" ] && [ -f .env ]; then
    if grep -q '^REDIS_HOST=' .env; then
        sed -i "s/^REDIS_HOST=.*/REDIS_HOST=${REDIS_HOST_VALUE}/" .env
    else
        echo "REDIS_HOST=${REDIS_HOST_VALUE}" >> .env
    fi
    ok "REDIS_HOST=${REDIS_HOST_VALUE} configurado no .env."
fi

if [ "$USE_REDIS" -eq 1 ] && [ "$WANT_REDIS_CONTAINER" -eq 0 ] && [ -f .env ]; then
    warn "Garanta que o Redis do host aceita conexões externas (bind 0.0.0.0 em"
    warn "redis.conf) — sem isso, o Redis recusa conexões vindas do container"
    warn "(modo protegido / protected-mode)."

    read -r -s -p "Senha do Redis do host (REDIS_PASSWORD, Enter para deixar em branco): " REDIS_PASSWORD_INPUT
    echo
    if [ -n "$REDIS_PASSWORD_INPUT" ]; then
        # Usa grep -v + append em vez de sed, para não ter problema com
        # caracteres especiais (/, &, #, etc.) que a senha possa conter.
        grep -v '^REDIS_PASSWORD=' .env > .env.tmp || true
        mv .env.tmp .env
        echo "REDIS_PASSWORD=${REDIS_PASSWORD_INPUT}" >> .env
        ok "REDIS_PASSWORD configurado no .env."
    else
        info "Nenhuma senha informada — REDIS_PASSWORD não foi alterado no .env."
    fi
fi

# Remove qualquer "depends_on:" que tenha ficado vazio depois de remover
# serviços (ex: só tinha "- mysql" e "- redis", e ambos foram removidos).
# Uma chave depends_on vazia (null) pode ser rejeitada por validadores mais
# rígidos de Compose.
awk '
{
    if ($0 ~ /^[ \t]*depends_on:[ \t]*$/) {
        if ((getline nextline) > 0) {
            if (nextline ~ /^[ \t]*- /) {
                print
                print nextline
            } else {
                print nextline
            }
        }
        next
    }
    print
}
' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"

# Prefixo do Redis com o nome do projeto — evita colisão de chaves de cache,
# sessão e fila quando várias aplicações Laravel compartilham a mesma
# instância de Redis (comum ao usar Redis nativo do host com múltiplos
# projetos, mas não faz mal nenhum mesmo com Redis em container).
if [ -f .env ]; then
    REDIS_PREFIX_VALUE="${PROJECT}_database_"
    if grep -q '^REDIS_PREFIX=' .env; then
        sed -i "s/^REDIS_PREFIX=.*/REDIS_PREFIX=${REDIS_PREFIX_VALUE}/" .env
    else
        echo "REDIS_PREFIX=${REDIS_PREFIX_VALUE}" >> .env
    fi
    ok "REDIS_PREFIX=${REDIS_PREFIX_VALUE} configurado no .env (evita colisão de chaves entre projetos)."
fi

# ------------- Portas de host únicas para serviços em container -------------
# Com vários projetos no ar ao mesmo tempo, dois containers de MySQL/Redis não
# podem publicar a mesma porta do host (erro "port is already allocated"). Se
# você optou por rodá-los em container, derivamos uma porta a partir do nome
# do projeto e, se já estiver ocupada, avançamos até uma livre. O app não
# depende disso (fala com os serviços pela rede interna 'sail'); estas portas
# são só para acesso direto do host (cliente de banco, Redis Insight, etc.).
if [ -f .env ] && { [ "$WANT_DB_CONTAINER" -eq 1 ] || [ "$WANT_REDIS_CONTAINER" -eq 1 ]; }; then
    PORT_OFFSET=$(( $(echo "$PROJECT" | cksum | cut -d' ' -f1) % 900 ))

    if [ "$WANT_DB_CONTAINER" -eq 1 ]; then
        DB_PORT_BASE=13306
        [ "$DB_ENGINE" = "pgsql" ] && DB_PORT_BASE=15432
        DB_HOST_PORT="$(free_port $(( DB_PORT_BASE + PORT_OFFSET )))"
        if grep -q '^FORWARD_DB_PORT=' .env; then
            sed -i "s/^FORWARD_DB_PORT=.*/FORWARD_DB_PORT=${DB_HOST_PORT}/" .env
        else
            echo "FORWARD_DB_PORT=${DB_HOST_PORT}" >> .env
        fi
        ok "FORWARD_DB_PORT=${DB_HOST_PORT} no .env (porta de host única do ${DB_ENGINE} em container)."
    fi

    if [ "$WANT_REDIS_CONTAINER" -eq 1 ]; then
        REDIS_HOST_PORT="$(free_port $(( 16379 + PORT_OFFSET )))"
        if grep -q '^FORWARD_REDIS_PORT=' .env; then
            sed -i "s/^FORWARD_REDIS_PORT=.*/FORWARD_REDIS_PORT=${REDIS_HOST_PORT}/" .env
        else
            echo "FORWARD_REDIS_PORT=${REDIS_HOST_PORT}" >> .env
        fi
        ok "FORWARD_REDIS_PORT=${REDIS_HOST_PORT} no .env (porta de host única do Redis em container)."
    fi
fi

# ------------------------- Renomear laravel.test ----------------------------

if grep -qE '^\s{4}laravel\.test:' "$COMPOSE_FILE"; then
    info "Renomeando o serviço 'laravel.test' para '${SERVICE_NAME}' em ${COMPOSE_FILE}..."
    sed -i "s/^\(\s\{4\}\)laravel\.test:/\1${SERVICE_NAME}:/" "$COMPOSE_FILE"
    ok "Serviço renomeado."
elif grep -qE "^\s{4}${SERVICE_NAME}:" "$COMPOSE_FILE"; then
    ok "Serviço já está nomeado como '${SERVICE_NAME}'."
else
    warn "Não encontrei nem 'laravel.test' nem '${SERVICE_NAME}' em ${COMPOSE_FILE}."
    warn "Confira manualmente o nome do serviço principal nesse arquivo."
fi

# Atualiza APP_SERVICE no .env
if [ -f .env ]; then
    if grep -q '^APP_SERVICE=' .env; then
        sed -i "s/^APP_SERVICE=.*/APP_SERVICE=${SERVICE_NAME}/" .env
    else
        echo "APP_SERVICE=${SERVICE_NAME}" >> .env
    fi
    ok "APP_SERVICE=${SERVICE_NAME} configurado no .env."
else
    warn ".env não encontrado — configure APP_SERVICE=${SERVICE_NAME} manualmente depois."
fi

# --------------------- Diretório local de build (PHP) ------------------------
# O "sail:install"/"sail:add" apontam o build context e os volumes de banco do
# compose.yaml para dentro do vendor (./vendor/laravel/sail/runtimes/X e
# ./vendor/laravel/sail/database/{mysql,pgsql,mariadb}/...) — funciona (é o
# Sail "de fábrica"), mas some no próximo "composer install"/update.
#
# A alternativa óbvia seria "php artisan sail:publish", só que esse comando
# não recebe lista nenhuma: ele sempre copia a árvore INTEIRA de stubs do
# pacote — um Dockerfile por versão de PHP suportada (8.0, 8.1, 8.2...) e a
# pasta de init de TODO banco suportado (mysql, mariadb, pgsql) — não só o que
# este projeto usa (foi assim que docker/8.0-8.4 e docker/mysql/mariadb/pgsql
# foram parar no sigait-plus, sem nunca serem referenciados pelo compose.yaml).
#
# Como o Dockerfile é reescrito do zero logo abaixo de qualquer forma, não há
# motivo pra publicar o da Sail só pra descartá-lo em seguida: criamos a pasta
# local nós mesmos e redirecionamos só a linha "context:" do serviço da
# aplicação pra ela. O volume de init do banco em container (quando usado)
# continua apontando pro vendor — não precisamos de cópia local dele, já que
# não mexemos nesse arquivo.
PHP_DIR_FROM_COMPOSE="$(
    sed -n "/^\s\{4\}${SERVICE_NAME}:/,/^\s\{4\}[a-zA-Z0-9_.-]\+:/p" "$COMPOSE_FILE" \
        | grep -m1 "context:" \
        | sed -E "s/.*context: *['\"]?\.\/([^'\"[:space:]]+)['\"]?.*/\1/"
)"

[ -z "$PHP_DIR_FROM_COMPOSE" ] && \
    fail "Não consegui identificar a linha 'context:' do serviço '${SERVICE_NAME}' em ${COMPOSE_FILE}. Confira manualmente."

PHP_VERSION="$(basename "$PHP_DIR_FROM_COMPOSE")"
PHP_DIR="docker/${PHP_VERSION}"

if [ "$PHP_DIR_FROM_COMPOSE" != "$PHP_DIR" ]; then
    info "Redirecionando o build context de '${SERVICE_NAME}' de '${PHP_DIR_FROM_COMPOSE}' (vendor) para '${PHP_DIR}' (local)..."
    sed -i -E "s#(context: *)['\"]?\./${PHP_DIR_FROM_COMPOSE}['\"]?#\1'./${PHP_DIR}'#" "$COMPOSE_FILE"
    ok "Build context ajustado para ${PHP_DIR} em ${COMPOSE_FILE}."
else
    ok "Build context já aponta para ${PHP_DIR}."
fi

mkdir -p "$PHP_DIR"
DOCKERFILE="${PHP_DIR}/Dockerfile"

info "Usando Dockerfiles em: ${PHP_DIR}"

NEEDS_REBUILD=0

# ------------- Runtime PHP: serversideup/php (Alpine + FPM + Nginx) ---------
# Substitui o Dockerfile padrão do Sail (Ubuntu + "php artisan serve" +
# Supervisor) por um baseado em serversideup/php: imagem menor (Alpine), só as
# extensões que o projeto realmente usa, e Nginx+PHP-FPM nativos em vez do
# servidor de desenvolvimento do PHP. Ver
# documentacao/projetos/multas/pdsait/infraestrutura/docker.md para o
# histórico completo dessa decisão.

if grep -q "FROM serversideup/php:" "$DOCKERFILE" 2>/dev/null; then
    ok "Dockerfile já está no runtime serversideup/php — pulando geração."
else
    info "Trocando o runtime do Sail (Ubuntu) por serversideup/php:${PHP_VERSION}-fpm-nginx-alpine-${SERVERSIDEUP_PHP_IMAGE_VERSION}..."

    # Sugestão de extensões a partir do composer.json, em vez de um chute fixo:
    # 1) qualquer "ext-xxx" declarado explicitamente (sinal mais confiável —
    #    foi assim que descobrimos que o pdsait precisava de "soap");
    # 2) uma pequena heurística para pacotes comuns de imagem/PDF que
    #    costumam precisar de gd/imagick sem declarar isso no composer.json.
    # "|| true" no fim do pipeline: sem nenhum "ext-xxx" no composer.json, o
    # grep não casa nada e sai com status 1 — com "pipefail" (set -euo
    # pipefail no topo do script), isso propaga como falha da atribuição e
    # mata o script aqui, silenciosamente (sem nenhuma mensagem de erro).
    DETECTED_EXT_FROM_COMPOSER="$(grep -oE '"ext-[a-z0-9_]+"' composer.json 2>/dev/null | sed -E 's/"ext-([a-z0-9_]+)"/\1/' || true)"

    HEURISTIC_EXT=""
    grep -qE '"(intervention/image|barryvdh/laravel-dompdf|mpdf/mpdf)"' composer.json 2>/dev/null && HEURISTIC_EXT="${HEURISTIC_EXT} gd"
    grep -qE '"(jenssegers/mongodb|mongodb/laravel-mongodb)"' composer.json 2>/dev/null && HEURISTIC_EXT="${HEURISTIC_EXT} mongodb"
    # pdo_mysql já vem na imagem base, mas pdo_pgsql não — sem isso o Laravel
    # não conecta de jeito nenhum num banco pgsql, então entra sempre que
    # esse for o motor escolhido (não é uma heurística, é obrigatório).
    [ "$DB_ENGINE" = "pgsql" ] && HEURISTIC_EXT="${HEURISTIC_EXT} pdo_pgsql pgsql"

    SUGGESTED_EXTENSIONS="$(printf 'bcmath\nintl\nmbstring\n%s\n%s\n' "$DETECTED_EXT_FROM_COMPOSER" "$HEURISTIC_EXT" \
        | tr -s ' ' '\n' | sed '/^$/d' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ *$//')"

    if [ -n "$DETECTED_EXT_FROM_COMPOSER$HEURISTIC_EXT" ]; then
        info "Detectei no composer.json indícios de que este projeto precisa de: ${DETECTED_EXT_FROM_COMPOSER} ${HEURISTIC_EXT}"
    fi
    read -r -p "Extensões PHP adicionais, além de pdo_mysql/redis/zip/opcache/pcntl (já vêm por padrão) [${SUGGESTED_EXTENSIONS}]: " EXTRA_EXT_INPUT
    EXTRA_EXTENSIONS="${EXTRA_EXT_INPUT:-$SUGGESTED_EXTENSIONS}"
    # xdebug sempre entra: fica desligado por padrão (XDEBUG_MODE=off no
    # compose.yaml) e só liga quando o dev pedir, igual ao comportamento do Sail.
    EXTRA_EXTENSIONS="${EXTRA_EXTENSIONS} xdebug"

    # Node/npm: a imagem serversideup/php NÃO traz Node (diferente do template
    # do Sail, que sempre instala). Só adiciona se o projeto tiver frontend.
    # Escrito em duas partes (em vez de um placeholder único) porque o bloco
    # pode ter 0 ou 2 linhas, e um "sed -e s/.../.../";" simples não lida bem
    # com substituição multi-linha.
    NEEDS_NODE=0
    if [ -f package.json ]; then
        info "package.json encontrado — adicionando Node.js/npm à imagem (necessário para 'sail npm run dev/build')."
        NEEDS_NODE=1
    fi

    # Remove os arquivos do runtime antigo do Sail que deixam de fazer sentido
    # (Supervisor, cron, entrypoint do Sail, php.ini — os limites de upload já
    # vêm certos por padrão nessa imagem: PHP_POST_MAX_SIZE/PHP_UPLOAD_MAX_FILE_SIZE=100M).
    rm -f "${PHP_DIR}/supervisord.conf" "${PHP_DIR}/scheduler" "${PHP_DIR}/start-container" "${PHP_DIR}/php.ini"

    cat > "$DOCKERFILE" <<'DOCKERFILE_EOF'
ARG PHP_VERSION=__PHP_VERSION__-fpm-nginx-alpine-__IMAGE_VERSION__

FROM serversideup/php:${PHP_VERSION}

ARG WWWUSER=1000
ARG WWWGROUP=1000

USER root

# pdo_mysql, redis e zip já vêm na imagem base.
RUN install-php-extensions __EXTENSIONS__
DOCKERFILE_EOF

    if [ "$NEEDS_NODE" -eq 1 ]; then
        cat >> "$DOCKERFILE" <<'DOCKERFILE_EOF'

# package.json detectado no projeto: Node/npm não vêm por padrão nessa imagem.
RUN apk add --no-cache nodejs npm
DOCKERFILE_EOF
    fi

    cat >> "$DOCKERFILE" <<'DOCKERFILE_EOF'

# Mapeia o www-data para o UID/GID do host, equivalente ao WWWUSER/WWWGROUP do Sail.
RUN docker-php-serversideup-set-id www-data "${WWWUSER}:${WWWGROUP}" \
    && docker-php-serversideup-set-file-permissions --owner www-data:www-data --service fpm-nginx

# O script vendor/bin/sail roda "docker compose exec -u sail", então precisamos
# de um usuário chamado "sail" apontando para o mesmo UID/GID do www-data.
RUN echo "sail:x:${WWWUSER}:${WWWGROUP}:Sail:/var/www/html:/bin/sh" >> /etc/passwd

USER www-data
DOCKERFILE_EOF

    sed -i \
        -e "s/__PHP_VERSION__/${PHP_VERSION}/g" \
        -e "s/__IMAGE_VERSION__/${SERVERSIDEUP_PHP_IMAGE_VERSION}/g" \
        -e "s/__EXTENSIONS__/${EXTRA_EXTENSIONS}/g" \
        "$DOCKERFILE"

    NEEDS_REBUILD=1
    ok "Dockerfile gerado em ${DOCKERFILE} (serversideup/php, extensões: ${EXTRA_EXTENSIONS}$( [ "$NEEDS_NODE" -eq 1 ] && echo ", node/npm"))."
fi

# WWWUSER precisa ser build arg (não variável de runtime como no template do
# Sail): o UID/GID do www-data é fixado em tempo de build nessa imagem.
if grep -qE "^\s+WWWUSER: '\\\$\{WWWUSER\}'\s*\$" "$COMPOSE_FILE"; then
    info "Movendo WWWUSER de variável de runtime para build arg em ${COMPOSE_FILE}..."
    sed -i "/^\s\+WWWUSER: '\${WWWUSER}'\s*\$/d" "$COMPOSE_FILE"
    sed -i "/WWWGROUP: '\${WWWGROUP}'/a\\                WWWUSER: '\${WWWUSER}'" "$COMPOSE_FILE"
    ok "WWWUSER agora é build arg em ${COMPOSE_FILE}."
else
    ok "WWWUSER já está configurado como build arg."
fi

# A porta interna do Nginx nessa imagem é 8080 (não 80, como no template do Sail).
if grep -qE "'\\\$\{APP_PORT:-80\}:80'" "$COMPOSE_FILE"; then
    info "Ajustando a porta interna do container para 8080 (padrão do Nginx dessa imagem)..."
    sed -i "s/'\${APP_PORT:-80}:80'/'\${APP_PORT:-80}:8080'/" "$COMPOSE_FILE"
    ok "Porta interna ajustada para 8080 em ${COMPOSE_FILE}."
else
    ok "Porta interna do container já está correta."
fi

# O healthcheck do template do Sail testa localhost:80 — nessa imagem o Nginx
# só escuta em 8080, então o healthcheck falhava sempre (unhealthy) mesmo com
# o container respondendo normalmente.
if grep -qE 'curl", "-f", "http://localhost:80/up' "$COMPOSE_FILE"; then
    info "Ajustando o healthcheck para usar a porta 8080..."
    sed -i 's#curl", "-f", "http://localhost:80/up#curl", "-f", "http://localhost:8080/up#' "$COMPOSE_FILE"
    ok "Healthcheck ajustado para 8080 em ${COMPOSE_FILE}."
else
    ok "Healthcheck já aponta para a porta correta."
fi

# ------------------------------- Timezone -----------------------------------
# Essa imagem já lê o timezone via variável de ambiente (PHP_DATE_TIMEZONE),
# sem precisar editar o Dockerfile — muito mais simples que o template do Sail.

detect_host_timezone() {
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl show -p Timezone --value 2>/dev/null
    elif [ -f /etc/timezone ]; then
        cat /etc/timezone
    fi
}

DEFAULT_TZ="$(detect_host_timezone)"
DEFAULT_TZ="${DEFAULT_TZ:-America/Sao_Paulo}"
read -r -p "Timezone da aplicação e do container [$DEFAULT_TZ]: " TZ_INPUT
TIMEZONE="${TZ_INPUT:-$DEFAULT_TZ}"

if grep -q "PHP_DATE_TIMEZONE:" "$COMPOSE_FILE"; then
    sed -i "s#PHP_DATE_TIMEZONE:.*#PHP_DATE_TIMEZONE: '${TIMEZONE}'#" "$COMPOSE_FILE"
    ok "Timezone do container ajustado para ${TIMEZONE} (${COMPOSE_FILE})."
else
    sed -i "/^\s\+LARAVEL_SAIL: 1\$/a\\            PHP_DATE_TIMEZONE: '${TIMEZONE}'" "$COMPOSE_FILE"
    ok "Timezone do container ajustado para ${TIMEZONE} (${COMPOSE_FILE}, variável PHP_DATE_TIMEZONE)."
fi

if [ -f config/app.php ]; then
    if grep -qE "'timezone'\s*=>\s*'UTC'" config/app.php; then
        sed -i -E "s#'timezone'(\s*=>\s*)'UTC'#'timezone'\1'${TIMEZONE}'#" config/app.php
        ok "config/app.php atualizado: timezone = ${TIMEZONE}."
    elif grep -qF "'${TIMEZONE}'" config/app.php; then
        ok "config/app.php já está com timezone = ${TIMEZONE}."
    else
        warn "Não encontrei \"'timezone' => 'UTC'\" em config/app.php. Ajuste manualmente se necessário."
    fi
else
    warn "config/app.php não encontrado — ajuste o timezone da aplicação manualmente."
fi

# ------------- Scheduler / Horizon / Queue worker (s6-overlay) -------------
# Cada um roda como serviço "longrun" independente do s6-overlay (o supervisor
# de processos já embutido na imagem serversideup/php), junto com o
# Nginx+PHP-FPM que a imagem já gerencia — sem precisar instalar cron nem
# editar supervisord.conf. São perguntas separadas (e não uma coisa só, como
# na versão anterior deste script) porque um projeto pode precisar do
# scheduler sem usar Horizon (ex: queue "sync" ou sem filas), ou de um worker
# de fila simples sem Horizon.
#
# A imagem já roda inteiramente como "www-data" (container non-root desde o
# PID 1), então os scripts dos serviços NÃO devem trocar de usuário (algo como
# "s6-setuidgid www-data") — isso falha com "unable to set supplementary
# group list: Operation not permitted", porque um processo não-root não pode
# chamar setgroups(), nem para "trocar" para o usuário que ele já é.

S6_DIR="${PHP_DIR}/s6-overlay"
S6_SERVICES_TO_REGISTER=""

# create_s6_service <nome> <comando artisan...> — cria (se não existir) o
# serviço em disco e marca para registro no Dockerfile (se ainda não registrado).
create_s6_service() {
    local name="$1"
    shift
    mkdir -p "${S6_DIR}/${name}"
    if [ ! -f "${S6_DIR}/${name}/run" ]; then
        info "Criando serviço s6 do ${name}..."
        {
            echo '#!/command/execlineb -P'
            echo 'with-contenv'
            echo "/usr/local/bin/php /var/www/html/artisan $*"
        } > "${S6_DIR}/${name}/run"
        echo "longrun" > "${S6_DIR}/${name}/type"
        ok "Serviço ${name} criado em ${S6_DIR}/${name}."
    else
        ok "Serviço ${name} já existe."
    fi
    if ! grep -q "s6-overlay/${name}" "$DOCKERFILE"; then
        S6_SERVICES_TO_REGISTER="${S6_SERVICES_TO_REGISTER} ${name}"
    fi
}

if ask_yes_no "Configurar o scheduler do Laravel (tarefas agendadas) rodando na mesma imagem?"; then
    create_s6_service scheduler "schedule:work --verbose --no-interaction"
else
    info "Pulando configuração do scheduler."
fi

HORIZON_DEFAULT="n"
grep -q '"laravel/horizon"' composer.json && HORIZON_DEFAULT="s"
if ask_yes_no "Este projeto usa (ou vai usar) Laravel Horizon, fila via Redis?" "$HORIZON_DEFAULT"; then
    create_s6_service horizon "horizon"

    if ! grep -q '"laravel/horizon"' composer.json; then
        warn "laravel/horizon não encontrado no composer.json. Instalando..."
        composer require laravel/horizon
    fi

    warn "Horizon usa Redis (não o driver 'database'). Confira se REDIS_HOST no .env"
    warn "aponta para um Redis de verdade acessível a partir do container (um Redis"
    warn "'nativo' do host normalmente é host.docker.internal, não 'redis' — só use"
    warn "'redis' como host se você tiver optado por Redis em container acima)."
elif ask_yes_no "Configurar um worker de fila (queue:work) sem Horizon?" "n"; then
    create_s6_service queue "queue:work --tries=3"
    info "Worker configurado com 'queue:work --tries=3'. Confira QUEUE_CONNECTION no .env"
    info "(precisa ser 'database' ou 'redis' — 'sync' processa na hora, sem worker)."
else
    info "Sem worker de fila configurado (ok se a fila for 'sync' ou não for usada)."
fi

# Registra de uma vez só, no Dockerfile, todos os serviços novos pendentes
# (a última linha do template gerado acima é sempre "USER www-data"; em vez de
# inserir no meio do arquivo com sed — frágil de escapar entre bash/sed/
# Dockerfile — removemos essa última linha, anexamos os blocos novos, e
# recolocamos "USER www-data" no fim).
if [ -n "$S6_SERVICES_TO_REGISTER" ]; then
    info "Registrando no Dockerfile:${S6_SERVICES_TO_REGISTER}..."
    sed -i '$ d' "$DOCKERFILE"
    for svc in $S6_SERVICES_TO_REGISTER; do
        {
            echo "COPY s6-overlay/${svc} /etc/s6-overlay/s6-rc.d/${svc}"
            echo "RUN chmod +x /etc/s6-overlay/s6-rc.d/${svc}/run \\"
            echo "    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/${svc}"
        } >> "$DOCKERFILE"
    done
    echo "USER www-data" >> "$DOCKERFILE"
    NEEDS_REBUILD=1
    ok "Serviços registrados no Dockerfile:${S6_SERVICES_TO_REGISTER}."
fi

# ------------------------------ Integração Traefik --------------------------

if ask_yes_no "Configurar acesso via domínio (Traefik) em vez de porta (ex: http://${PROJECT}.localhost)?"; then

    TRAEFIK_DIR="$HOME/traefik"

    if ! docker network inspect traefik >/dev/null 2>&1; then
        info "Criando a rede Docker compartilhada 'traefik'..."
        docker network create traefik
    fi

    if [ ! -f "$TRAEFIK_DIR/docker-compose.yml" ]; then
        info "Criando o Traefik compartilhado em ${TRAEFIK_DIR}..."
        mkdir -p "$TRAEFIK_DIR"
        cat > "$TRAEFIK_DIR/docker-compose.yml" <<'EOF'
services:
  traefik:
    # v3.6+ é necessário: versões anteriores (ex: v3.0-v3.5) usam uma versão
    # fixa (1.24) da API do Docker, incompatível com Docker Engine 29+, que
    # passou a exigir no mínimo a 1.44. A v3.6 introduziu negociação
    # automática da versão da API, resolvendo isso.
    image: traefik:v3.6
    restart: unless-stopped
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
    ports:
      - "80:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - traefik

networks:
  traefik:
    external: true
EOF
        ok "Traefik compartilhado criado em ${TRAEFIK_DIR}/docker-compose.yml."
    else
        # Já existe — avisa se estiver numa versão antiga conhecida por
        # quebrar com Docker 29+, mas não sobrescreve customizações.
        if grep -qE "image:\s*traefik:v?3\.[0-5]([^0-9]|$)" "$TRAEFIK_DIR/docker-compose.yml"; then
            warn "O Traefik em ${TRAEFIK_DIR}/docker-compose.yml está na faixa v3.0-v3.5 —"
            warn "essa faixa quebra com Docker Engine 29+ (erro 'client version 1.24 is"
            warn "too old'). Atualize a imagem para 'traefik:v3.6' manualmente e rode"
            warn "'docker compose up -d' de novo na pasta ${TRAEFIK_DIR}."
        fi
        ok "Traefik compartilhado já existe em ${TRAEFIK_DIR}."
    fi

    info "Subindo o Traefik compartilhado (se ainda não estiver rodando)..."
    (cd "$TRAEFIK_DIR" && docker compose up -d)

    if ! docker ps --filter "publish=80" --format '{{.Names}}' | grep -q .; then
        warn "Não detectei nenhum container publicando a porta 80 do host."
        warn "Confira 'docker logs' do container do Traefik em ${TRAEFIK_DIR} caso"
        warn "o acesso via *.localhost não funcione depois."
    fi

    OVERRIDE_FILE="docker-compose.override.yml"
    if [ -f "$OVERRIDE_FILE" ] && grep -q "traefik.enable=true" "$OVERRIDE_FILE" && grep -q "ports: !reset \[\]" "$OVERRIDE_FILE" && grep -q "loadbalancer.server.port=8080" "$OVERRIDE_FILE"; then
        ok "docker-compose.override.yml já configurado para o Traefik (com !reset, porta 8080)."
    else
        if [ -f "$OVERRIDE_FILE" ]; then
            warn "${OVERRIDE_FILE} existe mas está desatualizado (sem 'ports: !reset []' ou ainda na porta 80 do template antigo do Sail)."
            warn "Regenerando..."
        fi
        info "Criando ${OVERRIDE_FILE}..."
        # Porta 8080: é a porta interna do Nginx na imagem serversideup/php
        # (não 80, como no template padrão do Sail).
        cat > "$OVERRIDE_FILE" <<EOF
services:
  ${SERVICE_NAME}:
    ports: !reset []
    networks:
      - sail
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT}.rule=Host(\`${PROJECT}.localhost\`)"
      - "traefik.http.services.${PROJECT}.loadbalancer.server.port=8080"
      - "traefik.docker.network=traefik"

networks:
  traefik:
    external: true
EOF
        ok "${OVERRIDE_FILE} criado. Acesso será via http://${PROJECT}.localhost"
    fi

    # O script "sail" NÃO combina automaticamente o docker-compose.override.yml
    # (isso só acontece com "docker compose" puro, sem -f explícito). É preciso
    # declarar SAIL_FILES no .env para que o sail inclua os dois arquivos.
    if [ -f .env ]; then
        SAIL_FILES_VALUE="${COMPOSE_FILE}:${OVERRIDE_FILE}"
        if grep -q '^SAIL_FILES=' .env; then
            sed -i "s#^SAIL_FILES=.*#SAIL_FILES=${SAIL_FILES_VALUE}#" .env
        else
            echo "SAIL_FILES=${SAIL_FILES_VALUE}" >> .env
        fi
        ok "SAIL_FILES=${SAIL_FILES_VALUE} configurado no .env (necessário para o 'sail' combinar os dois arquivos)."
    fi
else
    info "Pulando integração com Traefik (acesso continuará via porta, ex: http://localhost)."
fi

# --------------------------------- Build / Up --------------------------------

if [ "$NEEDS_REBUILD" -eq 1 ]; then
    info "Mudanças no Dockerfile detectadas — rebuild necessário."
    ./vendor/bin/sail down 2>/dev/null || true
    ./vendor/bin/sail build --no-cache
else
    info "Nenhuma mudança de imagem detectada — sem necessidade de rebuild."
fi

info "Subindo os containers (sail up -d)..."
# --remove-orphans: reconcile_service() pode ter removido mysql/redis do
# compose.yaml (quando você opta por container->host); sem essa flag, o
# container antigo desses serviços fica "órfão", ainda rodando à toa.
# --force-recreate: garante que o container reflita o .env/compose.yaml que
# o script acabou de ajustar (REDIS_HOST, WWWUSER, timezone, etc.), mesmo
# quando o Compose não detecta mudança suficiente para recriar sozinho.
./vendor/bin/sail up -d --remove-orphans --force-recreate

# ------------------ Ferramentas de desenvolvimento (dev) --------------------
# Rodam DEPOIS do 'up' porque tudo acontece dentro do container (sail ...).

# Espera o container do app ficar em estado "running" antes de exec/composer.
info "Aguardando o container '${SERVICE_NAME}' ficar disponível..."
for _ in $(seq 1 30); do
    APP_CID="$(./vendor/bin/sail ps -q "${SERVICE_NAME}" 2>/dev/null | head -1)"
    if [ -n "$APP_CID" ] && \
       [ "$(docker inspect -f '{{.State.Running}}' "$APP_CID" 2>/dev/null)" = "true" ]; then
        break
    fi
    sleep 1
done

# ------------------- composer setup (install, .env, key, migrate) ----------
# Convenção já usada em siger/pdsait/sigait-plus: um script "setup" no
# composer.json que roda "composer install" + garante o ".env" + gera a
# APP_KEY + roda as migrations (e, quando há frontend, npm install/build).
if grep -q '"setup":' composer.json; then
    SETUP_DEFAULT="s"
    if [ "$SAIL_FRESH_INSTALL" -eq 0 ]; then
        # Projeto já tinha Sail configurado antes deste script rodar — não é
        # uma instalação nova. "composer setup" roda "artisan key:generate",
        # que troca a APP_KEY e invalida sessões/cookies e qualquer dado já
        # criptografado com a chave atual. Default "não" para não fazer isso
        # sem intenção explícita numa reconfiguração de projeto existente.
        SETUP_DEFAULT="n"
        warn "Este projeto já tinha Sail configurado — 'composer setup' roda 'artisan"
        warn "key:generate', que troca a APP_KEY e invalida sessões/cookies e qualquer"
        warn "dado já criptografado com a chave atual."
    fi

    SETUP_EXTRA=""
    [ -f package.json ] && SETUP_EXTRA=", npm install/build"

    if ask_yes_no "Rodar 'composer setup' agora (install, .env, key:generate, migrate --force${SETUP_EXTRA})?" "$SETUP_DEFAULT"; then
        info "Rodando 'composer setup' dentro do container..."
        ./vendor/bin/sail composer run-script setup
        ok "'composer setup' concluído."
    fi
else
    info "Nenhum script 'setup' em composer.json — pulando (sem essa convenção neste projeto)."
fi

# Laravel Debugbar (barryvdh/laravel-debugbar) como dependência de dev.
if ask_yes_no "Instalar o Laravel Debugbar (--dev)?" "s"; then
    if grep -q '"barryvdh/laravel-debugbar"' composer.json; then
        ok "Debugbar já está no composer.json."
    else
        info "Instalando barryvdh/laravel-debugbar --dev (dentro do container)..."
        ./vendor/bin/sail composer require barryvdh/laravel-debugbar --dev
        ok "Debugbar instalado."
    fi
fi

# Laravel Boost + registro do MCP no Claude Code.
if ask_yes_no "Instalar o Laravel Boost e registrar o MCP no Claude Code?" "s"; then
    if grep -q '"laravel/boost"' composer.json; then
        ok "laravel/boost já está no composer.json."
    else
        info "Instalando laravel/boost --dev (dentro do container)..."
        ./vendor/bin/sail composer require laravel/boost --dev
        ok "laravel/boost instalado."
    fi

    info "Rodando o instalador do Boost dentro do container (sail artisan boost:install)..."
    ./vendor/bin/sail artisan boost:install

    # O boost:mcp precisa rodar DENTRO do Sail: só lá os hosts 'mysql'/'redis'
    # resolvem. Por isso registramos o MCP como 'docker exec' no container do
    # projeto, e não com o PHP do host.
    APP_CID="$(./vendor/bin/sail ps -q "${SERVICE_NAME}" 2>/dev/null | head -1)"
    APP_CONTAINER_NAME=""
    if [ -n "$APP_CID" ]; then
        APP_CONTAINER_NAME="$(docker inspect -f '{{.Name}}' "$APP_CID" 2>/dev/null | sed 's#^/##')"
    fi

    if command -v claude >/dev/null 2>&1 && [ -n "$APP_CONTAINER_NAME" ]; then
        if claude mcp list 2>/dev/null | grep -q 'laravel-boost'; then
            ok "MCP 'laravel-boost' já está registrado no Claude Code."
        else
            info "Registrando o MCP 'laravel-boost' no Claude Code (escopo local)..."
            if claude mcp add -s local -t stdio laravel-boost -- \
                 docker exec -i -u sail "$APP_CONTAINER_NAME" php artisan boost:mcp; then
                ok "MCP 'laravel-boost' registrado (docker exec em ${APP_CONTAINER_NAME})."
            else
                warn "Falha ao registrar o MCP no Claude Code. Rode manualmente:"
                warn "  claude mcp add -s local -t stdio laravel-boost -- docker exec -i -u sail ${APP_CONTAINER_NAME} php artisan boost:mcp"
            fi
        fi
    else
        warn "CLI 'claude' não encontrado (ou container não resolvido) — registro não automático."
        warn "Com os containers de pé, registre o MCP manualmente com:"
        warn "  claude mcp add -s local -t stdio laravel-boost -- docker exec -i -u sail ${APP_CONTAINER_NAME:-<container>} php artisan boost:mcp"
    fi

    warn "Se o boost:install gerou um .mcp.json de projeto apontando para o PHP do"
    warn "host, prefira o registro em escopo local acima (docker exec) para o Sail."
fi

echo
ok "Setup concluído para o projeto '${PROJECT}'."
echo
echo "Próximos passos sugeridos:"
echo "  ./vendor/bin/sail artisan migrate"
echo "  ./vendor/bin/sail logs -f          # logs do container (Nginx, PHP-FPM, Horizon, scheduler)"
echo
if grep -q "traefik.enable=true" docker-compose.override.yml 2>/dev/null; then
    echo "  Acesse em: http://${PROJECT}.localhost"
else
    echo "  Acesse em: http://localhost (ou a porta definida em APP_PORT no .env)"
fi
echo
echo "Dica: crie um alias global de sail no seu shell, se ainda não tiver:"
echo "  echo \"alias sail='[ -f sail ] && bash sail || bash vendor/bin/sail'\" >> ~/.bashrc"
echo "  source ~/.bashrc"
