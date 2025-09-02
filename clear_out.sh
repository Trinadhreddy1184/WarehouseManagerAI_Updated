#!/bin/bash
set -e

# Stop and remove any running container
CONTAINER_ID=$(docker ps -aq --filter "ancestor=warehouse_manager_ai")
if [ -n "$CONTAINER_ID" ]; then
  docker rm -f "$CONTAINER_ID"
fi

# Remove built image
if docker images | grep -q warehouse_manager_ai; then
  docker rmi warehouse_manager_ai
fi

# Clean python caches
find . -name '__pycache__' -type d -prune -exec rm -r {} +
