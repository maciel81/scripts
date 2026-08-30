#!/usr/bin/env bash
#
# setup-php-apache.sh
# ---------------------------------------------------------------------------
# Configura um ambiente Docker (Apache + PHP + .htaccess) para QUALQUER
# sistema PHP que rode em Apache — sem framework, sem Laravel, sem Composer.
#
# Este script NÃO assume artisan, .env de aplicação, pasta public/ nem
# nenhuma convenção de framework. Ele só monta a infraestrutura Docker
# (Apache + PHP na versão que VOCÊ escolher, opcionalmente MySQL,
# opcionalmente Traefik) em volta de um projeto PHP já existente, cujo
# document root é a própria raiz do projeto e cujo roteamento depende de
# .htaccess (mod_rewrite).
#
# COMO USAR
#   1. Copie este arquivo para a raiz do projeto PHP.
#   2. chmod +x setup-php-apache.sh
#   3. ./setup-php-apache.sh
#
# É interativo (Enter aceita o padrão) e seguro rodar mais de uma vez —
# ele detecta o que já existe e evita sobrescrever configuração já feita.
#
# PRÉ-REQUISITOS
#   - Docker e Docker Compose instalados e funcionando (docker info OK)
#   - Projeto PHP existente na pasta atual (idealmente com index.php e/ou
#     .htaccess, mas o script não bloqueia se não encontrar)
# ---------------------------------------------------------------------------

set -euo pipefail

# --------------------------- Funções utilitárias ---------------------------

info()  { printf '\033[1;34m[info]\033[0m %s\n' "$1"; }
ok()    { printf '\033[1;32m[ok]\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m[atenção]\033[0m %s\n' "$1"; }
fail()  { printf '\033[1;31m[erro]\033[0m %s\n' "$1"; exit 1; }

ask_yes_no() {
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
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-'
}

# ------------------------------ Pré-checagens -------------------------------

command -v docker >/dev/null 2>&1 || \
    fail "Docker não encontrado. Instale o Docker antes de continuar."

docker info >/dev/null 2>&1 || \
    fail "Docker não está acessível (permissão ou serviço parado). Rode 'docker info' para diagnosticar."

if [ ! -f index.php ] && [ ! -f .htaccess ] && [ ! -f index.html ]; then
    warn "Não encontrei index.php, .htaccess nem index.html na pasta atual."
    warn "Confirme que está rodando este script na raiz do projeto PHP."
    if ! ask_yes_no "Continuar mesmo assim?"; then
        exit 0
    fi
fi

ok "Pré-checagens OK: Docker acessível."

# ------------------------------ Nome do projeto -----------------------------

DEFAULT_NAME="$(sanitize_name "$(basename "$PWD")")"
DEFAULT_NAME="${DEFAULT_NAME:-app}"
read -r -p "Nome do projeto (usado como nome do serviço/container) [$DEFAULT_NAME]: " PROJECT_INPUT
PROJECT="$(sanitize_name "${PROJECT_INPUT:-$DEFAULT_NAME}")"
PROJECT="${PROJECT:-app}"

# Nome do serviço no Compose — sem ponto de propósito: o nome do serviço vira
# hostname interno na rede Docker, e ponto ali confunde resolução de DNS.
SERVICE_NAME="$PROJECT"

info "Usando '${SERVICE_NAME}' como nome do serviço."

# -------------------------------- Versão do PHP ------------------------------
# Esta é a parte central: você escolhe a versão do PHP. A imagem oficial
# usada é sempre php:<versão>-apache, então o Apache já vem embutido.

SUPPORTED_PHP="5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4"

echo
echo "Versões disponíveis como imagem oficial (php:<versão>-apache):"
echo "  ${SUPPORTED_PHP}"
read -r -p "Qual versão do PHP este sistema usa? [7.4]: " PHP_VERSION_INPUT
PHP_VERSION="${PHP_VERSION_INPUT:-7.4}"

# Validação simples: avisa se a versão não estiver na lista conhecida.
PHP_KNOWN=0
for v in $SUPPORTED_PHP; do
    [ "$v" = "$PHP_VERSION" ] && PHP_KNOWN=1 && break
