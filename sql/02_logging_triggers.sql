-- Triggers de solo inserción para las tablas de bitácora

--  Como TRUNCATE es DDL, no funcionaria aqui.
--  ALTER TRIGGER trg_log_explorador_inmutable DISABLE para deshabilitar

CREATE OR REPLACE TRIGGER trg_log_explorador_inmutable
    BEFORE UPDATE OR DELETE ON log_explorador
BEGIN
    RAISE_APPLICATION_ERROR(-20001,
        'log_explorador es de solo insercion: no se permite UPDATE ni DELETE.');
END;
/

CREATE OR REPLACE TRIGGER trg_exception_log_inmutable
    BEFORE UPDATE OR DELETE ON exception_log
    FOR EACH ROW
BEGIN
    RAISE_APPLICATION_ERROR(-20002,
        'exception_log es de solo insercion: se intento '
        || CASE WHEN UPDATING THEN 'modificar' ELSE 'eliminar' END
        || ' el registro ex_id=' || :OLD.ex_id || '.');
END;
/
