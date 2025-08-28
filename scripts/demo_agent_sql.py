# NOTE: replace below with your actual chat model client; this is just a template.
from src.agents.agent_boot import load_system_messages, get_tools
from src.tools.sql_tool import run_sql

def fake_chat_call(messages, tools):
    # This stub "decides" to call run_sql for the demo; replace with your LLM client.
    return {"tool": "run_sql", "arguments": {"sql": "SELECT store, product_name, brand_name FROM app_inventory LIMIT 5"}}

if __name__ == "__main__":
    system = load_system_messages()
    tools, funcs = get_tools()
    # ask a sample question
    messages = system + [{"role": "user", "content": "show 5 products with brand names"}]
    out = fake_chat_call(messages, tools)
    if "tool" in out and out["tool"] in funcs:
        print(funcs[out["tool"]](**out["arguments"]))
    else:
        print(out)
