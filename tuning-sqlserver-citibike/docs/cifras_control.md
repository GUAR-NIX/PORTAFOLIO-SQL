# Cifras de control de la ingesta (Citi Bike Nueva York, enero–marzo 2024)

Archivo generado por `scripts/descargar_datos.py`. No editar a mano.

- **Fuente:** https://s3.amazonaws.com/tripdata/index.html (archivos `202401`, `202402` y `202403` del sistema de Nueva York)
- **TSV consolidado:** `data/raw/citibike_2024T1,tsv` (1.285,4 MB)
- **Filas brutas:** 6.672.881
- **Filas válidas:** 6.653.987
- **Filas con motivo de exclusión:** 18.894

## Desglose por mes

| Periodo | Archivo ZIP | MB del ZIP | Filas | Válidas | Eléctrica | Clásica | Miembros | Ocasionales |
| :---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `202401` | `202401-citibike-tripdata.zip` | 351,9 | 1.888.085 | 1.881.951 | 1.214.526 | 673.559 | 1.679.836 | 208.249 |
| `202402` | `202402-citibike-tripdata.zip` | 395,5 | 2.121.501 | 2.115.973 | 1.367.981 | 753.520 | 1.868.462 | 253.039 |
| `202403` | `202403-citibike-tripdata.zip` | 496,6 | 2.663.295 | 2.656.063 | 1.724.698 | 938.597 | 2.239.953 | 423.342 |

## Reglas de calidad (`motivo_exclusion`)

| Estado / motivo | Filas |
| :--- | ---: |
| `VALIDO` | 6.653.987 |
| `SIN_ESTACION_O_COORD_DESTINO` | 13.009 |
| `DATOS_ORIGEN_INCOMPLETOS` | 5.822 |
| `DURACION_EXCESIVA_MAYOR_24H` | 63 |

## Huella SHA-256 de los ZIP

- `202401-citibike-tripdata.zip`: `0a2e81eacd7bf3890712de8f2a1b56bda985c17d9e61b08acf5e7c7ec9f20eb0`
- `202402-citibike-tripdata.zip`: `f0209d02b862ec7422ea251f55626c007c8289adb62230e870ed7da24ef77f05`
- `202403-citibike-tripdata.zip`: `d1a58caa37a66bbe6477680f3fba283f6f638475855591a4a2e8b73dc4cf8470`
