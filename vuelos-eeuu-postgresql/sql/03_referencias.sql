-- 03 · Tablas de referencia: aeropuertos, aerolíneas y zonas horarias
--
-- BTS publica dos tablas de búsqueda (L_AIRPORT_ID y L_UNIQUE_CARRIERS) con
-- código y descripción. BTS no publica la zona horaria de cada aeropuerto en un
-- archivo descargable directo, así que se toma de mwgg/Airports (licencia MIT),
-- por código IATA, y se valida contra los propios horarios de BTS en 04_calidad.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS ref.aeropuerto_bts, ref.aerolinea_bts, ref.aeropuerto_tz;

CREATE TABLE ref.aeropuerto_bts (codigo int PRIMARY KEY, descripcion text NOT NULL);
CREATE TABLE ref.aerolinea_bts (codigo text PRIMARY KEY, descripcion text NOT NULL);
CREATE TABLE ref.aeropuerto_tz (
    iata          text PRIMARY KEY,
    zona_horaria  text NOT NULL,
    latitud       double precision,
    longitud      double precision,
    pais          text
);

COPY ref.aeropuerto_bts FROM '/datos/referencia/L_AIRPORT_ID.csv' WITH (FORMAT csv, HEADER true, ENCODING 'LATIN1');
COPY ref.aerolinea_bts FROM '/datos/referencia/L_UNIQUE_CARRIERS.csv' WITH (FORMAT csv, HEADER true, ENCODING 'LATIN1');
COPY ref.aeropuerto_tz FROM '/datos/referencia/aeropuertos_tz.csv' WITH (FORMAT csv, HEADER true);
