#!/bin/bash
# ============================================================
# setup.sh — Full setup and management script for the AI rig
# ============================================================
# Usage:
#   ./setup.sh install   — first-time full setup
#   ./setup.sh start     — start all services
#   ./setup.sh stop      — stop all services
#   ./setup.sh status    — check all services and GPU usage
#   ./setup.sh logs      — tail logs from all services
#   ./setup.sh test      — test all API endpoints
#   ./setup.sh n8n-info  — print what to enter in n8n
# ============================================================

set -e
COMPOSE_FILE="$(dirname "$0")/docker-compose.yml"
ENV_FILE="$(dirname "$0")/.env"

# Load .env so we can read SERVER_IP
if [ -f "$ENV_FILE" ]; then
  export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

SERVER_IP="${SERVER_IP:-localhost}"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

print_header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }
ok()  { echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}⚠${NC}  $1"; }
err() { echo -e "${RED}✗${NC} $1"; }

# ── Install (first-time) ─────────────────────────────────────
cmd_install() {
  print_header "First-time setup"

  # Check .env
  if [ ! -f "$ENV_FILE" ]; then
    err ".env file not found. Copy .env.example to .env and fill in your values."
    exit 1
  fi

  if grep -q "REPLACE_WITH_YOUR" "$ENV_FILE"; then
    err ".env still has placeholder values. Edit it first:"
    echo "    nano $ENV_FILE"
    exit 1
  fi

  ok ".env found"

  # Check Docker
  if ! command -v docker &> /dev/null; then
    err "Docker not found. Install it first:"
    echo "    curl -fsSL https://get.docker.com | sh"
    exit 1
  fi
  ok "Docker found: $(docker --version)"

  # Check nvidia-smi
  if ! command -v nvidia-smi &> /dev/null; then
    warn "nvidia-smi not found — GPU may not be configured"
  else
    GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)
    ok "GPUs detected: $GPU_COUNT"
  fi

  # Check nvidia-container-toolkit
  if ! docker info 2>/dev/null | grep -q "nvidia"; then
    warn "NVIDIA container toolkit may not be installed."
    echo "    Install with:"
    echo "    distribution=\$(. /etc/os-release; echo \$ID\$VERSION_ID)"
    echo "    curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -"
    echo "    curl -s -L https://nvidia.github.io/nvidia-docker/\$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list"
    echo "    sudo apt update && sudo apt install -y nvidia-container-toolkit"
    echo "    sudo systemctl restart docker"
  else
    ok "NVIDIA container toolkit detected"
  fi

  print_header "Starting services (heavy first)"
  echo "Starting Gemma 4 — this downloads ~49 GB on first run..."
  docker compose -f "$COMPOSE_FILE" up vllm-gemma4-main -d

  echo ""
  echo "Waiting for Gemma 4 to become ready (this takes 5-15 min on first run)..."
  TIMEOUT=900  # 15 minutes
  ELAPSED=0
  until curl -sf http://localhost:11501/health > /dev/null 2>&1; do
    sleep 10
    ELAPSED=$((ELAPSED+10))
    echo "  ... ${ELAPSED}s elapsed (downloading model or loading into VRAM)"
    if [ $ELAPSED -ge $TIMEOUT ]; then
      err "Gemma 4 did not start in time. Check logs:"
      echo "    docker logs vllm-gemma4-main"
      exit 1
    fi
  done
  ok "Gemma 4 is up"

  echo ""
  echo "Applying Gemma 4 transformers fix..."
  bash "$(dirname "$0")/fix-gemma4.sh"

  echo ""
  echo "Starting remaining services..."
  docker compose -f "$COMPOSE_FILE" up -d

  echo ""
  echo "Pulling embeddings model (nomic-embed-text)..."
  sleep 5  # wait for ollama to be ready
  docker exec ollama-embeddings ollama pull nomic-embed-text

  echo ""
  print_header "Setup complete"
  cmd_test
  cmd_n8n_info
}

# ── Start ────────────────────────────────────────────────────
cmd_start() {
  print_header "Starting all services"
  docker compose -f "$COMPOSE_FILE" up -d
  ok "Services started. Run './setup.sh status' to check."
}

# ── Stop ─────────────────────────────────────────────────────
cmd_stop() {
  print_header "Stopping all services"
  docker compose -f "$COMPOSE_FILE" down
  ok "All services stopped. Models stay cached in Docker volumes."
}

# ── Status ───────────────────────────────────────────────────
cmd_status() {
  print_header "Service status"
  docker compose -f "$COMPOSE_FILE" ps

  print_header "GPU usage (all 6 GPUs)"
  nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu \
    --format=csv,noheader,nounits | \
    awk -F', ' '{printf "  GPU %s  %-24s  %5s/%5s MB  %3s%% util  %s°C\n",$1,$2,$3,$4,$5,$6}'

  print_header "API health"
  for PORT in 11501 11502 11503 11504; do
    if curl -sf http://localhost:${PORT}/health > /dev/null 2>&1 || \
       curl -sf http://localhost:${PORT}/api/tags > /dev/null 2>&1; then
      ok "Port ${PORT} responding"
    else
      err "Port ${PORT} not responding"
    fi
  done
}

# ── Logs ─────────────────────────────────────────────────────
cmd_logs() {
  print_header "Tailing logs (Ctrl+C to stop)"
  docker compose -f "$COMPOSE_FILE" logs -f --tail=50
}

