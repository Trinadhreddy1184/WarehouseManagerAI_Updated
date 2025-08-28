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
