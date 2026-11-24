# Contributing

## Run the same checks as CI

```bash
pip install ruff==0.17.6
ruff check .
python .github/scripts/check_markdown_links.py

cd <project>
python -m venv .venv && source .venv/bin/activate      # on Windows: .venv\Scripts\Activate.ps1
pip install -r requirements.txt pytest
python -m pytest
```

Tests that need the raw dataset, a database or a local model are skipped with a message that says what is missing.

### SQL checks

```bash
pwsh .github/scripts/check_tsql.ps1        # T-SQL syntax, no server needed

cd vuelos-eeuu-postgresql                  # PostgreSQL pipeline on a synthetic fixture (needs Docker)
python tests/ci/crear_fixture.py
docker compose up -d --build --wait
```

The remaining commands of the PostgreSQL check are in [ci.yml](.github/workflows/ci.yml). Tests named `test_pipeline_sql.py` and
`test_dw.py` need a local SQL Server with the full dataset and are skipped otherwise.

## Documentation rules

- `README.md` is English and `README.es.md` is Spanish. Update both when a result changes.
- Some Spanish READMEs are generated, and a test compares them with the generator. Do not edit them by hand: `tuning-sqlserver-citibike` and `vuelos-eeuu-postgresql` (`python scripts/generar_readme.py`).
  Change the template or script and run the command.
- Every figure must come from `reports/` or from a test. Do not add a number that cannot be reproduced.
- Do not commit raw data, `.env` files, credentials or personal data.
