import os
import sys
import uuid
from typing import Any

from dotenv import load_dotenv

# --- Make sure we can import from src/... ---
# /opt/WarehouseManagerAI/ui -> parent is project root (/opt/WarehouseManagerAI)
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

load_dotenv()

import streamlit as st
from streamlit_chat import message

from src.llm.ModelManager import ModelManager
from src.config_defs.llm_config_defs import LLMMainConfig

st.set_page_config(page_title="Inventory Management Chatbot", layout="wide")

st.header("Inventory Management Chatbot")

# --- load config/model ---
llm_config: LLMMainConfig = LLMMainConfig.from_file(os.getenv("LLM_CONFIG_PATH"))
llm_model = ModelManager.new_instance_from_config(config=llm_config)

# --- state bootstrap ---
if "chat_answers_history" not in st.session_state:
    st.session_state["chat_answers_history"] = []
if "user_prompt_history" not in st.session_state:
    st.session_state["user_prompt_history"] = []
if "chat_history" not in st.session_state:
    st.session_state["chat_history"] = []  # list of tuples (role, text)

def _to_text(x: Any) -> str:
    """Normalize model outputs (str, AIMessage, dict) into plain text."""
    if isinstance(x, str):
        return x
    if hasattr(x, "content"):
        return x.content
    if isinstance(x, dict):
        for k in ("content", "text", "output", "answer"):
            v = x.get(k)
            if isinstance(v, str):
                return v
        try:
            import json
            return json.dumps(x, ensure_ascii=False)
        except Exception:
            return str(x)
    return str(x)

# --- input ---
prompt = st.text_input("Prompt", placeholder="Enter your message here...")

if prompt:
    with st.spinner("Generating response..."):
        generated_response = llm_model.provide_information(
            user_request=prompt,
            chat_history=st.session_state["chat_history"],  # tuples like ("human","..."), ("ai","...")
        )
        resp_text = _to_text(generated_response)

        # update histories
        st.session_state["user_prompt_history"].append(prompt)
        st.session_state["chat_answers_history"].append(resp_text)
        st.session_state["chat_history"].append(("human", prompt))
        st.session_state["chat_history"].append(("ai", resp_text))

# --- render history ---
if st.session_state["chat_answers_history"]:
    for answer, user_msg in zip(
        st.session_state["chat_answers_history"],
        st.session_state["user_prompt_history"],
    ):
        message(user_msg, is_user=True, key=str(uuid.uuid4()))
        message(answer)
