-- 02 · Staging, carga con COPY y auditoría por mes
--
-- Cada ZIP mensual de BTS trae un CSV de 109 columnas (más una coma final).
-- COPY ... FROM PROGRAM 'unzip -p ...' lee el CSV dentro del ZIP sin
-- descomprimirlo en disco. La carga es reanudable: cada mes se confirma
-- (COMMIT) por separado y un mes con estado 'OK' no se vuelve a cargar.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- 1) Tabla cruda: las 110 columnas como texto, sin tipos ni reglas.
--    UNLOGGED: no escribe WAL; si el servidor se cae se vacía, y no importa
--    porque se vuelve a llenar desde el ZIP.
CREATE UNLOGGED TABLE IF NOT EXISTS stg.vuelo_crudo (
    fila_csv bigint GENERATED ALWAYS AS IDENTITY,
    year text, quarter text, month text, dayofmonth text, dayofweek text, flightdate text,
    reporting_airline text, dot_id_reporting_airline text, iata_code_reporting_airline text,
    tail_number text, flight_number_reporting_airline text,
    originairportid text, originairportseqid text, origincitymarketid text, origin text,
    origincityname text, originstate text, originstatefips text, originstatename text, originwac text,
    destairportid text, destairportseqid text, destcitymarketid text, dest text,
    destcityname text, deststate text, deststatefips text, deststatename text, destwac text,
    crsdeptime text, deptime text, depdelay text, depdelayminutes text, depdel15 text,
    departuredelaygroups text, deptimeblk text, taxiout text, wheelsoff text, wheelson text, taxiin text,
    crsarrtime text, arrtime text, arrdelay text, arrdelayminutes text, arrdel15 text,
    arrivaldelaygroups text, arrtimeblk text, cancelled text, cancellationcode text, diverted text,
    crselapsedtime text, actualelapsedtime text, airtime text, flights text, distance text, distancegroup text,
    carrierdelay text, weatherdelay text, nasdelay text, securitydelay text, lateaircraftdelay text,
    firstdeptime text, totaladdgtime text, longestaddgtime text, divairportlandings text,
    divreacheddest text, divactualelapsedtime text, divarrdelay text, divdistance text,
    div1airport text, div1airportid text, div1airportseqid text, div1wheelson text,
    div1totalgtime text, div1longestgtime text, div1wheelsoff text, div1tailnum text,
    div2airport text, div2airportid text, div2airportseqid text, div2wheelson text,
    div2totalgtime text, div2longestgtime text, div2wheelsoff text, div2tailnum text,
    div3airport text, div3airportid text, div3airportseqid text, div3wheelson text,
    div3totalgtime text, div3longestgtime text, div3wheelsoff text, div3tailnum text,
    div4airport text, div4airportid text, div4airportseqid text, div4wheelson text,
    div4totalgtime text, div4longestgtime text, div4wheelsoff text, div4tailnum text,
    div5airport text, div5airportid text, div5airportseqid text, div5wheelson text,
    div5totalgtime text, div5longestgtime text, div5wheelsoff text, div5tailnum text,
    extra_coma_final text
);

-- 2) Staging tipado: solo las columnas que usa el proyecto, con tipos.
--    id_vuelo = AAAAMM * 10^7 + número de fila dentro del CSV del mes.
CREATE UNLOGGED TABLE IF NOT EXISTS stg.vuelo (
    id_vuelo              bigint PRIMARY KEY,
    anio_mes              int      NOT NULL,
    fecha_vuelo           date     NOT NULL,
    dia_semana_bts        smallint,            -- 1 = lunes ... 7 = domingo
    aerolinea             text     NOT NULL,
    matricula             text,                -- Tail_Number
    numero_vuelo          int,
    origen_id             int,
    origen                text,
    origen_ciudad         text,
    origen_estado         text,
    destino_id            int,
    destino               text,
    destino_ciudad        text,
    destino_estado        text,
    salida_prog_hhmm      smallint,            -- CRSDepTime (hora local, hhmm)
    salida_real_hhmm      smallint,            -- DepTime (puede ser 2400)
    retraso_salida        smallint,            -- DepDelay en minutos
    taxi_out              smallint,
    despegue_hhmm         smallint,            -- WheelsOff
    aterrizaje_hhmm       smallint,            -- WheelsOn
    taxi_in               smallint,
    llegada_prog_hhmm     smallint,            -- CRSArrTime
    llegada_real_hhmm     smallint,            -- ArrTime
    retraso_llegada       smallint,            -- ArrDelay
    llegada_15            boolean,             -- ArrDel15
    cancelado             boolean  NOT NULL,
    codigo_cancelacion    char(1),             -- A aerolínea, B clima, C NAS, D seguridad
    desviado              boolean  NOT NULL,
    duracion_prog_min     smallint,            -- CRSElapsedTime
    duracion_real_min     smallint,            -- ActualElapsedTime
    tiempo_aire_min       smallint,            -- AirTime
    distancia_millas      smallint,
    retraso_aerolinea     smallint,            -- CarrierDelay
    retraso_clima         smallint,            -- WeatherDelay
    retraso_nas           smallint,            -- NASDelay (sistema aéreo nacional)
    retraso_seguridad     smallint,            -- SecurityDelay
    retraso_avion_previo  smallint             -- LateAircraftDelay
);

