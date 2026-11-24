🇪🇸 **Español** · 🇬🇧 [English](README.en.md)

# Portafolio de SQL

Data warehouses, modelado dimensional, SCD tipo 2, grafos, optimización de consultas y PostgreSQL, sobre datos públicos reales con millones de filas.

**Herramientas principales:** SQL Server · PostgreSQL · T-SQL · Python (pruebas)

Cada carpeta es un proyecto independiente, con su propio README (resultados primero), guía paso a paso, pruebas automáticas y cómo reproducirlo. Los datos crudos no se versionan: cada proyecto trae un script que los descarga desde la fuente oficial.

## Proyectos

| Proyecto | De qué trata |
|---|---|
| [**WideWorldImporters: DW incremental y SCD tipo 2 en SQL Server**](dw-scd2-wide-world-importers/) | Data warehouse reproducible construido desde el OLTP oficial WideWorldImporters. Modela ventas, compras e inventario diario; conserva la historia de clientes y productos con SCD2; carga incrementos mediante marcas de agua y… |
| [**🚕 Data warehouse de los taxis amarillos de Nueva York 2024 en SQL Server**](dw-taxis-nyc-sqlserver/) | Data warehouse en T-SQL sobre SQL Server 2025 Express con los 41.169.720 viajes de taxi amarillo de Nueva York de 2024 (12 archivos Parquet oficiales de la TLC). Incluye carga incremental mes a mes e idempotente con auditoría,… |
| [**🎬 La red del cine en SQL Server: grafos, búsqueda de texto y ventanas sobre IMDb**](imdb-grafos-sqlserver/) | Análisis del catálogo de IMDb (6 archivos TSV, 205 M de filas, 102 M solo en title.principals) escrito íntegramente en T-SQL sobre SQL Server 2025 Express. Los TSV se cargan y filtran al vuelo con BULK INSERT / OPENROWSET(BULK) y… |
| [**🛒 Clientes de un retail online: RFM, cohortes y retención en T-SQL**](retail-rfm-cohortes-sql/) | Análisis de clientes de una tienda online del Reino Unido (regalos y artículos para el hogar, muchos clientes mayoristas) con 1.067.371 líneas de factura de dic-2009 a dic-2011. Todo el pipeline está escrito en T-SQL sobre SQL… |
| [**Laboratorio de rendimiento en SQL Server con Citi Bike Nueva York (enero–marzo 2024)**](tuning-sqlserver-citibike/) | Pregunta: ¿cuánto cambian el tiempo de respuesta y las páginas leídas cuando se elige bien el diseño físico (heap, índices cubrientes, índices filtrados, columnstore) y cuando se reescribe la consulta (predicados SARGables,… |
| [**Puntualidad de los vuelos comerciales de EE. UU. en PostgreSQL (2024)**](vuelos-eeuu-postgresql/) | Pregunta: ¿qué aerolíneas, aeropuertos, horas y rutas concentran los retrasos de los vuelos de EE. UU., por qué se retrasan y cuánto se propaga un retraso a los vuelos siguientes del mismo avión? Y, del lado técnico: ¿cuánto… |

## Cómo usar este repositorio

```bash
git clone https://github.com/GUAR-NIX/portafolio-sql.git
cd portafolio-sql/<proyecto>
```

Dentro de cada proyecto, sigue la sección «Cómo reproducir» de su README y `docs/GUIA_PASO_A_PASO.md`.

## Autor

**Erick Guarnizo** · [LinkedIn](https://www.linkedin.com/in/erick-g-571a7b3b4)

## Licencia

El código está bajo licencia [MIT](LICENSE). Los datos de cada proyecto conservan la licencia de su fuente, indicada en su README.
