#!/usr/bin/env bash
# =============================================================================
# download_model.sh
# Descarca modelul ONNX `all_MiniLM_L12_v2` din Object Storage-ul public Oracle
# si il dezarhiveaza in directorul `models/`, gata sa fie incarcat in DB prin
# `DBMS_VECTOR.LOAD_ONNX_MODEL` (vezi sql/03_load_onnx_model.sql).
#
# Sursa oficiala: blog post Oracle "Now Available! Pre-built Embedding
# Generation model for Oracle Database 23ai" (2024).
#
# Daca URL-ul de mai jos nu mai functioneaza, cauta versiunea curenta pe:
#   https://blogs.oracle.com/database/post/pre-built-embedding-generation-model
# sau in documentatia Oracle 23ai:
#   https://docs.oracle.com/en/database/oracle/oracle-database/23/vecse/
# =============================================================================

set -euo pipefail

# Calculeaza calea catre directorul `models` relativ la pozitia scriptului
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="${SCRIPT_DIR}/../models"
mkdir -p "${MODEL_DIR}"

# URL-ul Oracle public Object Storage (verificat la momentul scrierii proiectului)
# Modelul este zip-uit si contine: all_MiniLM_L12_v2.onnx + LICENSE + README
MODEL_URL="https://adwc4pm.objectstorage.us-ashburn-1.oci.customer-oci.com/p/VBRD9P8ZFWkKvnfhrWxkpPe8K03-JIoM5h_8EJyJcpE80c108fuUjg7R5L5O7mMZ/n/adwc4pm/b/OML-Resources/o/all_MiniLM_L12_v2_augmented.zip"
ZIP_FILE="${MODEL_DIR}/all_MiniLM_L12_v2_augmented.zip"
ONNX_FILE="${MODEL_DIR}/all_MiniLM_L12_v2.onnx"

echo "[$(date +%H:%M:%S)] Pornesc descarcarea modelului ONNX..."

# Skip daca modelul exista deja (idempotenta)
if [[ -f "${ONNX_FILE}" ]]; then
  echo "[$(date +%H:%M:%S)] Modelul exista deja: ${ONNX_FILE}"
  echo "                     Sterge fisierul daca vrei sa-l re-descarci."
  exit 0
fi

# Descarcare cu curl. -L urmeaza redirect-uri, -f failure on HTTP errors.
if command -v curl >/dev/null 2>&1; then
  curl -fL --progress-bar -o "${ZIP_FILE}" "${MODEL_URL}"
elif command -v wget >/dev/null 2>&1; then
  wget --show-progress -O "${ZIP_FILE}" "${MODEL_URL}"
else
  echo "EROARE: nu am gasit nici curl, nici wget. Instaleaza unul dintre ele."
  exit 1
fi

echo "[$(date +%H:%M:%S)] Descarcare completa. Dezarhivez..."

# Dezarhivare
if command -v unzip >/dev/null 2>&1; then
  unzip -o "${ZIP_FILE}" -d "${MODEL_DIR}"
else
  echo "EROARE: unzip nu este instalat. Instaleaza-l: brew install unzip (macOS)"
  exit 1
fi

# Verifica ca avem fisierul .onnx
if [[ ! -f "${ONNX_FILE}" ]]; then
  echo "EROARE: nu am gasit ${ONNX_FILE} dupa dezarhivare."
  echo "Continutul directorului models/:"
  ls -la "${MODEL_DIR}"
  exit 1
fi

# Curatam zip-ul pentru a economisi spatiu
rm -f "${ZIP_FILE}"

# Dimensiune fisier final (informativ)
SIZE=$(du -h "${ONNX_FILE}" | cut -f1)
echo "[$(date +%H:%M:%S)] Gata. Modelul ocupa ${SIZE} la: ${ONNX_FILE}"
echo ""
echo "Acum poti rula:  sql/03_load_onnx_model.sql"
