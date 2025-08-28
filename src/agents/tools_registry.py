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
