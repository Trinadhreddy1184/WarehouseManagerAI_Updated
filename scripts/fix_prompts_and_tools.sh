#!/usr/bin/env bash
set -euo pipefail
APP=/opt/WarehouseManagerAI
cd "$APP"

echo "== 0) Where are prompts coming from?"
echo "[grep configs + code for prompt references]"
grep -RniE "prompts/|agent_prompt|information_provider|system.*\.md|prompt.*file|prompt.*path" configs src ui || true
echo

echo "== 1) Update ALL candidate prompt files (root + src) with PG instructions"
mkdir -p prompts src/prompts

cat > prompts/agent_prompt_template.txt <<'TXT'
# Agent Instruction (Liquor and Wine Store / SQL)
You are a Liquor and Wine Store inventory assistant that MUST use the SQL tool to answer.
The database is PostgreSQL and exposes the following read-only view:
- app_inventory (items joined with product and brand names).

Rules:
- READ-ONLY: never CREATE/ALTER/DROP/GRANT/etc.
- Use LIMIT <= 10 for previews.
- For “how many” questions, use COUNT(*).
- If a query returns no rows, say so and suggest removing overly strict filters.

Examples:
- Total items → SELECT COUNT(*) AS total_items FROM app_inventory;
- Sample rows → SELECT store, product_name, brand_name FROM app_inventory LIMIT 10;
- Top brands  → SELECT brand_name, COUNT(*) AS items
                FROM app_inventory GROUP BY brand_name
                ORDER BY items DESC LIMIT 5;
TXT

cp prompts/agent_prompt_template.txt src/prompts/agent_prompt_template.txt

cat > prompts/information_provider_template.txt <<'TXT'
Use the SQL tool to query the liquor and wine store inventory in PostgreSQL.
Query ONLY this view: app_inventory.
Never reference S3, CSV or DuckDB. Always LIMIT for preview outputs.

Snippets:
- SELECT COUNT(*) FROM app_inventory;
- SELECT store, product_name, brand_name FROM app_inventory LIMIT 10;
- SELECT brand_name, COUNT(*) items FROM app_inventory
  GROUP BY brand_name ORDER BY items DESC LIMIT 10;
TXT

cp prompts/information_provider_template.txt src/prompts/information_provider_template.txt

# Optional system prompts some templates use
mkdir -p configs/prompts
cat > configs/prompts/system.md <<'MD'
You are the Liquor and Wine Store inventory assistant for a PostgreSQL database.
Answer by querying the database through the SQL tool. Do not mention S3, CSVs, or DuckDB.

Use ONLY this read-only view:
- app_inventory = items JOIN products JOIN brands
  Columns include: store, product_name, brand_name, …

Rules: read-only; LIMIT for previews; include store in filters/grouping if the question is store-specific.
MD

cat > configs/prompts/sql_tool.md <<'MD'
Use the SQL tool to query PostgreSQL.
Query ONLY: app_inventory.
Never reference S3/CSV/DuckDB. Always LIMIT for examples.
MD

echo "== 2) Register a simple read-only SQL tool (backed by DatabaseManager) =="
mkdir -p src/tools
# Keep existing file if already present; otherwise create/overwrite with safe version
cat > src/tools/sql_tool.py <<'PY'
from __future__ import annotations
from typing import Optional, Mapping, Any
import pandas as pd
from sqlalchemy.exc import SQLAlchemyError
from src.database.DatabaseManager import get_database

def _guard_readonly(sql: str) -> None:
    s = " " + sql.strip().lower() + " "
    if not s.lstrip().startswith("select "):
        raise ValueError("Only SELECT statements are allowed.")
    for tok in (";--", "/*", "*/", " drop ", " alter ", " create ", " grant ", " revoke ", " insert ", " update ", " delete "):
        if tok in s:
            raise ValueError("Only read-only queries are permitted.")

def sql_query(sql: str, params: Optional[Mapping[str, Any]] = None) -> pd.DataFrame:
    _guard_readonly(sql)
    db = get_database()
    try:
        return db.query_df(sql, params=params)
    except SQLAlchemyError as e:
        raise RuntimeError(f"SQL execution failed: {e}") from e

def sql_scalar(sql: str, params: Optional[Mapping[str, Any]] = None) -> Any:
    df = sql_query(sql, params)
    return None if df.empty else df.iat[0,0]
PY

mkdir -p src/agents
cat > src/agents/tools_registry.py <<'PY'
from __future__ import annotations
from typing import Dict, Any, Callable
from src.tools.sql_tool import sql_query, sql_scalar

TOOLS: Dict[str, Dict[str, Any]] = {
    "sql": {
        "description": "Run a read-only SELECT against PostgreSQL app_* views.",
        "func": sql_query,
    },
    "sql_scalar": {
        "description": "Run a read-only SELECT and return a single value.",
        "func": sql_scalar,
    },
}

def get_tool(name: str) -> Callable[..., Any]:
    return TOOLS[name]["func"]
PY

echo "== 3) Make sure ProductLookupAgent exports the expected class (compat) =="
cat > src/agents/ProductLookupAgent.py <<'PY'
from __future__ import annotations
from dataclasses import dataclass
from typing import Optional
import pandas as pd
from src.tools.sql_tool import sql_query

def find_products(q: Optional[str] = None, limit: int = 10) -> pd.DataFrame:
    limit = max(1, int(limit))
    if q:
        q_esc = q.replace("'", "''")
        sql = f"""
        SELECT store, product_name, brand_name
        FROM app_inventory
        WHERE product_name ILIKE '%{q_esc}%'
           OR brand_name   ILIKE '%{q_esc}%'
        LIMIT {limit}
        """
    else:
        sql = f"SELECT store, product_name, brand_name FROM app_inventory LIMIT {limit}"
    return sql_query(sql)

@dataclass
class ProductLookupAgent:
    @staticmethod
    def search(q: Optional[str] = None, limit: int = 10) -> pd.DataFrame:
        return find_products(q=q, limit=limit)

def product_lookup(q: Optional[str] = None, limit: int = 10) -> pd.DataFrame:
    return find_products(q=q, limit=limit)

__all__ = ["ProductLookupAgent", "find_products", "product_lookup"]
PY

# Re-export (helps some imports)
if ! grep -q "ProductLookupAgent" src/agents/__init__.py 2>/dev/null; then
  echo "from .ProductLookupAgent import ProductLookupAgent, find_products, product_lookup" >> src/agents/__init__.py
fi

echo "== 4) Remove legacy references (should print nothing)"
grep -RniE "duckdb|read_csv_auto|s3://|\\.csv([^a-zA-Z]|$)|warehouse\\.get_warehouse" src prompts || true

echo "== 5) Clear __pycache__ and restart Streamlit with env preserved"
find src -name "__pycache__" -type d -exec rm -rf {} + || true
pkill -f "streamlit.*ui/streamlit_ui.py" || true
set -a; source .env; set +a
export DATA_BACKEND=postgres
export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${DB_PORT}/${POSTGRES_DB}"
export SQLALCHEMY_DATABASE_URL="$DATABASE_URL"
nohup sudo -E .venv/bin/streamlit run ui/streamlit_ui.py \
  --server.port=8501 --server.address=0.0.0.0 > logs/streamlit.log 2>&1 &
echo "UI: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo localhost):8501"
