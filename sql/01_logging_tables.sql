-- Tablas de bitácora: log_explorador y exception_log

CREATE TABLE IF NOT EXISTS log_explorador (
    log_id                NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    herramienta           VARCHAR2(50)   NOT NULL,
    parametros            VARCHAR2(4000),
    resultado             VARCHAR2(10)   NOT NULL,   -- OK / ERROR
    mensaje               VARCHAR2(4000),
    usuario_bd            VARCHAR2(128),             -- usuario real (CURRENT_USER del llamador)
    usuario_sesion        VARCHAR2(128),             -- SESSION_USER (por MCP: C##CLOUD$SERVICE)
    usuario_so            VARCHAR2(128),
    equipo                VARCHAR2(256),
    ip                    VARCHAR2(64),
    modulo                VARCHAR2(64),
    accion                VARCHAR2(64),              -- por MCP: nombre de la herramienta
    identificador_cliente VARCHAR2(64),
    sid                   NUMBER,
    fecha                 TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS exception_log (
    ex_id                 NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ex_name               VARCHAR2(100)  NOT NULL,
    ex_message            VARCHAR2(500),
    ex_code               NUMBER,                    -- SQLCODE (NULL en excepciones de negocio)
    origen                VARCHAR2(261),             -- PAQUETE.SUBPROGRAMA que la registro
    traza                 VARCHAR2(4000),
    ex_timestamp          TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    db_user               VARCHAR2(128)  NOT NULL,
    usuario_so            VARCHAR2(128),
    equipo                VARCHAR2(256),
    ip                    VARCHAR2(64),
    modulo                VARCHAR2(64),
    identificador_cliente VARCHAR2(64),
    sid                   NUMBER,
    usuario_bd            VARCHAR2(128),
    accion                VARCHAR2(64)
);

-- Marca [PRIVADA]: pkg_permisos no publica estas tablas a los desarrolladores
COMMENT ON TABLE log_explorador IS '[PRIVADA] Bitacora de uso de pkg_explorador';
COMMENT ON TABLE exception_log  IS '[PRIVADA] Bitacora central de excepciones';
