"""
backend/main.py
================
FastAPI app pentru demo "Vector Search vs Keyword Search" pe Oracle Database 23ai.

Doua endpoint-uri principale:
  GET /api/search/vector?q=<query>&limit=5    -> cautare semantica (cosinus)
  GET /api/search/keyword?q=<query>&limit=5   -> cautare lexicala (Oracle Text)

Embedding-urile pentru query sunt generate cu modelul `all-MiniLM-L12-v2`
incarcat in proces Python (sentence-transformers). Acelasi model este folosit
si la ingest, garantand consistenta vector→vector.

Note despre arhitectura:
- Oracle 23ai *suporta* generarea embedding-urilor IN baza de date prin
  `DBMS_VECTOR.LOAD_ONNX_MODEL` + `VECTOR_EMBEDDING(...)`. Aceasta este abordarea
  ideala arhitectural si o demonstram in scripturile SQL drept exemplu.
- In aceasta implementare folosim Python-side embedding pentru ca PAR-ul Oracle
  Object Storage cu modelul augmented (`all_MiniLM_L12_v2_augmented.zip`)
  expira periodic si nu putem garanta disponibilitatea la momentul prezentarii.
- Calculele vector_distance, ordering si retrieval se fac TOATE in Oracle 23ai
  - asadar partea critica (cautarea vectoriala in DB) este pastrata.

Pornire:
    uvicorn backend.main:app --port 8000 --reload

Sau via script:
    ./scripts/start.sh
"""

from __future__ import annotations

import array
import logging
import os
import re
import time
from contextlib import asynccontextmanager
from typing import Any

import numpy as np
import oracledb  # type: ignore[import-untyped]
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from sentence_transformers import SentenceTransformer  # type: ignore[import-untyped]

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass


# -----------------------------------------------------------------------------
# Configurare logging
# -----------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("backend")


# -----------------------------------------------------------------------------
# Configurare conexiune Oracle (thin mode)
# -----------------------------------------------------------------------------
ORACLE_USER = os.getenv("ORACLE_USER", "vecuser")
ORACLE_PWD = os.getenv("ORACLE_PWD_VECUSER", "VecUser123")
ORACLE_DSN = os.getenv("ORACLE_DSN", "localhost:1521/FREEPDB1")
POOL_MIN = int(os.getenv("ORACLE_POOL_MIN", "1"))
POOL_MAX = int(os.getenv("ORACLE_POOL_MAX", "4"))

POOL: oracledb.ConnectionPool | None = None
EMBED_MODEL: SentenceTransformer | None = None
EMBEDDING_MODEL_NAME = "sentence-transformers/all-MiniLM-L12-v2"


# -----------------------------------------------------------------------------
# Lifespan: cream pool-ul + incarcam modelul la startup
# -----------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global POOL, EMBED_MODEL

    log.info("Incarc modelul de embedding: %s", EMBEDDING_MODEL_NAME)
    EMBED_MODEL = SentenceTransformer(EMBEDDING_MODEL_NAME)
    log.info("Model OK. Dim: %d", EMBED_MODEL.get_sentence_embedding_dimension())

    log.info("Initializez pool Oracle (%s@%s, min=%d, max=%d)",
             ORACLE_USER, ORACLE_DSN, POOL_MIN, POOL_MAX)
    POOL = oracledb.create_pool(
        user=ORACLE_USER,
        password=ORACLE_PWD,
        dsn=ORACLE_DSN,
        min=POOL_MIN,
        max=POOL_MAX,
        increment=1,
    )
    try:
        with POOL.acquire() as conn:
            cur = conn.cursor()
            cur.execute("""
                SELECT COUNT(*),
                       COUNT(CASE WHEN embedding IS NOT NULL THEN 1 END)
                  FROM posts
            """)
            total, with_emb = cur.fetchone()
            log.info("Conectat la Oracle. Posts: %d (cu embedding: %d)", total, with_emb)
    except Exception as exc:
        log.warning("Smoke test esuat: %s. Verifica ca DB e populata.", exc)

    yield

    if POOL:
        log.info("Inchid pool-ul Oracle")
        POOL.close()


