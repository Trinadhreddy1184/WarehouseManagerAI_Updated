# Warehouse Manager AI

This repository begins a fresh implementation of an AI-powered warehouse management
application. The goal is to build a modular, well-documented system that relies on
Amazon Bedrock models and an orchestrated multi-agent architecture.

## Project Goals
- Modular, agent-driven design with dynamic orchestration.
- Amazon Bedrock as the sole LLM provider.
- Streamlit-based user interface.
- Fully dockerized for reproducible deployment.

## Architecture Plan
```
agents/       # Agent definitions and coordination logic
llm_config/   # LLM configuration loaders and utilities
prompts/      # Prompt templates for agents and evaluations
scripts/      # Helper scripts for development and deployment
tests/        # Unit and integration tests
ui/           # Streamlit application code
utils/        # Shared utilities and helpers
data/         # Data assets and database files
docs/         # Project documentation and guides
```

Run `./run_all.sh` to build and start the application container.
Use `./clear_out.sh` to remove containers, images, and caches when resetting the environment.
