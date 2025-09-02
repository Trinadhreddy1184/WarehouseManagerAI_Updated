#!/bin/bash
set -e

IMAGE_NAME=warehouse_manager_ai

# Build image
 docker build -t "$IMAGE_NAME" .

# Run container
 docker run --rm --env-file .env -p 8501:8501 "$IMAGE_NAME"
