#!/usr/bin/env bash
# End-to-end check that a deployed opencode2api instance really answers model calls.
#
#   BASE_URL=https://opencode.example.com:99 API_KEY=sk-xxx ./scripts/test-api.sh
#
# Environment:
#   BASE_URL    base URL of the proxy                     (default http://127.0.0.1:10000)
#   API_KEY     value for "Authorization: Bearer <key>"   (omit when the proxy has no key)
#   MODEL       model id used by the chat tests           (auto-detected from /v1/models)
#   TIMEOUT     per-request max time, seconds             (default 180)
#   INSECURE    1 = skip TLS verification                 (default 0)
#   RESOLVE     host:port:ip, pins DNS for the whole run (see the note below)
#   BACKEND_URL hostname that must NOT serve the backend opencode server, e.g. a second
#               Traefik router pointing at container port 10001
#               (default: the BASE_URL host on port 10001)
#
# Exit status: 0 when every check passed, 1 otherwise.

set -u

BASE_URL="${BASE_URL:-http://127.0.0.1:10000}"
BASE_URL="${BASE_URL%/}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
TIMEOUT="${TIMEOUT:-180}"

# --noproxy '*': a loopback target must never be handed to an HTTP proxy. If
# http_proxy is set and the request is sent there instead, curl still exits 0 and the
# status you read back belongs to the proxy, not to the server under test.
CURL=(curl -sS --noproxy '*' --connect-timeout 10 --max-time "$TIMEOUT")
[ "${INSECURE:-0}" = "1" ] && CURL+=(-k)
# A local TUN proxy (Clash/Surge fake-ip) answers DNS with a synthetic address in
# 198.18.0.0/15 and then intermittently fails to route it. Pin the real IP to remove the
# DNS layer entirely: RESOLVE="host:port:1.2.3.4"
[ -n "${RESOLVE:-}" ] && CURL+=(--resolve "$RESOLVE")

AUTH=()
[ -n "$API_KEY" ] && AUTH=(-H "Authorization: Bearer ${API_KEY}")

ok=0
bad=0
rule() { printf '%s\n' "------------------------------------------------------------"; }
pass() { ok=$((ok + 1));  printf '  [PASS] %s\n' "$*"; }
fail() { bad=$((bad + 1)); printf '  [FAIL] %s\n' "$*"; }

# A request built with -w '\n%{http_code}' yields "<body>\n<code>". The command
# substitution strips trailing newlines, so the code is whatever follows the last one.
last_line() { printf '%s' "${1##*$'\n'}"; }
drop_last() { printf '%s' "${1%$'\n'*}"; }

rule
printf 'Target : %s\n' "$BASE_URL"
printf 'API key: %s\n' "$([ -n "$API_KEY" ] && echo set || echo 'not set')"
rule

# ------------------------------------------------------------- 1. is it reachable
# This step exists because Traefik answers an unmatched route with a 19-byte plain text
# "404 page not found", which is easy to mistake for the app rejecting the path. The
# app's own 404 is JSON (see res.status(404).json in src/proxy.js), so the body alone
# tells the two apart.
printf '\n[1/5] Reachability\n'
proxy_ok=1
probe=$(mktemp)
# Judge the captured value, not curl's exit status: on some Windows shells curl exits 23
# ("client returned ERROR on write") even when it printed the status code correctly, and
# `|| code=000` would then overwrite a good 200 with 000.
code=$("${CURL[@]}" -o "$probe" -w '%{http_code}' "$BASE_URL/health" 2>/dev/null)
[ -n "$code" ] || code=000
body=$(head -c 300 "$probe" 2>/dev/null)
rm -f "$probe" 2>/dev/null || true

case "$code" in
    200)     pass "/health -> 200";;
    401|403) pass "/health -> $code (reachable; a key is required)";;
    000)     fail "no response from $BASE_URL/health (connection refused, DNS or TLS failure)"
             proxy_ok=0;;
    404)
        if printf '%s' "$body" | grep -q '404 page not found'; then
            fail "/health -> 404 'page not found' (Go plain text). That is Traefik's own 404,
         meaning no router matched and the request never reached the container.
         Run scripts/diagnose-traefik.sh on the Docker host."
            proxy_ok=0
        else
            fail "/health -> 404 (body: ${body})"
            proxy_ok=0
        fi;;
    *)       fail "/health -> $code (body: ${body})"
             proxy_ok=0;;
esac

# ------------------------------------------------------- 5. backend exposure check
# Run this regardless of whether the proxy answered. It is independent of the proxy and
# is the finding that matters most when routing is broken: a deployment can be
# unreachable on its own hostname while the backend sits wide open on another one.
#
# The backend opencode server can run shell commands and read arbitrary files, so it
# must never be reachable without authentication. The usual accident is not a published
# port but a second Traefik router pointing at container port 10001: that serves the
# backend under its own hostname, where a port-based check would never look.
printf '\n[5/5] Backend exposure check\n'
if [ -n "${BACKEND_URL:-}" ]; then
    targets="${BACKEND_URL%/}"
else
    host="${BASE_URL#*//}"          # strip scheme
    host="${host%%/*}"              # strip path
    host="${host%%:*}"              # strip port
    targets="http://${host}:${OPENCODE_SERVER_PORT:-10001}"
fi

