#!/usr/bin/env bash
# ============================================================
# run_all.sh — EC2 host LLM+Streamlit, DB via docker-compose (default ports)
# - Postgres PG17 on 5432, Streamlit 8501
# - Drop & recreate DB each run (clean slate)
# - Sanitize dump; idempotent views; fail-safe SQL (CREATE IF NOT EXISTS / OR REPLACE)
# - docker-compose only (not `docker compose`)
# ============================================================
set -euo pipefail

APP_DIR="/opt/WarehouseManagerAI"
ENV_FILE="$APP_DIR/.env"
DC_FILE="$APP_DIR/docker-compose.db.yml"
TMP_DIR="$APP_DIR/tmp"
SANITIZED="$TMP_DIR/100_dump.sanitized.sql"
RAW_DUMP="$TMP_DIR/100_dump.sql"

log(){ printf "\n\033[1;32m[run_all]\033[0m %s\n" "$*"; }
die(){ echo "❌ $*" >&2; exit 1; }

sudo mkdir -p "$APP_DIR" "$TMP_DIR" "$APP_DIR/configs/Database" "$APP_DIR/views" "$APP_DIR/logs"
sudo chown -R "$USER":"$USER" "$APP_DIR"

cd "$APP_DIR"

# ---------- 0) .env (absolute path; LLM paths unchanged) ----------
log "Writing $ENV_FILE (LLM paths kept intact)…"
sudo tee "$ENV_FILE" >/dev/null <<'EOF'
AWS_REGION=us-east-1
AWS_DEFAULT_REGION=us-east-1

# absolute paths so OmegaConf can load them
LLM_CONFIG_PATH=/opt/WarehouseManagerAI/configs/llm_config.yaml
DATABASE_CONFIG_PATH=/opt/WarehouseManagerAI/configs/Database/postgresql.yaml
EMBEDDINGS_CONFIG_PATH=/opt/WarehouseManagerAI/configs/Embeddings/pinecone.yaml

# DB + S3
POSTGRES_DB=warehouse
POSTGRES_USER=app
POSTGRES_PASSWORD=app_pw
DB_PORT=5432
S3_BUCKET=scotch-sampledata
S3_KEY=vip_tables_20250623.sql
# OPTIONAL if object is private (set before running):
# export S3_PRESIGNED_URL=$(aws s3 presign s3://scotch-sampledata/vip_tables_20250623.sql --expires-in 3600)
# S3_PRESIGNED_URL=
EOF
sudo chown "$USER":"$USER" "$ENV_FILE"
set -a; source "$ENV_FILE"; set +a

# ---------- 1) DB config YAML ----------
log "Writing configs/Database/postgresql.yaml…"
cat > "$APP_DIR/configs/Database/postgresql.yaml" <<'YAML'
driver: postgresql
host: localhost
port: 5432
database: warehouse
username: app
password: app_pw
sqlalchemy_url: postgresql://app:app_pw@localhost:5432/warehouse
YAML

# ---------- 2) Idempotent views (safe for reruns) ----------
log "Writing views/999_app_views.sql…"
cat > "$APP_DIR/views/999_app_views.sql" <<'SQL'
-- Idempotent views; safe to re-run
CREATE EXTENSION IF NOT EXISTS vector;

DROP VIEW IF EXISTS app_inventory CASCADE;
DROP VIEW IF EXISTS app_vip_items CASCADE;
DROP VIEW IF EXISTS app_vip_products CASCADE;
DROP VIEW IF EXISTS app_vip_brands CASCADE;
DROP VIEW IF EXISTS app_vip_suppliers CASCADE;

DO $$
DECLARE
  has_store_col  boolean := EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vip_items' AND column_name='store'
  );
  has_source_id  boolean := EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vip_items' AND column_name='vip_source_id'
  );
  store_expr text;
BEGIN
  IF has_store_col THEN
    EXECUTE 'CREATE OR REPLACE VIEW app_vip_items AS SELECT * FROM vip_items';
    RETURN;
  END IF;

  IF has_source_id THEN
    store_expr := '(''source_'' || i.vip_source_id::text)';
  ELSE
    store_expr := 'NULL::text';
  END IF;

  EXECUTE format($f$
    CREATE OR REPLACE VIEW app_vip_items AS
    SELECT i.*, %s AS store
    FROM vip_items i
  $f$, store_expr);
END $$;

CREATE OR REPLACE VIEW app_vip_products AS
SELECT p.*,
       COALESCE(NULLIF(TRIM(p.consumer_product_name), ''),
                NULLIF(TRIM(p.product_name), ''),
                NULLIF(TRIM(p.product_short_name), ''),
                NULLIF(TRIM(p.fanciful_name), ''),
                'Unknown')::text AS app_product_name
