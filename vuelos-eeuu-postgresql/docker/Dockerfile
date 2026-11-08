# PostgreSQL 17 con versión fijada + unzip, para que COPY ... FROM PROGRAM
# lea el CSV directamente dentro del ZIP de BTS (sin descomprimirlo en disco).
FROM postgres:17.11-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends unzip \
 && rm -rf /var/lib/apt/lists/*
