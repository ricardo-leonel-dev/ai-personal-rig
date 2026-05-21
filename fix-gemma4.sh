#!/bin/bash
# ============================================================
# fix-gemma4.sh
# Run this ONCE after vllm-gemma4-main first starts.
#
# Problem: vLLM pins transformers <= 4.57.6 but Gemma 4
# requires >= 5.5.0. This script upgrades it inside the
# running container and restarts the service.
# ============================================================

set -e

echo ">>> Upgrading transformers inside vllm-gemma4-main..."
docker exec vllm-gemma4-main pip install \
  "transformers>=5.5.0" \
  --upgrade \
  --break-system-packages \
  --quiet

echo ">>> Restarting vllm-gemma4-main..."
docker restart vllm-gemma4-main

echo ">>> Waiting for service to come back up..."
until curl -sf http://localhost:11501/health > /dev/null 2>&1; do
  echo "    ... still starting"
  sleep 5
done

echo ""
echo "✓ Gemma 4 is up with correct transformers version."
echo "  Test: curl http://localhost:11501/v1/models"
