-- pkg_bitacora: registra en ambas bitácoras (transacciones autónomas, ACCESSIBLE BY)

CREATE OR REPLACE PACKAGE pkg_bitacora
    ACCESSIBLE BY (PACKAGE pkg_explorador, PACKAGE pkg_auditoria, PACKAGE pkg_instalacion, PACKAGE pkg_permisos)
AS

    PROCEDURE registrar (
        p_herramienta IN VARCHAR2,
        p_parametros  IN VARCHAR2,
        p_resultado   IN VARCHAR2,
        p_mensaje     IN VARCHAR2 DEFAULT NULL,
        p_usuario     IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE registrar_excepcion (
        p_nombre  IN VARCHAR2,
        p_mensaje IN VARCHAR2 DEFAULT NULL,
        p_codigo  IN NUMBER   DEFAULT NULL,
        p_usuario IN VARCHAR2 DEFAULT NULL
    );
END pkg_bitacora;
/

CREATE OR REPLACE PACKAGE BODY pkg_bitacora AS

    TYPE t_contexto IS RECORD (
        usuario_sesion        VARCHAR2(128),
        usuario_so            VARCHAR2(128),
        equipo                VARCHAR2(256),
        ip                    VARCHAR2(64),
        modulo                VARCHAR2(64),
        accion                VARCHAR2(64),
        identificador_cliente VARCHAR2(64),
        sid                   NUMBER
    );

    FUNCTION ctx (p_atributo IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN SYS_CONTEXT('USERENV', p_atributo);
    END ctx;

    FUNCTION capturar_contexto RETURN t_contexto IS
        v_ctx t_contexto;
    BEGIN
        v_ctx.usuario_sesion        := ctx('SESSION_USER');
        v_ctx.usuario_so            := ctx('OS_USER');
        v_ctx.equipo                := ctx('HOST');
        v_ctx.ip                    := ctx('IP_ADDRESS');
        v_ctx.modulo                := ctx('MODULE');
        v_ctx.accion                := ctx('ACTION');
        v_ctx.identificador_cliente := ctx('CLIENT_IDENTIFIER');
        v_ctx.sid                   := TO_NUMBER(ctx('SID'));
        RETURN v_ctx;
    END capturar_contexto;


    FUNCTION origen_llamada RETURN VARCHAR2 IS
    BEGIN
        IF UTL_CALL_STACK.DYNAMIC_DEPTH >= 3 THEN
            RETURN SUBSTR(UTL_CALL_STACK.CONCATENATE_SUBPROGRAM(
                              UTL_CALL_STACK.SUBPROGRAM(3)), 1, 261);
        END IF;
        RETURN 'BLOQUE ANONIMO';
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END origen_llamada;

    PROCEDURE registrar (
        p_herramienta IN VARCHAR2,
        p_parametros  IN VARCHAR2,
        p_resultado   IN VARCHAR2,
        p_mensaje     IN VARCHAR2 DEFAULT NULL,
        p_usuario     IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;   -- el registro persiste aunque el llamador haga ROLLBACK
        -- Las funciones privadas no pueden usarse dentro de SQL,
        -- asi que el contexto se arma en PL/SQL y luego se inserta.
        v_ctx t_contexto := capturar_contexto;
    BEGIN
        INSERT INTO log_explorador (
            herramienta, parametros, resultado, mensaje,
            usuario_sesion, usuario_bd, usuario_so, equipo, ip, modulo, accion,
            identificador_cliente, sid
        ) VALUES (
            SUBSTR(p_herramienta, 1, 50), SUBSTR(p_parametros, 1, 2000),
            p_resultado, SUBSTR(p_mensaje, 1, 2000),
            v_ctx.usuario_sesion,
            SUBSTR(NVL(p_usuario, v_ctx.usuario_sesion), 1, 128),
            v_ctx.usuario_so, v_ctx.equipo, v_ctx.ip, v_ctx.modulo, v_ctx.accion,
            v_ctx.identificador_cliente, v_ctx.sid
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;   -- un fallo de bitacora nunca debe romper la consulta del usuario

            DBMS_OUTPUT.PUT_LINE('pkg_bitacora.registrar fallo: ' || SQLERRM);
    END registrar;

    PROCEDURE registrar_excepcion (
        p_nombre  IN VARCHAR2,
        p_mensaje IN VARCHAR2 DEFAULT NULL,
        p_codigo  IN NUMBER   DEFAULT NULL,
        p_usuario IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;   -- el error queda registrado aunque la auditoria haga ROLLBACK
        v_ctx    t_contexto     := capturar_contexto;
        v_origen VARCHAR2(261)  := origen_llamada;
        -- La traza solo existe mientras se maneja un error; en excepciones
        -- de negocio levantadas con RAISE apunta a la linea del RAISE.
        v_traza  VARCHAR2(4000) := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
    BEGIN
        INSERT INTO exception_log (
            ex_name, ex_message, ex_code, origen, traza,
            db_user, usuario_bd, usuario_so, equipo, ip, modulo, accion,
            identificador_cliente, sid
        ) VALUES (
            SUBSTR(NVL(p_nombre, 'SIN_NOMBRE'), 1, 100), SUBSTR(p_mensaje, 1, 500),
            p_codigo, v_origen, v_traza,
            NVL(v_ctx.usuario_sesion, USER),
            SUBSTR(NVL(p_usuario, v_ctx.usuario_sesion), 1, 128),
            v_ctx.usuario_so, v_ctx.equipo, v_ctx.ip, v_ctx.modulo, v_ctx.accion,
            v_ctx.identificador_cliente, v_ctx.sid
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;   -- registrar un error nunca debe generar otro error
            DBMS_OUTPUT.PUT_LINE('pkg_bitacora.registrar_excepcion fallo: ' || SQLERRM);
    END registrar_excepcion;

END pkg_bitacora;
/