done
if [ "$PHP_KNOWN" -eq 0 ]; then
    warn "'${PHP_VERSION}' não está na lista de versões conhecidas."
    warn "O build vai tentar 'php:${PHP_VERSION}-apache' mesmo assim — se essa"
    warn "tag não existir no Docker Hub, o build vai falhar."
    if ! ask_yes_no "Continuar com PHP ${PHP_VERSION}?"; then
        exit 0
    fi
fi

info "Usando PHP ${PHP_VERSION} (imagem php:${PHP_VERSION}-apache)."
case "$PHP_VERSION" in
    5.6|7.0|7.1)
        warn "PHP ${PHP_VERSION} está em fim de vida (sem patches de segurança)."
        warn "Isso é esperado para sistemas legados, mas evite expor à internet."
        ;;
esac

# ------------------------------ Banco de dados -------------------------------

if ask_yes_no "Instalar MySQL em container Docker? (responda não se já usa um MySQL nativo no host)" "n"; then
    WANT_DB_CONTAINER=1
else
    WANT_DB_CONTAINER=0
fi

DB_NAME="$PROJECT"
DB_USER="$PROJECT"
DB_PASSWORD=""
DB_ROOT_PASSWORD=""
DB_HOST_VALUE=""

if [ "$WANT_DB_CONTAINER" -eq 1 ]; then
    read -r -p "Nome do banco de dados [$DB_NAME]: " DB_NAME_INPUT
    DB_NAME="${DB_NAME_INPUT:-$DB_NAME}"

    read -r -p "Usuário do banco [$DB_USER]: " DB_USER_INPUT
    DB_USER="${DB_USER_INPUT:-$DB_USER}"

    read -r -s -p "Senha do usuário do banco (Enter para gerar uma aleatória): " DB_PASSWORD_INPUT
    echo
    DB_PASSWORD="${DB_PASSWORD_INPUT:-$(openssl rand -hex 12 2>/dev/null || date +%s | sha256sum | cut -c1-24)}"

    read -r -s -p "Senha do root do MySQL (Enter para gerar uma aleatória): " DB_ROOT_PASSWORD_INPUT
    echo
    DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD_INPUT:-$(openssl rand -hex 12 2>/dev/null || date +%s | sha256sum | cut -c1-24)}"

    DB_HOST_VALUE="mysql"
else
    DB_HOST_VALUE="host.docker.internal"
    read -r -p "Nome do banco de dados a usar no MySQL do host [$DB_NAME]: " DB_NAME_INPUT
    DB_NAME="${DB_NAME_INPUT:-$DB_NAME}"
    read -r -p "Usuário do MySQL do host [$DB_USER]: " DB_USER_INPUT
    DB_USER="${DB_USER_INPUT:-$DB_USER}"
    read -r -s -p "Senha do usuário do MySQL do host: " DB_PASSWORD_INPUT
    echo
    DB_PASSWORD="$DB_PASSWORD_INPUT"

    warn "Garanta que o MySQL do host aceita conexões externas (bind-address"
    warn "0.0.0.0) e que o usuário '${DB_USER}' tem permissão '@%' para o banco"
    warn "'${DB_NAME}'. Exemplo de comandos SQL:"
    warn "  CREATE USER '${DB_USER}'@'%' IDENTIFIED BY 'sua_senha';"
    warn "  GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';"
    warn "  FLUSH PRIVILEGES;"
fi

# ------------------------------ Diretório docker/ ----------------------------

mkdir -p docker

# UID/GID do host: mapeados para o www-data do container (ver Dockerfile
# abaixo), para que arquivos escritos pela aplicação no volume montado não
# fiquem com dono incompatível (ex: www-data padrão da imagem, uid 33) —
# mesmo cuidado que o setup-sail.sh tem com WWWUSER/WWWGROUP.
WWWUSER="$(id -u)"
WWWGROUP="$(id -g)"

# Algumas extensões (mbstring, zip, gd via freetype) mudaram de nome/pré-req
# ao longo das versões. O bloco abaixo cobre bem de 7.x a 8.x. Para 5.6, as
# libs *-dev do Debian atual podem ser incompatíveis; se o build de gd/zip
# falhar no 5.6, comente essas extensões no Dockerfile e rebuild.
DOCKERFILE="docker/Dockerfile"
if [ ! -f "$DOCKERFILE" ]; then
    info "Criando ${DOCKERFILE}..."
    cat > "$DOCKERFILE" <<EOF
