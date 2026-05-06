-- =============================================================================
-- 03_load_onnx_model.sql
-- Incarca modelul ONNX `all_MiniLM_L12_v2` ca obiect MINING MODEL in baza de date.
--
-- DUPA acest pas, putem genera embeddings direct prin SQL:
--   SELECT VECTOR_EMBEDDING(ALL_MINILM_L12_V2 USING 'text' AS data) FROM dual;
--
-- Modelul (~125 MB) trebuie deja descarcat in ./models/ - vezi
-- `ingest/download_model.sh`.
--
-- IMPORTANT: scriptul porneste ca SYS (creeaza DIRECTORY si acorda grants),
-- apoi reconecteaza ca `vecuser` pentru a incarca modelul in schema corecta.
-- Acesta este motivul pentru care script-ul are CONNECT in mijloc.
-- =============================================================================

ALTER SESSION SET CONTAINER = FREEPDB1;

-- ----------------------------------------------------------------------------
-- 1. (ca SYS) Creeaza directory care pointeaza catre /opt/oracle/models
--    Acest path este montat din host (./models) prin docker-compose.yml
-- ----------------------------------------------------------------------------
CREATE OR REPLACE DIRECTORY MODEL_DIR AS '/opt/oracle/models';
GRANT READ, WRITE ON DIRECTORY MODEL_DIR TO vecuser;
GRANT EXECUTE ON DBMS_VECTOR TO vecuser;

-- ----------------------------------------------------------------------------
-- 2. Reconectam ca vecuser pentru a incarca modelul in schema acestuia.
--    DBMS_VECTOR.LOAD_ONNX_MODEL creeaza modelul in schema utilizatorului
--    care apeleaza, deci ne asiguram ca rulam ca vecuser.
-- ----------------------------------------------------------------------------
CONNECT vecuser/VecUser123@FREEPDB1

-- ----------------------------------------------------------------------------
-- 3. Drop modelul daca exista deja (idempotent)
-- ----------------------------------------------------------------------------
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM user_mining_models
  WHERE model_name = 'ALL_MINILM_L12_V2';

  IF v_count > 0 THEN
    DBMS_VECTOR.DROP_ONNX_MODEL(model_name => 'ALL_MINILM_L12_V2', force => TRUE);
  END IF;
END;
/

-- ----------------------------------------------------------------------------
-- 4. Incarca modelul ONNX
--    Numele fisierului trebuie sa corespunda cu cel descarcat in ./models/
-- ----------------------------------------------------------------------------
BEGIN
  DBMS_VECTOR.LOAD_ONNX_MODEL(
    directory  => 'MODEL_DIR',
    file_name  => 'all_MiniLM_L12_v2.onnx',
    model_name => 'ALL_MINILM_L12_V2',
    metadata   => JSON('{
      "function" : "embedding",
      "embeddingOutput" : "embedding",
      "input": {"input": ["DATA"]}
    }')
  );
END;
/

-- ----------------------------------------------------------------------------
-- 5. Verificare: dimensiunea unui embedding random (asteptam 384)
-- ----------------------------------------------------------------------------
SELECT
  'Model incarcat. Dim embedding pentru "hello world": ' ||
  TO_CHAR(VECTOR_DIMENSION_COUNT(
    VECTOR_EMBEDDING(ALL_MINILM_L12_V2 USING 'hello world' AS data)
  )) AS status
FROM dual;

-- ----------------------------------------------------------------------------
-- 6. Lista modele instalate in schema vecuser
-- ----------------------------------------------------------------------------
SELECT model_name, mining_function, algorithm
FROM user_mining_models
WHERE model_name = 'ALL_MINILM_L12_V2';

EXIT;
