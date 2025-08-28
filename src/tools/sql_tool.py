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
    import os
    if os.getenv('WM_DEBUG_SQL'):
        print(f"[SQL] {sql.strip()}")
    _guard_readonly(sql)
    db = get_database()
    try:
        return db.query_df(sql, params=params)
    except SQLAlchemyError as e:
        raise RuntimeError(f"SQL execution failed: {e}") from e

def sql_scalar(sql: str, params: Optional[Mapping[str, Any]] = None) -> Any:
    df = sql_query(sql, params)
    return None if df.empty else df.iat[0,0]
