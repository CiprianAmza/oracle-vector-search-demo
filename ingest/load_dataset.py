"""
load_dataset.py
================
Incarca un sample de ~5000 de intrebari StackOverflow in tabela `posts` din
Oracle 23ai. Foloseste dataset-ul HuggingFace `pacovaldez/stackoverflow-questions`.

Pasi:
  1. Descarca dataset-ul (cache local in ~/.cache/huggingface)
  2. Filtreaza dupa label (0 sau 1 = scor mai bun) daca exista
  3. Selecteaza primele 5000 de inregistrari relevante
  4. Strip HTML din body cu BeautifulSoup
  5. Extrage tag-urile (daca exista) si scor
  6. Genereaza embedding-uri cu `sentence-transformers/all-MiniLM-L12-v2`
     (fallback fata de DBMS_VECTOR.LOAD_ONNX_MODEL - PAR-ul Oracle a expirat)
  7. Conecteaza la Oracle (thin mode) si face batch INSERT cu executemany
     - inclusiv coloana `embedding VECTOR(384)` pasata ca lista de float32

Modelul folosit este IDENTIC cu cel pe care Oracle 23ai l-ar fi rulat in DB
(`all-MiniLM-L12-v2`, 384 dim). Calculele se fac local, in proces Python.

Usage:
    python ingest/load_dataset.py
    python ingest/load_dataset.py --limit 5000 --batch 200
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from typing import Iterable

import array
import numpy as np
import oracledb  # type: ignore[import-untyped]
from bs4 import BeautifulSoup
from datasets import load_dataset  # type: ignore[import-untyped]
from sentence_transformers import SentenceTransformer  # type: ignore[import-untyped]
from tqdm import tqdm

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass


# -----------------------------------------------------------------------------
# Configurare logging cu timestamp (cerinta: "Observable: log every major step")
# -----------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("ingest")


# -----------------------------------------------------------------------------
# Configurare conexiune Oracle (thin mode = nu necesita Instant Client)
# -----------------------------------------------------------------------------
ORACLE_USER = os.getenv("ORACLE_USER", "vecuser")
ORACLE_PWD = os.getenv("ORACLE_PWD_VECUSER", "VecUser123")
ORACLE_DSN = os.getenv("ORACLE_DSN", "localhost:1521/FREEPDB1")

DATASET_NAME = "pacovaldez/stackoverflow-questions"
DATASET_SPLIT = "train"
EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L12-v2"


def strip_html(text: str | None) -> str:
    """Curata HTML din body-ul intrebarii (StackOverflow stocheaza HTML brut)."""
    if not text:
        return ""
    try:
        soup = BeautifulSoup(text, "lxml")
    except Exception:
        soup = BeautifulSoup(text, "html.parser")
    cleaned = soup.get_text(separator=" ", strip=True)
    return cleaned[:8000]


def truncate(text: str | None, n: int) -> str | None:
    if text is None:
        return None
    return text[:n]


def iter_records(limit: int) -> Iterable[dict]:
    """Genereaza inregistrari curate gata de inserat in tabela `posts`."""
    log.info("Descarc dataset-ul HuggingFace: %s (%s)", DATASET_NAME, DATASET_SPLIT)
    ds = load_dataset(DATASET_NAME, split=DATASET_SPLIT)
    log.info("Dataset incarcat: %d randuri totale, coloane: %s", len(ds), ds.column_names)

    has_label = "label" in ds.column_names
    if has_label:
        log.info("Filtrez dupa label IN (0, 1) - intrebari de calitate ridicata")
        ds = ds.filter(lambda x: x.get("label") in (0, 1))
        log.info("Dupa filtrare: %d randuri", len(ds))

    count = 0
    for idx, row in enumerate(ds):
        if count >= limit:
            break
        title = row.get("title") or row.get("question_title") or ""
        body_raw = row.get("body") or row.get("question_body") or row.get("text") or ""
        tags = row.get("tags") or row.get("question_tags") or ""
        score = row.get("score") or row.get("label") or 0

        title = title.strip()
        body = strip_html(body_raw)

        if not title or len(body) < 20:
            continue

        if isinstance(tags, list):
            tags = " ".join(str(t) for t in tags)
        tags = (tags or "")[:500]

        try:
            score_int = int(score) if score is not None else 0
        except (TypeError, ValueError):
            score_int = 0

        yield {
            "id": idx + 1,
            "title": truncate(title, 500),
            "body": body,
            "tags": tags,
            "score": score_int,
        }
        count += 1


def insert_batch(
    conn: "oracledb.Connection",
    batch: list[dict],
    embeddings: np.ndarray,
) -> int:
    """
    Insert batch cu `executemany` - inclusiv embedding-uri ca VECTOR(384, FLOAT32).

    python-oracledb accepta VECTOR ca:
      - array.array('f', [...])  pentru FLOAT32
      - lista de floats Python (mai lent)
    Folosim array.array pentru performanta.
    """
    if not batch:
        return 0
    assert len(batch) == embeddings.shape[0]

    sql = """
        INSERT INTO posts (id, title, body, tags, score, embedding)
        VALUES (:id, :title, :body, :tags, :score, :embedding)
    """
    cur = conn.cursor()
    cur.setinputsizes(
        id=oracledb.NUMBER,
        title=oracledb.STRING,
        body=oracledb.DB_TYPE_CLOB,
        tags=oracledb.STRING,
        score=oracledb.NUMBER,
        # python-oracledb auto-detecteaza VECTOR din array.array sau list
    )

    rows = []
    for rec, emb in zip(batch, embeddings):
        rows.append({
            **rec,
            "embedding": array.array("f", emb.astype(np.float32).tolist()),
        })
    cur.executemany(sql, rows)
    conn.commit()
    return cur.rowcount


def truncate_table(conn: "oracledb.Connection") -> None:
    log.info("TRUNCATE posts (curatare inainte de incarcare)")
    cur = conn.cursor()
    cur.execute("TRUNCATE TABLE posts")
    conn.commit()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=5000, help="Numar maxim de inregistrari")
    parser.add_argument("--batch", type=int, default=200, help="Dimensiune batch INSERT")
    parser.add_argument("--no-truncate", action="store_true", help="Nu sterge datele existente")
    args = parser.parse_args()

    # ------------------------------------------------------------------------
    # 1. Incarca modelul de embedding (download din HuggingFace la prima rulare)
    # ------------------------------------------------------------------------
    log.info("Incarc modelul de embedding: %s", EMBEDDING_MODEL)
    log.info("(prima rulare: ~125 MB descarcare in ~/.cache/huggingface/)")
    model = SentenceTransformer(EMBEDDING_MODEL)
    log.info("Model incarcat. Dim embedding: %d", model.get_sentence_embedding_dimension())

    # ------------------------------------------------------------------------
    # 2. Conexiune Oracle
    # ------------------------------------------------------------------------
    log.info("Conectare la Oracle: %s@%s", ORACLE_USER, ORACLE_DSN)
    try:
        conn = oracledb.connect(user=ORACLE_USER, password=ORACLE_PWD, dsn=ORACLE_DSN)
    except oracledb.DatabaseError as exc:
        log.error("Conexiune esuata: %s", exc)
        log.error("Verifica ca Oracle DB ruleaza: docker compose ps")
        return 1
    log.info("Conexiune OK. Versiune DB: %s", conn.version)

    if not args.no_truncate:
        truncate_table(conn)

    # ------------------------------------------------------------------------
    # 3. Iterare + embed + insert
    # ------------------------------------------------------------------------
    t0 = time.time()
    inserted = 0
    batch: list[dict] = []
    progress = tqdm(total=args.limit, unit="rows", desc="Embed+Insert")

    def flush_batch() -> int:
        if not batch:
            return 0
        # Concatenam title + body (trunchiat) ca input pentru embedding,
        # similar cu ce face VECTOR_EMBEDDING(... USING title || ' ' || body)
        texts = [f"{r['title']} {r['body'][:2000]}" for r in batch]
        embs = model.encode(
            texts,
            batch_size=32,
            show_progress_bar=False,
            convert_to_numpy=True,
            normalize_embeddings=True,  # echivalent cu Oracle's L2 norm post-processing
        )
        n = insert_batch(conn, batch, embs)
        progress.update(n)
        batch.clear()
        return n

    for record in iter_records(args.limit):
        batch.append(record)
        if len(batch) >= args.batch:
            n = flush_batch()
            inserted += n
            if inserted % 500 < args.batch:
                log.info("Progres: %d randuri inserate (%.1f rec/s)",
                         inserted, inserted / max(time.time() - t0, 0.001))

    # Flush ultimul batch
    inserted += flush_batch()
    progress.close()

    elapsed = time.time() - t0
    log.info("Incarcare completa: %d randuri in %.1fs (%.1f rec/s)",
             inserted, elapsed, inserted / max(elapsed, 0.001))

    # Verificari finale (NU folosim COUNT(embedding) - VECTOR nu suporta agregari)
    cur = conn.cursor()
    cur.execute("""
        SELECT COUNT(*),
               COUNT(CASE WHEN embedding IS NOT NULL THEN 1 END)
          FROM posts
    """)
    total, with_emb = cur.fetchone()
    log.info("Total randuri: %d  (cu embedding: %d)", total, with_emb)

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
