## Data access contract (VERY IMPORTANT)
- Use the **run_sql** tool for data questions. Do NOT read files, do NOT use pandas, do NOT guess data.
- Allowed object: `app_inventory`.
- Always `LIMIT 200` (or less) unless specifically told otherwise.
- Read-only only: **SELECT** statements only. No CREATE/UPDATE/DELETE.
- Where possible, filter by `store` (may be `NULL` or values like `source_7` unless mapped).
- Return concise tables; no wide dumps.

## Examples
- “top 20 brands by item count” → `SELECT brand_name, COUNT(*) AS items FROM app_inventory GROUP BY 1 ORDER BY items DESC LIMIT 20;`
- “list items for wine_shop” → `SELECT store, product_name, brand_name FROM app_inventory WHERE store ~ '(?i)wine|shop' LIMIT 50;`
