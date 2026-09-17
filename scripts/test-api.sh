#!/usr/bin/env bash
# End-to-end check that a deployed opencode2api instance really answers model calls.
#
#   BASE_URL=https://opencode.example.com:99 API_KEY=sk-xxx ./scripts/test-api.sh
#
# Environment:
#   BASE_URL   base URL of the proxy                     (default http://127.0.0.1:10000)
#   API_KEY    value for "Authorization: Bearer <key>"   (omit when the proxy has no key)
#   MODEL      model id used by the chat tests           (auto-detected from /v1/models)
#   TIMEOUT    per-request max time, seconds             (default 180)
#   INSECURE   1 = skip TLS verification                 (default 0)
#
# Exit status: 0 when every check passed, 1 otherwise.

set -u

BASE_URL="${BASE_URL:-http://127.0.0.1:10000}"
BASE_URL="${BASE_URL%/}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
TIMEOUT="${TIMEOUT:-180}"

# --noproxy '*': a loopback target must never be handed to an HTTP proxy. If
# http_proxy is set and the request is sent there instead, curl still exits 0 and
# the status you read back belongs to the proxy, not to the server under test.
CURL=(curl -sS --noproxy '*' --connect-timeout 10 --max-time "$TIMEOUT")
[ "${INSECURE:-0}" = "1" ] && CURL+=(-k)

AUTH=()
[ -n "$API_KEY" ] && AUTH=(-H "Authorization: Bearer ${API_KEY}")

ok=0
bad=0
rule() { printf '%s\n' "------------------------------------------------------------"; }
pass() { ok=$((ok + 1));  printf '  [PASS] %s\n' "$*"; }
fail() { bad=$((bad + 1)); printf '  [FAIL] %s\n' "$*"; }
skip() { printf '  [SKIP] %s\n' "$*"; }

# A request built with -w '\n%{http_code}' yields "<body>\n<code>". The command
# substitution strips trailing newlines, so the code is whatever follows the last one.
last_line() { printf '%s' "${1##*$'\n'}"; }
drop_last() { printf '%s' "${1%$'\n'*}"; }

rule
printf 'Target : %s\n' "$BASE_URL"
printf 'API key: %s\n' "$([ -n "$API_KEY" ] && echo set || echo 'not set')"
rule

# ---------------------------------------------------------------- reachability
# This step exists because Traefik answers an unmatched route with a 19-byte plain
# text "404 page not found", which is easy to mistake for the app rejecting the path.
# The app's own 404 is JSON (see res.status(404).json in src/proxy.js), so the body
# alone tells the two apart.
printf '\n[1/5] Reachability\n'
probe=$(mktemp)
code=$("${CURL[@]}" -o "$probe" -w '%{http_code}' "$BASE_URL/health" 2>/dev/null) || code=000
body=$(head -c 300 "$probe" 2>/dev/null)
rm -f "$probe"

case "$code" in
    200)     pass "/health -> 200";;
    401|403) pass "/health -> $code (reachable; a key is required)";;
    000)     fail "no response from $BASE_URL/health (connection refused, DNS or TLS failure)";;
    404)
        if printf '%s' "$body" | grep -q '404 page not found'; then
            fail "/health -> 404 'page not found' (Go plain text). That is Traefik's own 404,
         meaning no router matched and the request never reached the container."
            rule
            printf 'Cannot continue. Run scripts/diagnose-traefik.sh on the Docker host.\n'
            exit 1
        fi
        fail "/health -> 404 (body: ${body})";;
    *)       fail "/health -> $code (body: ${body})";;
esac

