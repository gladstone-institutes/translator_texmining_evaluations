FROM python:3.12.14-slim-bookworm
LABEL version="0.1.0"
LABEL description="DuckDB + pandas environment for estimating SemMedDB-KGX predicate frequencies"

RUN pip install --no-cache-dir \
        duckdb==1.5.5 \
        pandas==3.0.6

RUN python -c "import duckdb, pandas; \
assert duckdb.__version__ == '1.5.5', duckdb.__version__; \
assert pandas.__version__ == '3.0.6', pandas.__version__; \
print('duckdb', duckdb.__version__, 'pandas', pandas.__version__)"
