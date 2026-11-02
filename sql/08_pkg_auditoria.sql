-- pkg_auditoria: las cuatro auditorías
-- Para compilar requiere el sinónimo RO_CHAR y las tablas de hallazgos en RO_DATA (ver README)

CREATE OR REPLACE PACKAGE pkg_auditoria AUTHID CURRENT_USER AS

    c_limite_multicuenta CONSTANT PLS_INTEGER := 3;

    TYPE t_lista_ips IS TABLE OF VARCHAR2(45);

    e_parametro_invalido EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_parametro_invalido, -20201);

    -- Funciones utilizables desde SQL (1 = si, 0 = no)
    FUNCTION fn_limite_multicuenta RETURN NUMBER;
    FUNCTION fn_calcular_puntos_job (p_job_level IN NUMBER) RETURN NUMBER;
    FUNCTION fn_existe_en_catalogo  (p_nameid IN NUMBER) RETURN NUMBER;
    FUNCTION fn_es_ipv4_valida      (p_ip IN VARCHAR2) RETURN NUMBER;
    FUNCTION fn_cuentas_por_ip      (p_ip IN VARCHAR2) RETURN NUMBER;

    PROCEDURE sp_items_fantasma;
    -- Sin lista: revisa todas las IPs
    PROCEDURE sp_multicuenta (p_ips    IN t_lista_ips DEFAULT NULL,
                              p_limite IN NUMBER      DEFAULT c_limite_multicuenta);
    -- Sin personaje: revisa todos
    PROCEDURE sp_puntos_invalidos (p_char_id IN ro_char.char_id%TYPE DEFAULT NULL);
    PROCEDURE sp_items_gm;

END pkg_auditoria;
/

