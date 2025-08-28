#!/usr/bin/env bash
# ============================================================
# Clear-out script: kill Streamlit/app processes + stop & clean Docker
# - Default (HARD=0): keeps Docker volumes (your DB data stays)
# - HARD=1: deletes EVERYTHING (containers, images, volumes, cache)
# ============================================================
set -euo pipefail

APP_DIR="/opt/WarehouseManagerAI"
HARD="${HARD:-0}"          # 0 = safe (default), 1 = nuke (includes db_data volume)
CLEAR_VENV="${CLEAR_VENV:-0}"  # 1 to remove .venv too

echo "== Disk BEFORE =="
df -h || true
docker system df || true

echo "== Kill host app processes (Streamlit / Uvicorn / Gunicorn / common Python UI) =="
# Try graceful; ignore if not running
pkill -f "streamlit run"         2>/dev/null || true
pkill -f "ui/streamlit_ui.py"    2>/dev/null || true
pkill -f "uvicorn"               2>/dev/null || true
pkill -f "gunicorn"              2>/dev/null || true

# Extra safety: kill any stray streamlit/python serving port 8501
if command -v lsof >/dev/null 2>&1; then
  lsof -ti :8501 | xargs -r kill -9 || true
fi

echo "== Stop system Postgres if present (free port 5432) =="
sudo systemctl stop postgresql     2>/dev/null || true
sudo systemctl stop postgresql-14  2>/dev/null || true
sudo systemctl stop postgresql-15  2>/dev/null || true
sudo systemctl stop postgresql-16  2>/dev/null || true

echo "== Stop any compose stack in ${APP_DIR} (keeps volumes unless HARD=1 later) =="
if [ -d "$APP_DIR" ]; then
  ( cd "$APP_DIR" && docker-compose down --remove-orphans || true )
fi

echo "== Stop & remove ALL running/stopped containers =="
docker ps  -q | xargs -r docker stop || true
docker ps -aq | xargs -r docker rm   || true

echo "== Truncate large Docker logs (keeps containers, but we removed them anyway) =="
for id in $(docker ps -aq); do
  LOG=$(docker inspect --format='{{.LogPath}}' "$id" 2>/dev/null || true)
  [ -n "${LOG:-}" ] && sudo sh -c "truncate -s 0 '$LOG'" || true
done

echo "== Remove temporary SQL dump files (host + seed volume if present) =="
# Host dump
rm -f "$APP_DIR/seed/100_dump.sql" 2>/dev/null || true
# Volume dump (does not remove the volume itself)
SEED_VOL=$(docker volume ls --format '{{.Name}}' | grep -E '^seed_data$' || true)
if [ -n "$SEED_VOL" ]; then
  docker run --rm -v "$SEED_VOL":/seed alpine sh -lc 'rm -f /seed/100_dump.sql; ls -lah /seed || true'
fi

echo "== Prune Docker builder cache and dangling resources =="
docker builder prune -f || true
docker image   prune -f || true
docker network prune -f || true
docker container prune -f || true

if [ "$HARD" = "1" ]; then
  echo "== HARD=1: NUKING ALL Docker images + volumes (includes your DB data) =="
  docker system prune -a -f --volumes || true
else
  echo "== HARD=0: Keeping Docker volumes (your DB data stays)."
  # Optionally clean unused volumes (won't touch in-use ones). Comment out if you want to keep everything.
  docker volume prune -f || true
fi

if [ "$CLEAR_VENV" = "1" ]; then
  echo "== Removing Python venv =="
  rm -rf "$APP_DIR/.venv" 2>/dev/null || true
fi

echo "== Disk AFTER =="
docker system df || true
df -h || true

echo "✅ Clear-out complete."
echo "   • Default kept DB data (set HARD=1 to remove everything)."
echo "   • To restart later, run your setup script again."