for t in $targets; do
    bresp=$(curl -sS -w '\n%{http_code}' --noproxy '*' --connect-timeout 5 --max-time 10 \
        "$t/global/health" 2>/dev/null)
    bcode=$(last_line "$bresp")
    [ -n "$bcode" ] || bcode=000
    bbody=$(drop_last "$bresp")
    case "$bcode" in
        000)     pass "$t not reachable";;
        404)
            # A plain-text 404 is the reverse proxy's own: no router matches this
            # hostname, so the backend is simply not published here. Counting it as a
            # failure was wrong -- it is the state you want.
            if printf '%s' "$bbody" | grep -q '404 page not found'; then
                pass "$t -> 404 from the reverse proxy (no router; the backend is not published here)"
            else
                fail "$t -> 404, but the body is not the reverse proxy's own: $(printf '%s' "$bbody" | head -c 120)"
            fi;;
        401|403) pass "$t reachable but requires auth (${bcode})";;
        *)       fail "$t answered ${bcode} WITHOUT authentication. That is the opencode
         backend itself, which can run shell commands and read arbitrary files. Close
         the router that points at container port 10001; the proxy on 10000 is the
         only thing that belongs on the internet.";;
    esac
done

if [ "$proxy_ok" = "0" ]; then
    printf '\n[2/5]-[4/5] skipped: the proxy was never reached, so the model checks would only add noise.\n'
    rule
    printf 'passed=%s failed=%s\n' "$ok" "$bad"
    exit 1
fi

# ---------------------------------------------------------------------- 2. models
printf '\n[2/5] GET /v1/models\n'
resp=$("${CURL[@]}" -w '\n%{http_code}' "${AUTH[@]}" "$BASE_URL/v1/models" 2>/dev/null)
code=$(last_line "$resp")
body=$(drop_last "$resp")
if [ "$code" = "200" ]; then
    ids=$(printf '%s' "$body" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
    n=$(printf '%s\n' "$ids" | grep -c .)
    pass "/v1/models -> 200, ${n} model(s)"
    printf '%s\n' "$ids" | head -5 | sed 's/^/         /'
    [ "$n" -gt 5 ] && printf '         ... and %s more\n' "$((n - 5))"
    [ -z "$MODEL" ] && MODEL=$(printf '%s\n' "$ids" | head -1)
else
    fail "/v1/models -> $code (body: $(printf '%s' "$body" | head -c 200))"
fi

if [ -z "$MODEL" ]; then
    printf '\nNo model id available, skipping the chat tests.\n'
    rule
    printf 'passed=%s failed=%s\n' "$ok" "$bad"
    exit 1
fi
printf '\nUsing model: %s\n' "$MODEL"

# ------------------------------------------------------------ 3. non-streamed call
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

# ------------------------------------------------------------------ 4. streamed call
# time_starttransfer is the moment the first byte arrives. When a proxy buffers the
# whole response (Traefik's buffering middleware, nginx proxy_buffering, ...) it lands
# at almost the same instant as time_total instead of early on, and the client sees no
# output until generation has finished. Comparing the two catches that.
printf '\n[4/5] POST /v1/chat/completions (streamed, SSE)\n'
spayload=$(printf '{"model":"%s","messages":[{"role":"user","content":"Count from 1 to 10, one number per line."}],"stream":true,"max_tokens":128}' "$MODEL")
# Use curl's own instants rather than timestamping each SSE line from a shell read loop.
# Process creation costs hundreds of milliseconds per call on some systems (measured at
# ~475ms on Windows/Git Bash), so per-line stamps measure how fast the loop drained its
# buffer rather than when the bytes arrived. curl's time_starttransfer and time_total are
# exact and cost nothing.
sse=$(mktemp)
metrics=$("${CURL[@]}" -N -o "$sse" -w '%{http_code} %{time_starttransfer} %{time_total}' \
    "${AUTH[@]}" \
    -H 'Content-Type: application/json' -H 'Accept: text/event-stream' \
    -d "$spayload" "$BASE_URL/v1/chat/completions" 2>/dev/null)
scode=$(printf '%s' "$metrics" | cut -d' ' -f1)
ttfb=$(printf '%s' "$metrics" | cut -d' ' -f2)
ttot=$(printf '%s' "$metrics" | cut -d' ' -f3)
# Count content chunks only: the [DONE] sentinel is a `data:` line too, and including it
# reported one more chunk than there were actual deltas. awk also sidesteps the
# `grep -c ... || echo 0` trap, which yields "0\n0" because grep -c prints 0 AND exits 1.
chunks=$(awk '/^data:/ && $0 != "data: [DONE]" { n++ } END { print n + 0 }' "$sse")
done_seen=$(awk '$0 == "data: [DONE]" { n++ } END { print n + 0 }' "$sse")

if [ "$scode" = "200" ] && [ "$chunks" -gt 0 ]; then
    pass "stream -> 200, ${chunks} SSE chunk(s), first byte at ${ttfb}s, done at ${ttot}s"
    printf '         first chunk: %s\n' "$(grep -m1 '^data:' "$sse" | head -c 160)"
    [ "$done_seen" -gt 0 ] && printf '         terminated with [DONE]\n'
    # A buffer hands the whole body over at once, so the first and last byte nearly
    # coincide. Compare that window ABSOLUTELY. A ratio test also fires on a short answer
    # that follows a long first token -- normal for a reasoning model, not buffering --
    # and it produced false positives here twice before this was rewritten.
    gap_ms=$(awk -v a="$ttfb" -v b="$ttot" 'BEGIN { printf "%d", (b - a) * 1000 }')
    if [ "$gap_ms" -lt 100 ]; then
        fail "only ${gap_ms}ms between the first and last byte, so the body came in one
         burst. Something between you and the container is buffering it. With Traefik,
         remove the buffering middleware from this router."
    else
        pass "the body streamed over ${gap_ms}ms (first byte ${ttfb}s, last ${ttot}s)"
    fi
else
    fail "stream -> ${scode} (chunks=${chunks}, body: $(head -c 300 "$sse" 2>/dev/null))"
fi
rm -f "$sse" 2>/dev/null || true

rule
printf 'passed=%s failed=%s\n' "$ok" "$bad"
[ "$bad" -eq 0 ] || exit 1
