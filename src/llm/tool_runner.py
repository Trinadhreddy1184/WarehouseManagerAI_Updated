from __future__ import annotations
import os
from pathlib import Path
from typing import Any, List

from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_core.tools import Tool

from src.tools.sql_tool import sql_query, sql_scalar

def _system_prompt() -> str:
    p = Path("/opt/WarehouseManagerAI/configs/prompts/system.md")
    if p.exists():
        return p.read_text(encoding="utf-8")
    return (
        "You are a Liquor and Wine Store inventory assistant with SQL tools over PostgreSQL. "
        "Use ONLY app_vip_items, app_vip_products, app_vip_brands, app_inventory. "
        "Read-only queries; use LIMIT for previews."
    )

def _try_bedrock():
    try:
        from langchain_aws import ChatBedrock
        model_id = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
        region = os.getenv("AWS_REGION", "us-east-1")
        return ChatBedrock(model_id=model_id, region_name=region)
    except Exception:
        return None

def _get_model():
    # Try Bedrock; if unavailable fall back to rule-based answers
    m = _try_bedrock()
    if m is not None:
        return m
    return None

def _tools():
    return [
        Tool.from_function(
            name="sql",
            description="Run a read-only SELECT against PostgreSQL app_* views.",
            func=sql_query,
        ),
        Tool.from_function(
            name="sql_scalar",
            description="Run a read-only SELECT and return a single value.",
            func=sql_scalar,
        ),
    ]

def _rule_based_fallback(question: str) -> str:
    """
    If no LLM provider is available, answer common queries directly via SQL.
    Keeps the app usable and avoids crashes.
    """
    q = (question or "").lower()
    if "how many" in q and ("items" in q or "records" in q or "rows" in q):
        n = sql_scalar("SELECT COUNT(*) FROM app_vip_items")
        return f"Total items: {int(n)}"
    if "top" in q and "brand" in q:
        df = sql_query("""
            SELECT brand_name, COUNT(*) AS items
            FROM app_inventory
            GROUP BY brand_name
            ORDER BY items DESC
            LIMIT 5
        """)
        return df.to_string(index=False)
    # default small preview
    df = sql_query("SELECT store, product_name, brand_name FROM app_inventory LIMIT 5")
    return df.to_string(index=False)

def run_with_tools(question: str) -> str:
    """
    Preferred path: tool-enabled LLM. If no provider available, safe rule-based fallback.
    """
    model = _get_model()
    if model is None:
        return _rule_based_fallback(question)

    prompt = ChatPromptTemplate.from_messages([
        ("system", _system_prompt()),
        ("human", "{input}")
    ])
    chain = prompt | model.bind_tools(_tools()) | StrOutputParser()
    return chain.invoke({"input": question})
