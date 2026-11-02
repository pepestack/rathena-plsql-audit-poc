-- pkg_permisos: GRANT SELECT y sinónimos públicos (mediante jobs del scheduler)

  CREATE OR REPLACE PACKAGE pkg_permisos AS

    e_tabla_inexistente EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_tabla_inexistente, -20301);

    FUNCTION fn_nombre_sinonimo (p_tabla IN VARCHAR2) RETURN VARCHAR2;

    PROCEDURE sp_publicar_tabla (p_tabla IN VARCHAR2);

    -- Elimina el sinonimo publico de una tabla borrada (el GRANT se va con la tabla)
    PROCEDURE sp_despublicar_tabla (p_tabla IN VARCHAR2);

    PROCEDURE sp_publicar_todas;

    PROCEDURE sp_programar_publicacion    (p_tabla IN VARCHAR2);
    PROCEDURE sp_programar_despublicacion (p_tabla IN VARCHAR2);

END pkg_permisos;
/

CREATE OR REPLACE PACKAGE BODY pkg_permisos AS


    -- Tablas internas: llevan esta marca al inicio de su comentario
    c_marca_privada CONSTANT VARCHAR2(20) := '[PRIVADA]';



    -- No se publican:
    --   tablas de hallazgos (las define pkg_instalacion)
    --   tablas con comentario '[PRIVADA]...' (logs y otras internas)
    FUNCTION es_excluida (p_tabla IN VARCHAR2) RETURN BOOLEAN IS
        v_privada NUMBER;
    BEGIN
        IF p_tabla LIKE 'BIN$%' OR pkg_instalacion.fn_es_tabla_hallazgo(p_tabla) = 1 THEN
            RETURN TRUE;
        END IF;
        SELECT COUNT(*) INTO v_privada
          FROM user_tab_comments
         WHERE table_name = p_tabla
           AND comments LIKE c_marca_privada || '%';
        RETURN v_privada > 0;
    END es_excluida;

    -- Programa un job que ejecuta p_procedimiento(p_tabla) en unos segundos.
    -- Transaccion autonoma: el trigger no puede confirmar, esta si.
    -- Debe terminar con COMMIT o ROLLBACK explicito (si no, ORA-06519 al salir).
    PROCEDURE programar_job (p_procedimiento IN VARCHAR2, p_tabla IN VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        -- Dentro del bloque protegido: si algo falla, el DDL no se interrumpe
        IF es_excluida(p_tabla) THEN
            RETURN;
        END IF;
        DBMS_SCHEDULER.CREATE_JOB(
            job_name   => DBMS_SCHEDULER.GENERATE_JOB_NAME('PERMISOS_'),
            job_type   => 'PLSQL_BLOCK',
            job_action => 'BEGIN ro_data.pkg_permisos.' || p_procedimiento || '('
                       || DBMS_ASSERT.ENQUOTE_LITERAL(p_tabla) || '); END;',
            start_date => SYSTIMESTAMP + INTERVAL '5' SECOND,   -- despues del COMMIT del DDL
            enabled    => TRUE,
            auto_drop  => TRUE,
            comments   => p_procedimiento || ' ' || p_tabla);
        COMMIT;   -- CREATE_JOB no confirma por si solo
    EXCEPTION
        WHEN OTHERS THEN
            -- Sin RAISE: un fallo aqui no debe hacer fallar el CREATE o DROP
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'PROGRAMAR_JOB',
                p_mensaje => p_procedimiento || ' ' || p_tabla || ': ' || SQLERRM,
                p_codigo  => SQLCODE);
            BEGIN
                ROLLBACK;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;   -- ni siquiera el ROLLBACK debe bloquear el DDL
            END;
    END programar_job;



    -- Palabra reservada de Oracle (p. ej. CHAR): el sinonimo lleva prefijo RO_
    FUNCTION fn_nombre_sinonimo (p_tabla IN VARCHAR2) RETURN VARCHAR2 IS
        v_reservada NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_reservada
          FROM v$reserved_words
         WHERE keyword = p_tabla
           AND reserved = 'Y';
        IF v_reservada > 0 THEN
            RETURN 'RO_' || p_tabla;
        END IF;
        RETURN p_tabla;
    END fn_nombre_sinonimo;

    PROCEDURE sp_publicar_tabla (p_tabla IN VARCHAR2) IS
        v_existe NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_existe FROM user_tables WHERE table_name = p_tabla;
        IF v_existe = 0 THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'E_TABLA_INEXISTENTE',
                p_mensaje => 'No existe la tabla ' || p_tabla,
                p_codigo  => -20301);
            RAISE_APPLICATION_ERROR(-20301, 'No existe la tabla RO_DATA.' || p_tabla);
        END IF;

        IF es_excluida(p_tabla) THEN
            DBMS_OUTPUT.PUT_LINE(RPAD(p_tabla, 32) || 'excluida');
            RETURN;
        END IF;

        -- ENQUOTE_NAME: el nombre va como identificador, nunca como SQL libre
        EXECUTE IMMEDIATE 'GRANT SELECT ON '
                       || DBMS_ASSERT.ENQUOTE_NAME(p_tabla, FALSE) || ' TO desarrollador';
        EXECUTE IMMEDIATE 'CREATE OR REPLACE PUBLIC SYNONYM '
                       || DBMS_ASSERT.ENQUOTE_NAME(fn_nombre_sinonimo(p_tabla), FALSE)
                       || ' FOR ro_data.' || DBMS_ASSERT.ENQUOTE_NAME(p_tabla, FALSE);

        DBMS_OUTPUT.PUT_LINE(RPAD(p_tabla, 32) || 'publicada como ' || fn_nombre_sinonimo(p_tabla));
    EXCEPTION
        WHEN e_tabla_inexistente THEN
            RAISE;
        WHEN OTHERS THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'PUBLICAR_TABLA',
                p_mensaje => p_tabla || ': ' || SQLERRM,
                p_codigo  => SQLCODE);
            RAISE;
    END sp_publicar_tabla;

    PROCEDURE sp_despublicar_tabla (p_tabla IN VARCHAR2) IS
        v_sinonimo VARCHAR2(130) := fn_nombre_sinonimo(p_tabla);
        v_existe   NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_existe
          FROM all_synonyms
         WHERE owner = 'PUBLIC'
           AND synonym_name = v_sinonimo
           AND table_owner  = 'RO_DATA'
           AND table_name   = p_tabla;

        IF v_existe > 0 THEN
            EXECUTE IMMEDIATE 'DROP PUBLIC SYNONYM '
                           || DBMS_ASSERT.ENQUOTE_NAME(v_sinonimo, FALSE);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'DESPUBLICAR_TABLA',
                p_mensaje => p_tabla || ': ' || SQLERRM,
                p_codigo  => SQLCODE);
            RAISE;
    END sp_despublicar_tabla;

    PROCEDURE sp_publicar_todas IS
    BEGIN
        FOR r IN (SELECT table_name FROM user_tables ORDER BY table_name) LOOP
            BEGIN
                sp_publicar_tabla(r.table_name);
            EXCEPTION
                WHEN OTHERS THEN
                    -- ya registrado; una tabla con error no detiene las demas
                    DBMS_OUTPUT.PUT_LINE(RPAD(r.table_name, 32) || 'error: ' || SQLERRM);
            END;
        END LOOP;
    END sp_publicar_todas;

    PROCEDURE sp_programar_publicacion (p_tabla IN VARCHAR2) IS
    BEGIN
        programar_job('sp_publicar_tabla', p_tabla);
    END sp_programar_publicacion;

    PROCEDURE sp_programar_despublicacion (p_tabla IN VARCHAR2) IS
    BEGIN
        programar_job('sp_despublicar_tabla', p_tabla);
    END sp_programar_despublicacion;

END pkg_permisos;
/
