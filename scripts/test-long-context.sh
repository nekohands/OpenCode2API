#!/usr/bin/env bash
# Reproduce a streaming failure on long-context requests.
#
# A long prompt makes a model slow to emit its first token. The proxy has two timers
# that end the stream when nothing arrives:
#
#   OPENCODE2API_EVENT_FIRST_DELTA_TIMEOUT_MS  (default 30000)  no first token in time
#   OPENCODE2API_EVENT_IDLE_TIMEOUT_MS         (default  8000)  gap between tokens
#
# Both fall back to polling the session for the finished message. That loses true
# streaming, and if the poll also comes up short the response ends without a normal
# finish. Neither variable is documented anywhere, which is why this failure mode is
# hard to attribute. This script sends a prompt of roughly the requested size and
# reports the timings that decide the question.
#
#   BASE_URL=https://host:99 API_KEY=sk-xxx ./scripts/test-long-context.sh
#
# Environment:
#   BASE_URL        proxy base URL                     (default http://127.0.0.1:10000)
#   API_KEY         Bearer token
#   MODEL           model id                           (auto-detected from /v1/models)
#   TARGET_TOKENS   approximate prompt size in tokens  (default 50000)
#   MAX_TOKENS      max output tokens                  (default 256)
#   TIMEOUT         per-request max time, seconds      (default 600)
#   INSECURE        1 = skip TLS verification          (default 0)
#   RESOLVE         host:port:ip, pins DNS for the whole run (see the note below)

set -u

BASE_URL="${BASE_URL:-http://127.0.0.1:10000}"
BASE_URL="${BASE_URL%/}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-}"
TARGET_TOKENS="${TARGET_TOKENS:-50000}"
MAX_TOKENS="${MAX_TOKENS:-256}"
TIMEOUT="${TIMEOUT:-600}"

CURL=(curl -sS --noproxy '*' --connect-timeout 10 --max-time "$TIMEOUT")
[ "${INSECURE:-0}" = "1" ] && CURL+=(-k)
# A local TUN proxy (Clash/Surge fake-ip) answers DNS with a synthetic address in
# 198.18.0.0/15 and then intermittently fails to route it, which surfaces as 000 on some
# attempts and 200 on others. Pinning the real IP removes the DNS layer entirely:
#   RESOLVE="host:port:1.2.3.4"
[ -n "${RESOLVE:-}" ] && CURL+=(--resolve "$RESOLVE")
AUTH=()
[ -n "$API_KEY" ] && AUTH=(-H "Authorization: Bearer ${API_KEY}")

