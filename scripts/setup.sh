#!/usr/bin/env bash
# =============================================================================
# scripts/setup.sh
# Setup end-to-end pentru demo Oracle Vector vs Keyword Search.
#
# Rulat o singura data dupa `git clone`. Idempotent: re-rularea functioneaza.
#
# Pasi:
#   1. Verifica prerequisite (docker, python, curl)
#   2. Porneste containerul Oracle (daca nu ruleaza deja)
#   3. Asteapta DB ready (loop sqlplus)
#   4. Descarca modelul ONNX (~125 MB) daca nu exista
#   5. Restart DB (pentru ca vector_memory_size cere SCOPE=SPFILE)
#   6. Ruleaza scripturile SQL (01, 02, 03)
#   7. Instaleaza dependintele Python si incarca dataset-ul
#   8. Genereaza embedding-urile in DB (SQL 04)
#   9. Raporteaza durata totala si numarul de randuri
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Culori pentru output (mai usor de citit)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
err() { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; }

# Incarcam .env daca exista
if [[ -f .env ]]; then
  log "Incarc .env"
  set -a; source .env; set +a
else
  warn "Fisierul .env nu exista. Folosesc valorile default. Recomand 'cp .env.example .env'"
  ORACLE_PWD="${ORACLE_PWD:-DemoPass123}"
  VECUSER_PWD="${VECUSER_PWD:-VecUser123}"
fi

CONTAINER_NAME="${ORACLE_CONTAINER_NAME:-oracle-23ai-demo}"
START_TIME=$(date +%s)

# ----------------------------------------------------------------------------
# 1. Prerequisite
# ----------------------------------------------------------------------------
log "Pas 1/9: verific prerequisite"
for cmd in docker python3 curl unzip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Comanda '$cmd' nu este instalata."
    exit 1
  fi
done

# Detectam docker compose v2 vs v1
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  err "Nu am gasit nici 'docker compose' nici 'docker-compose'."
  exit 1
fi
log "Folosesc: ${DC}"

# ----------------------------------------------------------------------------
# 2. Pornire container
# ----------------------------------------------------------------------------
log "Pas 2/9: pornesc containerul Oracle"
${DC} up -d
log "Container ${CONTAINER_NAME} pornit"

# ----------------------------------------------------------------------------
# 3. Wait for DB ready
# ----------------------------------------------------------------------------
log "Pas 3/9: astept ca DB-ul sa fie pregatit (poate dura 2-5 minute la primul boot)..."

wait_for_db() {
  # Verificare prin proba SQL reala - mai robusta decat grep pe checkDBStatus.sh
  # (acel script pe imaginea 23ai lite NU printeaza "READY", returneaza prin exit code)
  local max=${1:-420}
  local waited=0
  until docker exec "${CONTAINER_NAME}" bash -c \
        "echo 'SELECT 1 FROM dual;' | sqlplus -s sys/${ORACLE_PWD}@FREEPDB1 as sysdba" \
        2>/dev/null | grep -qE "^\s*1\s*$"; do
    if [[ ${waited} -ge ${max} ]]; then
      err "DB nu a devenit ready in ${max}s. Verifica: docker logs ${CONTAINER_NAME}"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
    echo -n "."
  done
  echo ""
  log "DB ready dupa ${waited}s"
  return 0
}

wait_for_db 420 || exit 1

# ----------------------------------------------------------------------------
# 4. Descarcam modelul ONNX
# ----------------------------------------------------------------------------
log "Pas 4/9: descarc modelul ONNX"
bash ingest/download_model.sh

# ----------------------------------------------------------------------------
# 5. Restart pentru a aplica vector_memory_size (SPFILE)
# ----------------------------------------------------------------------------
log "Pas 5/9: configurez vector_memory_size si restart DB"
docker exec "${CONTAINER_NAME}" bash -c "
  echo \"ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;\" | sqlplus -S sys/${ORACLE_PWD}@FREE as sysdba
" || warn "ALTER SYSTEM a esuat (poate e deja setat)"

log "Restart DB pentru aplicarea vector_memory_size"
docker exec "${CONTAINER_NAME}" bash -c "
  echo \"SHUTDOWN IMMEDIATE;
STARTUP;\" | sqlplus -S sys/${ORACLE_PWD}@FREE as sysdba
" || warn "Restart prin sqlplus a esuat. Incerc restart container."

# Wait din nou ca sa fie ready
log "Astept din nou ca DB sa fie ready dupa restart..."
wait_for_db 180 || exit 1

# ----------------------------------------------------------------------------
# 6. Ruleaza scripturile SQL (01, 02, 03)
# ----------------------------------------------------------------------------
run_sql_as_sys() {
  local script_path="$1"
  local script_name=$(basename "$script_path")
  log "Rulez ${script_name} ca SYS"
  docker exec -i "${CONTAINER_NAME}" \
    sqlplus -S "sys/${ORACLE_PWD}@FREEPDB1 as sysdba" < "$script_path" \
    || { err "Esec rulare ${script_name}"; exit 1; }
}

run_sql_as_vecuser() {
  local script_path="$1"
  local script_name=$(basename "$script_path")
  log "Rulez ${script_name} ca vecuser"
  docker exec -i "${CONTAINER_NAME}" \
    sqlplus -S "vecuser/${VECUSER_PWD}@FREEPDB1" < "$script_path" \
    || { err "Esec rulare ${script_name}"; exit 1; }
}

log "Pas 6/9: rulez scripturi SQL"
run_sql_as_sys     sql/01_setup_user.sql
run_sql_as_vecuser sql/02_setup_schema.sql
# 03 trebuie inceput ca SYS (creeaza directory) apoi executa parti ca vecuser
run_sql_as_sys     sql/03_load_onnx_model.sql

# ----------------------------------------------------------------------------
# 7. Python deps + ingest dataset
# ----------------------------------------------------------------------------
log "Pas 7/9: instalez dependinte Python si incarc dataset-ul"

# Cream un venv local daca nu exista
if [[ ! -d .venv ]]; then
  log "Creez venv .venv"
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

pip install --quiet --upgrade pip
pip install --quiet -r ingest/requirements.txt
pip install --quiet -r backend/requirements.txt

ORACLE_USER=vecuser \
ORACLE_PWD_VECUSER="${VECUSER_PWD}" \
ORACLE_DSN="localhost:1521/FREEPDB1" \
python ingest/load_dataset.py

# ----------------------------------------------------------------------------
# 8. Generam embedding-urile in DB
# ----------------------------------------------------------------------------
log "Pas 8/9: generez embedding-uri in DB (poate dura 2-5 minute)"
run_sql_as_vecuser sql/04_generate_embeddings.sql

# ----------------------------------------------------------------------------
# 9. Raport final
# ----------------------------------------------------------------------------
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
log "Pas 9/9: setup complet"

echo ""
echo "=========================================="
echo "  Setup finalizat in $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo "=========================================="
echo ""
echo "Pasul urmator:  ./scripts/start.sh"
echo "Apoi deschide:  http://localhost:8000/"
echo ""
