#!/usr/bin/env bash
# One-shot Colab GPU worker for the haz pool.
#
# Colab runtimes almost never allow a real TUN device, so Tailscale runs in
# userspace mode and a tiny SOCKS5->TCP forwarder lets the worker reach the NATS
# bus over the tailnet via localhost. Run in a Colab SSH session or single cell:
#   curl -fsSL https://raw.githubusercontent.com/krymov/haz-dist/main/colab.sh \
#     | TS_AUTHKEY=hskey-... NATS_TOKEN=... bash
set -euo pipefail
: "${TS_AUTHKEY:?set TS_AUTHKEY}"; : "${NATS_TOKEN:?set NATS_TOKEN}"
MODEL="${MODEL:-Qwen/Qwen2.5-3B-Instruct}"
BUS_HOST="${BUS_HOST:-100.64.0.2}"; BUS_PORT="${BUS_PORT:-4222}"
HS="${HEADSCALE_URL:-https://hs.krmv.dev}"

curl -fsSL https://tailscale.com/install.sh | sh
pkill -f tailscaled 2>/dev/null || true; sleep 1
tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 \
  --state=/var/lib/tailscale/tailscaled.state >/tmp/tailscaled.log 2>&1 &
sleep 3
tailscale up --login-server="$HS" --authkey="$TS_AUTHKEY" \
  --hostname="colab-$(hostname | cut -c1-8)" --accept-routes=false --shields-up
echo "tailnet: $(tailscale ip -4 | head -1)"

# SOCKS5 -> TCP bridge so plain TCP clients (nats.go) can reach the tailnet bus.
pip -q install pysocks
cat > /tmp/hazfwd.py <<PYEOF
import socket, threading, socks
LISTEN=("127.0.0.1", ${BUS_PORT}); TARGET=("${BUS_HOST}", ${BUS_PORT}); PROXY=("127.0.0.1",1055)
def pipe(a,b):
    try:
        while True:
            d=a.recv(65536)
            if not d: break
            b.sendall(d)
    except Exception: pass
    finally:
        for s in (a,b):
            try: s.close()
            except Exception: pass
def handle(c):
    r=socks.socksocket(); r.set_proxy(socks.SOCKS5,*PROXY)
    try: r.connect(TARGET)
    except Exception: c.close(); return
    threading.Thread(target=pipe,args=(c,r),daemon=True).start(); pipe(r,c)
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
srv.bind(LISTEN); srv.listen(128)
while True:
    c,_=srv.accept(); threading.Thread(target=handle,args=(c,),daemon=True).start()
PYEOF
nohup python3 /tmp/hazfwd.py >/tmp/hazfwd.log 2>&1 &
sleep 2

pip -q install vllm
nohup vllm serve "$MODEL" --port 8000 --max-model-len 8192 >/tmp/vllm.log 2>&1 &
echo "waiting for vLLM (downloads the model on first run)..."
until curl -s http://localhost:8000/v1/models >/dev/null 2>&1; do sleep 5; done
echo "vLLM ready"

curl -fsSL https://github.com/krymov/haz-dist/releases/latest/download/haz-linux-amd64 \
  -o /usr/local/bin/haz && chmod +x /usr/local/bin/haz
export HAZ_NATS_URL="nats://${NATS_TOKEN}@127.0.0.1:${BUS_PORT}" VLLM_URL="http://localhost:8000"
exec haz worker gpu