-- 3) Auditoría de carga: una fila por mes.
CREATE TABLE IF NOT EXISTS control.carga_mes (
    anio_mes          int PRIMARY KEY,
    archivo           text        NOT NULL,
    filas_copiadas    bigint,
    filas_tipadas     bigint,
    segundos_copy     numeric(8,2),
    segundos_tipado   numeric(8,2),
    estado            text        NOT NULL DEFAULT 'EN_CURSO',
    iniciado_en       timestamptz NOT NULL DEFAULT clock_timestamp(),
    terminado_en      timestamptz
);

-- 4) Cifras de control calculadas en PostgreSQL con la misma definición que
--    scripts/descargar_datos.py usa sobre el CSV (data/cifras_control.json).
CREATE TABLE IF NOT EXISTS control.cifras_mes (
    anio_mes              int PRIMARY KEY,
    filas                 bigint,
    cancelados            bigint,
    desviados             bigint,
    con_retraso_15        bigint,
    suma_retraso_llegada  numeric(14,1),
    suma_retraso_salida   numeric(14,1),
    suma_distancia        numeric(14,1),
    suma_late_aircraft    numeric(14,1),
    sin_matricula         bigint,
    fecha_min             date,
    fecha_max             date,
    dias                  int,
    aerolineas            int
);

-- hhmm de BTS ('0856', '2400', '') a smallint
CREATE OR REPLACE FUNCTION stg.hhmm(t text) RETURNS smallint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT NULLIF(btrim(t), '')::smallint
$$;

-- '-5.00' / '' a minutos enteros
CREATE OR REPLACE FUNCTION stg.minutos(t text) RETURNS smallint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT round(NULLIF(btrim(t), '')::numeric)::smallint
$$;

CREATE OR REPLACE PROCEDURE control.cargar_mes(p_anio int, p_mes int)
LANGUAGE plpgsql AS $$
DECLARE
    v_anio_mes int  := p_anio * 100 + p_mes;
    v_archivo  text := format('/datos/vuelos/%s_%s.zip', p_anio, lpad(p_mes::text, 2, '0'));
    v_t0       timestamptz;
    v_copiadas bigint;
    v_tipadas  bigint;
    v_seg_copy numeric;
