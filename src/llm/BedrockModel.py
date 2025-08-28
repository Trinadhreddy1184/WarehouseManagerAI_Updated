import warnings
import os
import json
import boto3
from botocore.config import Config

from langchain_aws import ChatBedrock
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnableLambda

from .ModelBase import ModelBase
from src.config_defs.llm_config_defs import LLMTag

warnings.filterwarnings("ignore", category=DeprecationWarning, module="langchain")


class Bedrock(ModelBase):
    """
    Unified Bedrock wrapper that:
      - Uses ChatBedrock (messages) for Anthropic Claude models
      - Uses Bedrock 'converse' (messages) for Amazon Nova models
    Exposes a single .provide_information(user_request, chat_history) API
    so the rest of the app stays unchanged.
    """

    def __init__(self, config):
        super().__init__(config)

        if config.llm.llm_tag != LLMTag.BEDROCK:
            raise ValueError("BedrockPipeline can only be used with Bedrock")
        if config.bedrock is None:
            raise ValueError("BedrockPipeline requires a BedrockConfig")

        # ---- load config ----
        region = getattr(config.bedrock, "region_name", os.getenv("AWS_REGION", "us-east-1"))
        model_id = getattr(config.bedrock, "model_id", "")

        self.temperature = float(getattr(config.llm, "temperature", 0.2))
        self.top_p       = float(getattr(config.llm, "top_p", 0.9))
        self.max_tokens  = int(getattr(config.llm, "max_tokens", 400))

        # ---- bedrock client with adaptive retries ----
        self._br = boto3.client(
            "bedrock-runtime",
            region_name=region,
            config=Config(retries={"max_attempts": 12, "mode": "adaptive"})
        )

        # ---- common chat prompt (system + history + user) ----
        self.prompt = ChatPromptTemplate.from_messages([
            ("system", "You are an inventory assistant. Be concise and factful."),
            MessagesPlaceholder("chat_history"),
            ("human", "{user_request}")
        ])

        # ---- choose path by model family ----
        if model_id.startswith("anthropic."):
            # Claude (messages) → ChatBedrock path
            self.client = ChatBedrock(
                model_id=model_id,
                client=self._br,
                model_kwargs={
                    "temperature": self.temperature,
                    "top_p": self.top_p,
                    "max_tokens": self.max_tokens,
                    "anthropic_version": "bedrock-2023-05-31",
                },
            )

        elif model_id.startswith("amazon.nova-"):
            # Nova → Bedrock 'converse' API (messages) wrapped as a Runnable,
            # so it plugs into `prompt | client | StrOutputParser()`
            def _normalize_to_role_text(x):
                """
                Accepts LangChain BaseMessage OR tuple(role,text) OR dict
                OR str; returns (role, text)
                """
                # BaseMessage?
                if hasattr(x, "type"):
                    if x.type == "human":     role = "user"
                    elif x.type == "ai":      role = "assistant"
                    elif x.type == "system":  role = "system"
                    else:                     role = "user"
                    if isinstance(x.content, str):
                        text = x.content
                    elif isinstance(x.content, list) and x.content and isinstance(x.content[0], dict):
                        text = x.content[0].get("text", str(x.content))
                    else:
                        text = str(x.content)
                    return role, text

                # ("user","hello")
                if isinstance(x, tuple) and len(x) == 2:
                    return str(x[0] or "user"), str(x[1])

                # {"role":"user","content":[{"text":"hi"}]} or {"role":"user","content":"hi"}
                if isinstance(x, dict):
                    role = str(x.get("role", "user"))
                    c = x.get("content", "")
                    if isinstance(c, str):
                        text = c
                    elif isinstance(c, list) and c and isinstance(c[0], dict):
                        text = c[0].get("text", str(c))
                    else:
                        text = str(c)
                    return role, text

                # plain string -> treat as user
                return "user", str(x)

            def _nova_runnable(messages):
                # messages comes from ChatPromptTemplate; normalize every item
                if not isinstance(messages, (list, tuple)):
                    messages = [messages]
                br_messages = []
                for m in messages:
                    role, text = _normalize_to_role_text(m)
                    br_messages.append({"role": role, "content": [{"text": text}]})

                resp = self._br.converse(
                    modelId=model_id,
                    messages=br_messages,
                    inferenceConfig={
                        "maxTokens": self.max_tokens,
                        "temperature": self.temperature,
                        "topP": self.top_p,
                    },
                )
                return resp["output"]["message"]["content"][0]["text"]

            self.client = RunnableLambda(_nova_runnable)

        else:
            raise ValueError(f"Unsupported Bedrock model id: {model_id}")

        # final chain used by the rest of the app
        self.chain = self.prompt | self.client | StrOutputParser()

    # === public API used by ModelManager ===
    def provide_information(self, user_request: str, chat_history):
        return self.chain.invoke({
            "chat_history": chat_history or [],
            "user_request": user_request
        })
