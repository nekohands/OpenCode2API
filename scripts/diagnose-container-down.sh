#!/usr/bin/env bash
# Run this ON THE DOCKER HOST when containers that should be running are not.
#
#   ./scripts/diagnose-container-down.sh [name ...]
#
# With no arguments it inspects every container that is not Up, plus the usual host-level
# suspects. When a container is gone rather than crashed, the router that pointed at it
# disappears from the reverse proxy too, so the visible symptom is a 404 on the hostname
# rather than anything that mentions the container -- which is why this is worth checking
# before touching any proxy configuration.
#
# The three findings that matter most are OOMKilled, a host reboot, and a full disk.

set -u

rule() { printf '\n%s\n' "============================================================"; }
step() { printf '\n--- %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || { echo "docker not found in PATH"; exit 1; }

rule; echo "1. Host state"
info "uptime : $(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"
info "since  : $(uptime -s 2>/dev/null || echo unknown)"
# A reboot explains a whole set of containers stopping at once. `restart: unless-stopped`
# brings them back automatically, so if everything is down after a reboot the restart
# policy is not what you think it is, or they were stopped by hand first.
info "memory :"
free -h 2>/dev/null | sed 's/^/    /' || warn "free not available"
info "disk   :"
df -h / /var/lib/docker 2>/dev/null | sort -u | sed 's/^/    /' || warn "df not available"

rule; echo "2. Containers that are not Up"
stopped=$(docker ps -a --filter 'status=exited' --filter 'status=created' \
    --filter 'status=dead' --filter 'status=paused' --filter 'status=restarting' \
    --format '{{.Names}}')
if [ -n "$stopped" ]; then
    docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Image}}' \
        | grep -vE '  .*Up ' || true
else
    info "every container is Up"
fi

if [ "$#" -gt 0 ]; then
    stopped="$*"
fi

rule; echo "3. Why each one stopped"
for c in $stopped; do
    step "$c"
    docker inspect -f \
        '  status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} err={{.State.Error}}' \
        "$c" 2>/dev/null || { warn "cannot inspect $c"; continue; }
    fin=$(docker inspect -f '{{.State.FinishedAt}}' "$c" 2>/dev/null)
    started=$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null)
    info "started=$started finished=$fin"
    policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)
    info "restart policy: ${policy:-<none>}"
    [ "$policy" = "no" ] || [ -z "$policy" ] && \
        warn "no restart policy -- it will stay down until started by hand"

    oom=$(docker inspect -f '{{.State.OOMKilled}}' "$c" 2>/dev/null)
    if [ "$oom" = "true" ]; then
        warn "OOMKilled: the kernel killed it for memory. Raise the container limit, or"
        warn "check whether something else on the host is consuming memory."
    fi

    step "last 30 log lines of $c"
    docker logs --tail 30 "$c" 2>&1 | sed 's/^/    /' || info "(no logs)"
done

rule; echo "4. Kernel and daemon level evidence"
step "OOM kills in the kernel log"
if command -v dmesg >/dev/null 2>&1; then
    dmesg 2>/dev/null | grep -iE 'killed process|out of memory|oom-kill' | tail -10 | sed 's/^/  /' \
        || info "nothing found"
else
    info "dmesg not available"
fi

step "docker daemon restarts"
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u docker --since '2 days ago' --no-pager 2>/dev/null \
        | grep -iE 'starting up|shutting down|stopped|failed' | tail -10 | sed 's/^/  /' \
        || info "nothing found"
else
    info "journalctl not available"
fi

rule; echo "5. What to do with the result"
cat <<'EOF'
  oom=true                     -> memory pressure; give the container a limit and check
                                  what else is running, or add swap
  exit=137 without oom=true    -> SIGKILL from outside the kernel OOM path, usually
                                  `docker stop` or a `docker system prune`
  restart policy "no"          -> nothing will bring it back; set restart: unless-stopped
  host uptime very short       -> the machine rebooted; check why
  disk at 100%                 -> docker cannot start containers at all; free space first

  After starting a container again, remember that new-api DISABLES a channel after
  repeated upstream failures and does not re-enable it automatically. The models stay
  missing from /v1/models until the channel is enabled by hand in its admin UI, so
  "the container is up but the model is still gone" is expected until you do that.
EOF