FROM vip_products p;

CREATE OR REPLACE VIEW app_vip_brands AS
SELECT b.*,
       COALESCE(NULLIF(TRIM(b.consumer_brand_name), ''),
                NULLIF(TRIM(b.brand_name), ''),
                NULLIF(TRIM(b.brand_short_name), ''),
                'Unknown')::text AS app_brand_name
FROM vip_brands b;

CREATE OR REPLACE VIEW app_vip_suppliers AS SELECT * FROM vip_suppliers;

CREATE OR REPLACE VIEW app_inventory AS
SELECT
  i.*,
  p.app_product_name AS product_name,
  b.app_brand_name   AS brand_name
FROM app_vip_items i
JOIN app_vip_products p ON p.vip_product_id = i.vip_product_id
JOIN app_vip_brands   b ON b.vip_brand_id   = p.vip_brand_id;
SQL

# ---------- 3) DB adapters (no LLM changes) ----------
mkdir -p "$APP_DIR/src/database"
cat > "$APP_DIR/src/database/Postgres.py" <<'PY'
from __future__ import annotations
import os
import pandas as pd
from sqlalchemy import create_engine, text

class Postgres:
    def __init__(self, url: str | None = None):
        self.url = url or os.getenv("DATABASE_URL") or os.getenv("SQLALCHEMY_DATABASE_URL")
        if not self.url:
            host = os.getenv("DB_HOST", "localhost")
            port = int(os.getenv("DB_PORT", "5432"))
            db   = os.getenv("DB_NAME", "warehouse")
            user = os.getenv("DB_USER", "app")
            pwd  = os.getenv("DB_PASS", "app_pw")
            self.url = f"postgresql://{user}:{pwd}@{host}:{port}/{db}"
        self.engine = create_engine(self.url, pool_pre_ping=True, future=True)
    def query_df(self, sql: str, params: dict | None = None) -> pd.DataFrame:
        with self.engine.connect() as conn:
            return pd.read_sql(text(sql), conn, params=params)
    def execute(self, sql: str, params: dict | None = None) -> None:
        with self.engine.begin() as conn:
            conn.execute(text(sql), params or {})
    def close(self):
        try: self.engine.dispose()
        except Exception: pass
PY

cat > "$APP_DIR/src/database/DatabaseManager.py" <<'PY'
from __future__ import annotations
import os
from .Postgres import Postgres
class DatabaseManager:
    def __init__(self, url: str | None = None):
        self._db = Postgres(url or os.getenv("DATABASE_URL"))
    def query_df(self, sql: str, params: dict | None = None): return self._db.query_df(sql, params)
    def execute(self, sql: str, params: dict | None = None): return self._db.execute(sql, params)
    def close(self): self._db.close()
    @staticmethod
    def get_database(url: str | None = None) -> Postgres: return Postgres(url or os.getenv("DATABASE_URL"))
def get_database(url: str | None = None) -> Postgres: return DatabaseManager.get_database(url)
PY

# ---------- 4) docker-compose (PG17 on 5432) ----------
log "Writing $DC_FILE (pgvector PG17, default port 5432)…"
cat > "$DC_FILE" <<'YAML'
services:
  db:
    image: pgvector/pgvector:pg17
    container_name: wm_pgvector
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 3s
      timeout: 3s
      retries: 40
    volumes:
      - db_data:/var/lib/postgresql/data
volumes:
  db_data:
YAML

# ---------- 5) Stop host postgres, start container cleanly ----------
log "Stopping any host postgres using 5432 (if present)…"
sudo systemctl stop postgresql 2>/dev/null || true
sudo systemctl stop postgresql-14 2>/dev/null || true
sudo systemctl stop postgresql-15 2>/dev/null || true
sudo systemctl stop postgresql-16 2>/dev/null || true
sudo fuser -k 5432/tcp 2>/dev/null || true

log "Starting DB with docker-compose…"
docker-compose -f "$DC_FILE" up -d || true
sleep 2

STATUS="$(docker inspect -f '{{.State.Status}}' wm_pgvector 2>/dev/null || echo not-found)"
if [ "$STATUS" != "running" ]; then
  log "DB container state: $STATUS. Recreating data volume to clear mismatches…"
  docker-compose -f "$DC_FILE" down
  DB_VOL="$(docker volume ls --format '{{.Name}}' | grep -E 'db_data$' || true)"
  [ -n "$DB_VOL" ] && docker volume rm "$DB_VOL"
  docker-compose -f "$DC_FILE" up -d
fi

log "Waiting for Postgres to be ready on 5432…"
until docker exec wm_pgvector pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do sleep 1; done
log "Postgres is ready."

