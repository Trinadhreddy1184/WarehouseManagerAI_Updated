from __future__ import annotations
from pathlib import Path
from typing import Any
from src.agents.tools_registry import TOOLS, TOOL_FUNCS

def load_system_messages() -> list[dict[str, str]]:
    # Base system content (add your project-specific instructions here)
    base = "You are the Warehouse Manager AI. Use tools when helpful."
    sql_rules = Path("prompts/system_sql.md").read_text(encoding="utf-8")
    return [{"role": "system", "content": base + "\n\n" + sql_rules}]

def get_tools() -> tuple[list[dict[str, Any]], dict[str, Any]]:
    return TOOLS, TOOL_FUNCS
