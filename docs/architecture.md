# Arhitectura solutiei

Acest document descrie arhitectura tehnica a demo-ului **Vector Search vs Keyword Search** pe Oracle Database 23ai.

## Diagrama componenta

```mermaid
flowchart LR
    subgraph Browser["Browser (Chrome / Safari)"]
      UI["index.html<br/>vanilla JS"]
    end

    subgraph App["Backend (Python 3.10+)"]
      API["FastAPI<br/>/api/search/vector<br/>/api/search/keyword"]
      POOL["python-oracledb<br/>connection pool<br/>(thin mode)"]
      API --> POOL
    end

    subgraph DB["Oracle Database 23ai (Docker, ARM64)"]
      direction TB
      POSTS[("posts<br/>id, title, body, tags, score,<br/>embedding VECTOR(384))")]
      TEXT[("idx_posts_text<br/>CTXSYS.CONTEXT")]
      MODEL[["ALL_MINILM_L12_V2<br/>ONNX mining model<br/>(125 MB, 384 dim)"]]
      VEC["VECTOR_EMBEDDING()<br/>VECTOR_DISTANCE() COSINE"]
      CTX["CONTAINS()<br/>SCORE()"]
      MODEL -.uses.-> VEC
      VEC --> POSTS
      CTX --> TEXT
      TEXT --> POSTS
    end

    UI -- "GET ?q=..." --> API
    POOL -- "SELECT ... VECTOR_EMBEDDING(:q)<br/>ORDER BY VECTOR_DISTANCE" --> VEC
    POOL -- "SELECT ... CONTAINS(body,:q,1)<br/>ORDER BY SCORE(1)" --> CTX
```

## Flux de date la incarcare (one-time)

```mermaid
sequenceDiagram
    participant User
    participant SetupScript as scripts/setup.sh
    participant HF as HuggingFace
    participant Oracle as Oracle 23ai
    participant Model as Object Storage Oracle

    User->>SetupScript: ./scripts/setup.sh
    SetupScript->>Oracle: docker compose up + wait ready
    SetupScript->>Model: download all_MiniLM_L12_v2.onnx
    Model-->>SetupScript: ~125 MB
    SetupScript->>Oracle: 01_setup_user.sql (CREATE USER vecuser)
    SetupScript->>Oracle: 02_setup_schema.sql (CREATE TABLE posts + idx_posts_text)
    SetupScript->>Oracle: 03_load_onnx_model.sql (DBMS_VECTOR.LOAD_ONNX_MODEL)
    SetupScript->>HF: load_dataset("pacovaldez/stackoverflow-questions")
    HF-->>SetupScript: 5000 sampled records
    SetupScript->>Oracle: INSERT INTO posts (executemany batch)
    SetupScript->>Oracle: 04_generate_embeddings.sql<br/>(UPDATE SET embedding = VECTOR_EMBEDDING(...))
    Oracle->>Oracle: ruleaza modelul ONNX intern<br/>(NU iese din DB)
    Oracle-->>User: ready
```

## Flux la runtime (per query)

```mermaid
sequenceDiagram
    participant Browser
    participant FastAPI
    participant Oracle

    Browser->>FastAPI: GET /api/search/vector?q="how to make code faster"
    FastAPI->>Oracle: SELECT ... VECTOR_DISTANCE(<br/>  embedding,<br/>  VECTOR_EMBEDDING(MODEL USING :q),<br/>  COSINE) ORDER BY ...
    Oracle->>Oracle: 1. embedding query (in-DB)
    Oracle->>Oracle: 2. compute cosine distance pentru toate randurile (5000)
    Oracle->>Oracle: 3. sort + top 5
    Oracle-->>FastAPI: rezultate (id, title, body, distance)
    FastAPI-->>Browser: JSON

    par Same query, parallel
        Browser->>FastAPI: GET /api/search/keyword?q="how to make code faster"
        FastAPI->>FastAPI: sanitize q (strip operators)
        FastAPI->>Oracle: SELECT ... CONTAINS(body, :q, 1) > 0<br/>ORDER BY SCORE(1) DESC
        Oracle->>Oracle: index lookup CTXSYS.CONTEXT
        Oracle-->>FastAPI: rezultate (id, title, body, score)
        FastAPI-->>Browser: JSON
    end
```

## De ce aceasta arhitectura?

### Embedding-uri **in baza de date**, nu in Python

Modelul ONNX `all_MiniLM_L12_v2` este incarcat in Oracle 23ai prin
`DBMS_VECTOR.LOAD_ONNX_MODEL`. Toate operatiile de tip embedding (atat la
incarcare cat si la query) ruleaza prin SQL:

```sql
VECTOR_EMBEDDING(ALL_MINILM_L12_V2 USING 'text' AS data)
```

Avantaje:
- **Consistenta**: acelasi model pentru indexare si query (nu poate aparea
  drift intre versiunea Python si versiunea DB).
- **Performanta**: nu trebuie sa transferam vectori de 384 floats prin retea
  pentru fiecare query. Totul ramane local in DB.
- **Simplitate operationala**: backend-ul Python nu are dependinte
  ML (PyTorch / Transformers / ONNX runtime). Foarte usor de deployat.
- **Demonstrabil**: arata ca Oracle 23ai este o platforma AI integrata, nu
  doar un store de vectori.

### Cautare exacta vs index HNSW

Pentru **5000 randuri**, cautarea exacta (full scan + `ORDER BY VECTOR_DISTANCE`)
ruleaza in <100 ms. Avantaje:
- 100% recall (precizie).
- Zero edge cases legate de index (fara `vector_memory` overflow, fara
  rebuild costisitor).
- Mai rapid de demonstrat - presentation-friendly.

Pentru dataset-uri >100K randuri, ar fi necesar un index HNSW:
```sql
CREATE VECTOR INDEX idx_posts_emb ON posts(embedding)
  ORGANIZATION INMEMORY NEIGHBOR GRAPH
  DISTANCE COSINE
  WITH TARGET ACCURACY 95;
```

### Oracle Text ca baseline keyword

Multi consideram "keyword search" = `LIKE '%cuvant%'`. Acest demo foloseste
`CTXSYS.CONTEXT` - indexul invertit profesional al Oracle - cu:

- **Lexer** care normalizeaza case si stemming
- **SCORE(1)** care returneaza un scor TF-IDF-like
- Operatori avansati: `NEAR`, `ACCUM`, fuzzy match (nefolositi explicit aici,
  dar disponibili)

Acesta este o comparatie corecta academic: o solutie "traditional NLP" matura
contra unei solutii "neural embeddings".

## Caracteristici operationale

| Component | Specificatie |
|-----------|--------------|
| DB image | `container-registry.oracle.com/database/free:latest-lite` |
| Platforma | linux/arm64/v8 (native Apple Silicon) |
| `vector_memory_size` | 512 MB |
| Pool conexiuni | min=1, max=4 |
| Backend port | 8000 (FastAPI) |
| DB port | 1521 |
| Model ONNX | 125 MB (descarcat o singura data) |
| Dataset | ~5000 randuri din StackOverflow |
| Timp setup | ~10-15 minute |
| Timp embed bulk | ~2-5 minute pentru 5000 randuri |
| Latenta query vector | ~50-100 ms |
| Latenta query keyword | ~10-30 ms |
