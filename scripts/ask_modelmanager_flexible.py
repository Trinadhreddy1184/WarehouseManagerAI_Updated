import os, sys, inspect
from pathlib import Path
sys.path.insert(0, "/opt/WarehouseManagerAI")

os.environ.setdefault("WM_DEBUG_SQL","1")  # show [SQL] queries if invoked

# Try to load config (optional)
cfg = None
try:
    from omegaconf import OmegaConf
    cfg_path = os.getenv("LLM_CONFIG_PATH", "/opt/WarehouseManagerAI/configs/llm_config.yaml")
    if Path(cfg_path).exists():
        cfg = OmegaConf.load(cfg_path)
except Exception as e:
    print("Config load warning:", repr(e))

from src.llm.ModelManager import ModelManager

def build_manager():
    sig = inspect.signature(ModelManager)
    params = set(sig.parameters.keys())
    # Try a few safe combos without importing provider classes
    candidates = []
    if len(params) == 0:
        candidates.append({})
    candidates.append({"config": cfg, "llm": None})
    if "config" in params and "llm" not in params:
        candidates.append({"config": cfg})
    if "llm" in params and "config" not in params:
        candidates.append({"llm": None})

    last_err = None
    for kwargs in candidates:
        try:
            print("Trying ModelManager(**%r)" % kwargs)
            mm = ModelManager(**{k:v for k,v in kwargs.items() if k in params})
            return mm
        except Exception as e:
            last_err = e
            print("…failed:", repr(e))
    raise RuntimeError(f"Could not construct ModelManager with signature {params}. Last error: {last_err}")

def main(question: str):
    mm = build_manager()
    # If ModelManager has no LLM, supply a tool-enabled adapter so calls succeed.
    if not getattr(mm, "llm", None):
        from src.llm.adapters.ToolEnabledLLM import ToolEnabledLLM
        mm.llm = ToolEnabledLLM()
        print("Injected ToolEnabledLLM into ModelManager.llm")
    ans = mm.provide_information(user_request=question, chat_history=[])
    print("\nANSWER:\n", ans)

if __name__ == "__main__":
    q = " ".join(sys.argv[1:]) or "How many items are there in inventory?"
    print("LLM_CONFIG_PATH:", os.getenv("LLM_CONFIG_PATH"))
    main(q)
