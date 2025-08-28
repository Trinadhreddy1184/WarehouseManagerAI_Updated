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
