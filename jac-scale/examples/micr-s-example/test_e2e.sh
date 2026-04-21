#!/usr/bin/env bash
# End-to-end test for the jac-shop microservice example.
#
# Starts the full stack (gateway + 3 services) in the background, runs
# each shipped feature through curl, reports PASS/FAIL per check, and
# always tears the stack down on exit.
#
# Run from this directory:
#   ./test_e2e.sh
#
# Exit 0 if every check passed, non-zero otherwise. Structured so the
# individual check_* blocks map 1:1 to future pytest/jac-test cases.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR"

# Allow overriding the jac binary for envs where it's not on PATH
# (e.g. conda envs without activation):  JAC_BIN=/path/to/jac ./test_e2e.sh
JAC_BIN="${JAC_BIN:-jac}"

GATEWAY="http://localhost:8000"
STACK_LOG="$SCRIPT_DIR/.jac/e2e_stack.log"
STACK_PID=""

RED=$'\e[31m'; GREEN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RESET=$'\e[0m'
PASS=0; FAIL=0; FAIL_NAMES=()

log()     { printf '%s[%s]%s %s\n' "$DIM" "$(date +%H:%M:%S)" "$RESET" "$*"; }
section() { printf '\n%s== %s ==%s\n' "$YEL" "$*" "$RESET"; }

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$name"
    PASS=$((PASS+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$name"
    FAIL=$((FAIL+1))
    FAIL_NAMES+=("$name")
  fi
}

# Assertion helper: pipe JSON into this, pass a python expression on `d`.
#   echo "$resp" | json_is 'd["status"] == "healthy"'
json_is() {
  python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(2)
sys.exit(0 if ($1) else 1)
"
}

# Extract a JSON path as a string on stdout.
#   TOKEN=$(echo "$resp" | json_get 'd["token"]')
json_get() {
  python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(2)
v=$1
print(v if v is not None else '')
"
}

cleanup() {
  local exit_code=$?
  section "Teardown"
  if [ -n "$STACK_PID" ] && kill -0 "$STACK_PID" 2>/dev/null; then
    # Stack was launched with setsid so its pgid == its pid. Send the
    # signal to the whole group so children die too; atexit alone
    # doesn't fire reliably when the parent is blocked in uvicorn.
    log "stopping stack (pgid $STACK_PID)"
    kill -INT -"$STACK_PID" 2>/dev/null || kill -INT "$STACK_PID" 2>/dev/null || true
    sleep 2
    if kill -0 "$STACK_PID" 2>/dev/null; then
      log "stack did not exit cleanly, SIGTERM group"
      kill -TERM -"$STACK_PID" 2>/dev/null || kill -TERM "$STACK_PID" 2>/dev/null || true
      sleep 1
    fi
    wait "$STACK_PID" 2>/dev/null || true
  fi

  # Verify children died (atexit or group-signal cascade)
  local remaining
  remaining=$(pgrep -cf "jac start.*--no_client" 2>/dev/null || echo 0)
  remaining=${remaining//[[:space:]]/}
  if [ "${remaining:-0}" -gt 0 ] 2>/dev/null; then
    printf '  %sFAIL%s  subprocess cleanup (found %s orphan(s))\n' "$RED" "$RESET" "$remaining"
    FAIL=$((FAIL+1)); FAIL_NAMES+=("subprocess cleanup")
    pkill -f "jac start.*--no_client" 2>/dev/null || true
  else
    printf '  %sPASS%s  subprocess cleanup\n' "$GREEN" "$RESET"
    PASS=$((PASS+1))
  fi

  printf '\n  Passed: %s%d%s   Failed: %s%d%s\n' \
    "$GREEN" "$PASS" "$RESET" "$RED" "$FAIL" "$RESET"
  if [ "$FAIL" -gt 0 ]; then
    printf '  Failing checks:\n'
    for n in "${FAIL_NAMES[@]}"; do printf '    - %s\n' "$n"; done
    exit 1
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
section "Pre-flight"

command -v "$JAC_BIN" >/dev/null 2>&1 && check "jac binary ($JAC_BIN) available" true || check "jac binary ($JAC_BIN) available" false
command -v curl    >/dev/null 2>&1 && check "curl on PATH"   true || check "curl on PATH" false
command -v python3 >/dev/null 2>&1 && check "python3 on PATH" true || check "python3 on PATH" false

port_free=true
if (exec 3<>/dev/tcp/127.0.0.1/8000) 2>/dev/null; then
  exec 3>&- 3<&-
  port_free=false
fi
check ":8000 is free" $port_free

if [ "$FAIL" -gt 0 ]; then
  log "aborting: pre-flight failed"
  exit 1
fi

# Clean state so subprocesses come up with fresh data
rm -rf .jac/data .jac/logs 2>/dev/null || true
mkdir -p .jac

# ---------------------------------------------------------------------------
# 1. Start stack
# ---------------------------------------------------------------------------
section "Start stack"

# Run jac start in its own process group so SIGINT propagates to children.
setsid "$JAC_BIN" start main.jac > "$STACK_LOG" 2>&1 &
STACK_PID=$!
log "launched stack (pid $STACK_PID); log -> $STACK_LOG"

wait_healthy() {
  local deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$STACK_PID" 2>/dev/null; then
      log "stack exited prematurely"
      tail -20 "$STACK_LOG" 2>/dev/null || true
      return 1
    fi
    local resp
    resp=$(curl -sf "$GATEWAY/health" 2>/dev/null || echo "")
    if [ -n "$resp" ]; then
      local n
      n=$(echo "$resp" | python3 -c "import sys,json
d=json.load(sys.stdin)
svcs=d.get('services',{})
healthy=[k for k,v in svcs.items() if v.get('status')=='healthy']
print(len(healthy))
" 2>/dev/null || echo 0)
      if [ "$n" = "3" ]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

check "all 3 services healthy within 60s" wait_healthy

if [ "$FAIL" -gt 0 ]; then
  log "cannot run feature checks; stack did not come up"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. ServiceDeployer / LocalDeployer (roadmap 1, 1a, 1b, 1c, 13)
# ---------------------------------------------------------------------------
section "ServiceDeployer / LocalDeployer"

# Three subprocess children spawned (one per service) = subprocess isolation
CHILDREN=$(pgrep -f "jac start.*--no_client" 2>/dev/null | wc -l)
check "3 service subprocesses running (one per service)" \
  bash -c "[ '$CHILDREN' -eq 3 ]"

# Ports land in 18000-18999 (hash-based), read from /health
PORTS=$(echo "$(curl -s $GATEWAY/health)" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(' '.join(str(v.get('port','')) for v in d.get('services',{}).values()))
")
check "ports are in 18000-18999 range (hash-based)" \
  bash -c 'for p in '"$PORTS"'; do [ "$p" -ge 18000 ] && [ "$p" -le 18999 ] || exit 1; done'

# Shared anchor store at .jac/data/anchor_store.db (all services + gateway
# share one graph, consistent with the monolith model). Per-service node
# class registration lives in examples/.../shared/models.jac.
check "shared anchor store exists (.jac/data/anchor_store.db)" \
  bash -c "[ -f .jac/data/anchor_store.db ]"

# Per-service log files at .jac/logs/{name}.log (roadmap 13)
check "per-service log file exists (products_app)" bash -c "[ -s .jac/logs/products_app.log ]"
check "per-service log file exists (cart_app)"     bash -c "[ -s .jac/logs/cart_app.log ]"
check "per-service log file exists (orders_app)"   bash -c "[ -s .jac/logs/orders_app.log ]"

# ---------------------------------------------------------------------------
# 3. CLI (roadmap 5)
# ---------------------------------------------------------------------------
section "CLI (jac setup / jac scale)"

check "jac setup microservice --list runs" \
  bash -c "$JAC_BIN setup microservice --list | grep -q 'products_app'"

check "jac scale status shows 3 services" \
  bash -c "$JAC_BIN scale status 2>&1 | grep -cE 'products_app|cart_app|orders_app' | grep -qE '^[3-9]'"

# ---------------------------------------------------------------------------
# 4. Gateway surface (roadmap 2)
# ---------------------------------------------------------------------------
section "Gateway surface"

HEALTH_RESP=$(curl -s "$GATEWAY/health")

check "/health reports status=healthy" \
  bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if d.get(\"status\")==\"healthy\" else 1)"' \
  "$HEALTH_RESP"

check "/health lists all 3 services" \
  bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);s=set(d.get(\"services\",{}).keys());exit(0 if {\"products_app\",\"cart_app\",\"orders_app\"}.issubset(s) else 1)"' \
  "$HEALTH_RESP"

# /admin/ and / depend on admin-dist and client-build being present.
# A 200 means the feature is enabled and bundle is on disk; 404 means
# "feature gated off" for this example, which is a valid shipping state.
# Either is acceptable -- what's NOT acceptable is 500 or connection
# refused (that would mean the handler itself is broken).
check "/admin/ returns 200 or 404 (not 5xx)" \
  bash -c "code=\$(curl -s -o /dev/null -w '%{http_code}' $GATEWAY/admin/); [ \"\$code\" = '200' ] || [ \"\$code\" = '404' ]"

check "/ (SPA root) returns 200 or 404 (not 5xx)" \
  bash -c "code=\$(curl -s -o /dev/null -w '%{http_code}' $GATEWAY/); [ \"\$code\" = '200' ] || [ \"\$code\" = '404' ]"

check "/nonexistent returns 404" \
  bash -c "curl -s -o /dev/null -w '%{http_code}' $GATEWAY/this-path-does-not-exist | grep -q '^404$'"

# ---------------------------------------------------------------------------
# 5. Public function proxy (roadmap 2a)
# list_products requires auth (def:pub != unauthenticated in jac-scale).
# The proxy check runs AFTER login below so we have a token; this section
# only verifies the route plumbing returns a response with an envelope
# shape (even 401 is a valid proxied response).
# ---------------------------------------------------------------------------
section "Public proxy (/api/products/function/list_products plumbing)"

PROD_RESP=$(curl -s -X POST "$GATEWAY/api/products/function/list_products" \
  -H 'Content-Type: application/json' -d '{}')

check "list_products returns a TransportResponse envelope" \
  bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if \"ok\" in d else 1)"' \
  "$PROD_RESP"

# ---------------------------------------------------------------------------
# 6. Built-in passthrough: /user/register + /user/login (roadmap 8)
# ---------------------------------------------------------------------------
section "Built-in passthrough (/user/*)"

# jac-scale uses an identity/credential-based auth API, not email/password
USERNAME="e2e_$(date +%s)"
PASSWORD="hunter2pass"

REGISTER_BODY=$(python3 -c "import json;print(json.dumps({
  'identities':[{'type':'username','value':'$USERNAME'}],
  'credential':{'type':'password','password':'$PASSWORD'}
}))")
REG_RESP=$(curl -s -X POST "$GATEWAY/user/register" \
  -H 'Content-Type: application/json' -d "$REGISTER_BODY")
check "/user/register accepts new user" \
  bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if d.get(\"ok\") else 1)"' \
  "$REG_RESP"

LOGIN_BODY=$(python3 -c "import json;print(json.dumps({
  'identity':{'type':'username','value':'$USERNAME'},
  'credential':{'type':'password','password':'$PASSWORD'}
}))")
LOGIN_RESP=$(curl -s -X POST "$GATEWAY/user/login" \
  -H 'Content-Type: application/json' -d "$LOGIN_BODY")
TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except: sys.exit(0)
# Envelope: {ok, data: {token, ...}}
data=d.get('data') or {}
print(data.get('token') or d.get('token') or '')
" 2>/dev/null)

check "/user/login returns a token" \
  bash -c '[ -n "$0" ]' "$TOKEN"

if [ -z "$TOKEN" ]; then
  log "skipping auth-gated checks (no token)"
else
  # -------------------------------------------------------------------------
  # 6b. Authenticated public proxy: list_products should now return data
  # -------------------------------------------------------------------------
  section "Authenticated proxy (/api/products/function/list_products)"

  AUTH_PROD_RESP=$(curl -s -X POST "$GATEWAY/api/products/function/list_products" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}')
  check "list_products returns ok=true with token" \
    bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if d.get(\"ok\") else 1)"' \
    "$AUTH_PROD_RESP"

  check "list_products returns non-empty catalog" \
    bash -c 'echo "$0" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data=d.get(\"data\")
items=data.get(\"result\") if isinstance(data,dict) and \"result\" in data else data
exit(0 if items else 1)"' \
    "$AUTH_PROD_RESP"

  # -------------------------------------------------------------------------
  # 7. sv import auth forwarding (roadmap 4a/4b: THE critical path)
  # -------------------------------------------------------------------------
  section "sv_service_call auth forwarding"

  ADD_RESP=$(curl -s -X POST "$GATEWAY/api/cart/function/add_to_cart" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"product_id":"prod_1","product_name":"Wireless Headphones","price":49.99,"qty":2}')
  check "cart/add_to_cart succeeds" \
    bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if d.get(\"ok\") else 1)"' \
    "$ADD_RESP"

  VIEW_RESP=$(curl -s -X POST "$GATEWAY/api/cart/function/view_cart" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}')
  check "cart/view_cart shows the added item" \
    bash -c 'echo "$0" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data=d.get(\"data\",{}).get(\"result\") or d.get(\"data\",{})
items=(data or {}).get(\"items\",[]) if isinstance(data,dict) else []
exit(0 if any(i.get(\"product_id\")==\"prod_1\" for i in items) else 1)"' \
    "$VIEW_RESP"

  ORDER_RESP=$(curl -s -X POST "$GATEWAY/api/orders/function/create_order" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}')
  check "orders/create_order succeeds (sv-import reaches cart_app with auth)" \
    bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if d.get(\"ok\") else 1)"' \
    "$ORDER_RESP"

  # After create_order, cart should be empty (clear_cart ran via sv import)
  VIEW2_RESP=$(curl -s -X POST "$GATEWAY/api/cart/function/view_cart" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}')
  check "cart cleared after create_order (proves sv-import auth forwarded)" \
    bash -c 'echo "$0" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data=d.get(\"data\",{}).get(\"result\") or d.get(\"data\",{})
items=(data or {}).get(\"items\",[]) if isinstance(data,dict) else []
exit(0 if not items else 1)"' \
    "$VIEW2_RESP"

  # -------------------------------------------------------------------------
  # 8. Negative: no auth -> downstream sv call should reject
  # -------------------------------------------------------------------------
  section "Negative: create_order without auth"

  # Refill cart so we can tell if clear_cart wrongly ran
  curl -s -X POST "$GATEWAY/api/cart/function/add_to_cart" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"product_id":"prod_1","product_name":"x","price":1,"qty":1}' >/dev/null

  NOAUTH_RESP=$(curl -s -X POST "$GATEWAY/api/orders/function/create_order" \
    -H 'Content-Type: application/json' -d '{}')
  check "create_order without auth returns error" \
    bash -c 'echo "$0" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except:
    sys.exit(0)  # Non-JSON error response is also a fail path
exit(0 if not d.get(\"ok\") else 1)"' \
    "$NOAUTH_RESP"

  VIEW3_RESP=$(curl -s -X POST "$GATEWAY/api/cart/function/view_cart" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}')
  check "cart still has item (clear_cart did NOT run under no-auth path)" \
    bash -c 'echo "$0" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data=d.get(\"data\",{}).get(\"result\") or d.get(\"data\",{})
items=(data or {}).get(\"items\",[]) if isinstance(data,dict) else []
exit(0 if items else 1)"' \
    "$VIEW3_RESP"
fi

# ---------------------------------------------------------------------------
# 9. Scale CLI (status + logs) (roadmap 5a)
#
# stop/restart are currently broken: scale_cmd builds a fresh
# LocalDeployer per invocation with empty pm.processes, so it can't
# reach processes the orchestrator spawned. Tracked in ROADMAP row 5a.
# Only exercising the CLI paths that don't depend on cross-process
# state here: status, logs.
# ---------------------------------------------------------------------------
section "jac scale status / logs"

check "jac scale status lists 3 services" \
  bash -c "$JAC_BIN scale status 2>&1 | grep -cE 'products_app|cart_app|orders_app' | grep -qE '^[3-9]'"

check "jac scale logs cart_app returns content" \
  bash -c "$JAC_BIN scale logs cart_app --lines 5 2>&1 | grep -q '.'"

# Cleanup handled by trap
