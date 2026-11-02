-- Triggers DDL: publican y despublican automáticamente las tablas de RO_DATA

CREATE OR REPLACE TRIGGER trg_publicar_tablas
    AFTER CREATE ON SCHEMA
BEGIN
    IF ORA_DICT_OBJ_TYPE = 'TABLE' AND ORA_DICT_OBJ_OWNER = 'RO_DATA' THEN
        pkg_permisos.sp_programar_publicacion(ORA_DICT_OBJ_NAME);
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_despublicar_tablas
    AFTER DROP ON SCHEMA
BEGIN
    IF ORA_DICT_OBJ_TYPE = 'TABLE' AND ORA_DICT_OBJ_OWNER = 'RO_DATA' THEN
        pkg_permisos.sp_programar_despublicacion(ORA_DICT_OBJ_NAME);
    END IF;
END;
/
