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
