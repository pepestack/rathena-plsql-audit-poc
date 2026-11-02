-- 00_admin_setup.sql: configuración de referencia (ejecutar como ADMIN en Autonomous Database)

-- Esquema dueño de los datos y los objetos
CREATE USER ro_data IDENTIFIED BY "&ro_data_pwd" DEFAULT TABLESPACE data QUOTA UNLIMITED ON data;

-- RESOURCE aporta CREATE TABLE, CREATE PROCEDURE y CREATE TRIGGER
GRANT RESOURCE TO ro_data;

GRANT CREATE SESSION,
      CREATE JOB,                -- jobs de DBMS_SCHEDULER lanzados para pkg_permisos
      CREATE PUBLIC SYNONYM,
      DROP PUBLIC SYNONYM
   TO ro_data;


GRANT SELECT ON sys.v_$reserved_words TO ro_data;   
GRANT EXECUTE ON DBMS_CLOUD_AI_AGENT TO ro_data;   

-- Rol de los desarrolladores. El SELECT sobre las tablas lo otorga pkg_permisos
-- y el EXECUTE sobre los paquetes, 09_grants.sql
CREATE ROLE desarrollador;
GRANT CREATE SESSION,
      CREATE TABLE,             
      CREATE SEQUENCE,
      CREATE SYNONYM,
      CREATE VIEW,
      CREATE TRIGGER
   TO desarrollador;
GRANT EXECUTE ON DBMS_CLOUD_AI_AGENT TO desarrollador;

-- Usuarios desarrolladores
CREATE USER pepe   IDENTIFIED BY "&pepe_pwd"   DEFAULT TABLESPACE data QUOTA UNLIMITED ON data;
CREATE USER seba   IDENTIFIED BY "&seba_pwd"   DEFAULT TABLESPACE data QUOTA UNLIMITED ON data;
GRANT desarrollador TO pepe, seba;

-- Los datos del juego no están en el repositorio: deberían ser cargados en RO_DATA
-- y publicarlos con EXEC ro_data.pkg_permisos.sp_publicar_todas;
