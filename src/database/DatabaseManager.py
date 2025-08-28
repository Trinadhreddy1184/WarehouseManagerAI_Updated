from __future__ import annotations
import os
from .Postgres import Postgres
class DatabaseManager:
    def __init__(self, url: str | None = None):
        self._db = Postgres(url or os.getenv("DATABASE_URL"))
    def query_df(self, sql: str, params: dict | None = None): return self._db.query_df(sql, params)
    def execute(self, sql: str, params: dict | None = None): return self._db.execute(sql, params)
    def close(self): self._db.close()
    @staticmethod
    def get_database(url: str | None = None) -> Postgres: return Postgres(url or os.getenv("DATABASE_URL"))
def get_database(url: str | None = None) -> Postgres: return DatabaseManager.get_database(url)
