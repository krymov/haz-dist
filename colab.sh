#!/usr/bin/env bash
# One-shot Colab (or any GPU box) worker bootstrap. Run in a Colab SSH session
# or a single cell:
#   curl -fsSL https://raw.githubusercontent.com/krymov/haz-dist/main/colab.sh \
#     | TS_AUTHKEY=hskey-... NATS_TOKEN=... bash
set -euo pipefail
: "${TS_AUTHKEY:?set TS_AUTHKEY}"; : "${NATS_TOKEN:?set NATS_TOKEN}"
MODEL="${MODEL:-Qwen/Qwen2.5-3B-Instruct}"

curl -fsSL https://tailscale.com/install.sh | sh
if [ -e /dev/net/tun ]; then
  tailscaled --state=/var/lib/tailscale/tailscaled.state >/tmp/ts.log 2>&1 &
else
  echo "WARN: no /dev/net/tun; userspace mode can't reach the bus — recycle the runtime." >&2
  tailscaled --tun=userspace-networking --socks5-server=localhost:1055 \
    --state=/var/lib/tailscale/tailscaled.state >/tmp/ts.log 2>&1 &
fi
sleep 3
tailscale up --login-server=https://hs.krmv.dev --authkey="$TS_AUTHKEY" \
  --hostname="colab-$(hostname | cut -c1-8)" --accept-routes=false --shields-up
echo "tailnet: $(tailscale ip -4 | head -1)"

pip -q install vllm
nohup vllm serve "$MODEL" --port 8000 --max-model-len 8192 >/tmp/vllm.log 2>&1 &
echo "waiting for vLLM (first run downloads the model)..."
until curl -s localhost:8000/v1/models >/dev/null 2>&1; do sleep 5; done
echo "vLLM ready"

curl -fsSL https://github.com/krymov/haz-dist/releases/latest/download/haz-linux-amd64 \
  -o /usr/local/bin/haz && chmod +x /usr/local/bin/haz
export HAZ_NATS_URL="nats://${NATS_TOKEN}@100.64.0.2:4222" VLLM_URL="http://localhost:8000"
exec haz worker gpu
