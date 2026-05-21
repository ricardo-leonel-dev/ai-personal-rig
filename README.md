# AI Rig — Local LLM Platform

6 × NVIDIA GeForce GTX 1660 Ti · 36 GB total VRAM

## Services

| Port  | Service           | Model                       | GPUs    |
| ----- | ----------------- | --------------------------- | ------- |
| 11501 | Gemma 4 26B MoE   | google/gemma-4-26B-A4B-it   | 0,1,2,3 |
| 11502 | Qwen 3.5 9B fast  | Qwen/Qwen3.5-9B-Instruct    | 4       |
| 11503 | Qwen 2.5 VL 7B    | Qwen/Qwen2.5-VL-7B-Instruct | 5       |
| 11504 | Ollama embeddings | nomic-embed-text (CPU)      | none    |
| 3000  | Open WebUI        | browser chat UI             | —       |

---

## First-time setup

```bash
# 1. Clone or copy these files to your server
# 2. Create your .env file
cp .env.example .env
nano .env          # fill in HF_TOKEN and SERVER_IP

# 3. Secure it
chmod 600 .env
chmod +x setup.sh fix-gemma4.sh

# 4. Run full install
./setup.sh install
```

The install script will:

- Start Gemma 4 first and wait for it to load (~5-15 min, downloads ~49 GB on first run)
- Apply the Gemma 4 transformers version fix automatically
- Start the remaining 4 services
- Pull the nomic-embed-text embedding model
- Run a full test of all endpoints

---

## Daily use

```bash
./setup.sh start     # start everything
./setup.sh stop      # stop everything (models stay cached)
./setup.sh status    # GPU usage + service health
./setup.sh test      # test all endpoints + a quick inference
./setup.sh n8n-info  # print what to enter in n8n
```

---

## Connecting n8n (on your other server)

In n8n → **Credentials → New → OpenAI API**, create one credential per model:

| Credential name | Base URL                  | Model name                    |
| --------------- | ------------------------- | ----------------------------- |
| Gemma 4 main    | `http://YOUR_IP:11501/v1` | `google/gemma-4-26B-A4B-it`   |
| Qwen 3.5 fast   | `http://YOUR_IP:11502/v1` | `Qwen/Qwen3.5-9B-Instruct`    |
| Qwen vision     | `http://YOUR_IP:11503/v1` | `Qwen/Qwen2.5-VL-7B-Instruct` |

For the **Ollama** (embeddings) node in n8n:

- Base URL: `http://YOUR_IP:11504`
- Model: `nomic-embed-text`

> **API Key**: vLLM doesn't validate it — use any string like `not-needed`.

Run `./setup.sh n8n-info` to get the exact values with your real IP printed out.

---

## Firewall (if n8n is on a different machine)

Allow only your n8n server to reach the LLM ports:

```bash
sudo ufw allow from N8N_SERVER_IP to any port 11501
sudo ufw allow from N8N_SERVER_IP to any port 11502
sudo ufw allow from N8N_SERVER_IP to any port 11503
sudo ufw allow from N8N_SERVER_IP to any port 11504
# Port 3000 (WebUI) — open to your whole local network
sudo ufw allow from 192.168.1.0/24 to any port 3000
sudo ufw enable
```

---

## Troubleshooting

**Gemma 4 OOM at startup**
Lower memory utilization in docker-compose.yml:

```yaml
--gpu-memory-utilization 0.85
# and/or reduce context length:
--max-model-len 4096
```

**"Model not found" in n8n**
The model name must exactly match what vLLM loaded. Check it:

```bash
curl http://localhost:11501/v1/models
```

Use the `id` field value as the model name in n8n.

**Gemma 4 tool-calling not working**
The transformers fix must be applied. Run:

```bash
./fix-gemma4.sh
```

**GPU visible to wrong container**
`CUDA_VISIBLE_DEVICES=0` inside a container always refers to the
_first reserved device_, not physical GPU 0. Each container only
sees the GPUs listed in its `device_ids`. This is correct behavior.

**Check which model is using which GPU**

```bash
nvidia-smi
# Look at the Processes section — shows container PID and VRAM
```

---

## Security notes

- Never commit `.env` to git — add it to `.gitignore`
- The vLLM ports (11501-11504) have no authentication. Keep them
  firewalled to trusted IPs only.