app = FastAPI(
    title="Oracle Vector vs Keyword Search Demo",
    description="Tema 10 - Comparatie cautare semantica vs lexicala pe Oracle 23ai",
    version="1.0.0",
    lifespan=lifespan,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def _read_clob(val: Any) -> str:
    """python-oracledb returneaza CLOB-uri ca obiecte LOB - .read() explicit."""
    if val is None:
        return ""
    if hasattr(val, "read"):
        try:
            return val.read()
        except Exception:
            return ""
    return str(val)


def _embed_query(text: str) -> "array.array":
    """Genereaza embedding pentru query si il converteste in array.array('f') -
    formatul acceptat direct de python-oracledb pentru bind VECTOR(384, FLOAT32)."""
    assert EMBED_MODEL is not None, "Model not loaded"
    vec: np.ndarray = EMBED_MODEL.encode(
        text, normalize_embeddings=True, convert_to_numpy=True
    )
    return array.array("f", vec.astype(np.float32).tolist())


# Sanitize input pentru Oracle Text CONTAINS()
_OT_FORBIDDEN = re.compile(r"[\{\}\[\]&|,!\(\)\-=\$%\*\?<>\"'\\:;@\#~^`]")


def _sanitize_for_text(q: str) -> str:
    if not q:
        return ""
    cleaned = _OT_FORBIDDEN.sub(" ", q)
    tokens = [tok for tok in cleaned.split() if len(tok) >= 2]
    if not tokens:
        return ""
    return " ".join(tokens)


# -----------------------------------------------------------------------------
# SQL-urile principale (definite o singura data, refolosite la search + explain)
# -----------------------------------------------------------------------------
SQL_VECTOR = """
    SELECT id, title,
           DBMS_LOB.SUBSTR(body, 300, 1) AS body_preview,
           tags,
           VECTOR_DISTANCE(embedding, :emb, COSINE) AS distance
      FROM posts
     WHERE embedding IS NOT NULL
     ORDER BY distance
     FETCH FIRST :lim ROWS ONLY
"""

SQL_KEYWORD = """
    SELECT id, title,
           DBMS_LOB.SUBSTR(body, 300, 1) AS body_preview,
           tags,
           SCORE(1) AS score_text
      FROM posts
     WHERE CONTAINS(body, :q, 1) > 0
     ORDER BY SCORE(1) DESC
     FETCH FIRST :lim ROWS ONLY
"""


# -----------------------------------------------------------------------------
# Endpoint: cautare vectoriala
# -----------------------------------------------------------------------------
@app.get("/api/search/vector")
def search_vector(
    q: str = Query(..., min_length=1),
    limit: int = Query(5, ge=1, le=50),
) -> list[dict]:
    """
    Cautare vectoriala (semantica) folosind cosine distance.
    Embedding-ul query-ului este generat in Python si pasat ca bind parameter.
    """
    if POOL is None:
        raise HTTPException(status_code=503, detail="Pool DB nu este initializat")

    t0 = time.time()
    query_embedding = _embed_query(q)
    embed_ms = (time.time() - t0) * 1000

    t1 = time.time()
    try:
        with POOL.acquire() as conn:
            cur = conn.cursor()
            cur.execute(SQL_VECTOR, emb=query_embedding, lim=limit)
            cols = [d[0].lower() for d in cur.description]
            rows = cur.fetchall()
            results = []
            for row in rows:
                rec = dict(zip(cols, row))
                rec["body_preview"] = _read_clob(row[2])
                if rec.get("distance") is not None:
                    rec["distance"] = round(float(rec["distance"]), 4)
                    rec["similarity"] = round(max(0.0, 1.0 - rec["distance"]), 4)
                results.append(rec)
    except oracledb.DatabaseError as exc:
        log.error("Eroare DB la cautare vectoriala: %s", exc)
        raise HTTPException(status_code=500, detail=f"Eroare DB: {exc}")

    db_ms = (time.time() - t1) * 1000
    log.info("VECTOR  q=%r  embed=%.0fms  db=%.0fms  results=%d",
             q, embed_ms, db_ms, len(results))
    return results


# -----------------------------------------------------------------------------
# Endpoint: cautare keyword (Oracle Text)
# -----------------------------------------------------------------------------
@app.get("/api/search/keyword")
def search_keyword(
    q: str = Query(..., min_length=1),
    limit: int = Query(5, ge=1, le=50),
) -> list[dict]:
    if POOL is None:
        raise HTTPException(status_code=503, detail="Pool DB nu este initializat")

    cleaned_q = _sanitize_for_text(q)
    if not cleaned_q:
        return []

    t0 = time.time()
    try:
        with POOL.acquire() as conn:
            cur = conn.cursor()
            cur.execute(SQL_KEYWORD, q=cleaned_q, lim=limit)
            cols = [d[0].lower() for d in cur.description]
            rows = cur.fetchall()
            results = []
            for row in rows:
                rec = dict(zip(cols, row))
                rec["body_preview"] = _read_clob(row[2])
                if rec.get("score_text") is not None:
                    rec["score_text"] = round(float(rec["score_text"]), 2)
                results.append(rec)
    except oracledb.DatabaseError as exc:
        log.error("Eroare DB la cautare keyword: %s", exc)
        raise HTTPException(status_code=500, detail=f"Eroare DB: {exc}")

    log.info("KEYWORD q=%r (cleaned=%r)  results=%d  time=%.0fms",
             q, cleaned_q, len(results), (time.time() - t0) * 1000)
    return results


def _get_explain_plan(conn, sql: str, **bind_params) -> str:
    """
    Returneaza planul de executie Oracle pentru o instructiune SQL data.

    Foloseste EXPLAIN PLAN + DBMS_XPLAN.DISPLAY (cu format BASIC + PREDICATE
    + COST). Bind variables sunt acceptate dar nu influenteaza planul, doar
    permit ca SQL-ul sa fie sintactic valid.

    Format-ul de output este textul ASCII tipic Oracle:
      ----------------------------------------
      | Id | Operation                | Name |
      ----------------------------------------
      | 0  | SELECT STATEMENT         |      |
      | 1  |  COUNT STOPKEY           |      |
      ...
    """
    cur = conn.cursor()

    # 1. Generam un statement_id unic pentru a izola planul nostru
    stmt_id = f"demo_{int(time.time() * 1000)}"

    # 2. EXPLAIN PLAN ... FOR <SQL>
    explain_sql = f"EXPLAIN PLAN SET STATEMENT_ID = :sid FOR {sql}"
    bind_params["sid"] = stmt_id
    cur.execute(explain_sql, bind_params)

    # 3. DBMS_XPLAN.DISPLAY pentru formatare ASCII
    cur.execute("""
        SELECT plan_table_output
          FROM TABLE(DBMS_XPLAN.DISPLAY(
            table_name   => 'PLAN_TABLE',
            statement_id => :sid,
            format       => 'BASIC +PREDICATE +COST +ROWS +BYTES'
          ))
    """, sid=stmt_id)
    rows = cur.fetchall()

    # Curatam planul pentru a evita stoarcare in plan_table
    cur.execute("DELETE FROM plan_table WHERE statement_id = :sid", sid=stmt_id)
    conn.commit()

    return "\n".join(r[0] for r in rows if r[0] is not None)


# -----------------------------------------------------------------------------
# Endpoint: /api/explain
# Returneaza planul de executie Oracle pentru ambele queries (vector + keyword).
# Util pentru a arata academic CUM executa Oracle cele doua tipuri de cautare:
#   - Vector: TABLE ACCESS FULL + SORT ORDER BY VECTOR_DISTANCE + COUNT STOPKEY
#   - Keyword: DOMAIN INDEX (CTXSYS.CONTEXT) + SORT ORDER BY SCORE + COUNT STOPKEY
# -----------------------------------------------------------------------------
@app.get("/api/explain")
def explain(
    q: str = Query(..., min_length=1, description="Query-ul pentru care se genereaza planurile"),
    limit: int = Query(5, ge=1, le=50),
) -> dict:
    if POOL is None:
        raise HTTPException(status_code=503, detail="Pool DB nu este initializat")

    # Generam embedding-ul ca sa pasam un bind valid (planul NU depinde de valoare,
    # dar bind-ul trebuie sa fie de tip VECTOR ca sa fie valid sintactic)
    query_embedding = _embed_query(q)
    cleaned_q = _sanitize_for_text(q) or q

    try:
        with POOL.acquire() as conn:
            vector_plan = _get_explain_plan(
                conn, SQL_VECTOR, emb=query_embedding, lim=limit
            )
            keyword_plan = _get_explain_plan(
                conn, SQL_KEYWORD, q=cleaned_q, lim=limit
            )
    except oracledb.DatabaseError as exc:
        log.error("Eroare la EXPLAIN PLAN: %s", exc)
        raise HTTPException(status_code=500, detail=f"Eroare DB: {exc}")

    log.info("EXPLAIN q=%r  vector=%d lines  keyword=%d lines",
             q, len(vector_plan.splitlines()), len(keyword_plan.splitlines()))

    return {
        "query": q,
        "vector_plan": vector_plan,
        "keyword_plan": keyword_plan,
        "vector_sql": SQL_VECTOR.strip(),
        "keyword_sql": SQL_KEYWORD.strip(),
    }


# -----------------------------------------------------------------------------
# Status
# -----------------------------------------------------------------------------
@app.get("/api/status")
def status() -> dict:
    if POOL is None:
        return {"ok": False, "reason": "pool not initialized"}
    try:
        with POOL.acquire() as conn:
            cur = conn.cursor()
            cur.execute("""
                SELECT COUNT(*),
                       COUNT(CASE WHEN embedding IS NOT NULL THEN 1 END)
                  FROM posts
            """)
            total, with_emb = cur.fetchone()
        return {
            "ok": True,
            "posts_total": total,
            "posts_with_embedding": with_emb,
            "model_loaded": EMBED_MODEL is not None,
            "embedding_model": EMBEDDING_MODEL_NAME,
        }
    except Exception as exc:
        return {"ok": False, "reason": str(exc)}


# -----------------------------------------------------------------------------
# Frontend static
# -----------------------------------------------------------------------------
_FRONTEND_DIR = os.path.join(os.path.dirname(__file__), "..", "frontend")
_FRONTEND_DIR = os.path.abspath(_FRONTEND_DIR)

if os.path.isdir(_FRONTEND_DIR):
    @app.get("/")
    def serve_index():
        return FileResponse(os.path.join(_FRONTEND_DIR, "index.html"))

    app.mount("/static", StaticFiles(directory=_FRONTEND_DIR), name="static")
