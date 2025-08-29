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
        match config.llm.llm_tag:
            case LLMTag.BEDROCK:
                return ModelManager(config, Bedrock(config))
            # case LLMTag.OPENAI:
            #     return ModelManager(config, OpenAIModel(config))
            case _:
                raise ValueError(f"Invalid LLM tag: {config.llm.llm_tag}")

    def provide_information(
        self,
        user_request: str,
        chat_history: Optional[List[Dict[str, Any]]] = None
    ) -> str:
        return self.llm.provide_information(user_request, chat_history or [])
