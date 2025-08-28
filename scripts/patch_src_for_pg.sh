#!/usr/bin/env bash
set -euo pipefail
APP=/opt/WarehouseManagerAI
cd "$APP"

echo "==> Ensure prompt folder"
mkdir -p configs/prompts

echo "==> Write PG-first system prompts (new files)"
cat > configs/prompts/system.md <<'MD'
You are the Inventory Management assistant for a PostgreSQL data warehouse.
Answer by querying the database through the SQL tool. Do not mention S3, CSVs, or DuckDB.

Use ONLY these read-only views:
- app_vip_items    (includes store if present)
- app_vip_products (includes app_product_name TEXT)
- app_vip_brands   (includes app_brand_name   TEXT)
- app_vip_suppliers
- app_inventory = app_vip_items JOIN app_vip_products JOIN app_vip_brands
  Columns include: store, product_name, brand_name, …

Rules:
- READ-ONLY: Never CREATE/ALTER/DROP/GRANT.
- For samples, always LIMIT ≤ 10.
- Prefer app_inventory when you need item names/brands.
- When a question is store-specific, include store in GROUP BY / filters.

Examples:
- Total items → SELECT COUNT(*) AS total_items FROM app_vip_items;
- Top brands → SELECT brand_name, COUNT(*) AS items
               FROM app_inventory GROUP BY brand_name
               ORDER BY items DESC LIMIT 5;
- Sample inventory rows → SELECT store, product_name, brand_name
                          FROM app_inventory LIMIT 10;
If a query returns no rows, say so and suggest a nearby alternative (e.g., remove store filter).
MD

cat > configs/prompts/sql_tool.md <<'MD'
You have a SQL tool connected to PostgreSQL.
- Query only app_vip_items, app_vip_products, app_vip_brands, app_inventory.
- Never reference raw vip_* tables or S3/CSV/DuckDB.
- Always LIMIT for previews.

Snippets:
- SELECT COUNT(*) FROM app_vip_items;
- SELECT store, product_name, brand_name FROM app_inventory LIMIT 10;
- SELECT brand_name, COUNT(*) items FROM app_inventory
  GROUP BY brand_name ORDER BY items DESC LIMIT 10;
MD

echo "==> Patch src/prompts templates (remove legacy references)"
mkdir -p src/prompts
if [ -f src/prompts/agent_prompt_template.txt ]; then cp -n src/prompts/agent_prompt_template.txt src/prompts/agent_prompt_template.txt.bak; fi
cat > src/prompts/agent_prompt_template.txt <<'TXT'
# Agent Instruction (Inventory / SQL)
You are an Inventory Management assistant that MUST use the SQL tool to answer.
The database is PostgreSQL and exposes the following views:
- app_vip_items, app_vip_products, app_vip_brands, app_vip_suppliers, app_inventory.

Guidelines:
- Read-only queries only.
- Prefer app_inventory for items with names/brands.
- Use LIMIT <= 10 when previewing.
- If asked "how many", use COUNT(*).

Examples:
- "How many items?" → SELECT COUNT(*) AS total_items FROM app_vip_items;
- "Show a few items" → SELECT store, product_name, brand_name FROM app_inventory LIMIT 10;
TXT

if [ -f src/prompts/information_provider_template.txt ]; then cp -n src/prompts/information_provider_template.txt src/prompts/information_provider_template.txt.bak; fi
cat > src/prompts/information_provider_template.txt <<'TXT'
When you need data, call the SQL tool with a SELECT statement against:
- app_vip_items, app_vip_products, app_vip_brands, app_inventory.
Never reference S3, CSV, or DuckDB sources. Keep results concise, use LIMIT for samples.
TXT

echo "==> Ensure Database shim is used by tools"
mkdir -p src/tools
if [ -f src/tools/sql_tool.py ]; then cp -n src/tools/sql_tool.py src/tools/sql_tool.py.bak; fi
cat > src/tools/sql_tool.py <<'PY'
from __future__ import annotations
from typing import Optional, Mapping, Any
import pandas as pd
from sqlalchemy.exc import SQLAlchemyError
from src.database.DatabaseManager import get_database

def _guard_readonly(sql: str) -> None:
    bad = (";--", "/*", "*/", " drop ", " alter ", " create ", " grant ", " revoke ", " insert ", " update ", " delete ")
    s = " " + sql.strip().lower() + " "
    if not s.lstrip().startswith("select "):
        raise ValueError("Only SELECT statements are allowed.")
    if any(tok in s for tok in bad):
        raise ValueError("Only read-only SELECT queries are permitted.")

