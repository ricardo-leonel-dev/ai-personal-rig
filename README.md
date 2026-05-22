# AI Multi-Agent Rig — 6 Independent Agents

6 × NVIDIA GeForce GTX 1660 Ti · 36 GB total VRAM  
**6 AI agents running in parallel, 1 GPU each**

## Agents & Services

| Port  | Agent             | Model (4-bit quantized)     | GPU  |
| ----- | ----------------- | --------------------------- | ---- |
| 11501 | Reasoning         | Mistral 7B AWQ              | 0    |
| 11502 | Coder             | DeepSeek 7B Coder AWQ       | 1    |
| 11503 | Planning          | Llama 3.1 8B AWQ            | 2    |
| 11504 | Multilingual      | Qwen 2.5 7B AWQ             | 3    |
| 11505 | Validation        | Mistral 7B AWQ              | 4    |
| 11506 | Lightweight       | Phi 3.5 mini (native)       | 5    |
| 11507 | Ollama embeddings | nomic-embed-text (CPU)      | —    |
| 3000  | Open WebUI        | Multi-agent control UI      | —    |

---

## First-time setup

```bash
# 1. Create your .env file
cp .env.example .env
nano .env          # fill in HF_TOKEN and OPEN_WEBUI_SECRET

# 2. Secure it
chmod 600 .env

# 3. Start all 6 agents
docker compose up -d

# 4. Monitor Agent 0 startup (~2-5 min per agent to load)
docker logs vllm-agent-0 -f
```

On first run, each agent will download its model (~3.5-4 GB each):
- Agent 0-1: ~3 min each
- Agent 2: ~3.5 min
- Agent 3-4: ~3 min each
- Agent 5: ~2.5 min

Total first-run time: ~20-30 minutes for all 6 agents

---

## Daily use

```bash
# Start all agents
docker compose up -d

# Stop all agents (models stay cached in Docker volumes)
docker compose down

# Check agent status & GPU usage
nvidia-smi
docker ps

# Test an agent endpoint
curl http://localhost:11501/v1/models

# Check logs
docker logs vllm-agent-0 -f      # Agent 0 (Mistral reasoning)
docker logs vllm-agent-1 -f      # Agent 1 (DeepSeek coder)
# ... etc for agents 2-5
```

---

## Connecting n8n (on your other server)

In n8n → **Credentials → New → OpenAI API**, create credentials for each agent:

| Agent | Base URL                  | Model name                      |
| ----- | ------------------------- | ------------------------------- |
| 0     | `http://YOUR_IP:11501/v1` | `TheBloke/Mistral-7B-AWQ`       |
| 1     | `http://YOUR_IP:11502/v1` | `TheBloke/deepseek-coder-7b-AWQ`|
| 2     | `http://YOUR_IP:11503/v1` | `TheBloke/Llama-2-8B-AWQ`       |
| 3     | `http://YOUR_IP:11504/v1` | `TheBloke/Qwen-7B-AWQ`          |
| 4     | `http://YOUR_IP:11505/v1` | `TheBloke/Mistral-7B-AWQ`       |
| 5     | `http://YOUR_IP:11506/v1` | `microsoft/phi-3.5-mini`        |

For the **Ollama** (embeddings) node in n8n:

- Base URL: `http://YOUR_IP:11507`
- Model: `nomic-embed-text`

> **API Key**: vLLM doesn't validate it — use any string like `not-needed`.

---

## Firewall (if n8n is on a different machine)

Allow only your n8n server to reach the agent ports:

```bash
sudo ufw allow from N8N_SERVER_IP to any port 11501:11507
# Port 3000 (WebUI) — open to your whole local network
sudo ufw allow from 192.168.1.0/24 to any port 3000
sudo ufw enable
```

---

## Troubleshooting

**Agent won't start / OOM errors**
Each agent has 4-bit quantization to fit in ~5GB per GPU. If startup fails:

```bash
# Lower memory utilization in docker-compose.yml
--gpu-memory-utilization 0.70  # (was 0.80)
# or reduce context length
--max-model-len 2048  # (was 4096)
```

Then restart: `docker compose up -d`

**"Model not found" error when calling agent**
Check what the agent actually loaded:

```bash
curl http://localhost:11501/v1/models
```

The `id` field is what to use in n8n (it matches the `--quantization awq` version).

**Agent is slow / high latency**
With 6 agents on 6 GPUs, each is memory-constrained. To speed up one:
- Stop unused agents: `docker stop vllm-agent-3 vllm-agent-4`
- Agents will run faster with freed VRAM

**GPU visible to wrong container**
`CUDA_VISIBLE_DEVICES=0` in a container refers to the first device in its `device_ids` list. Each agent only sees 1 GPU. This is correct.

**Monitor GPU usage across all agents**

```bash
watch nvidia-smi
# Shows all 6 agents and their VRAM usage in the Processes section
```

---

## Security notes

- Never commit `.env` to git — it's in `.gitignore` by default
- The agent ports (11501-11507) have no authentication. Keep them
  firewalled to trusted IPs only.
- Each agent can read/write files and execute code — only expose to
  trusted orchestrators like n8n on isolated networks
- Rotate your HF_TOKEN periodically if exposed