CREATE OR REPLACE PACKAGE BODY pkg_auditoria AS


    c_lote CONSTANT PLS_INTEGER := 500;

    -- Excepciones de negocio: se registran y la auditoria continua
    e_reporte_reciente EXCEPTION;
    e_ip_invalida      EXCEPTION;
    e_exceso_puntos    EXCEPTION;
    e_items_gm         EXCEPTION;

    TYPE t_fantasma IS RECORD (
        nameid      ro_data.inventory.nameid%TYPE,
        cantidad    ro_data.inventory.amount%TYPE,
        account_id  ro_char.account_id%TYPE,
        char_id     ro_char.char_id%TYPE,
        nombre_char ro_char.name%TYPE,
        reportado   NUMBER                    -- 1 = ya reportado en las ultimas 24 h
    );
    TYPE t_fantasmas IS TABLE OF t_fantasma;

    TYPE t_cuenta IS RECORD (
        account_id ro_data.login.account_id%TYPE,
        usuario    ro_data.login.userid%TYPE,
        ultima_ip  ro_data.login.last_ip%TYPE,
        conexiones ro_data.login.logincount%TYPE
    );
    TYPE t_cuentas IS TABLE OF t_cuenta;
    TYPE t_ids     IS TABLE OF NUMBER;

    TYPE t_personaje IS RECORD (
        char_id        ro_char.char_id%TYPE,
        cuenta         ro_data.login.userid%TYPE,
        personaje      ro_char.name%TYPE,
        job_level      ro_char.job_level%TYPE,
        puntos_legales NUMBER,
        puntos_reales  NUMBER
    );
    TYPE t_personajes IS TABLE OF t_personaje;

    -- Nota: pkg_bitacora se llama directo (sin envoltorio) para que
    -- origen_llamada registre el subprograma real que detecto el error.



    PROCEDURE validar_limite (p_limite IN NUMBER) IS
    BEGIN
        IF p_limite IS NULL OR p_limite < c_limite_multicuenta THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'E_PARAMETRO_INVALIDO',
                p_mensaje => 'p_limite=' || NVL(TO_CHAR(p_limite), 'NULL'),
                p_codigo  => -20201,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            RAISE_APPLICATION_ERROR(-20201,
                'El limite debe ser un numero mayor o igual a ' || c_limite_multicuenta);
        END IF;
    END validar_limite;

    PROCEDURE validar_personaje (p_char_id IN NUMBER) IS
        v_existe NUMBER;
    BEGIN
        IF p_char_id IS NULL THEN
            RETURN;
        END IF;
        SELECT COUNT(*) INTO v_existe FROM ro_char WHERE char_id = p_char_id;
        IF v_existe = 0 THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'E_PARAMETRO_INVALIDO',
                p_mensaje => 'No existe el personaje char_id=' || p_char_id,
                p_codigo  => -20201,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            RAISE_APPLICATION_ERROR(-20201, 'No existe el personaje ' || p_char_id);
        END IF;
    END validar_personaje;

    -- Sin lista: IPs con p_limite cuentas o mas.
    -- Con lista: IPs validas, sin repetir, que alcancen el limite.
    FUNCTION ips_a_auditar (p_ips IN t_lista_ips, p_limite IN NUMBER) RETURN t_lista_ips IS
        v_resultado t_lista_ips := t_lista_ips();
        v_unicas    t_lista_ips;
        i           PLS_INTEGER;
    BEGIN
        IF p_ips IS NULL THEN
            SELECT last_ip BULK COLLECT INTO v_resultado
              FROM ro_data.login
             WHERE last_ip IS NOT NULL
             GROUP BY last_ip
            HAVING COUNT(*) >= p_limite;
            RETURN v_resultado;
        END IF;

        v_unicas := SET(p_ips);
        i := v_unicas.FIRST;
        WHILE i IS NOT NULL LOOP
            BEGIN
                IF fn_es_ipv4_valida(v_unicas(i)) = 0 THEN
                    RAISE e_ip_invalida;
                END IF;
                IF fn_cuentas_por_ip(v_unicas(i)) >= p_limite THEN
                    v_resultado.EXTEND;
                    v_resultado(v_resultado.LAST) := v_unicas(i);
                END IF;
            EXCEPTION
                WHEN e_ip_invalida THEN
                    DBMS_OUTPUT.PUT_LINE('IP omitida por formato invalido: ' || v_unicas(i));
                    ro_data.pkg_bitacora.registrar_excepcion(
                        p_nombre  => 'E_IP_INVALIDA',
                        p_mensaje => 'Formato IPv4 incorrecto: ' || NVL(v_unicas(i), 'NULL'),
                        p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            END;
            i := v_unicas.NEXT(i);
        END LOOP;
        RETURN v_resultado;
    END ips_a_auditar;



    -- SQL no puede leer constantes de paquete; esta funcion la expone
    FUNCTION fn_limite_multicuenta RETURN NUMBER IS
    BEGIN
        RETURN c_limite_multicuenta;
    END fn_limite_multicuenta;

    -- Un punto de skill por nivel de job, sin contar el nivel 1
    FUNCTION fn_calcular_puntos_job (p_job_level IN NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN p_job_level - 1;
    END fn_calcular_puntos_job;

    FUNCTION fn_existe_en_catalogo (p_nameid IN NUMBER) RETURN NUMBER IS
        v_existe NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_existe
          FROM dual
         WHERE EXISTS (SELECT 1 FROM ro_data.item_db_equip  WHERE id = p_nameid)
            OR EXISTS (SELECT 1 FROM ro_data.item_db_etc    WHERE id = p_nameid)
            OR EXISTS (SELECT 1 FROM ro_data.item_db_usable WHERE id = p_nameid);
        RETURN v_existe;
    END fn_existe_en_catalogo;

    FUNCTION fn_es_ipv4_valida (p_ip IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF REGEXP_LIKE(p_ip,
               '^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}'
            || '([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$') THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_es_ipv4_valida;

    FUNCTION fn_cuentas_por_ip (p_ip IN VARCHAR2) RETURN NUMBER IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_total FROM ro_data.login WHERE last_ip = p_ip;
        RETURN v_total;
    END fn_cuentas_por_ip;



    PROCEDURE sp_items_fantasma IS
        -- NOT EXISTS en SQL en vez de fn_existe_en_catalogo: evita un cambio
        -- de contexto SQL -> PL/SQL por cada fila del inventario
        CURSOR cur_fantasmas IS
            SELECT i.nameid, i.amount, c.account_id, c.char_id, c.name,
                   CASE WHEN EXISTS (SELECT 1 FROM reporte_items_fantasma r
                                      WHERE r.char_id = c.char_id
                                        AND r.nameid  = i.nameid
                                        AND r.fecha  >= SYSDATE - 1)
                        THEN 1 ELSE 0 END
              FROM ro_data.inventory i
              JOIN ro_char c ON c.char_id = i.char_id
             WHERE NOT EXISTS (SELECT 1 FROM ro_data.item_db_equip  e WHERE e.id = i.nameid)
               AND NOT EXISTS (SELECT 1 FROM ro_data.item_db_etc    t WHERE t.id = i.nameid)
               AND NOT EXISTS (SELECT 1 FROM ro_data.item_db_usable u WHERE u.id = i.nameid);

        v_lote   t_fantasmas;
        v_nuevos t_fantasmas;
        v_total  PLS_INTEGER := 0;
    BEGIN
        SAVEPOINT sp_inicio;
        OPEN cur_fantasmas;
        LOOP
            FETCH cur_fantasmas BULK COLLECT INTO v_lote LIMIT c_lote;
            EXIT WHEN v_lote.COUNT = 0;

            v_nuevos := t_fantasmas();
            FOR i IN 1 .. v_lote.COUNT LOOP
                BEGIN
                    IF v_lote(i).reportado = 1 THEN
                        RAISE e_reporte_reciente;
                    END IF;
                    v_nuevos.EXTEND;
                    v_nuevos(v_nuevos.LAST) := v_lote(i);
                EXCEPTION
                    WHEN e_reporte_reciente THEN
                        ro_data.pkg_bitacora.registrar_excepcion(
                            p_nombre  => 'E_REPORTE_RECIENTE',
                            p_mensaje => 'char_id=' || v_lote(i).char_id || ', nameid=' || v_lote(i).nameid
                                      || ' ya reportado en las ultimas 24 horas',
                            p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
                END;
            END LOOP;

            FORALL i IN 1 .. v_nuevos.COUNT
                INSERT INTO reporte_items_fantasma (nameid, cantidad, account_id, char_id, nombre_char)
                VALUES (v_nuevos(i).nameid, v_nuevos(i).cantidad, v_nuevos(i).account_id,
                        v_nuevos(i).char_id, v_nuevos(i).nombre_char);
            v_total := v_total + v_nuevos.COUNT;
        END LOOP;
        CLOSE cur_fantasmas;

        DBMS_OUTPUT.PUT_LINE('Items fantasma registrados: ' || v_total);
    EXCEPTION
        WHEN OTHERS THEN
            IF cur_fantasmas%ISOPEN THEN
                CLOSE cur_fantasmas;
            END IF;
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'ERROR_INESPERADO',
                p_mensaje => SQLERRM,
                p_codigo  => SQLCODE,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            ROLLBACK TO sp_inicio;
            RAISE;
    END sp_items_fantasma;

    PROCEDURE sp_multicuenta (p_ips    IN t_lista_ips DEFAULT NULL,
                              p_limite IN NUMBER      DEFAULT c_limite_multicuenta) IS
        v_ips     t_lista_ips;
        v_cuentas t_cuentas;
        v_ids     t_ids;
    BEGIN
        validar_limite(p_limite);
        SAVEPOINT sp_inicio;

        v_ips := ips_a_auditar(p_ips, p_limite);

        SELECT account_id, userid, last_ip, logincount
          BULK COLLECT INTO v_cuentas
          FROM ro_data.login
         WHERE last_ip IN (SELECT COLUMN_VALUE FROM TABLE(v_ips))
         ORDER BY last_ip, account_id;

        FORALL i IN 1 .. v_cuentas.COUNT
            INSERT INTO reporte_multicuenta (account_id, usuario, ultima_ip, conexiones)
            VALUES (v_cuentas(i).account_id, v_cuentas(i).usuario,
                    v_cuentas(i).ultima_ip, v_cuentas(i).conexiones)
            RETURNING reporte_id BULK COLLECT INTO v_ids;

        FORALL i IN 1 .. v_cuentas.COUNT
            INSERT INTO reporte_multicuenta_personaje (reporte_id, nombre, base_level, class)
            SELECT v_ids(i), name, base_level, class
              FROM ro_char
             WHERE account_id = v_cuentas(i).account_id;

        DBMS_OUTPUT.PUT_LINE('IPs con multicuenta: ' || v_ips.COUNT
                             || ', cuentas registradas: ' || v_cuentas.COUNT);
    EXCEPTION
        WHEN e_parametro_invalido THEN
            RAISE;
        WHEN OTHERS THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'ERROR_INESPERADO',
                p_mensaje => SQLERRM,
                p_codigo  => SQLCODE,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            ROLLBACK TO sp_inicio;
            RAISE;
    END sp_multicuenta;

    PROCEDURE sp_puntos_invalidos (p_char_id IN ro_char.char_id%TYPE DEFAULT NULL) IS
        CURSOR cur_novicios IS
            SELECT c.char_id, l.userid, c.name, c.job_level,
                   ro_data.pkg_auditoria.fn_calcular_puntos_job(c.job_level),
                   NVL(c.skill_point, 0)
                   + NVL((SELECT SUM(s.lv)
                            FROM ro_data.skill s
                            JOIN ro_data.skill_db_data sk ON sk.skill_id = s.id
                           WHERE s.char_id = c.char_id), 0)
              FROM ro_char c
              JOIN ro_data.login l ON l.account_id = c.account_id
             WHERE c.class = 0
               AND c.job_level > 0
               AND (p_char_id IS NULL OR c.char_id = p_char_id);

        v_lote      t_personajes;
        v_hallazgos t_personajes;
        v_total     PLS_INTEGER := 0;
    BEGIN
        validar_personaje(p_char_id);
        SAVEPOINT sp_inicio;

        DELETE FROM auditoria_puntos_invalidos
         WHERE p_char_id IS NULL OR char_id = p_char_id;

        OPEN cur_novicios;
        LOOP
            FETCH cur_novicios BULK COLLECT INTO v_lote LIMIT c_lote;
            EXIT WHEN v_lote.COUNT = 0;

            v_hallazgos := t_personajes();
            FOR i IN 1 .. v_lote.COUNT LOOP
                BEGIN
                    IF v_lote(i).puntos_reales > v_lote(i).puntos_legales THEN
                        RAISE e_exceso_puntos;
                    END IF;
                EXCEPTION
                    WHEN e_exceso_puntos THEN
                        v_hallazgos.EXTEND;
                        v_hallazgos(v_hallazgos.LAST) := v_lote(i);
                        ro_data.pkg_bitacora.registrar_excepcion(
                            p_nombre  => 'E_EXCESO_PUNTOS',
                            p_mensaje => 'char_id=' || v_lote(i).char_id
                                      || ', puntos_reales=' || v_lote(i).puntos_reales
                                      || ', puntos_legales=' || v_lote(i).puntos_legales,
                            p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
                END;
            END LOOP;

            FORALL i IN 1 .. v_hallazgos.COUNT
                INSERT INTO auditoria_puntos_invalidos
                       (char_id, cuenta, personaje, job_level, puntos_legales, puntos_reales)
                VALUES (v_hallazgos(i).char_id, v_hallazgos(i).cuenta, v_hallazgos(i).personaje,
                        v_hallazgos(i).job_level, v_hallazgos(i).puntos_legales,
                        v_hallazgos(i).puntos_reales);
            v_total := v_total + v_hallazgos.COUNT;
        END LOOP;
        CLOSE cur_novicios;

        DBMS_OUTPUT.PUT_LINE('Personajes con anomalias: ' || v_total);
    EXCEPTION
        WHEN e_parametro_invalido THEN
            RAISE;
        WHEN OTHERS THEN
            IF cur_novicios%ISOPEN THEN
                CLOSE cur_novicios;
            END IF;
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'ERROR_INESPERADO',
                p_mensaje => SQLERRM,
                p_codigo  => SQLCODE,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            ROLLBACK TO sp_inicio;
            RAISE;
    END sp_puntos_invalidos;

    PROCEDURE sp_items_gm IS
        v_total PLS_INTEGER;
    BEGIN
        SAVEPOINT sp_inicio;
        DELETE FROM auditoria_items_gm;

        -- Cada coincidencia con picklog cuenta, incluso las repetidas
        INSERT INTO auditoria_items_gm (cuenta, personaje, nameid, cantidad)
        SELECT l.userid, c.name, i.nameid, i.amount
          FROM ro_data.inventory i
          JOIN ro_char c         ON c.char_id = i.char_id
          JOIN ro_data.login l   ON l.account_id = c.account_id
          JOIN ro_data.picklog p ON p.char_id = i.char_id AND p.nameid = i.nameid
         WHERE p.type = 'A';                   -- 'A' = creado por un administrador
        v_total := SQL%ROWCOUNT;

        DBMS_OUTPUT.PUT_LINE('Coincidencias registradas: ' || v_total);
        IF v_total > 0 THEN
            RAISE e_items_gm;
        END IF;
    EXCEPTION
        WHEN e_items_gm THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'E_ITEMS_GM',
                p_mensaje => v_total || ' items creados por GM en inventarios (ver auditoria_items_gm)',
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
        WHEN OTHERS THEN
            ro_data.pkg_bitacora.registrar_excepcion(
                p_nombre  => 'ERROR_INESPERADO',
                p_mensaje => SQLERRM,
                p_codigo  => SQLCODE,
                p_usuario => SYS_CONTEXT('USERENV', 'CURRENT_USER'));
            ROLLBACK TO sp_inicio;
            RAISE;
    END sp_items_gm;

END pkg_auditoria;
/
