#!/usr/bin/env python3
"""Minimal stdio JSONL probe. Redacts account identity before persisting output."""
import hashlib, json, os, select, subprocess, sys, time

CODEX = os.environ.get("CODEX_PATH", os.path.expanduser("~/.local/bin/codex"))
p = subprocess.Popen([CODEX, "app-server", "--stdio"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
next_id = 1
results = []

SAFE_NUMERIC_KEYS = {"usedPercent","windowDurationMins","resetsAt","inputTokens","cachedInputTokens","outputTokens","reasoningOutputTokens","totalTokens","modelContextWindow"}
SAFE_STRING_KEYS = {"status","planType","limitId","limitName","type","sourceKind"}

def structural(value, key="", path=""):
    if isinstance(value, dict):
        return {k: structural(v, k, f"{path}.{k}" if path else k) for k,v in value.items()
                if not any(x in k.lower() for x in ("message","content","text","prompt","email","tokenvalue","cookie","credential","path","cwd"))}
    if isinstance(value, list):
        return {"type":"array","count":len(value),"sample":structural(value[0], key, path+"[]") if value else None}
    if key in SAFE_NUMERIC_KEYS and isinstance(value,(int,float)): return value
    if key in SAFE_STRING_KEYS and isinstance(value,str): return value
    if key.lower().endswith("id") and isinstance(value,str): return "sha256:"+hashlib.sha256(value.encode()).hexdigest()[:12]
    return {"type":type(value).__name__}

def send(method, params=None, timeout=8):
    global next_id
    rid = next_id; next_id += 1
    msg = {"jsonrpc":"2.0", "id": rid, "method": method, "params": params or {}}
    p.stdin.write(json.dumps(msg, separators=(",", ":")) + "\n"); p.stdin.flush()
    deadline = time.time() + timeout
    notifications = []
    while time.time() < deadline:
        ready, _, _ = select.select([p.stdout], [], [], min(.25, deadline-time.time()))
        if not ready: continue
        line = p.stdout.readline()
        if not line: break
        try: obj = json.loads(line)
        except Exception: continue
        if obj.get("id") == rid:
            results.extend(notifications)
            results.append({"request": method, "response": structural(obj)})
            return obj
        # Notifications can contain a machine name, installation ID, paths, or
        # message content. Persist the same structural representation used for
        # responses instead of recursively copying unknown scalar values.
        notifications.append({"notification": structural(obj)})
    results.append({"request": method, "timeout": True})
    return None

send("initialize", {"clientInfo":{"name":"haloscope-probe","title":"Haloscope Probe","version":"0.1.0"},"capabilities":{"experimentalApi":True}})
if p.poll() is not None:
    print("app-server exited during initialize:", p.stderr.read()[:2000], file=sys.stderr)
    sys.exit(2)
p.stdin.write(json.dumps({"jsonrpc":"2.0","method":"initialized","params":{}})+"\n"); p.stdin.flush()
thread_list_response = None
for method, params in [
    ("account/read", {"refreshToken":False}),
    ("account/rateLimits/read", {}),
    ("account/usage/read", {}),
    ("thread/list", {"limit":25,"sortKey":"updated_at","sortDirection":"desc","sourceKinds":[]}),
    ("thread/loaded/list", {}),
]:
    response = send(method, params)
    if method == "thread/list": thread_list_response = response

# Read one real thread and exercise experimental pagination against it.
thread_ids=[]
if thread_list_response:
    data=thread_list_response.get("result",{}).get("data",[])
    thread_ids=[x.get("id") for x in data if x.get("id")]
if thread_ids:
    tid=thread_ids[0]
    send("thread/read", {"threadId":tid,"includeTurns":True})
    send("thread/turns/list", {"threadId":tid,"limit":20})
    send("thread/items/list", {"threadId":tid,"limit":50})

os.makedirs("docs/probe", exist_ok=True)
with open("docs/probe/app-server-0.144.1-sanitized.json", "w") as f:
    json.dump(results, f, indent=2, ensure_ascii=False)
p.terminate()
try: p.wait(timeout=2)
except subprocess.TimeoutExpired: p.kill()
summary=[]
for x in results:
    if "request" in x:
        response=x.get("response",{})
        summary.append({"method":x["request"],"ok":"result" in response,"error":response.get("error"),"timeout":x.get("timeout",False)})
print(json.dumps(summary, indent=2, ensure_ascii=False))