FROM php:${PHP_VERSION}-apache

ARG WWWUSER=1000
ARG WWWGROUP=1000

# Extensões comuns em sistemas PHP legados
RUN apt-get update && apt-get install -y --no-install-recommends \\
        libpng-dev \\
        libjpeg-dev \\
        libfreetype6-dev \\
        libzip-dev \\
        libxml2-dev \\
        libonig-dev \\
        unzip \\
        git \\
        curl \\
    && docker-php-ext-configure gd --with-freetype --with-jpeg \\
    && docker-php-ext-install -j\$(nproc) \\
        gd \\
        mysqli \\
        pdo_mysql \\
        mbstring \\
        xml \\
        zip \\
        opcache \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Habilita mod_rewrite (necessário para .htaccess reescrever URLs)
RUN a2enmod rewrite

# Permite que o .htaccess sobrescreva configurações (AllowOverride All).
# Sem isto o Apache IGNORA o .htaccess e as regras de rewrite não têm efeito.
RUN { \\
        echo '<Directory /var/www/html>'; \\
        echo '    AllowOverride All'; \\
        echo '    Require all granted'; \\
        echo '</Directory>'; \\
    } > /etc/apache2/conf-available/htaccess-override.conf \\
    && a2enconf htaccess-override

# Mapeia o www-data (usuário do Apache/PHP-FPM nessa imagem) para o UID/GID
# do host — equivalente ao WWWUSER/WWWGROUP do Sail. Sem isso, arquivos
# criados pela aplicação no volume montado ficam com o dono padrão da
# imagem (www-data, uid/gid 33), inacessível/gravável só como root no host.
RUN usermod -u "\${WWWUSER}" www-data && groupmod -g "\${WWWGROUP}" www-data \\
    && chown -R www-data:www-data /var/www/html

WORKDIR /var/www/html
EOF
    ok "${DOCKERFILE} criado (PHP ${PHP_VERSION} + Apache + mod_rewrite, www-data mapeado para uid/gid ${WWWUSER}/${WWWGROUP})."
else
    ok "${DOCKERFILE} já existe — não sobrescrevendo (edite manualmente se precisar)."
    if ! grep -q 'ARG WWWUSER' "$DOCKERFILE"; then
        warn "${DOCKERFILE} não mapeia www-data para o UID/GID do host (ARG WWWUSER"
        warn "ausente) — arquivos gravados pela aplicação no volume podem ficar com"
        warn "dono incompatível (www-data, uid/gid 33). Considere adicionar manualmente"
        warn "(ver bloco 'RUN usermod/groupmod' gerado para instalações novas)."
    fi
fi

PHP_INI="docker/php.ini"
if [ ! -f "$PHP_INI" ]; then
    info "Criando ${PHP_INI} (ajustes comuns para sistemas legados)..."
    cat > "$PHP_INI" <<'EOF'
; Ajustes comuns úteis para sistemas PHP legados
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 120
display_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
EOF
    ok "${PHP_INI} criado."
else
    ok "${PHP_INI} já existe — não sobrescrevendo."
fi

# ------------------------------ .env (só do Docker) --------------------------

ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    info "Criando ${ENV_FILE} (usado SÓ pelo Docker Compose, não pela aplicação PHP)..."
    {
        echo "# Este .env e lido automaticamente pelo Docker Compose para as"
        echo "# variaveis abaixo. A aplicacao PHP NAO le este arquivo —"
        echo "# configure as credenciais de banco manualmente no arquivo de"
        echo "# config do proprio sistema (ex: config.php, conexao.php)."
        echo "APP_PORT=8080"
        echo "WWWUSER=${WWWUSER}"
        echo "WWWGROUP=${WWWGROUP}"
        echo "DB_HOST=${DB_HOST_VALUE}"
        echo "DB_NAME=${DB_NAME}"
        echo "DB_USER=${DB_USER}"
        echo "DB_PASSWORD=${DB_PASSWORD}"
        if [ "$WANT_DB_CONTAINER" -eq 1 ]; then
            echo "DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
            echo "FORWARD_DB_PORT=3306"
        fi
    } > "$ENV_FILE"
    ok "${ENV_FILE} criado."
