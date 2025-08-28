from __future__ import annotations
from typing import List, Any
from src.llm.tool_runner import run_with_tools

class ToolEnabledLLM:
    """Drop-in object for ModelManager.llm that answers via the tool-enabled SQL chain."""
    def provide_information(self, user_request: str, chat_history: List[Any]):
        return run_with_tools(user_request)
