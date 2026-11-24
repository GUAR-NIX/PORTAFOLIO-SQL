🇪🇸 [Español](README.md) · 🇬🇧 **English**

# SQL portfolio

Data warehouses, dimensional modeling, SCD type 2, graphs, query optimization and PostgreSQL, on real public data with millions
of rows.

**Main tools:** SQL Server · PostgreSQL · T-SQL · Python (tests)

Each folder is an independent project with its own README (results first), step-by-step guide, automated tests and
reproduction instructions. Raw data are not versioned: every project ships a script that downloads them from the official
source.

> 🌐 Each project has an English summary with its key results; the full documentation is in Spanish.

## Projects

| Project | What it is about |
|---|---|
| [**WideWorldImporters: incremental DW and SCD type 2 in SQL Server**](dw-scd2-wide-world-importers/README.en.md) | Sales, purchases and daily inventory with customer and product history, loaded with watermarks |
| [**🚕 Data warehouse of New York's 2024 yellow taxis in SQL Server**](dw-taxis-nyc-sqlserver/README.en.md) | 41.2 million trips, incremental and idempotent monthly load, partitioned columnstore fact table |
| [**🎬 The film network in SQL Server: graphs, text search and windows on IMDb**](imdb-grafos-sqlserver/README.en.md) | 205 million rows, a graph with `SHORTEST_PATH` and degrees of separation |
| [**🛒 Customers of an online retailer: RFM, cohorts and retention in T-SQL**](retail-rfm-cohortes-sql/README.en.md) | 1.07 million invoice lines, documented cleaning, star schema, RFM and cohorts |
| [**Performance lab in SQL Server with Citi Bike New York (January–March 2024)**](tuning-sqlserver-citibike/README.en.md) | Nine experiments measuring how much indexes, columnstore and rewrites change response time |
| [**Punctuality of U.S. commercial flights in PostgreSQL (2024)**](vuelos-eeuu-postgresql/README.en.md) | 7.08 million flights, delay propagation and measured partitioning, BRIN and partial indexes |

## How to use this repository

```bash
git clone https://github.com/GUAR-NIX/PORTAFOLIO-SQL.git
cd PORTAFOLIO-SQL/<project>
```

Inside each project, follow the reproduction section of its README and `docs/GUIA_PASO_A_PASO.md` (Spanish).

## Author

**Erick Guarnizo** · [LinkedIn](https://www.linkedin.com/in/erick-g-571a7b3b4)

## License

Code is under the [MIT](LICENSE) license. Each project's data keep the license of their source, stated in its README.
