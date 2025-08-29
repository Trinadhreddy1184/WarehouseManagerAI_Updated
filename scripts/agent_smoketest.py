import os, sys, json
from pathlib import Path

# Ensure imports work exactly like the app
repo_root = os.environ.get("PYTHONPATH")
if repo_root and Path(repo_root).exists():
    sys.path.insert(0, repo_root)
else:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

def header(t): print("\n" + "="*10 + " " + t + " " + "="*10)

# 0) ENV
header("ENV")
for k in ("PYTHONPATH","LLM_CONFIG_PATH","DATA_BACKEND","DATABASE_URL","DATABASE_CONFIG_PATH","EMBEDDINGS_CONFIG_PATH"):
    print(f"{k}={os.getenv(k)}")

# 1) LLM config peek (what keys mention prompts/tools/sql?)
header("LLM CONFIG (prompt/tool snippets)")
try:
    from omegaconf import OmegaConf
    p = os.getenv("LLM_CONFIG_PATH")
    if p and Path(p).exists():
        cfg = OmegaConf.load(p)
        c = OmegaConf.to_container(cfg, resolve=True)
        def find(kws, node, prefix=""):
            out = {}
            if isinstance(node, dict):
                for k,v in node.items():
                    low = str(k).lower()
                    if any(kw in low for kw in kws):
                        out[prefix+str(k)] = v
                    out.update(find(kws, v, prefix+str(k)+"."))
            elif isinstance(node, list):
                for i,v in enumerate(node):
                    out.update(find(kws, v, prefix+f"{i}."))
            return out
        print(json.dumps(find(["prompt","system","tool","sql"], c), indent=2))
    else:
        print("LLM_CONFIG_PATH not set or file missing")
except Exception as e:
    print("Config peek failed:", repr(e))

# 2) Tools registry
header("TOOLS registry")
try:
    from src.agents.tools_registry import TOOLS
    print("TOOLS:", list(TOOLS.keys()))
except Exception as e:
    print("No tools_registry or import failed:", repr(e))

# 3) DB smoke (through the same tool path the agent uses)
header("DB smoke tests (via sql_tool)")
try:
    os.environ.setdefault("WM_DEBUG_SQL","1")
    from src.tools.sql_tool import sql_scalar, sql_query
    print("COUNT(app_inventory) =>", sql_scalar("SELECT COUNT(*) FROM app_inventory"))
    df = sql_query("SELECT store, product_name, brand_name FROM app_inventory LIMIT 3")
    print(df.to_string(index=False))
except Exception as e:
    print("DB/tool test failed:", repr(e))

# 4) Full model call like the UI
header("ModelManager.provide_information()")
try:
    from src.llm.ModelManager import ModelManager
    from src.config_defs.llm_config_defs import LLMMainConfig
    p = os.getenv("LLM_CONFIG_PATH")
    if p and Path(p).exists():
        cfg = LLMMainConfig.from_file(p)
        mm = ModelManager.new_instance_from_config(cfg)
        answer = mm.provide_information(user_request="How many items are there in inventory?", chat_history=[])
        print("LLM ANSWER:\n", answer)
    else:
        print("LLM_CONFIG_PATH not set or file missing")
except Exception as e:
    print("ModelManager path failed:", repr(e))
