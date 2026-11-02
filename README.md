# rathena-plsql-audit-poc

Prueba de concepto de **desarrollo PL/SQL y administración de bases de datos** sobre Oracle Autonomous Database. Audita los datos de una base de un servidor privado de Ragnarok Online ([rAthena](https://github.com/rathena/rathena)) en busca de actividad sospechosa, y expone herramientas de solo lectura a agentes de IA mediante el servidor MCP integrado de Oracle.

Nació como proyecto académico (Taller de Base de Datos, BDY1103, Duoc UC). Es un ejercicio de aprendizaje, no un sistema de producción.

## Qué hace

Los paquetes de auditoría señalan hallazgos para que una persona los revise. Nunca modifican los datos del juego ni determinan por sí mismos que se rompió una regla.

| Auditoría | Procedimiento | Detecta |
|---|---|---|
| Ítems fantasma | `pkg_auditoria.sp_items_fantasma` | Ítems en inventario cuyo id no está en ningún catálogo `item_db_*` |
| Multicuenta | `pkg_auditoria.sp_multicuenta` | Cuentas que comparten última IP (umbral por defecto: 3), con sus personajes |
| Puntos de skill inválidos | `pkg_auditoria.sp_puntos_invalidos` | Novices con más puntos de skill de los que permite su job level |
| Ítems creados por GM | `pkg_auditoria.sp_items_gm` | Ítems en inventario con registro de administrador (`@item`) en `picklog` |

Los hallazgos se guardan en tablas de reporte creadas en el esquema del propio desarrollador (por medio de `pkg_instalacion.sp_crear_tablas`). Los errores y las reglas de negocio infringidas van a una bitácora central que solo acepta inserción, `exception_log`. Cada llamada a una herramienta por MCP queda en `log_explorador`.

## Qué demuestra

- **Derechos del invocador** (`AUTHID CURRENT_USER`): el código vive en `RO_DATA`, pero se ejecuta con los privilegios de quien lo llama y escribe en su esquema.
- **Encapsulamiento con `ACCESSIBLE BY`**: `pkg_bitacora` solo puede ser llamado por los paquetes indicados en la cláusula.
- **Transacciones autónomas**: los registros de bitácora son una transacción aparte de la principal, por lo que sobreviven al `ROLLBACK` del llamador.
- **Bitácoras inmutables** mediante triggers `BEFORE UPDATE OR DELETE`.
- **Procesamiento masivo**: `BULK COLLECT ... LIMIT` y `FORALL`.
- **Manejo de errores**: excepciones definidas por el usuario y con `EXCEPTION_INIT`, `SAVEPOINT` / `ROLLBACK TO`, `FORMAT_ERROR_BACKTRACE`, `UTL_CALL_STACK`.
- **Triggers DDL a nivel de esquema** que delegan el trabajo a jobs de `DBMS_SCHEDULER` porque un trigger no puede hacer commit, de modo que las tablas nuevas se publican automáticamente.
- **Modelo de privilegios**: acceso por rol, un sinónimo público por tabla y `DBMS_ASSERT` en el SQL dinámico.
- **Integración con IA**: funciones PL/SQL registradas como herramientas con `DBMS_CLOUD_AI_AGENT` y servidas por el servidor MCP de Autonomous Database. El usuario real se recupera de la sesión MCP (`C##CLOUD$SERVICE`) para la trazabilidad.

## Estructura del repositorio

```
sql/
├── 00_admin_setup.sql      # Configuración de referencia: esquema, rol, usuarios (ejecutados como ADMIN)
├── 01_logging_tables.sql   # log_explorador, exception_log
├── 02_logging_triggers.sql # Triggers de solo inserción
├── 03_pkg_bitacora.sql     # Paquete de bitácora
├── 04_pkg_explorador.sql   # Herramientas MCP
├── 05_pkg_instalacion.sql  # Crea las tablas de hallazgos
├── 06_pkg_permisos.sql     # Permisos + sinónimos públicos
├── 07_ddl_triggers.sql     # Publicación / despublicación automática de tablas
└── 08_pkg_auditoria.sql    # Las auditorías

docs/                       # Informe y diagramas
```

## Suposiciones

Los scripts no crean su propio entorno. Esto es lo que asumen, reconstruido a partir del código. `sql/00_admin_setup.sql` es un script de referencia para la parte del administrador.

**Plataforma**
- Oracle Autonomous Database 26ai (Lakehouse).
- El servidor MCP está habilitado en la instancia y `DBMS_CLOUD_AI_AGENT` está disponible, véase [la documentación](https://docs.oracle.com/es-ww/iaas/autonomous-database-serverless/doc/mcp-server.html).

**Esquemas, roles y usuarios**
- El esquema `RO_DATA` es dueño de las tablas del juego, las tablas de bitácora y todos los paquetes y triggers.
- El rol `desarrollador` se otorga a los usuarios desarrolladores.
- Los desarrolladores leen los datos del juego mediante sinónimos públicos. `CHAR` es palabra reservada, por lo que su sinónimo es `RO_CHAR`, que es el que usa `pkg_auditoria`.

**Datos del juego**
- Las tablas de rAthena (`login`, `char`, `inventory`, `picklog`, `skill`, `skill_db_data`, `atcommandlog`, `ipbanlist`, `quest`) y las tablas `item_db_equip`, `item_db_etc` e `item_db_usable` (convertidas desde los catálogos YAML) se cargaron en `RO_DATA` mediante un proceso ELT. Este repositorio no incluye datos del juego.


## Instalación

Primero reemplaza los marcadores de contraseña del paso 1.

| # | Ejecutar como | Script |
|---|---|---|
| 1 | `ADMIN` | `00_admin_setup.sql` |
| 2 | `RO_DATA` | cargar las tablas del juego |
| 3 | `RO_DATA` | `01` a `06`, en orden |
| 4 | `RO_DATA` | `EXEC pkg_permisos.sp_publicar_todas;` crea los sinónimos (incluido `RO_CHAR`) |
| 5 | `RO_DATA` | `07_ddl_triggers.sql` |
| 6 | `RO_DATA` | `EXEC pkg_instalacion.sp_crear_tablas;` (el paquete de auditoría necesita las tablas de hallazgos para compilar) |
| 7 | `RO_DATA` | `08_pkg_auditoria.sql`|


## Uso

Como usuario desarrollador:

```sql
-- una vez por esquema: crear las tablas de reporte
EXEC ro_data.pkg_instalacion.sp_crear_tablas;

-- ejecutar las auditorías
SET SERVEROUTPUT ON
EXEC ro_data.pkg_auditoria.sp_items_fantasma;
EXEC ro_data.pkg_auditoria.sp_multicuenta;                 -- todas las IP, límite 3
EXEC ro_data.pkg_auditoria.sp_multicuenta(p_limite => 5);
EXEC ro_data.pkg_auditoria.sp_puntos_invalidos;
EXEC ro_data.pkg_auditoria.sp_items_gm;

-- exponer el explorador de esquema a un agente de IA mediante MCP
EXEC ro_data.pkg_explorador.registrar_herramientas;
```

Herramientas MCP: `LIST_SCHEMAS`, `LIST_OBJECTS`, `GET_OBJECT_DETAILS`, `EXECUTE_SQL` (solo lectura, paginada, máximo 200 filas por página) y `RESUMEN_ESQUEMA`.


## Autores

José Calderón y Sebastian Apablaza. Taller de Base de Datos
