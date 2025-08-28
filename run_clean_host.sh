#!/usr/bin/env bash
# ============================================================
# Clean stop + Host-run UI + Docker DB on REGULAR PORTS
#   - DB: 5432 (host)
#   - Streamlit: 8501
#   - AWS: host creds/role
#   - LLM config paths kept exactly as provided
# ============================================================
set -euo pipefail

APP_DIR="/opt/WarehouseManagerAI"
cd "$APP_DIR"

echo "== 0) Kill host processes & stop/remove containers (non-destructive) =="
# stop host Streamlit/uvicorn if any
pkill -f "streamlit run"     2>/dev/null || true
pkill -f "ui/streamlit_ui.py" 2>/dev/null || true
pkill -f "uvicorn"           2>/dev/null || true
pkill -f "gunicorn"          2>/dev/null || true

# bring down any compose stacks in this dir (keeps volumes)
docker-compose down || true
# stop/remove stray containers (keep volumes/images)
docker ps -q | xargs -r docker stop || true
docker ps -aq | xargs -r docker rm || true

# if host has a local postgres on 5432, stop it so we can bind Docker to 5432
sudo systemctl stop postgresql 2>/dev/null || true
sudo systemctl stop postgresql-14 2>/dev/null || true
sudo systemctl stop postgresql-15 2>/dev/null || true

echo "== 1) Ensure .env with regular ports & your absolute config paths =="
cat > .env <<'EOF'
AWS_REGION=us-east-1
AWS_DEFAULT_REGION=us-east-1

# absolute paths so OmegaConf can load them (unchanged)
LLM_CONFIG_PATH=/opt/WarehouseManagerAI/configs/llm_config.yaml
DATABASE_CONFIG_PATH=/opt/WarehouseManagerAI/configs/Database/postgresql.yaml
EMBEDDINGS_CONFIG_PATH=/opt/WarehouseManagerAI/configs/Embeddings/pinecone.yaml

# DB on regular port
POSTGRES_DB=warehouse
POSTGRES_USER=app
POSTGRES_PASSWORD=app_pw
DB_PORT=5432

# S3 dump location (host AWS CLI will use these)
S3_BUCKET=scotch-sampledata
S3_KEY=vip_tables_20250623.sql
# Optional: export S3_PRESIGNED_URL=<url> before running if object is private
EOF

# export for this shell (so we can use sudo -E later)
set -a; source .env; set +a

echo "== 2) DB client config file the app already uses (host: localhost:5432) =="
mkdir -p configs/Database
cat > configs/Database/postgresql.yaml <<'YAML'
driver: postgresql
host: localhost
port: 5432
database: warehouse
username: app
password: app_pw
sqlalchemy_url: postgresql://app:app_pw@localhost:5432/warehouse
YAML

echo "== 3) Views (idempotent; includes app_inventory) =="
mkdir -p views
cat > views/999_app_views.sql <<'SQL'
DROP VIEW IF EXISTS app_inventory CASCADE;
DROP VIEW IF EXISTS app_vip_items CASCADE;
DROP VIEW IF EXISTS app_vip_products CASCADE;
DROP VIEW IF EXISTS app_vip_brands CASCADE;
DROP VIEW IF EXISTS app_vip_suppliers CASCADE;

CREATE EXTENSION IF NOT EXISTS vector;

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

echo "== 4) Minimal compose for DB (regular 5432 on host) =="
cat > docker-compose.yml <<'YAML'
services:
  db:
    image: pgvector/pgvector:pg16
    container_name: wm_pgvector
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "${DB_PORT}:5432"
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

echo "== 5) Bring up DB on 5432 and wait for health =="
docker-compose up -d db
until docker-compose exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  sleep 1
done

echo "== 6) Download SQL dump on host via AWS CLI (uses your role/profile) =="
mkdir -p seed
TMP_DUMP="seed/100_dump.sql"
if [ -n "${S3_PRESIGNED_URL:-}" ]; then
  echo "Using presigned URL…"
  curl -fsSL "$S3_PRESIGNED_URL" -o "$TMP_DUMP"
else
  echo "Using aws s3 cp…"
  aws sts get-caller-identity >/dev/null
  aws s3 cp "s3://${S3_BUCKET}/${S3_KEY}" "$TMP_DUMP" --region "$AWS_REGION"
fi
ls -lh "$TMP_DUMP"