# ── Test endpoints ───────────────────────────────────────────
cmd_test() {
  print_header "Testing all API endpoints"

  echo -e "\n${BOLD}Gemma 4 26B MoE — :11501${NC}"
  RESULT=$(curl -sf http://localhost:11501/v1/models 2>/dev/null)
  if [ $? -eq 0 ]; then
    MODEL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "unknown")
    ok "Model: $MODEL"
  else
    err "Not responding — check: docker logs vllm-gemma4-main"
  fi

  echo -e "\n${BOLD}Qwen 3.5 9B Fast — :11502${NC}"
  RESULT=$(curl -sf http://localhost:11502/v1/models 2>/dev/null)
  if [ $? -eq 0 ]; then
    MODEL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "unknown")
    ok "Model: $MODEL"
  else
    err "Not responding — check: docker logs vllm-qwen35-fast"
  fi

  echo -e "\n${BOLD}Qwen 2.5 VL Vision — :11503${NC}"
  RESULT=$(curl -sf http://localhost:11503/v1/models 2>/dev/null)
  if [ $? -eq 0 ]; then
    MODEL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "unknown")
    ok "Model: $MODEL"
  else
    err "Not responding — check: docker logs vllm-qwen-vision"
  fi

  echo -e "\n${BOLD}Ollama Embeddings — :11504${NC}"
  RESULT=$(curl -sf http://localhost:11504/api/tags 2>/dev/null)
  if [ $? -eq 0 ]; then
    ok "Ollama responding"
    MODELS=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); [print('  -',m['name']) for m in d.get('models',[])]" 2>/dev/null)
    [ -n "$MODELS" ] && echo "$MODELS" || warn "No models pulled yet — run: docker exec ollama-embeddings ollama pull nomic-embed-text"
  else
    err "Not responding — check: docker logs ollama-embeddings"
  fi

  echo -e "\n${BOLD}Open WebUI — :3000${NC}"
  if curl -sf http://localhost:3000 > /dev/null 2>&1; then
    ok "Open WebUI responding at http://${SERVER_IP}:3000"
  else
    err "Not responding — check: docker logs open-webui"
  fi

  # Quick inference test on Qwen 3.5 (fastest model)
  echo -e "\n${BOLD}Inference test (Qwen 3.5)${NC}"
  RESPONSE=$(curl -sf http://localhost:11502/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "Qwen/Qwen3.5-9B-Instruct",
      "messages": [{"role":"user","content":"Reply with just the word WORKING"}],
      "max_tokens": 10,
      "temperature": 0
    }' 2>/dev/null)
  if [ $? -eq 0 ]; then
    REPLY=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'].strip())" 2>/dev/null)
    ok "Response: $REPLY"
  else
    err "Inference test failed"
  fi
}

# ── n8n connection info ──────────────────────────────────────
cmd_n8n_info() {
  print_header "How to connect n8n to this server"

  echo ""
  echo -e "${BOLD}In n8n → Credentials → New → OpenAI API${NC}"
  echo ""
  echo -e "  Create ${BOLD}3 credentials${NC}, one per model:"
  echo ""
  echo -e "  ${CYAN}Credential 1: Gemma 4 (main brain)${NC}"
  echo "    API Key : any-string-here"
  echo "    Base URL: http://${SERVER_IP}:11501/v1"
  echo "    Model   : google/gemma-4-26B-A4B-it"
  echo ""
  echo -e "  ${CYAN}Credential 2: Qwen 3.5 (fast / coding / Spanish)${NC}"
  echo "    API Key : any-string-here"
  echo "    Base URL: http://${SERVER_IP}:11502/v1"
  echo "    Model   : Qwen/Qwen3.5-9B-Instruct"
  echo ""
  echo -e "  ${CYAN}Credential 3: Qwen Vision (images / PDFs)${NC}"
  echo "    API Key : any-string-here"
  echo "    Base URL: http://${SERVER_IP}:11503/v1"
  echo "    Model   : Qwen/Qwen2.5-VL-7B-Instruct"
  echo ""
  echo -e "${BOLD}For RAG / embeddings in n8n:${NC}"
  echo "    Type    : Ollama"
  echo "    Base URL: http://${SERVER_IP}:11504"
  echo "    Model   : nomic-embed-text"
  echo ""
  echo -e "${BOLD}Open WebUI (browser chat):${NC}"
  echo "    http://${SERVER_IP}:3000"
  echo ""
  warn "If n8n is on a different network segment, make sure ports"
  echo "    11501, 11502, 11503, 11504 are open in your firewall"
  echo "    for the n8n server's IP address only."
  echo ""
  echo "    Firewall rule example (ufw):"
  echo "    sudo ufw allow from N8N_SERVER_IP to any port 11501"
  echo "    sudo ufw allow from N8N_SERVER_IP to any port 11502"
  echo "    sudo ufw allow from N8N_SERVER_IP to any port 11503"
  echo "    sudo ufw allow from N8N_SERVER_IP to any port 11504"
}

# ── Router ───────────────────────────────────────────────────
case "${1:-help}" in
  install)  cmd_install ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  status)   cmd_status ;;
  logs)     cmd_logs ;;
  test)     cmd_test ;;
  n8n-info) cmd_n8n_info ;;
  *)
    echo ""
    echo -e "${BOLD}AI Rig Management Script${NC}"
    echo ""
    echo "  ./setup.sh install   — first-time full setup"
    echo "  ./setup.sh start     — start all services"
    echo "  ./setup.sh stop      — stop all services"
    echo "  ./setup.sh status    — check services + GPU usage"
    echo "  ./setup.sh logs      — tail all container logs"
    echo "  ./setup.sh test      — test all API endpoints"
    echo "  ./setup.sh n8n-info  — print n8n connection details"
    echo ""
    ;;
esac