rule() { printf '%s\n' "------------------------------------------------------------"; }
info() { printf '  %s\n' "$*"; }
bad()  { printf '  !! %s\n' "$*"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT
body="$tmp/body"
payload="$tmp/payload.json"

rule
printf 'Target      : %s\n' "$BASE_URL"
printf 'Target size : ~%s tokens\n' "$TARGET_TOKENS"
printf 'API key     : %s\n' "$([ -n "$API_KEY" ] && echo set || echo 'not set')"
rule

# ---------------------------------------------------------------- reachability
# Only an EMPTY result counts as failure. On some Windows shells curl exits 23
# ("client returned ERROR on write") even when it printed the status code correctly, so
# `|| code=000` would overwrite a perfectly good 200 with 000. Judge the captured value,
# never curl's exit status.
code=""
for _ in 1 2 3; do
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE_URL/health" 2>/dev/null)
    [ -n "$code" ] && break
    sleep 2
done
[ -n "$code" ] || code=000
if [ "$code" != "200" ] && [ "$code" != "401" ] && [ "$code" != "403" ]; then
    bad "/health -> ${code}. The request never reaches the proxy, so nothing below would be meaningful."
    if [ "$code" = "404" ]; then
        bad "A plain-text 404 is the reverse proxy's own; see scripts/diagnose-traefik.sh."
    elif [ "$code" = "000" ]; then
        bad "No connection at all, three attempts in a row. Check the host and port, and note"
        bad "that a local proxy can also cause this -- retry with RESOLVE=<host>:<port>:<real-ip>."
    fi
    exit 1
fi
info "/health -> ${code}"

# ---------------------------------------------------------------------- model
if [ -z "$MODEL" ]; then
    resp=$("${CURL[@]}" -w '\n%{http_code}' "${AUTH[@]}" "$BASE_URL/v1/models" 2>/dev/null)
    MODEL=$(printf '%s' "$resp" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
    if [ -z "$MODEL" ]; then
        bad "could not read a model id from /v1/models; set MODEL=... explicitly"
        exit 1
    fi
fi
info "model: ${MODEL}"

# -------------------------------------------------------------------- payload
# ~4 characters per token for English prose. The filler is plain ASCII with no quotes or
# backslashes so it can be embedded in JSON as-is, and it is written to a file rather
# than passed on the command line because a 200 KB argv is not portable.
chars=$(( TARGET_TOKENS * 4 ))
sentence='The quick brown fox jumps over the lazy dog and then rests for a while. '
per=${#sentence}
reps=$(( chars / per ))
{
    printf '{"model":"%s","messages":[{"role":"user","content":"' "$MODEL"
    i=0
    while [ "$i" -lt "$reps" ]; do printf '%s' "$sentence"; i=$((i + 1)); done
    printf '\\n\\nIgnore the text above. Reply with exactly one word: pong"}]'
    printf ',"stream":true,"max_tokens":%s}' "$MAX_TOKENS"
} > "$payload"
info "payload: $(wc -c < "$payload") bytes (~$TARGET_TOKENS tokens)"

# --------------------------------------------------------------------- stream
printf '\nSending. The first token may take minutes at this size.\n'
# curl reports the two instants that matter, accurately and for free:
#   time_starttransfer = when the first body byte arrived
#   time_total         = when the last one did
# Do NOT timestamp each SSE line from a shell read loop instead: process creation costs
# hundreds of milliseconds per call on some systems (measured at ~475ms on Windows/Git
# Bash), so those stamps measure how fast the loop drained its buffer rather than when
# the bytes arrived, and the computed spread comes out several times too large.
metrics=$("${CURL[@]}" -N -o "$body" \
    -w '%{http_code} %{time_starttransfer} %{time_total}' "${AUTH[@]}" \
    -H 'Content-Type: application/json' -H 'Accept: text/event-stream' \
    -d @"$payload" "$BASE_URL/v1/chat/completions" 2>/dev/null)

status=$(printf '%s' "$metrics" | cut -d' ' -f1)
ttfb=$(printf '%s' "$metrics" | cut -d' ' -f2)
ttot=$(printf '%s' "$metrics" | cut -d' ' -f3)
printf '\nHTTP: %s\n' "${status:-<none>}"

chunks=$(grep -c '^data:' "$body" 2>/dev/null)
chunks=${chunks:-0}
done_seen=$(grep -c '^data: \[DONE\]' "$body" 2>/dev/null)
done_seen=${done_seen:-0}

if [ "$chunks" -eq 0 ]; then
    bad "the response contained no SSE chunks at all."
    printf '  body: %s\n' "$(head -c 400 "$body")"
    exit 1
fi

ttfb_ms=$(awk -v a="$ttfb" 'BEGIN { printf "%d", a * 1000 }')
gap_ms=$(awk -v a="$ttfb" -v b="$ttot" 'BEGIN { printf "%d", (b - a) * 1000 }')

rule
printf 'chunks            : %s\n' "$chunks"
printf 'first byte at     : %s ms\n' "$ttfb_ms"
printf 'last byte at      : %s ms\n' "$(awk -v b="$ttot" 'BEGIN { printf "%d", b * 1000 }')"
printf 'streaming window  : %s ms   (last byte - first byte)\n' "$gap_ms"
printf 'terminated [DONE] : %s\n' "$([ "$done_seen" -gt 0 ] && echo yes || echo NO)"

rule
verdict=0
if [ "$done_seen" -eq 0 ]; then
    bad "the stream ended WITHOUT a [DONE] sentinel -- the response was cut short."
    verdict=1
fi
if [ "$ttfb_ms" -ge 30000 ]; then
    bad "the first byte took ${ttfb_ms} ms, at or past the default first-delta timeout (30000 ms)."
    info "The proxy most likely abandoned the event stream and fell back to polling."
    info "Raise OPENCODE2API_EVENT_FIRST_DELTA_TIMEOUT_MS, e.g. 300000 for long contexts."
    verdict=1
fi
# A buffer hands over the whole body at once, so the two instants nearly coincide. This
# is an ABSOLUTE comparison on purpose: a ratio test also fires on a short answer that
# follows a long first token, which is normal for a reasoning model, not buffering.
if [ "$gap_ms" -lt 100 ]; then
    bad "only ${gap_ms} ms between the first and last byte, so the body arrived in one burst."
    info "Something between you and the proxy is buffering the response."
    info "With Traefik, remove the buffering middleware from this router."
    verdict=1
fi
if [ "$verdict" -eq 0 ]; then
    info "the stream started and finished normally at this size."
    info "If a client still reports a broken stream, the cut is downstream of the proxy:"
    info "check the reverse proxy read timeout and any buffering middleware, then the client."
fi
exit "$verdict"
