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
    log "stopping stack (pid $STACK_PID)"
    kill -INT "$STACK_PID" 2>/dev/null || true
    # give atexit a moment to clean up children
    sleep 2
    if kill -0 "$STACK_PID" 2>/dev/null; then
      log "stack did not exit cleanly, SIGTERM"
      kill -TERM "$STACK_PID" 2>/dev/null || true
    fi
    wait "$STACK_PID" 2>/dev/null || true
  fi

  # Verify atexit actually killed children
  local remaining
  remaining=$(pgrep -f "jac start.*--no_client" 2>/dev/null | wc -l || echo 0)
  if [ "$remaining" -gt 0 ]; then
    printf '  %sFAIL%s  atexit cleanup (found %s orphan subprocess(es))\n' "$RED" "$RESET" "$remaining"
    FAIL=$((FAIL+1)); FAIL_NAMES+=("atexit cleanup")
    pkill -f "jac start.*--no_client" 2>/dev/null || true
  else
    printf '  %sPASS%s  atexit cleanup\n' "$GREEN" "$RESET"
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

command -v jac     >/dev/null 2>&1 && check "jac on PATH"    true || check "jac on PATH" false
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
setsid jac start main.jac > "$STACK_LOG" 2>&1 &
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

# Per-service data isolation: .jac/data/{name}/ exists for each
check "per-service data dir exists (products_app)" bash -c "[ -d .jac/data/products_app ]"
check "per-service data dir exists (cart_app)"     bash -c "[ -d .jac/data/cart_app ]"
check "per-service data dir exists (orders_app)"   bash -c "[ -d .jac/data/orders_app ]"

# Per-service log files at .jac/logs/{name}.log (roadmap 13)
check "per-service log file exists (products_app)" bash -c "[ -s .jac/logs/products_app.log ]"
check "per-service log file exists (cart_app)"     bash -c "[ -s .jac/logs/cart_app.log ]"
check "per-service log file exists (orders_app)"   bash -c "[ -s .jac/logs/orders_app.log ]"

# ---------------------------------------------------------------------------
# 3. CLI (roadmap 5)
# ---------------------------------------------------------------------------
section "CLI (jac setup / jac scale)"

check "jac setup microservice --list runs" \
  bash -c 'jac setup microservice --list | grep -q "products_app"'

check "jac scale status shows 3 services" \
  bash -c 'jac scale status 2>&1 | grep -cE "products_app|cart_app|orders_app" | grep -qE "^[3-9]"'

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

check "/admin/ returns 200" \
  bash -c "curl -sf -o /dev/null -w '%{http_code}' $GATEWAY/admin/ | grep -q '^200$'"

check "/ (SPA) returns 200" \
  bash -c "curl -sf -o /dev/null -w '%{http_code}' $GATEWAY/ | grep -q '^200$'"

check "/nonexistent returns 404" \
  bash -c "curl -s -o /dev/null -w '%{http_code}' $GATEWAY/this-path-does-not-exist | grep -q '^404$'"

# ---------------------------------------------------------------------------
# 5. Public function proxy (roadmap 2a)
# ---------------------------------------------------------------------------
section "Public proxy (/api/products/function/list_products)"

PROD_RESP=$(curl -s -X POST "$GATEWAY/api/products/function/list_products" \
  -H 'Content-Type: application/json' -d '{}')

check "list_products returns ok envelope" \
  bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if d.get(\"ok\") else 1)"' \
  "$PROD_RESP"

check "list_products returns non-empty catalog" \
  bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);items=d.get(\"data\",{}).get(\"result\",[]) or d.get(\"data\",[]);exit(0 if items else 1)"' \
  "$PROD_RESP"

# ---------------------------------------------------------------------------
# 6. Built-in passthrough: /user/register + /user/login (roadmap 8)
# ---------------------------------------------------------------------------
section "Built-in passthrough (/user/*)"

EMAIL="e2e-$(date +%s)@test.com"
REG_RESP=$(curl -s -X POST "$GATEWAY/user/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"hunter2\"}")
check "/user/register accepts new user" \
  bash -c 'echo "$0" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if (d.get(\"ok\") or d.get(\"message\")) else 1)"' \
  "$REG_RESP"

LOGIN_RESP=$(curl -s -X POST "$GATEWAY/user/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"hunter2\"}")
TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except: sys.exit(0)
print(d.get('token') or (d.get('data') or {}).get('token') or '')
" 2>/dev/null)

check "/user/login returns a token" \
  bash -c '[ -n "$0" ]' "$TOKEN"

if [ -z "$TOKEN" ]; then
  log "skipping auth-gated checks (no token)"
else
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
# 9. Scale CLI (stop/restart) (roadmap 5a)
# ---------------------------------------------------------------------------
section "jac scale stop/restart"

check "jac scale stop cart_app succeeds" \
  bash -c 'jac scale stop cart_app 2>&1 | grep -qi "stopped"'

# Cart down: gateway should return 502/503
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/api/cart/function/view_cart" \
  -H "Authorization: Bearer ${TOKEN:-x}" -H 'Content-Type: application/json' -d '{}')
check "cart call returns 502/503 while stopped" \
  bash -c "[ '$STATUS' = '502' ] || [ '$STATUS' = '503' ]"

check "jac scale restart cart_app succeeds" \
  bash -c 'jac scale restart cart_app 2>&1 | grep -qiE "restart|Restarted"'

# Give cart_app a moment to come back
sleep 3
STATUS2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/api/cart/function/view_cart" \
  -H "Authorization: Bearer ${TOKEN:-x}" -H 'Content-Type: application/json' -d '{}')
check "cart responds 200 after restart" \
  bash -c "[ '$STATUS2' = '200' ]"

check "jac scale logs cart_app returns content" \
  bash -c 'jac scale logs cart_app --lines 5 2>&1 | grep -qi "."'

# Cleanup handled by trap
