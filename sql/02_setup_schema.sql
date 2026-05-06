-- =============================================================================
-- 02_setup_schema.sql
-- Creeaza tabela `posts` si indexii necesari pentru ambele tipuri de cautare:
--   - cautare semantica (vectoriala) - coloana `embedding VECTOR(384, FLOAT32)`
--     Embedding-ul e calculat pe `title || ' ' || body` (vezi load_dataset.py).
--   - cautare lexicala (keyword)     - index `CTXSYS.CONTEXT` cu MULTI_COLUMN_DATASTORE
--     peste `title + body` pentru o comparatie SIMETRICA cu cautarea vectoriala.
--
-- Trebuie rulat ca utilizator `vecuser` (NU ca SYS).
-- =============================================================================

ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = vecuser;

-- ----------------------------------------------------------------------------
-- 1. Drop existing (idempotent)
-- ----------------------------------------------------------------------------
DECLARE
  e_table_not_exist EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_table_not_exist, -942);
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE vecuser.posts CASCADE CONSTRAINTS PURGE';
EXCEPTION
  WHEN e_table_not_exist THEN NULL;
END;
/

-- ----------------------------------------------------------------------------
-- 2. Tabela `posts` - schema principala
--    embedding: VECTOR(384, FLOAT32) - dimensiunea modelului ALL_MINILM_L12_V2
-- ----------------------------------------------------------------------------
CREATE TABLE vecuser.posts (
  id        NUMBER PRIMARY KEY,
  title     VARCHAR2(500),
  body      CLOB,
  tags      VARCHAR2(500),
  score     NUMBER,
  embedding VECTOR(384, FLOAT32)
);

-- Comentarii pentru documentare
COMMENT ON TABLE  vecuser.posts            IS 'StackOverflow Q&A posts pentru demo Vector vs Keyword Search';
COMMENT ON COLUMN vecuser.posts.id         IS 'ID unic al post-ului din dataset';
COMMENT ON COLUMN vecuser.posts.title      IS 'Titlul intrebarii';
COMMENT ON COLUMN vecuser.posts.body       IS 'Corpul intrebarii (HTML stripat)';
COMMENT ON COLUMN vecuser.posts.tags       IS 'Tag-uri (ex: java, python, sql)';
COMMENT ON COLUMN vecuser.posts.score      IS 'Scor din StackOverflow (label sau upvotes)';
COMMENT ON COLUMN vecuser.posts.embedding  IS 'Embedding 384-dim generat de ALL_MINILM_L12_V2 in baza de date';

-- ----------------------------------------------------------------------------
-- 3. Preferinte Oracle Text:
--    a) lexer case-insensitive
--    b) MULTI_COLUMN_DATASTORE peste title + body
--    Astfel, indexul lexical va concatena title + body si va indexa ambele,
--    aliniind comparatia cu cautarea vectoriala (care embedaza title + body).
-- ----------------------------------------------------------------------------
BEGIN
  -- Drop preferences daca exista (idempotent)
  BEGIN CTXSYS.CTX_DDL.DROP_PREFERENCE('vecuser.demo_lexer');     EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN CTXSYS.CTX_DDL.DROP_PREFERENCE('vecuser.demo_datastore'); EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Lexer
  CTXSYS.CTX_DDL.CREATE_PREFERENCE('vecuser.demo_lexer', 'BASIC_LEXER');
  CTXSYS.CTX_DDL.SET_ATTRIBUTE('vecuser.demo_lexer', 'mixed_case', 'NO');
  CTXSYS.CTX_DDL.SET_ATTRIBUTE('vecuser.demo_lexer', 'index_themes', 'NO');
  CTXSYS.CTX_DDL.SET_ATTRIBUTE('vecuser.demo_lexer', 'index_text', 'YES');

  -- Datastore: indexeaza title + body ca un singur document virtual
  CTXSYS.CTX_DDL.CREATE_PREFERENCE('vecuser.demo_datastore', 'MULTI_COLUMN_DATASTORE');
  CTXSYS.CTX_DDL.SET_ATTRIBUTE('vecuser.demo_datastore', 'COLUMNS', 'title, body');
END;
/

-- ----------------------------------------------------------------------------
-- 4. Index Oracle Text (CTXSYS.CONTEXT) cu MULTI_COLUMN_DATASTORE
--    Coloana indexata sintactic ramane `body`, dar datastore-ul indexeaza
--    text-ul concatenat din `title + body`. Asadar `CONTAINS(body, :q, 1)`
--    cauta efectiv in title + body.
--    Suporta SCORE(), operatori NEAR, AND, OR, fuzzy, etc.
-- ----------------------------------------------------------------------------
CREATE INDEX vecuser.idx_posts_text
  ON vecuser.posts(body)
  INDEXTYPE IS CTXSYS.CONTEXT
  PARAMETERS ('
    DATASTORE vecuser.demo_datastore
    LEXER     vecuser.demo_lexer
    SYNC (ON COMMIT)
  ');

-- ----------------------------------------------------------------------------
-- 5. NOTA: NU cream index HNSW peste embedding.
--    Pentru ~5000 randuri, cautarea exacta (full scan + ORDER BY VECTOR_DISTANCE)
--    este suficient de rapida si elimina edge cases ale HNSW in timpul demo-ului.
--    Pentru dataset-uri mari, se va adauga ulterior:
--      CREATE VECTOR INDEX idx_posts_emb ON posts(embedding)
--        ORGANIZATION INMEMORY NEIGHBOR GRAPH
--        DISTANCE COSINE WITH TARGET ACCURACY 95;
-- ----------------------------------------------------------------------------

SELECT 'Schema creata cu succes' AS status FROM dual;

EXIT;
