#!/usr/bin/env bash
# Run this ON THE DOCKER HOST to find out why a Traefik-fronted deployment answers
# "404 page not found" for every path.
#
#   ./scripts/diagnose-traefik.sh [app_container] [traefik_container]
#
# Defaults: app_container=opencode2api   traefik_container=traefik
#
# Background: Traefik answers a request with a plain-text "404 page not found\n"
# (19 bytes, Go's http.NotFound) when NO router matches. It answers 502/503 when a
# router matches but its backend is unreachable. So a 404 means the request never
# reached the container, and the cause is always one of:
#   a) the container is not running            -> its router is dropped
#   b) the router labels are missing/invalid   -> the router is dropped
#   c) the router is bound to a different entrypoint than the one you connect to
#   d) Traefik's Docker provider cannot see the container (wrong network, no socket)
# This script checks all four.

set -u

APP="${1:-opencode2api}"
TRAEFIK="${2:-traefik}"

PROXY_PORT="${OPENCODE_PROXY_PORT:-10000}"

rule()  { printf '\n%s\n' "============================================================"; }
step()  { printf '\n--- %s\n' "$*"; }
warn()  { printf '  !! %s\n' "$*"; }
info()  { printf '  %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || { echo "docker not found in PATH"; exit 1; }

inspect() { docker inspect -f "$2" "$1" 2>/dev/null; }

rule; echo "0. Docker"
docker version --format '  server {{.Server.Version}} (api {{.Server.APIVersion}})' 2>/dev/null || warn "cannot talk to the Docker daemon"

rule; echo "1. Are the containers running?"
docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Image}}' | grep -E "^  (${APP}|${TRAEFIK})\b" || warn "neither '${APP}' nor '${TRAEFIK}' found; adjust the arguments"

step "app container state"
state=$(inspect "$APP" '{{.State.Status}}')
health=$(inspect "$APP" '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}')
exitcode=$(inspect "$APP" '{{.State.ExitCode}}')
err=$(inspect "$APP" '{{.State.Error}}')
if [ -z "$state" ]; then
    warn "container '${APP}' does not exist -- if it was never created, check 'docker compose up' output for an IP/network error"
else
    info "status=${state}  health=${health}  exit=${exitcode}  error=${err:-none}"
    if [ "$state" != "running" ]; then
        warn "the container is NOT running, so Traefik has no router for it and returns 404."
        warn "look at the last lines of: docker logs --tail 50 ${APP}"
    fi
fi

rule; echo "2. Is the app actually serving inside its own container?"
if [ "$state" = "running" ]; then
    probe=$(docker exec "$APP" curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PROXY_PORT}/health" 2>&1)
    case "$probe" in
        200) info "/health -> 200, the proxy is up";;
        *)   warn "/health -> ${probe}  (expected 200). The container is running but not serving.";;
    esac
else
    warn "skipped, container not running"
fi

rule; echo "3. Which network(s) is each container on, and with which IP?"
appnets=$(inspect "$APP" '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}')
trknets=$(inspect "$TRAEFIK" '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}')
info "app     : ${appnets:-<none>}"
info "traefik : ${trknets:-<none>}"

shared=0
for n in $appnets; do
    name="${n%%=*}"
    case " $trknets " in *" $name="*) shared=1; info "shared network: ${name}";; esac
done
[ "$shared" = "1" ] || warn "the two containers share NO network -- Traefik cannot reach the app even if the router exists"

step "IPAM of each app network (a fixed ipv4_address equal to the gateway breaks 'up')"
for n in $appnets; do
    name="${n%%=*}"
    cfg=$(docker network inspect -f '{{range .IPAM.Config}}subnet={{.Subnet}} gateway={{.Gateway}}{{end}}' "$name" 2>/dev/null)
    ip="${n##*=}"
    info "${name}: ${cfg}  (app ip=${ip})"
    gw=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$name" 2>/dev/null)
    if [ -n "$gw" ] && [ "$ip" = "$gw" ]; then
        warn "the app container took the GATEWAY address ${gw} on ${name}."
        warn "That is the classic 'docker compose up' failure: 'Address already in use'."
        warn "Use .2 or higher for a fixed ipv4_address."
    fi
done

rule; echo "4. Traefik labels actually present on the container"
labels=$(docker inspect -f '{{range $k,$v := .Config.Labels}}{{if eq (printf "%.7s" $k) "traefik"}}{{$k}}={{$v}}{{"\n"}}{{end}}{{end}}' "$APP" 2>/dev/null)
if [ -z "$labels" ]; then
    warn "no traefik.* labels on '${APP}'. With providers.docker.exposedByDefault=false,"
    warn "Traefik ignores the container entirely and every request 404s."
else
    printf '%s' "$labels" | sed 's/^/  /'
    printf '%s' "$labels" | grep -q 'traefik.enable=true' \
        || warn "traefik.enable=true is missing; add it if exposedByDefault is false"
    printf '%s' "$labels" | grep -q 'loadbalancer.server.port' \
        || warn "no traefik.http.services.*.loadbalancer.server.port label; Traefik must guess the port"
    printf '%s' "$labels" | grep -q 'traefik.docker.network' \
        || warn "no traefik.docker.network label; when the container is on several networks Traefik may pick the wrong one"
fi

rule; echo "5. Traefik itself"
step "published ports"
docker port "$TRAEFIK" 2>/dev/null | sed 's/^/  /' || warn "cannot read ports"
info "(the host port you connect to must be listed here; if you reach :99, some entrypoint is mapped to 99)"

step "command line / entrypoints"
args=$(inspect "$TRAEFIK" '{{join .Args " "}}')
cmd=$(inspect "$TRAEFIK" '{{join .Config.Cmd " "}}')
info "cmd : ${cmd:-<none>}"
[ -n "$args" ] && printf '%s' "$args" | tr ' ' '\n' | grep -E 'entrypoints|providers|api' | sed 's/^/  /'
info "NOTE: a router only answers on the entrypoints listed in its"
info "      traefik.http.routers.<name>.entrypoints label. If your router says"
info "      'websecure' but you connect to :99, you get exactly this 404."

step "docker socket mounted? (without it the Docker provider discovers nothing)"
mounts=$(inspect "$TRAEFIK" '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}')
printf '%s' "$mounts" | grep -i 'docker.sock' | sed 's/^/  /' || warn "no docker.sock mount found; Traefik cannot read container labels"

step "recent Traefik errors"
docker logs --tail 400 "$TRAEFIK" 2>&1 | grep -iE 'error|level=error|cannot|unable|no valid' | tail -30 | sed 's/^/  /' || info "no error lines"

step "anything Traefik logged about this app"
docker logs --tail 400 "$TRAEFIK" 2>&1 | grep -iE "$APP|opencode" | tail -20 | sed 's/^/  /' || info "nothing"

rule; echo "6. What to do with the result"
cat <<'EOF'
  - container not running      -> docker compose up -d, then read the error it prints
  - ip == gateway              -> change ipv4_address to .2, or drop it and let Docker assign
  - no traefik.* labels        -> add them (see docker-compose.yml in this repo)
  - router entrypoints mismatch-> align the label with the host port you actually connect to
  - no docker.sock mount       -> mount /var/run/docker.sock:/var/run/docker.sock:ro
  - still stuck                -> temporarily publish the proxy port directly,
                                  e.g. -p 10000:10000, and curl it on the host. That
                                  separates "the app is broken" from "Traefik is misconfigured".
EOF
