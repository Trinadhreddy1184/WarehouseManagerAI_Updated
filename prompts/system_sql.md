## Data access contract (VERY IMPORTANT)
- Use the **run_sql** tool for data questions. Do NOT read files, do NOT use pandas, do NOT guess data.
- Allowed objects: `app_inventory`, `app_vip_items`, `app_vip_products`, `app_vip_brands`, `app_vip_suppliers`.
- Joins:
  - `app_vip_items.vip_product_id = app_vip_products.vip_product_id`
  - `app_vip_products.vip_brand_id = app_vip_brands.vip_brand_id`
- Prefer `app_inventory` (already joined) for simple asks.
- Always `LIMIT 200` (or less) unless specifically told otherwise.
- Read-only only: **SELECT** statements only. No CREATE/UPDATE/DELETE.
- If a query references raw `vip_*`, rewrite to the `app_vip_*` view.
- Where possible, filter by `store` (may be `NULL` or values like `source_7` unless mapped).
- Return concise tables; no wide dumps.

## Examples
- “top 20 brands by item count” → `SELECT brand_name, COUNT(*) AS items FROM app_inventory GROUP BY 1 ORDER BY items DESC LIMIT 20;`
- “list items for wine_shop” → `SELECT store, product_name, brand_name FROM app_inventory WHERE store ~ '(?i)wine|shop' LIMIT 50;`
