-- pkg_instalacion: crea las tablas de hallazgos en el esquema del llamador

CREATE OR REPLACE PACKAGE pkg_instalacion AUTHID CURRENT_USER AS


    e_sin_privilegio EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_sin_privilegio, -20101);

    e_nombre_ocupado EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_nombre_ocupado, -20102);



    PROCEDURE sp_crear_tablas;

    -- Cantidad de tablas de hallazgos que faltan en el esquema del llamador
    -- (0 = instalacion completa). Utilizable desde SQL.
    FUNCTION fn_tablas_faltantes RETURN NUMBER;

    FUNCTION fn_es_tabla_hallazgo (p_tabla IN VARCHAR2) RETURN NUMBER;

END pkg_instalacion;
/

CREATE OR REPLACE PACKAGE BODY pkg_instalacion AS


    TYPE t_definicion IS RECORD (
        nombre VARCHAR2(128),
        ddl    VARCHAR2(4000)
    );
    TYPE t_definiciones IS TABLE OF t_definicion;

    -- ORA-00955: el nombre ya lo usa otro objeto del esquema.
    -- Excepcion privada: solo se usa para traducirla a e_nombre_ocupado.
    e_ora_nombre_usado EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_ora_nombre_usado, -955);



    -- Lista de tablas en orden de creacion: las tablas padre antes que las
    -- hijas (reporte_multicuenta antes que reporte_multicuenta_personaje).
    FUNCTION definiciones RETURN t_definiciones IS
    BEGIN
        RETURN t_definiciones(
            t_definicion(
                nombre => 'REPORTE_ITEMS_FANTASMA',
                ddl    => 'CREATE TABLE reporte_items_fantasma ('
                       || '  audit_id    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,'
                       || '  nameid      NUMBER NOT NULL,'
                       || '  cantidad    NUMBER NOT NULL,'
                       || '  account_id  NUMBER NOT NULL,'
                       || '  char_id     NUMBER,'
                       || '  nombre_char VARCHAR2(50),'
                       || '  fecha       DATE DEFAULT SYSDATE)'),
            t_definicion(
                nombre => 'REPORTE_MULTICUENTA',
                ddl    => 'CREATE TABLE reporte_multicuenta ('
                       || '  reporte_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,'
                       || '  account_id NUMBER NOT NULL,'
                       || '  usuario    VARCHAR2(50) NOT NULL,'
                       || '  ultima_ip  VARCHAR2(45) NOT NULL,'
                       || '  conexiones NUMBER,'
                       || '  fecha      DATE DEFAULT SYSDATE NOT NULL)'),
            t_definicion(
                nombre => 'REPORTE_MULTICUENTA_PERSONAJE',
                ddl    => 'CREATE TABLE reporte_multicuenta_personaje ('
                       || '  personaje_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,'
                       || '  reporte_id   NUMBER NOT NULL,'
                       || '  nombre       VARCHAR2(50) NOT NULL,'
                       || '  base_level   NUMBER,'
                       || '  class        NUMBER,'
                       || '  CONSTRAINT fk_reporte_personaje'
                       || '    FOREIGN KEY (reporte_id) REFERENCES reporte_multicuenta (reporte_id))'),
            t_definicion(
                nombre => 'AUDITORIA_PUNTOS_INVALIDOS',
                ddl    => 'CREATE TABLE auditoria_puntos_invalidos ('
                       || '  auditoria_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,'
                       || '  char_id        NUMBER NOT NULL,'
                       || '  cuenta         VARCHAR2(23) NOT NULL,'   -- login.userid
                       || '  personaje      VARCHAR2(30) NOT NULL,'   -- char.name
                       || '  job_level      NUMBER,'
                       || '  puntos_legales NUMBER,'
                       || '  puntos_reales  NUMBER,'
                       || '  fecha          DATE DEFAULT SYSDATE NOT NULL)'),
            t_definicion(
                nombre => 'AUDITORIA_ITEMS_GM',
                ddl    => 'CREATE TABLE auditoria_items_gm ('
                       || '  auditoria_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,'
                       || '  cuenta       VARCHAR2(23) NOT NULL,'     -- login.userid
                       || '  personaje    VARCHAR2(30) NOT NULL,'     -- char.name
                       || '  nameid       NUMBER NOT NULL,'
                       || '  cantidad     NUMBER,'
                       || '  fecha        DATE DEFAULT SYSDATE NOT NULL)')
        );
    END definiciones;

    -- Con AUTHID CURRENT_USER, USER_TABLES muestra las tablas del llamador
    FUNCTION existe_tabla (p_nombre IN VARCHAR2) RETURN BOOLEAN IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM user_tables WHERE table_name = p_nombre;
        RETURN v_total > 0;
    END existe_tabla;

    -- Verifica que el llamador pueda crear tablas antes de empezar.
    -- En codigo con derechos del invocador los roles estan habilitados,
    -- por lo que SESSION_PRIVS incluye lo otorgado por el rol desarrollador.
    PROCEDURE verificar_privilegio IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total
          FROM session_privs
         WHERE privilege IN ('CREATE TABLE', 'CREATE ANY TABLE');

        IF v_total = 0 THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'E_SIN_PRIVILEGIO',
                p_mensaje => 'Falta CREATE TABLE para ' || SYS_CONTEXT('USERENV', 'CURRENT_USER'),
                p_codigo  => -20101,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            RAISE_APPLICATION_ERROR(-20101,
                'Falta el privilegio CREATE TABLE en el esquema '
                || SYS_CONTEXT('USERENV', 'CURRENT_USER'));
        END IF;
    END verificar_privilegio;

    -- Crea una tabla si no existe con SQL dinamico
    -- Como el DLL hace commit por si solo, se usa pragma para aislar el procedimiento
    -- y no interferir con otras transacciones

    PROCEDURE crear_tabla (p_nombre IN VARCHAR2, p_ddl IN VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        IF existe_tabla(p_nombre) THEN
            DBMS_OUTPUT.PUT_LINE(RPAD(p_nombre, 32) || 'ya existe');
        ELSE
            EXECUTE IMMEDIATE p_ddl;
            DBMS_OUTPUT.PUT_LINE(RPAD(p_nombre, 32) || 'creada');
        END IF;
    EXCEPTION
        -- existe_tabla solo revisa tablas; si hay una vista o sinonimo con
        -- el mismo nombre, el CREATE falla
        WHEN e_ora_nombre_usado THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'E_NOMBRE_OCUPADO',
                p_mensaje => p_nombre || ' ya lo usa otro objeto del esquema',
                p_codigo  => SQLCODE,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            RAISE_APPLICATION_ERROR(-20102,
                'El nombre ' || p_nombre || ' ya lo usa otro objeto (vista, sinonimo...)',
                TRUE);   -- TRUE conserva el ORA-00955 original en la pila
        WHEN OTHERS THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'CREAR_TABLA',
                p_mensaje => 'No se pudo crear ' || p_nombre || ': ' || SQLERRM,
                p_codigo  => SQLCODE,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            RAISE;   -- las tablas siguientes pueden depender de esta
    END crear_tabla;



    PROCEDURE sp_crear_tablas IS
        v_defs t_definiciones := definiciones;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('Instalando en el esquema '
                             || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
        verificar_privilegio;
        FOR i IN 1 .. v_defs.COUNT LOOP
            crear_tabla(v_defs(i).nombre, v_defs(i).ddl);
        END LOOP;
    END sp_crear_tablas;

    FUNCTION fn_tablas_faltantes RETURN NUMBER IS
        v_defs      t_definiciones := definiciones;
        v_faltantes NUMBER := 0;
    BEGIN
        FOR i IN 1 .. v_defs.COUNT LOOP
            IF NOT existe_tabla(v_defs(i).nombre) THEN
                v_faltantes := v_faltantes + 1;
            END IF;
        END LOOP;
        RETURN v_faltantes;
    END fn_tablas_faltantes;

    FUNCTION fn_es_tabla_hallazgo (p_tabla IN VARCHAR2) RETURN NUMBER IS
       v_defs t_definiciones := definiciones;
    BEGIN
       FOR i IN 1 .. v_defs.COUNT LOOP
           IF v_defs(i).nombre = UPPER(p_tabla) THEN
               RETURN 1;
           END IF;
       END LOOP;
       RETURN 0;
    END fn_es_tabla_hallazgo;

END pkg_instalacion;
/