echo "== 7) Load dump if base tables missing; always (re)create views =="
HAS_VIP_ITEMS=$(docker-compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT to_regclass('public.vip_items') IS NOT NULL")
if [ "$HAS_VIP_ITEMS" != "t" ]; then
  echo "vip_items not found -> loading dump… (this may take a while)"
  cat "$TMP_DUMP" | docker-compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1
else
  echo "vip_items exists -> skipping dump load."
fi

echo "Applying app_* views…"
docker-compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<'SQL'
\set ON_ERROR_STOP on
DROP VIEW IF EXISTS app_inventory CASCADE;
DROP VIEW IF EXISTS app_vip_items CASCADE;
DROP VIEW IF EXISTS app_vip_products CASCADE;
DROP VIEW IF EXISTS app_vip_brands CASCADE;
DROP VIEW IF EXISTS app_vip_suppliers CASCADE;
CREATE EXTENSION IF NOT EXISTS vector;
DO $$
DECLARE has_store_col boolean := EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='vip_items' AND column_name='store');
        has_source_id boolean := EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='vip_items' AND column_name='vip_source_id');
        store_expr text;
BEGIN
  IF has_store_col THEN
    EXECUTE 'CREATE OR REPLACE VIEW app_vip_items AS SELECT * FROM vip_items';
  ELSE
    store_expr := CASE WHEN has_source_id THEN '(''source_'' || i.vip_source_id::text)' ELSE 'NULL::text' END;
    EXECUTE format($f$ CREATE OR REPLACE VIEW app_vip_items AS SELECT i.*, %s AS store FROM vip_items i $f$, store_expr);
  END IF;
END $$;
CREATE OR REPLACE VIEW app_vip_products AS
SELECT p.*, COALESCE(NULLIF(TRIM(p.consumer_product_name), ''), NULLIF(TRIM(p.product_name), ''), NULLIF(TRIM(p.product_short_name), ''), NULLIF(TRIM(p.fanciful_name), ''), 'Unknown')::text AS app_product_name FROM vip_products p;
CREATE OR REPLACE VIEW app_vip_brands AS
SELECT b.*, COALESCE(NULLIF(TRIM(b.consumer_brand_name), ''), NULLIF(TRIM(b.brand_name), ''), NULLIF(TRIM(b.brand_short_name), ''), 'Unknown')::text AS app_brand_name FROM vip_brands b;
CREATE OR REPLACE VIEW app_vip_suppliers AS SELECT * FROM vip_suppliers;
CREATE OR REPLACE VIEW app_inventory AS
SELECT i.*, p.app_product_name AS product_name, b.app_brand_name AS brand_name
FROM app_vip_items i
JOIN app_vip_products p ON p.vip_product_id = i.vip_product_id
JOIN app_vip_brands   b ON b.vip_brand_id   = p.vip_brand_id;
SQL

echo "== 8) Verify DB objects on 5432 =="
docker-compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
"SELECT to_regclass('public.app_vip_items') AS app_vip_items, to_regclass('public.app_inventory') AS app_inventory;"
docker-compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
"SELECT COUNT(*) AS items FROM app_vip_items;"
docker-compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
"SELECT store, product_name, brand_name FROM app_inventory LIMIT 5;"

echo "== 9) Clean the downloaded dump to save space (safe) =="
rm -f "$TMP_DUMP" || true

echo "== 10) Host venv for Streamlit / DB libs =="
python3 -m venv .venv 2>/dev/null || true
source .venv/bin/activate
pip install -q --upgrade pip
pip install -q "SQLAlchemy>=2.0" "psycopg2-binary>=2.9" pandas omegaconf streamlit

echo "== 11) Run Streamlit on host (LLM + AWS creds on host; DB at localhost:5432) =="
export DATA_BACKEND=postgres
export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${DB_PORT}/${POSTGRES_DB}"

echo "Open http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo localhost):8501"
# preserve env/AWS for root process; keep HOME so ~/.aws is visible
sudo -E env "PATH=$PATH" "HOME=$HOME" \
  DATA_BACKEND="$DATA_BACKEND" \
  DATABASE_URL="$DATABASE_URL" \
  LLM_CONFIG_PATH="$LLM_CONFIG_PATH" \
  DATABASE_CONFIG_PATH="$DATABASE_CONFIG_PATH" \
  EMBEDDINGS_CONFIG_PATH="$EMBEDDINGS_CONFIG_PATH" \
  AWS_REGION="$AWS_REGION" AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
  streamlit run ui/streamlit_ui.py --server.port=8501 --server.address=0.0.0.0

