#!/usr/bin/env bash
# =============================================================================
# scripts/recover.sh
# Continua setup-ul de la o stare partial-completata.
# Folosit pentru ca PAR-ul Oracle Object Storage cu modelul augmented expira;
# trecem pe Python-side embedding generation cu sentence-transformers (acelasi
# model `all-MiniLM-L12-v2`).
#
# Pasi (toti idempotenti):
#   1. Verifica DB ready prin proba SQL
#   2. Aplica vector_memory_size si restart daca nu e setat
#   3. Re-ruleaza SQL 01, 02 (idempotente)  - SQL 03 si 04 NU mai sunt necesare
#   4. Setup venv + Python deps (include sentence-transformers, ~500 MB)
#   5. Incarca dataset + genereaza embedding-uri in Python + INSERT in posts
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; }

# .env
if [[ -f .env ]]; then set -a; source .env; set +a; fi
ORACLE_PWD="${ORACLE_PWD:-DemoPass123}"
VECUSER_PWD="${VECUSER_PWD:-VecUser123}"
CONTAINER_NAME="${ORACLE_CONTAINER_NAME:-oracle-23ai-demo}"

# ----------------------------------------------------------------------------
# 1. Verifica DB ready (proba SQL)
# ----------------------------------------------------------------------------
log "Pas 1/5: verific DB ready prin proba SQL"
wait_for_db() {
  local max=${1:-180}
  local waited=0
  until docker exec "${CONTAINER_NAME}" bash -c \
        "echo 'SELECT 1 FROM dual;' | sqlplus -s sys/${ORACLE_PWD}@FREEPDB1 as sysdba" \
        2>/dev/null | grep -qE "^\s*1\s*$"; do
    if [[ ${waited} -ge ${max} ]]; then
      err "DB nu raspunde in ${max}s"; return 1
    fi
    sleep 5; waited=$((waited + 5)); echo -n "."
  done
  echo ""
  log "DB ready"
}
wait_for_db 60 || exit 1

# ----------------------------------------------------------------------------
# 2. vector_memory_size + restart conditional
# ----------------------------------------------------------------------------
log "Pas 2/5: verific vector_memory_size"
CURRENT_VMS=$(docker exec -i "${CONTAINER_NAME}" \
  sqlplus -S "sys/${ORACLE_PWD}@FREEPDB1 as sysdba" 2>/dev/null <<'EOF' | tr -d ' \r\n'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT value FROM v$parameter WHERE name = 'vector_memory_size';
EXIT;
EOF
)

if [[ "${CURRENT_VMS}" != "536870912" ]]; then
  log "Setez vector_memory_size = 512M (curent: ${CURRENT_VMS})"
  docker exec -i "${CONTAINER_NAME}" sqlplus -S "sys/${ORACLE_PWD}@FREE as sysdba" <<EOF || warn "ALTER esuat"
ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;
EXIT;
EOF
  log "Restart container pentru a aplica setarea"
  docker compose restart oracle-db
  sleep 10
  wait_for_db 180 || exit 1
else
  log "vector_memory_size deja setat la 512M"
fi

# ----------------------------------------------------------------------------
# 3. SQL 01 + 02 (NU mai e nevoie de 03 si 04 - facem embedding in Python)
# ----------------------------------------------------------------------------
log "Pas 3/5: rulez sql/01_setup_user.sql ca SYS"
docker exec -i "${CONTAINER_NAME}" \
  sqlplus -S "sys/${ORACLE_PWD}@FREEPDB1 as sysdba" < sql/01_setup_user.sql

log "Rulez sql/02_setup_schema.sql ca vecuser"
docker exec -i "${CONTAINER_NAME}" \
  sqlplus -S "vecuser/${VECUSER_PWD}@FREEPDB1" < sql/02_setup_schema.sql

# ----------------------------------------------------------------------------
# 4. venv Python + dependinte (include sentence-transformers, prima rulare ~500 MB)
# ----------------------------------------------------------------------------
log "Pas 4/5: setup Python (venv + deps)"
if [[ ! -d .venv ]]; then
  log "Creez venv .venv"
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip
log "Instalez dependinte (poate dura 1-3 min - sentence-transformers + PyTorch)"
pip install -r ingest/requirements.txt
pip install -r backend/requirements.txt

# ----------------------------------------------------------------------------
# 5. Ingest dataset + embedding generation (in Python, batch_size 32)
# ----------------------------------------------------------------------------
log "Pas 5/5: incarc dataset + generez embeddings (5-8 min total)"
log "Prima rulare descarca modelul all-MiniLM-L12-v2 (~125 MB) din HuggingFace"
ORACLE_USER=vecuser \
ORACLE_PWD_VECUSER="${VECUSER_PWD}" \
ORACLE_DSN="localhost:1521/FREEPDB1" \
python ingest/load_dataset.py

# ----------------------------------------------------------------------------
# Final
# ----------------------------------------------------------------------------
log "Setup finalizat. Porneste backend-ul cu:"
echo ""
echo "    ./scripts/start.sh"
echo ""
echo "Apoi deschide: http://localhost:8000/"
