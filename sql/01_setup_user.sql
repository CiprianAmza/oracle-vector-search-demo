-- =============================================================================
-- 01_setup_user.sql
-- Creeaza utilizatorul aplicativ `vecuser`, un tablespace dedicat (`demo_data`)
-- cu Automatic Segment Space Management (ASSM) si privilegiile necesare.
--
-- Trebuie rulat ca SYS (sau un alt utilizator privilegiat) pe PDB-ul FREEPDB1.
--
-- IMPORTANT: tipul `VECTOR` din Oracle 23ai necesita tablespace cu ASSM. Default-ul
-- PDB-ului FREEPDB1 (`SYSTEM`) este Manual SSM, deci `CREATE TABLE ... VECTOR(...)`
-- esueaza cu ORA-43853. Cream tablespace-ul `demo_data` cu ASSM si il atasam ca
-- default pentru vecuser.
-- =============================================================================

-- Asiguram ca operam in PDB-ul aplicativ (nu in CDB$ROOT)
ALTER SESSION SET CONTAINER = FREEPDB1;

SET SERVEROUTPUT ON

-- ----------------------------------------------------------------------------
-- 1. Drop user existent (idempotent)
-- ----------------------------------------------------------------------------
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM dba_users WHERE username = 'VECUSER';
  IF v_count > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Drop user vecuser existent');
    EXECUTE IMMEDIATE 'DROP USER vecuser CASCADE';
  END IF;
END;
/

-- ----------------------------------------------------------------------------
-- 2. Creeaza tablespace-ul `demo_data` cu ASSM (idempotent)
--    Folosim path standard din imaginea Oracle Free: /opt/oracle/oradata/FREE/FREEPDB1/
-- ----------------------------------------------------------------------------
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM dba_tablespaces WHERE tablespace_name = 'DEMO_DATA';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE q'[
      CREATE TABLESPACE demo_data
        DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/demo_data01.dbf'
        SIZE 256M AUTOEXTEND ON NEXT 64M MAXSIZE 2G
        EXTENT MANAGEMENT LOCAL
        SEGMENT SPACE MANAGEMENT AUTO
    ]';
    DBMS_OUTPUT.PUT_LINE('Tablespace demo_data creat cu ASSM');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Tablespace demo_data exista deja');
  END IF;
END;
/

-- ----------------------------------------------------------------------------
-- 3. Creeaza utilizatorul aplicativ cu default tablespace = demo_data
-- ----------------------------------------------------------------------------
CREATE USER vecuser IDENTIFIED BY VecUser123
  DEFAULT TABLESPACE demo_data
  QUOTA UNLIMITED ON demo_data;

-- ----------------------------------------------------------------------------
-- 4. Roluri si privilegii
--    DB_DEVELOPER_ROLE: rol nou in 23ai care contine privilegiile uzuale de
--    dezvoltator (CREATE TABLE, CREATE PROCEDURE, etc).
-- ----------------------------------------------------------------------------
GRANT DB_DEVELOPER_ROLE TO vecuser;
GRANT CREATE SESSION TO vecuser;
GRANT RESOURCE TO vecuser;
GRANT CREATE MINING MODEL TO vecuser;
-- Necesar pentru indexul Oracle Text (CTXSYS.CONTEXT)
GRANT EXECUTE ON CTXSYS.CTX_DDL TO vecuser;
GRANT CTXAPP TO vecuser;
GRANT EXECUTE ON DBMS_VECTOR TO vecuser;

-- ----------------------------------------------------------------------------
-- 5. Confirmare
-- ----------------------------------------------------------------------------
SELECT 'Utilizatorul vecuser creat. Default tablespace: ' || default_tablespace AS status
  FROM dba_users WHERE username = 'VECUSER';

EXIT;