# ---------- 6) Download dump on HOST ----------
log "Downloading SQL dump on host…"
if [ -n "${S3_PRESIGNED_URL:-}" ]; then
  curl -fsSL "$S3_PRESIGNED_URL" -o "$RAW_DUMP"
else
  aws s3 cp "s3://${S3_BUCKET}/${S3_KEY}" "$RAW_DUMP" --region "$AWS_REGION"
fi
ls -lh "$RAW_DUMP"

# ---------- 7) Sanitize dump (fail-safe) ----------
log "Sanitizing dump (removing PG-version GUCs, crunchy roles, noisy grants/owners)…"
# Remove any timeout GUCs (transaction_timeout, idle_in_transaction_session_timeout, statement_timeout…)
# Remove crunchy roles/grants/owners
# Remove ALTER OWNER/GRANT/REVOKE lines that may reference unknown roles
sed -E \
  -e "/^[[:space:]]*SET[[:space:]]+[a-z_]*timeout[[:space:]]*=/Id" \
  -e "/pg_catalog\.set_config\('.*timeout'/Id" \
  -e "/CRUNCHY|crunchy_/Id" \
  -e "/^[[:space:]]*ALTER[[:space:]]+(TABLE|SEQUENCE|VIEW|FUNCTION|SCHEMA)[[:space:]].*OWNER TO[[:space:]]/Id" \
  -e "/^[[:space:]]*(GRANT|REVOKE)[[:space:]]+/Id" \
  "$RAW_DUMP" > "$SANITIZED"

# Prepend a preamble that guarantees a clean DB and schema
PREAMBLE="$TMP_DIR/00_preamble.sql"
cat > "$PREAMBLE" <<SQL
SET client_min_messages = warning;
-- Drop and recreate the target DB to guarantee a clean slate
-- (do this from the 'postgres' db)
SQL

log "Recreating database (clean)…"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${POSTGRES_DB}';"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c \
  "DROP DATABASE IF EXISTS ${POSTGRES_DB};"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c \
  "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};"

# Ensure clean public schema, extension and ownership BEFORE load
log "Preparing schema and extensions…"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
  "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA IF NOT EXISTS public AUTHORIZATION ${POSTGRES_USER}; GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
  "CREATE EXTENSION IF NOT EXISTS vector;"

# ---------- 8) Load sanitized dump ----------
log "Loading sanitized dump (this can take a while)…"
docker cp "$SANITIZED" wm_pgvector:/tmp/100_dump.sanitized.sql
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" --single-transaction -v ON_ERROR_STOP=1 \
  -f /tmp/100_dump.sanitized.sql

# ---------- 9) Apply idempotent views ----------
log "Applying app_* views (idempotent)…"
docker cp "$APP_DIR/views/999_app_views.sql" wm_pgvector:/tmp/999_app_views.sql
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /tmp/999_app_views.sql

# ---------- 10) Verify ----------
log "Verifying objects and sampling rows…"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
  "SELECT to_regclass('public.vip_items') AS vip_items, to_regclass('public.app_vip_items') AS app_vip_items, to_regclass('public.app_inventory') AS app_inventory;"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
  "SELECT COUNT(*) AS items FROM app_vip_items;"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wm_pgvector \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
  "SELECT store, product_name, brand_name FROM app_inventory LIMIT 10;"

# remove host dump to save space
rm -f "$RAW_DUMP" "$SANITIZED" 2>/dev/null || true

# ---------- 11) Host venv + Streamlit (background) ----------
log "Preparing host venv for Streamlit…"
if [ ! -d "$APP_DIR/.venv" ]; then sudo python3 -m venv "$APP_DIR/.venv"; fi
sudo "$APP_DIR/.venv/bin/pip" install --upgrade pip >/dev/null
if [ -f "$APP_DIR/requirements.txt" ]; then
  sudo "$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"
else
  sudo "$APP_DIR/.venv/bin/pip" install SQLAlchemy>=2.0 psycopg2-binary>=2.9 pandas omegaconf streamlit boto3
fi

export DATA_BACKEND=postgres
export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${DB_PORT}/${POSTGRES_DB}"
export SQLALCHEMY_DATABASE_URL="$DATABASE_URL"

log "Launching Streamlit on 0.0.0.0:8501 (background)…"
nohup sudo -E "$APP_DIR/.venv/bin/streamlit" run ui/streamlit_ui.py \
  --server.port=8501 --server.address=0.0.0.0 \
  > "$APP_DIR/logs/streamlit.log" 2>&1 &

log "Streamlit PID: $!"
log "Open:  http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo localhost):8501"
log "Tail:  tail -f $APP_DIR/logs/streamlit.log"

