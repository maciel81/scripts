#!/usr/bin/env bash
# Sincroniza as memórias de projeto do Claude Code (~/.claude/projects/*/memory/)
# entre dispositivos, via um repositório git dedicado (claude-memory-sync).
#
# Convenção sem device-codes: a base dos projetos é sempre $HOME/Code (real dir
# ou symlink) em qualquer máquina, e ~/.claude/projects/ já é sempre $HOME por
# natureza. A pasta de memória de cada projeto é localizada dinamicamente
# procurando o diretório do projeto dentro de $HOME/Code e recodificando o path
# real (símlinks resolvidos) do jeito que o próprio Claude Code nomeia as pastas
# em ~/.claude/projects (substituindo "/" por "-").
#
# Uso:
#   claude-sync.sh update              # git pull no repo de memórias
#   claude-sync.sh add <projeto>       # cria pasta do projeto no repo
#   claude-sync.sh del <projeto>       # remove pasta do projeto no repo
#   claude-sync.sh push <projeto|all>  # memória local -> repo (commit+push)
#   claude-sync.sh pull <projeto|all>  # repo -> memória local
set -euo pipefail

PROJECTS_DIR="$HOME/.claude/projects"
CODE_BASE="$(realpath "$HOME/Code" 2>/dev/null || true)"
MEMORY_REPO="$CODE_BASE/claude-memory-sync"

err() { echo "ERRO: $*" >&2; }
warn() { echo "AVISO: $*" >&2; }

require_setup() {
  if [ -z "$CODE_BASE" ] || [ ! -d "$CODE_BASE" ]; then
    err "\$HOME/Code não existe (nem como diretório real, nem como symlink). Crie-o antes de usar este script."
    exit 1
  fi
  if [ ! -d "$MEMORY_REPO/.git" ]; then
    err "Repositório de memórias não encontrado em $MEMORY_REPO (clone https://github.com/maciel81/claude-memory-sync ali)."
    exit 1
  fi
}

# Codifica um path absoluto do jeito que o Claude Code nomeia pastas em ~/.claude/projects
encode_path() {
  echo "$1" | sed 's#/#-#g'
}

# Acha o diretório real de um projeto dentro de $CODE_BASE. Erra se achar 0 ou
# mais de 1 candidato (ambíguo) em vez de adivinhar.
resolve_project_path() {
  local name="$1"
  local matches
  matches="$(find "$CODE_BASE" -maxdepth 2 -type d \
    \( -name node_modules -o -name vendor -o -name .git -o -path "$MEMORY_REPO" \) -prune \
    -o -type d -name "$name" -print 2>/dev/null)"

  local count
  count="$(echo "$matches" | sed '/^$/d' | wc -l)"

  if [ "$count" -eq 0 ]; then
    return 1
  elif [ "$count" -gt 1 ]; then
    err "projeto '$name' é ambíguo, achei mais de um diretório:"
    echo "$matches" >&2
    return 1
  fi
  echo "$matches"
}

# Caminho da pasta memory/ local de um projeto (pode não existir ainda)
local_memory_dir() {
  local name="$1"
  local proj_path
  proj_path="$(resolve_project_path "$name")" || return 1
  echo "$PROJECTS_DIR/$(encode_path "$proj_path")/memory"
}

cmd_update() {
  require_setup
  if ! git -C "$MEMORY_REPO" ls-remote --exit-code origin >/dev/null 2>&1; then
    warn "repositório remoto ainda está vazio, nada pra puxar."
    return 0
  fi
  git -C "$MEMORY_REPO" pull --rebase --autostash -q
}

cmd_add() {
  require_setup
  local project="$1"
  mkdir -p "$MEMORY_REPO/$project"
  touch "$MEMORY_REPO/$project/.gitkeep"
  git -C "$MEMORY_REPO" add "$project"
  if git -C "$MEMORY_REPO" diff --cached --quiet; then
    echo "'$project' já existe no repositório, nada a fazer."
    return 0
  fi
  git -C "$MEMORY_REPO" commit -q -m "add: cria projeto $project"
  git -C "$MEMORY_REPO" push -q
  echo "OK: $MEMORY_REPO/$project criado e enviado."
}