else
    ok "${ENV_FILE} já existe — não sobrescrevendo. Confira manualmente se os"
    ok "valores de DB_HOST/DB_NAME/DB_USER/DB_PASSWORD ainda fazem sentido."
    if grep -q '^WWWUSER=' "$ENV_FILE"; then
        sed -i "s/^WWWUSER=.*/WWWUSER=${WWWUSER}/" "$ENV_FILE"
    else
        echo "WWWUSER=${WWWUSER}" >> "$ENV_FILE"
    fi
    if grep -q '^WWWGROUP=' "$ENV_FILE"; then
        sed -i "s/^WWWGROUP=.*/WWWGROUP=${WWWGROUP}/" "$ENV_FILE"
    else
        echo "WWWGROUP=${WWWGROUP}" >> "$ENV_FILE"
    fi
    ok "WWWUSER=${WWWUSER} / WWWGROUP=${WWWGROUP} configurados no ${ENV_FILE}."
fi

# ------------------------------ docker-compose.yml ---------------------------

COMPOSE_FILE="docker-compose.yml"
if [ -f "$COMPOSE_FILE" ]; then
    ok "${COMPOSE_FILE} já existe — não sobrescrevendo."
    if ! grep -q 'WWWUSER' "$COMPOSE_FILE"; then
        warn "${COMPOSE_FILE} não passa WWWUSER/WWWGROUP como build arg do serviço"
        warn "'${SERVICE_NAME}'. Adicione manualmente (dentro de 'build:'):"
        warn "      args:"
        warn "        WWWUSER: '\${WWWUSER}'"
        warn "        WWWGROUP: '\${WWWGROUP}'"
    fi
else
    info "Criando ${COMPOSE_FILE}..."

    {
        echo "services:"
        echo "  ${SERVICE_NAME}:"
        echo "    build:"
        echo "      context: ./docker"
        echo "      dockerfile: Dockerfile"
        echo "      args:"
        echo "        WWWUSER: '\${WWWUSER}'"
        echo "        WWWGROUP: '\${WWWGROUP}'"
        echo "    image: ${PROJECT}/app"
        echo "    ports:"
        echo "      - '\${APP_PORT:-8080}:80'"
        echo "    extra_hosts:"
        echo "      - 'host.docker.internal:host-gateway'"
        echo "    volumes:"
        echo "      - '.:/var/www/html'"
        echo "      - './docker/php.ini:/usr/local/etc/php/conf.d/99-custom.ini'"
        echo "    networks:"
        echo "      - app"
        if [ "$WANT_DB_CONTAINER" -eq 1 ]; then
            echo "    depends_on:"
            echo "      - mysql"
        fi
        echo
        if [ "$WANT_DB_CONTAINER" -eq 1 ]; then
            echo "  mysql:"
            echo "    image: 'mysql:8.0'"
            echo "    ports:"
            echo "      - '\${FORWARD_DB_PORT:-3306}:3306'"
            echo "    environment:"
            echo "      MYSQL_ROOT_PASSWORD: '\${DB_ROOT_PASSWORD}'"
            echo "      MYSQL_DATABASE: '\${DB_NAME}'"
            echo "      MYSQL_USER: '\${DB_USER}'"
            echo "      MYSQL_PASSWORD: '\${DB_PASSWORD}'"
            echo "    volumes:"
            echo "      - '${PROJECT}-mysql:/var/lib/mysql'"
            echo "    networks:"
            echo "      - app"
            echo "    healthcheck:"
            echo "      test: ['CMD', 'mysqladmin', 'ping', '-p\${DB_ROOT_PASSWORD}']"
            echo "      retries: 3"
            echo "      timeout: 5s"
            echo
        fi
        echo "networks:"
        echo "  app:"
        echo "    driver: bridge"
        if [ "$WANT_DB_CONTAINER" -eq 1 ]; then
            echo
            echo "volumes:"
            echo "  ${PROJECT}-mysql:"
            echo "    driver: local"
        fi
    } > "$COMPOSE_FILE"

    ok "${COMPOSE_FILE} criado."
fi

