from __future__ import annotations

from typing import List, Dict, Any, Optional

from src.config_defs.llm_config_defs import LLMTag, LLMMainConfig
from src.llm.ModelBase import ModelBase
from src.llm.BedrockModel import Bedrock
# from .OpenAIModel import OpenAIModel  # enable if you support OpenAI too

class ModelManager:
    def __init__(self, config: LLMMainConfig, llm: ModelBase):
        self.config = config
        self.llm = llm

    @staticmethod
    def new_instance_from_config(config: LLMMainConfig) -> "ModelManager":
        """Create a new ``ModelManager`` based on the provided configuration.

        The previous implementation used Python's ``match`` statement, which is
        only available from Python 3.10 onwards.  This caused a ``SyntaxError``
        when running the code in environments that rely on older Python
        versions, such as 3.9.  To maintain compatibility, the pattern matching
        has been rewritten using standard ``if``/``elif`` logic.
        """
        tag = config.llm.llm_tag
        if tag == LLMTag.BEDROCK:
            return ModelManager(config, Bedrock(config))
        # elif tag == LLMTag.OPENAI:
        #     return ModelManager(config, OpenAIModel(config))
        else:
            raise ValueError(f"Invalid LLM tag: {tag}")

    def provide_information(
        self,
        user_request: str,
        chat_history: Optional[List[Dict[str, Any]]] = None
    ) -> str:
        return self.llm.provide_information(user_request, chat_history or [])