BEGIN
    INSERT INTO control.carga_mes (anio_mes, archivo) VALUES (v_anio_mes, v_archivo)
    ON CONFLICT (anio_mes) DO UPDATE
        SET estado = 'EN_CURSO', iniciado_en = clock_timestamp(), terminado_en = NULL;

    TRUNCATE stg.vuelo_crudo RESTART IDENTITY;
    v_t0 := clock_timestamp();
    -- La lista explícita de columnas deja fuera fila_csv, que numera las filas en orden.
    EXECUTE format(
        'COPY stg.vuelo_crudo (%s) FROM PROGRAM %L WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')',
        (SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum)
           FROM pg_attribute
          WHERE attrelid = 'stg.vuelo_crudo'::regclass AND attnum > 1 AND NOT attisdropped),
        format('unzip -p %s "*.csv"', v_archivo));
    GET DIAGNOSTICS v_copiadas = ROW_COUNT;
    v_seg_copy := extract(epoch FROM clock_timestamp() - v_t0);

    v_t0 := clock_timestamp();
    DELETE FROM stg.vuelo WHERE anio_mes = v_anio_mes;
    INSERT INTO stg.vuelo
    SELECT v_anio_mes::bigint * 10000000 + c.fila_csv,
           v_anio_mes,
           c.flightdate::date,
           c.dayofweek::smallint,
           c.reporting_airline,
           NULLIF(btrim(c.tail_number), ''),
           NULLIF(btrim(c.flight_number_reporting_airline), '')::int,   -- agosto trae 1 vuelo sin número
           NULLIF(btrim(c.originairportid), '')::int, c.origin, c.origincityname, c.originstate,
           NULLIF(btrim(c.destairportid), '')::int,   c.dest,   c.destcityname,   c.deststate,
           stg.hhmm(c.crsdeptime), stg.hhmm(c.deptime), stg.minutos(c.depdelay),
           stg.minutos(c.taxiout), stg.hhmm(c.wheelsoff), stg.hhmm(c.wheelson),
           stg.minutos(c.taxiin),
           stg.hhmm(c.crsarrtime), stg.hhmm(c.arrtime), stg.minutos(c.arrdelay),
           NULLIF(c.arrdel15, '')::numeric = 1,
           c.cancelled::numeric = 1,
           NULLIF(btrim(c.cancellationcode), ''),
           c.diverted::numeric = 1,
           stg.minutos(c.crselapsedtime), stg.minutos(c.actualelapsedtime),
           stg.minutos(c.airtime), stg.minutos(c.distance),
           stg.minutos(c.carrierdelay), stg.minutos(c.weatherdelay),
           stg.minutos(c.nasdelay), stg.minutos(c.securitydelay),
           stg.minutos(c.lateaircraftdelay)
      FROM stg.vuelo_crudo c;
    GET DIAGNOSTICS v_tipadas = ROW_COUNT;

    -- Cifras de control del mes, desde el texto crudo (misma definición que en Python).
    DELETE FROM control.cifras_mes WHERE anio_mes = v_anio_mes;
    INSERT INTO control.cifras_mes
    SELECT v_anio_mes,
           count(*),
           count(*) FILTER (WHERE cancelled::numeric = 1),
           count(*) FILTER (WHERE diverted::numeric = 1),
           count(*) FILTER (WHERE NULLIF(arrdel15, '')::numeric = 1),
           coalesce(sum(NULLIF(arrdelay, '')::numeric), 0),
           coalesce(sum(NULLIF(depdelay, '')::numeric), 0),
           coalesce(sum(NULLIF(distance, '')::numeric), 0),
           coalesce(sum(NULLIF(lateaircraftdelay, '')::numeric), 0),
           count(*) FILTER (WHERE btrim(coalesce(tail_number, '')) = ''),
           min(flightdate::date), max(flightdate::date),
           count(DISTINCT flightdate), count(DISTINCT reporting_airline)
      FROM stg.vuelo_crudo;

    UPDATE control.carga_mes
       SET filas_copiadas  = v_copiadas,
           filas_tipadas   = v_tipadas,
           segundos_copy   = round(v_seg_copy, 2),
           segundos_tipado = round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 2),
           estado          = CASE WHEN v_copiadas = v_tipadas THEN 'OK' ELSE 'DESCUADRE' END,
           terminado_en    = clock_timestamp()
     WHERE anio_mes = v_anio_mes;
    TRUNCATE stg.vuelo_crudo;
END $$;

-- Carga reanudable: confirma cada mes y salta los que ya están en 'OK'.
CREATE OR REPLACE PROCEDURE control.cargar_rango(p_anio int, p_desde int, p_hasta int)
LANGUAGE plpgsql AS $$
DECLARE
    m int;
BEGIN
    FOR m IN p_desde .. p_hasta LOOP
        IF EXISTS (SELECT 1 FROM control.carga_mes
                    WHERE anio_mes = p_anio * 100 + m AND estado = 'OK') THEN
            RAISE NOTICE 'Mes %-%: ya cargado, se omite', p_anio, m;
            CONTINUE;
        END IF;
        CALL control.cargar_mes(p_anio, m);
        COMMIT;
        RAISE NOTICE 'Mes %-%: cargado', p_anio, m;
    END LOOP;
END $$;