def sql_query(sql: str, params: Optional[Mapping[str, Any]] = None) -> pd.DataFrame:
    """Execute a read-only query and return a DataFrame."""
    _guard_readonly(sql)
    db = get_database()  # resolves DATABASE_URL/SQLALCHEMY_DATABASE_URL
    try:
        return db.query_df(sql, params=params)
    except SQLAlchemyError as e:
        raise RuntimeError(f"SQL execution failed: {e}") from e

def sql_scalar(sql: str, params: Optional[Mapping[str, Any]] = None) -> Any:
    """Return the first cell of the first row."""
    df = sql_query(sql, params)
    return None if df.empty else df.iat[0, 0]
PY

echo "==> Register the SQL tool in agents/tools_registry.py"
mkdir -p src/agents
if [ -f src/agents/tools_registry.py ]; then cp -n src/agents/tools_registry.py src/agents/tools_registry.py.bak; fi
cat > src/agents/tools_registry.py <<'PY'
from __future__ import annotations
from typing import Dict, Any, Callable
from src.tools.sql_tool import sql_query, sql_scalar

# Minimal registry the model runner can use to expose tools
TOOLS: Dict[str, Dict[str, Any]] = {
    "sql": {
        "description": "Run a read-only SELECT against PostgreSQL app_* views.",
        "func": sql_query,   # returns pandas DataFrame
    },
    "sql_scalar": {
        "description": "Run a read-only SELECT and return a single value.",
        "func": sql_scalar,  # returns Python scalar
    }
}

def get_tool(name: str) -> Callable[..., Any]:
    return TOOLS[name]["func"]
PY

echo "==> Update ProductLookupAgent to use app_inventory via sql tool"
if [ -f src/agents/ProductLookupAgent.py ]; then cp -n src/agents/ProductLookupAgent.py src/agents/ProductLookupAgent.py.bak; fi
cat > src/agents/ProductLookupAgent.py <<'PY'
from __future__ import annotations
import pandas as pd
from typing import Optional
from src.tools.sql_tool import sql_query

def find_products(q: Optional[str]=None, limit: int=10) -> pd.DataFrame:
    """
    Look up products/items from app_inventory.
    If q is provided, fuzzy match on product_name/brand_name.
    """
    if q:
        sql = f"""
        SELECT store, product_name, brand_name
        FROM app_inventory
        WHERE product_name ILIKE '%{q.replace("'", "''")}%'
           OR brand_name   ILIKE '%{q.replace("'", "''")}%'
        LIMIT {int(limit)}
        """
    else:
        sql = f"SELECT store, product_name, brand_name FROM app_inventory LIMIT {int(limit)}"
    return sql_query(sql)
PY

echo "==> Minimal helper in LLM to load the new prompts (non-breaking)"
mkdir -p src/llm
if [ -f src/llm/ModelManager.py ]; then cp -n src/llm/ModelManager.py src/llm/ModelManager.py.bak; fi
python - <<'PY'
from pathlib import Path
p = Path("src/llm/ModelManager.py")
if not p.exists():
    # Create a tiny stub; your existing code will override at import time if present
    p.write_text("PROMPT_DIR = '/opt/WarehouseManagerAI/configs/prompts'\n", encoding='utf-8')

s = p.read_text(encoding='utf-8')
inject = '''
from pathlib import Path
PROMPT_DIR = str(Path("/opt/WarehouseManagerAI/configs/prompts"))
def _load_text(path: str) -> str:
    try: return Path(path).read_text(encoding="utf-8")
    except Exception: return ""
def build_system_prompt() -> str:
    base = _load_text(f"{PROMPT_DIR}/system.md")
    sql  = _load_text(f"{PROMPT_DIR}/sql_tool.md")
    return "\\n\\n".join([x for x in (base, sql) if x.strip()])
'''
if "build_system_prompt" not in s:
    # inject after first import block or at top
    lines = s.splitlines()
    insert_at = 0
    for i, line in enumerate(lines[:50]):
        if line.strip() == "" and i > 0:
            insert_at = i
            break
    lines.insert(insert_at, inject)
    p.write_text("\\n".join(lines), encoding="utf-8")
PY

echo "==> Final sanity greps (legacy refs)"
grep -RniE "duckdb|read_csv_auto|s3://|\.csv[^a-zA-Z]|warehouse\.get_warehouse" src || true
echo "==> Done"
