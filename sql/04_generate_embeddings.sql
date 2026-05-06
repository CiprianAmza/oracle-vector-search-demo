-- =============================================================================
-- 04_generate_embeddings.sql
-- Genereaza embeddings pentru toate post-urile incarcate in tabela `posts`.
--
-- Rulat ca `vecuser` DUPA:
--   1. tabela `posts` este creata (02_setup_schema.sql)
--   2. modelul ONNX este incarcat (03_load_onnx_model.sql)
--   3. datele sunt populate (ingest/load_dataset.py)
--
-- *** PUNCT-CHEIE AL DEMO-ULUI ***
-- Aici, embedding-urile sunt generate INTERN in Oracle 23ai prin SQL.
-- Aplicatia Python NU calculeaza vectori - tot procesul ruleaza in baza de date.
-- Acesta este unul dintre marile avantaje Oracle 23ai ca platforma AI integrata.
--
-- Timp estimat pentru 5000 randuri: ~2-5 minute (depinde de hardware).
-- =============================================================================

ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = vecuser;

-- ----------------------------------------------------------------------------
-- Cronometrare: pornim un timer
-- ----------------------------------------------------------------------------
SET TIMING ON
SET SERVEROUTPUT ON

DECLARE
  v_start  TIMESTAMP;
  v_end    TIMESTAMP;
  v_total  NUMBER;
  v_done   NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_total FROM vecuser.posts WHERE embedding IS NULL;
  DBMS_OUTPUT.PUT_LINE('Posts care necesita embedding: ' || v_total);

  v_start := SYSTIMESTAMP;

  -- ------------------------------------------------------------------------
  -- Generam embedding pentru fiecare post folosind concatenarea title+body.
  -- Limitam body-ul la 2000 caractere pentru a evita probleme cu input-ul
  -- modelului (max ~512 tokens). Modelul taie automat textul daca depaseste.
  -- ------------------------------------------------------------------------
  UPDATE vecuser.posts
     SET embedding = VECTOR_EMBEDDING(
       ALL_MINILM_L12_V2 USING (title || ' ' || DBMS_LOB.SUBSTR(body, 2000, 1)) AS data
     )
   WHERE embedding IS NULL;

  v_done := SQL%ROWCOUNT;
  COMMIT;

  v_end := SYSTIMESTAMP;
  DBMS_OUTPUT.PUT_LINE('Embeddings generate: ' || v_done);
  DBMS_OUTPUT.PUT_LINE('Durata totala: ' ||
    EXTRACT(SECOND FROM (v_end - v_start)) + 60*EXTRACT(MINUTE FROM (v_end - v_start)) ||
    ' secunde');
END;
/

-- ----------------------------------------------------------------------------
-- Verificare: numara embeddings valide
-- ----------------------------------------------------------------------------
SELECT
  COUNT(*)                                  AS total_posts,
  COUNT(embedding)                          AS posts_with_embedding,
  COUNT(*) - COUNT(embedding)               AS posts_missing
FROM vecuser.posts;

-- ----------------------------------------------------------------------------
-- Sanity check: dimensiunea unui embedding random
-- ----------------------------------------------------------------------------
SELECT
  id,
  VECTOR_DIMENSION_COUNT(embedding) AS dim,
  SUBSTR(title, 1, 60) AS title_preview
FROM vecuser.posts
WHERE embedding IS NOT NULL
  AND ROWNUM <= 3;

EXIT;
