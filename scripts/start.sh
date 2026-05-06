#!/usr/bin/env bash
# =============================================================================
# scripts/start.sh
# Porneste backend-ul FastAPI (care serveste si frontend-ul) si deschide
# automat browserul la pagina demo.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }

# Activeaza venv daca exista
if [[ -d .venv ]]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

# Incarcam .env daca exista
if [[ -f backend/.env ]]; then
  set -a; source backend/.env; set +a
elif [[ -f .env ]]; then
  set -a; source .env; set +a
fi

PORT="${APP_PORT:-8000}"
HOST="${APP_HOST:-127.0.0.1}"

log "Pornesc backend FastAPI la http://${HOST}:${PORT}"
log "Frontend-ul este servit la /  (acelasi port)"

# Deschide browserul (in fundal, dupa 2s ca uvicorn sa apuce sa porneasca)
(
  sleep 2
  if command -v open >/dev/null 2>&1; then          # macOS
    open "http://${HOST}:${PORT}/"
  elif command -v xdg-open >/dev/null 2>&1; then    # Linux
    xdg-open "http://${HOST}:${PORT}/"
  fi
) &

# Pornim uvicorn in foreground (Ctrl+C il opreste)
exec uvicorn backend.main:app --host "${HOST}" --port "${PORT}" --reload
