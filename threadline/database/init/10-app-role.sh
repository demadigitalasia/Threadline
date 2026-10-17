#!/bin/sh
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set app_password="$THREADLINE_APP_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE threadline_app LOGIN PASSWORD %L', :'app_password') \gexec
GRANT CONNECT ON DATABASE threadline TO threadline_app;
SQL