# ---------------------------------------------------------------------- models
printf '\n[2/5] GET /v1/models\n'
resp=$("${CURL[@]}" -w '\n%{http_code}' "${AUTH[@]}" "$BASE_URL/v1/models" 2>/dev/null)
code=$(last_line "$resp")
body=$(drop_last "$resp")
if [ "$code" = "200" ]; then
    ids=$(printf '%s' "$body" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
    n=$(printf '%s\n' "$ids" | grep -c . )
    pass "/v1/models -> 200, ${n} model(s)"
    printf '%s\n' "$ids" | head -5 | sed 's/^/         /'
    [ "$n" -gt 5 ] && printf '         ... and %s more\n' "$((n - 5))"
    [ -z "$MODEL" ] && MODEL=$(printf '%s\n' "$ids" | head -1)
else
    fail "/v1/models -> $code (body: $(printf '%s' "$body" | head -c 200))"
fi

if [ -z "$MODEL" ]; then
    printf '\nNo model id available, skipping the chat tests.\n'
    rule; printf 'passed=%s failed=%s\n' "$ok" "$bad"
    exit 1
fi
printf '\nUsing model: %s\n' "$MODEL"

# ------------------------------------------------------------ non-streamed call
printf '\n[3/5] POST /v1/chat/completions (non-streamed)\n'
payload=$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly one word: pong"}],"stream":false,"max_tokens":64}' "$MODEL")
resp=$("${CURL[@]}" -w '\n%{http_code}' "${AUTH[@]}" \
    -H 'Content-Type: application/json' \
    -d "$payload" "$BASE_URL/v1/chat/completions" 2>/dev/null)
code=$(last_line "$resp")
body=$(drop_last "$resp")
if [ "$code" = "200" ]; then
    pass "chat/completions -> 200"
    printf '%s' "$body" | grep -o '"content"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/^/         /'
    printf '%s' "$body" | grep -q '"reasoning_content"' \
        && printf '         (response also carries reasoning_content)\n'
    printf '%s' "$body" | grep -q '"finish_reason"' \
        && printf '%s' "$body" | grep -o '"finish_reason"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/^/         /'
else
    fail "chat/completions -> $code (body: $(printf '%s' "$body" | head -c 400))"
fi

# ------------------------------------------------------------------ streamed call
# time_starttransfer is the moment the first byte arrives. When a proxy buffers the
# whole response (Traefik's buffering middleware, nginx proxy_buffering, ...) it lands
# at almost the same instant as time_total instead of early on, and the client sees no
# output until generation has finished. Comparing the two catches that.
printf '\n[4/5] POST /v1/chat/completions (streamed, SSE)\n'
spayload=$(printf '{"model":"%s","messages":[{"role":"user","content":"Count from 1 to 10, one number per line."}],"stream":true,"max_tokens":128}' "$MODEL")
sse=$(mktemp)
timing=$("${CURL[@]}" -N -o "$sse" -w '%{http_code} %{time_starttransfer} %{time_total}' "${AUTH[@]}" \
    -H 'Content-Type: application/json' -H 'Accept: text/event-stream' \
    -d "$spayload" "$BASE_URL/v1/chat/completions" 2>/dev/null)
scode=$(printf '%s' "$timing" | cut -d' ' -f1)
ttfb=$(printf '%s' "$timing" | cut -d' ' -f2)
ttot=$(printf '%s' "$timing" | cut -d' ' -f3)
chunks=$(grep -c '^data:' "$sse" 2>/dev/null || echo 0)
done_seen=$(grep -c '^data: \[DONE\]' "$sse" 2>/dev/null || echo 0)

if [ "$scode" = "200" ] && [ "$chunks" -gt 0 ]; then
    pass "stream -> 200, ${chunks} SSE chunk(s), first byte at ${ttfb}s, done at ${ttot}s"
    printf '%s\n' "         first chunk: $(grep -m1 '^data:' "$sse" | head -c 160)"
    [ "$done_seen" -gt 0 ] && printf '         terminated with [DONE]\n'
    buffered=$(awk -v a="$ttfb" -v b="$ttot" 'BEGIN { print (b > 0 && a >= b * 0.9) ? "yes" : "no" }')
    if [ "$buffered" = "yes" ]; then
        fail "the first byte arrived at ${ttfb}s out of ${ttot}s total -- the response looks
         BUFFERED. Something between you and the container is accumulating the whole
         body, so streaming is broken. With Traefik, remove the buffering middleware
         from this router."
    else
        pass "first byte arrived early (${ttfb}s of ${ttot}s), the response is streamed"
    fi
else
    fail "stream -> ${scode} (chunks=${chunks}, body: $(head -c 300 "$sse" 2>/dev/null))"
fi
rm -f "$sse"

# ------------------------------------------------------------------- public surface
# The backend opencode server can run shell commands and read files. If it is
# published anywhere, that is a remote-code-execution surface, so it is worth
# reporting rather than silently ignoring.
printf '\n[5/5] Leak check on the backend port\n'
backend="${BASE_URL%:*}"
backend="${backend%/*}"
backend_port="${OPENCODE_SERVER_PORT:-10001}"
if [ "$backend_port" = "10000" ]; then
    skip "not checked (same as the proxy port)"
else
    bcode=$(curl -sS -o /dev/null -w '%{http_code}' --noproxy '*' --connect-timeout 5 --max-time 8 \
        "${backend}:${backend_port}/global/health" 2>/dev/null) || bcode=000
    case "$bcode" in
        000) pass "port ${backend_port} is not reachable from here";;
        401|403) pass "port ${backend_port} is reachable but demands auth (${bcode})";;
        *)   fail "port ${backend_port} answered ${bcode} without auth. That is the opencode
         backend itself, which can run shell commands and read files. Do not expose it.";;
    esac
fi

rule
printf 'passed=%s failed=%s\n' "$ok" "$bad"
[ "$bad" -eq 0 ] || exit 1
