import os, sys, inspect
from pathlib import Path
sys.path.insert(0, "/opt/WarehouseManagerAI")

from omegaconf import OmegaConf

CFG_PATH = os.getenv("LLM_CONFIG_PATH", "/opt/WarehouseManagerAI/configs/llm_config.yaml")
cfg = OmegaConf.load(CFG_PATH)
provider = str(cfg.get("main", {}).get("provider", "bedrock")).lower()

def build_llm():
    # Prefer Bedrock (Claude) if present in your repo/config
    if provider in ("bedrock", "aws", "anthropic", "claude"):
        try:
            from src.llm.BedrockModel import BedrockModel
            sig = inspect.signature(BedrockModel)
            return BedrockModel(cfg) if len(sig.parameters)>=1 else BedrockModel()
        except Exception as e:
            print("BedrockModel init failed:", e)
    raise RuntimeError("No LLM provider could be constructed.")

def build_manager(llm):
    from src.llm.ModelManager import ModelManager
    sig = inspect.signature(ModelManager)
    if "config" in sig.parameters and "llm" in sig.parameters:
        return ModelManager(config=cfg, llm=llm)
    if len(sig.parameters)==0:
        m = ModelManager()
        # best effort attach
        if hasattr(m, "config"): m.config = cfg
        if hasattr(m, "llm"): m.llm = llm
        return m
    # positional fallback
    return ModelManager(cfg, llm)

def main(q: str):
    # echo SQL queries if the chain ends up using our sql tool
    os.environ.setdefault("WM_DEBUG_SQL", "1")
    llm = build_llm()
    mm = build_manager(llm)
    ans = mm.provide_information(user_request=q, chat_history=[])
    print("\nANSWER:\n", ans)

if __name__ == "__main__":
    question = " ".join(sys.argv[1:]) or "How many items are there in inventory?"
    print("LLM_CONFIG_PATH:", CFG_PATH)
    print("Provider:", provider)
    main(question)