# ------------------------------ Integração Traefik --------------------------
# Opcional: acesso por domínio (http://projeto.localhost) em vez de porta.

if ask_yes_no "Configurar acesso via domínio (Traefik) em vez de porta (ex: http://${PROJECT}.localhost)?" "n"; then

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
    # v3.6+ é necessário: versões anteriores usam uma versão fixa (1.24) da
    # API do Docker, incompatível com Docker Engine 29+ (mínimo 1.44).
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
        if grep -qE "image:\s*traefik:v?3\.[0-5]([^0-9]|$)" "$TRAEFIK_DIR/docker-compose.yml"; then
            warn "O Traefik em ${TRAEFIK_DIR}/docker-compose.yml está na faixa v3.0-v3.5 —"
            warn "isso quebra com Docker Engine 29+. Atualize a imagem para 'traefik:v3.6'."
        fi
        ok "Traefik compartilhado já existe em ${TRAEFIK_DIR}."
    fi

    info "Subindo o Traefik compartilhado (se ainda não estiver rodando)..."
    (cd "$TRAEFIK_DIR" && docker compose up -d)

    OVERRIDE_FILE="docker-compose.override.yml"
    if [ -f "$OVERRIDE_FILE" ] && grep -q "traefik.enable=true" "$OVERRIDE_FILE" && grep -q "ports: !reset \[\]" "$OVERRIDE_FILE"; then
        ok "${OVERRIDE_FILE} já configurado para o Traefik."
    else
        info "Criando ${OVERRIDE_FILE}..."
        cat > "$OVERRIDE_FILE" <<EOF
services:
  ${SERVICE_NAME}:
    ports: !reset []
    networks:
      - app
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${PROJECT}.rule=Host(\`${PROJECT}.localhost\`)"
      - "traefik.http.services.${PROJECT}.loadbalancer.server.port=80"
      - "traefik.docker.network=traefik"

networks:
  traefik:
    external: true
EOF
        ok "${OVERRIDE_FILE} criado. Acesso será via http://${PROJECT}.localhost"
    fi

    if ! grep -q '^COMPOSE_FILE=' .env 2>/dev/null; then
        echo "COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml" >> .env
        ok "COMPOSE_FILE configurado no .env (o 'docker compose' puro já combina"
        ok "os dois arquivos automaticamente lendo essa variável)."
    fi
else
    info "Pulando integração com Traefik (acesso continuará via porta, ex: http://localhost:8080)."
fi

# --------------------------------- Build / Up --------------------------------

info "Buildando a imagem..."
docker compose build

info "Subindo os containers..."
docker compose up -d

echo
ok "Setup concluído para o projeto '${PROJECT}'."
echo
echo "Resumo:"
echo "  PHP:      ${PHP_VERSION} (Apache + mod_rewrite, AllowOverride All)"
echo "  Document root: raiz do projeto (sem pasta public/)"
if [ "$WANT_DB_CONTAINER" -eq 1 ]; then
    echo "  MySQL:    container Docker"
    echo "    Host (de dentro do container): mysql"
    echo "    Banco:    ${DB_NAME}"
    echo "    Usuário:  ${DB_USER}"
    echo "    Senha:    (definida no .env, campo DB_PASSWORD)"
else
    echo "  MySQL:    externo/nativo do host"
    echo "    Host (de dentro do container): host.docker.internal"
fi
echo
echo "IMPORTANTE: como este sistema não usa .env de aplicação, configure"
echo "manualmente as credenciais de banco no arquivo de configuração do"
echo "próprio sistema (ex: config.php), usando os valores gravados em ${ENV_FILE}."
echo
if grep -q "traefik.enable=true" docker-compose.override.yml 2>/dev/null; then
    echo "Acesse em: http://${PROJECT}.localhost"
else
    echo "Acesse em: http://localhost:8080 (ou a porta definida em APP_PORT no .env)"
fi
echo
echo "Comandos úteis:"
echo "  docker compose logs -f ${SERVICE_NAME}      Ver logs da aplicação"
echo "  docker compose exec ${SERVICE_NAME} bash    Abrir shell no container"
echo "  docker compose down                          Parar os containers"
echo "  docker compose up -d                         Subir os containers"
