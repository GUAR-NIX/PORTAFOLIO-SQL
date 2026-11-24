"""Crea en data/raw/ un mes sintético de 7 vuelos para la prueba de humo del CI (solo biblioteca estándar).

    python tests/ci/crear_fixture.py

Los vuelos son inventados y no salen de BTS. El orden de las columnas se lee de sql/02_staging_y_carga.sql,
así que el CSV siempre coincide con la tabla cruda. Se niega a sobrescribir datos reales descargados.

    1-3  Avión N1CI: a tiempo, raíz de un retraso de 60 min y vuelo siguiente que sale 30 min tarde
    4    Cancelado                                    (entra al hecho, con marca)
    5    Cruza la medianoche                          (entra al hecho, con marca)
    6    Velocidad imposible                          (cuarentena)
    7    Duplicado exacto del vuelo 1                 (cuarentena)
"""
from __future__ import annotations

import csv
import io
import re
import sys
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
CRUDO = RAIZ / "data" / "raw"
AEROPUERTOS = {  # código inventado, zona horaria y desfase en enero (horas respecto a UTC)
    "ATL": (9001, "America/New_York", -5),
    "DFW": (9002, "America/Chicago", -6),
    "JFK": (9003, "America/New_York", -5),
}


def columnas() -> list[str]:
    sql = (RAIZ / "sql" / "02_staging_y_carga.sql").read_text(encoding="utf-8")
    bloque = re.search(r"CREATE UNLOGGED TABLE IF NOT EXISTS stg\.vuelo_crudo \((.*?)\n\);", sql, re.S).group(1)
    return re.findall(r"(\w+) text", bloque)


def vuelo(numero: int, matricula: str, origen: str, destino: str, salida: str, duracion: int,
          retraso_salida: int | None = 0, retraso_llegada: int | None = 0, *, distancia: int = 700,
          causas: tuple[int, ...] | None = None, cancelado: bool = False) -> dict[str, str]:
    """Fila coherente con las reglas de calidad: las horas locales se derivan de las zonas horarias."""
    sale = datetime.strptime(f"2024-01-10 {salida}", "%Y-%m-%d %H:%M")
    zona_o, zona_d = (timezone(timedelta(hours=AEROPUERTOS[x][2])) for x in (origen, destino))
    llega = (sale.replace(tzinfo=zona_o) + timedelta(minutes=duracion)).astimezone(zona_d)

    def hhmm(t: datetime) -> str:
        return t.strftime("%H%M")

    f = {
        "year": "2024", "quarter": "1", "month": "1", "dayofmonth": "10", "dayofweek": "3", "flightdate": "2024-01-10",
        "reporting_airline": "ZZ", "tail_number": matricula, "flight_number_reporting_airline": str(numero),
        "originairportid": str(AEROPUERTOS[origen][0]), "origin": origen, "origincityname": origen, "originstate": "XX",
        "destairportid": str(AEROPUERTOS[destino][0]), "dest": destino, "destcityname": destino, "deststate": "XX",
        "crsdeptime": hhmm(sale), "crsarrtime": hhmm(llega), "cancelled": "0.00", "diverted": "0.00",
        "crselapsedtime": f"{duracion}.00", "distance": f"{distancia}.00",
    }
    if cancelado:
        return f | {"cancelled": "1.00", "cancellationcode": "B"}
    real = duracion + retraso_llegada - retraso_salida
    f |= {
        "deptime": hhmm(sale + timedelta(minutes=retraso_salida)), "depdelay": f"{retraso_salida}.00",
        "arrtime": hhmm(llega + timedelta(minutes=retraso_llegada)), "arrdelay": f"{retraso_llegada}.00",
        "arrdel15": "1.00" if retraso_llegada >= 15 else "0.00", "taxiout": "15.00", "taxiin": "8.00",
        "wheelsoff": hhmm(sale + timedelta(minutes=retraso_salida + 15)),
        "wheelson": hhmm(llega + timedelta(minutes=retraso_llegada - 8)),
        "actualelapsedtime": f"{real}.00", "airtime": f"{real - 23}.00",
    }
    if causas:
        nombres = ("carrierdelay", "weatherdelay", "nasdelay", "securitydelay", "lateaircraftdelay")
        f |= {n: f"{m}.00" for n, m in zip(nombres, causas, strict=True)}
    return f


def main() -> int:
    zip_mes = CRUDO / "vuelos" / "2024_01.zip"
    if any(p.stat().st_size > 10_000 for p in CRUDO.rglob("*") if p.is_file()):
        print(f"{CRUDO} contiene datos reales descargados: no se sobrescriben")
        return 1
    filas = [
        vuelo(1, "N1CI", "ATL", "DFW", "08:00", 150, 0, 5),
        vuelo(2, "N1CI", "DFW", "JFK", "10:30", 200, 50, 60, distancia=1300, causas=(60, 0, 0, 0, 0)),
        vuelo(3, "N1CI", "JFK", "ATL", "16:00", 160, 30, 20, causas=(0, 0, 0, 0, 20)),
        vuelo(4, "N2CI", "ATL", "JFK", "09:00", 140, cancelado=True),
        vuelo(5, "N2CI", "JFK", "DFW", "22:30", 240, 0, 0, distancia=1300),
        vuelo(6, "N3CI", "ATL", "DFW", "12:00", 150, 0, 0, distancia=5000),
        vuelo(1, "N1CI", "ATL", "DFW", "08:00", 150, 0, 5),
    ]
    cols = columnas()
    texto = io.StringIO()
    w = csv.DictWriter(texto, fieldnames=cols, restval="", lineterminator="\n")
    w.writeheader()
    w.writerows(filas)
    zip_mes.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_mes, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("fixture_2024_01.csv", texto.getvalue())

    ref = CRUDO / "referencia"
    ref.mkdir(parents=True, exist_ok=True)
    (ref / "L_AIRPORT_ID.csv").write_text(
        "Code,Description\n" + "".join(f'{i},"Fixture: {a}"\n' for a, (i, _, _) in AEROPUERTOS.items()), encoding="latin-1")
    (ref / "L_UNIQUE_CARRIERS.csv").write_text("Code,Description\nZZ,Aerolínea de prueba\n", encoding="latin-1")
    (ref / "aeropuertos_tz.csv").write_text(
        "iata,zona_horaria,latitud,longitud,pais\n"
        + "".join(f"{a},{z},0,0,US\n" for a, (_, z, _) in AEROPUERTOS.items()), encoding="utf-8")
    print(f"Fixture: {len(filas)} vuelos, {len(cols)} columnas, en {CRUDO.relative_to(RAIZ)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
