🇺🇸 **English** · 🇪🇸 [Español](README.es.md)

# SQL Server and PostgreSQL: warehouses, tuning and reconciliation

[![CI](https://github.com/GUAR-NIX/PORTAFOLIO-SQL/actions/workflows/ci.yml/badge.svg)](https://github.com/GUAR-NIX/PORTAFOLIO-SQL/actions/workflows/ci.yml)

Six projects on public data with up to 205 million rows: incremental loads, SCD type 2, partitioning, columnstore, graphs and query tuning,
reconciled against the source.

| Project | Measured result | Code | Tests |
|---|---|---|---|
| [NYC taxi data warehouse](dw-taxis-nyc-sqlserver/README.md) | **41.2 million** trips; source = fact + quarantine with difference **0** in the 12 months | [code](dw-taxis-nyc-sqlserver/sql) | [tests](dw-taxis-nyc-sqlserver/tests) |
| [SQL Server performance lab](tuning-sqlserver-citibike/README.md) | **92.50–99.96%** fewer pages read in nine experiments, with identical results | [code](tuning-sqlserver-citibike/sql) | [tests](tuning-sqlserver-citibike/tests) |
| [U.S. flight delays in PostgreSQL](vuelos-eeuu-postgresql/README.md) | **7.08 million** flights; BRIN index 0.039 MB vs. 47.0 MB for the B-tree | [code](vuelos-eeuu-postgresql/sql) | [tests](vuelos-eeuu-postgresql/tests) |
| [Incremental warehouse with SCD2](dw-scd2-wide-world-importers/README.md) | Full load 2,979 ms; incremental without changes **26.8 ms** (medians of 5) | [code](dw-scd2-wide-world-importers/sql) | [tests](dw-scd2-wide-world-importers/tests) |
| [Film network as a graph](imdb-grafos-sqlserver/README.md) | **205.5 million** rows read, 0 rejected; `SHORTEST_PATH` 2.1 s vs. 62 s for a recursive CTE | [code](imdb-grafos-sqlserver/sql) | [tests](imdb-grafos-sqlserver/tests) |
| [RFM, cohorts and retention](retail-rfm-cohortes-sql/README.md) | **1.07 million** lines reconciled with difference **0** in rows, units and amount | [code](retail-rfm-cohortes-sql/sql) | [tests](retail-rfm-cohortes-sql/tests) |

## Start here

| If you are looking for… | Go to |
|---|---|
| **Query tuning** | [Performance lab](tuning-sqlserver-citibike/README.md): 260 measured runs, warm and cold |
| **Pipeline reliability** | [NYC taxi warehouse](dw-taxis-nyc-sqlserver/README.md): idempotent monthly load that survived a restart |
| **How it is checked** | [CI workflow](.github/workflows/ci.yml): Ruff, Markdown links, T-SQL syntax with Microsoft's parser, database-free tests, and the PostgreSQL pipeline on a synthetic fixture |
| **Design and decisions** | The full README of each project (Spanish) has the architecture, limits and reproduction commands |

## How results were measured

- Timings are medians of repeated runs on one local machine.
- Control figures are computed in Python from the source files and compared with the database.
- The SQL Server integration tests need the full datasets and run locally; CI checks the syntax of every T-SQL script.
- The PostgreSQL job runs the real scripts on seven synthetic flights; it does not reproduce the published figures.

## How to use this repository

```bash
git clone https://github.com/GUAR-NIX/PORTAFOLIO-SQL.git
cd PORTAFOLIO-SQL/<project>
```

Each project has its own README, tests and `docs/GUIA_PASO_A_PASO.md` (Spanish). Raw data are not versioned: a script gets them from
the official source. The English page of each project is a summary; the full documentation is in Spanish.
See [CONTRIBUTING.md](CONTRIBUTING.md) to run the checks.

## Author

**Erick Guarnizo** · [LinkedIn](https://www.linkedin.com/in/erick-g-571a7b3b4) · [GitHub profile](https://github.com/GUAR-NIX)

## License

Code is under the [MIT](LICENSE) license. Each project's data keep the license of their source, stated in its README.