cmd_del() {
  require_setup
  local project="$1"
  if [ ! -d "$MEMORY_REPO/$project" ]; then
    warn "'$project' não existe no repositório."
    return 0
  fi
  read -r -p "Remover '$project' do repositório de memórias (histórico git preserva, mas some do HEAD)? [y/N] " ans
  case "$ans" in
    y|Y) ;;
    *) echo "Cancelado."; return 0 ;;
  esac
  git -C "$MEMORY_REPO" rm -rq "$project"
  git -C "$MEMORY_REPO" commit -q -m "del: remove projeto $project"
  git -C "$MEMORY_REPO" push -q
  echo "OK: $project removido."
}

# Envia a memória local de um projeto pro repo (assume update já rodado)
do_push_one() {
  local project="$1"
  local local_dir
  if ! local_dir="$(local_memory_dir "$project")"; then
    warn "não consegui localizar o projeto '$project' em $CODE_BASE, pulando."
    return 0
  fi
  if [ ! -d "$local_dir" ]; then
    warn "sem memória local pra '$project' ($local_dir não existe), nada a enviar."
    return 0
  fi

  mkdir -p "$MEMORY_REPO/$project"
  rsync -a --delete --exclude '.gitkeep' "$local_dir"/ "$MEMORY_REPO/$project"/
  git -C "$MEMORY_REPO" add "$project"
  if git -C "$MEMORY_REPO" diff --cached --quiet; then
    echo "'$project': sem mudanças."
    return 0
  fi
  git -C "$MEMORY_REPO" commit -q -m "push: $project de $(hostname) $(date -Iseconds)"
  if ! git -C "$MEMORY_REPO" push -q; then
    err "push de '$project' rejeitado (repositório remoto tem commits novos). Rode 'claude-sync.sh update' e tente de novo."
    return 1
  fi
  echo "OK: '$project' enviado."
}

# Traz a memória de um projeto do repo pra local (assume update já rodado)
do_pull_one() {
  local project="$1"
  if [ ! -d "$MEMORY_REPO/$project" ]; then
    warn "'$project' não existe no repositório, pulando."
    return 0
  fi
  local local_dir
  if ! local_dir="$(local_memory_dir "$project")"; then
    warn "não consegui localizar o projeto '$project' em $CODE_BASE, pulando."
    return 0
  fi
  mkdir -p "$local_dir"
  rsync -a --delete --exclude '.gitkeep' "$MEMORY_REPO/$project"/ "$local_dir"/
  echo "OK: '$project' atualizado localmente."
}

cmd_push() {
  require_setup
  local target="$1"
  cmd_update
  if [ "$target" = "all" ]; then
    local project dir
    for dir in "$MEMORY_REPO"/*/; do
      [ -d "$dir" ] || continue
      project="$(basename "$dir")"
      do_push_one "$project"
    done
  else
    do_push_one "$target"
  fi
}

cmd_pull() {
  require_setup
  local target="$1"
  cmd_update
  if [ "$target" = "all" ]; then
    local project dir
    for dir in "$MEMORY_REPO"/*/; do
      [ -d "$dir" ] || continue
      project="$(basename "$dir")"
      do_pull_one "$project"
    done
  else
    do_pull_one "$target"
  fi
}

usage() {
  cat <<'EOF'
Uso: claude-sync.sh <comando> [projeto]

  update              git pull no repositório de memórias
  add <projeto>       cria pasta do projeto no repositório
  del <projeto>       remove pasta do projeto no repositório
  push <projeto|all>  memória local -> repositório (commit+push)
  pull <projeto|all>  repositório -> memória local
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    update) cmd_update ;;
    add) [ $# -eq 2 ] || { usage; exit 1; }; cmd_add "$2" ;;
    del) [ $# -eq 2 ] || { usage; exit 1; }; cmd_del "$2" ;;
    push) [ $# -eq 2 ] || { usage; exit 1; }; cmd_push "$2" ;;
    pull) [ $# -eq 2 ] || { usage; exit 1; }; cmd_pull "$2" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
