-- =============================================================================
-- patch_keyword_index.sql
-- Patch one-shot: schimba indexul Oracle Text de la single-column (`body`) la
-- MULTI_COLUMN_DATASTORE (`title + body`), pentru o comparatie simetrica cu
-- cautarea vectoriala (care embedaza title + body).
--
-- NU sterge date. NU schimba schema tabelei. Doar dropueaza indexul vechi si
-- re-creeaza unul nou cu datastore-ul potrivit.
--
-- Rulare:
--   docker exec -i oracle-23ai-demo \
--     sqlplus -S "vecuser/VecUser123@FREEPDB1" < sql/patch_keyword_index.sql
-- =============================================================================

ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = vecuser;

-- ----------------------------------------------------------------------------
-- 1. Drop indexul vechi (single-column)
-- ----------------------------------------------------------------------------
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM user_indexes WHERE index_name = 'IDX_POSTS_TEXT';
  IF v_count > 0 THEN
    EXECUTE IMMEDIATE 'DROP INDEX vecuser.idx_posts_text';
  END IF;
END;
/

-- ----------------------------------------------------------------------------
-- 2. (Re-)creeaza preferinte: lexer + multi_column_datastore
-- ----------------------------------------------------------------------------
BEGIN
  BEGIN CTXSYS.CTX_DDL.DROP_PREFERENCE('vecuser.demo_lexer');     EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN CTXSYS.CTX_DDL.DROP_PREFERENCE('vecuser.demo_datastore'); EXCEPTION WHEN OTHERS THEN NULL; END;

  CTXSYS.CTX_DDL.CREATE_PREFERENCE('vecuser.demo_lexer', 'BASIC_LEXER');
  CTXSYS.CTX_DDL.SET_ATTRIBUTE('vecuser.demo_lexer', 'mixed_case', 'NO');
  CTXSYS.CTX_DDL.SET_ATTRIBUTE('vecuser.demo_lexer', 'index_themes', 'NO');
  CTXSYS.CTX_DDL.SET_ATTRIBUTE('vecuser.demo_lexer', 'index_text', 'YES');

  CTXSYS.CTX_DDL.CREATE_PREFERENCE('vecuser.demo_datastore', 'MULTI_COLUMN_DATASTORE');
  CTXSYS.CTX_DDL.SET_ATTRIBUTE('vecuser.demo_datastore', 'COLUMNS', 'title, body');
END;
/

-- ----------------------------------------------------------------------------
-- 3. Creeaza indexul nou cu MULTI_COLUMN_DATASTORE
--    Indexarea reala a celor 5000 randuri dureaza ~30-90 sec.
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
-- 4. Verificare
-- ----------------------------------------------------------------------------
SELECT 'Index recreat. Token-uri din title care acum sunt vizibile:' AS info FROM dual;

SELECT COUNT(*) AS posts_with_token_concurrentmodificationexception
  FROM vecuser.posts
 WHERE CONTAINS(body, 'ConcurrentModificationException', 1) > 0;

EXIT;
