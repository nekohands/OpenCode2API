#!/bin/bash

PUID=${PUID:-1000}
PGID=${PGID:-1000}
OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD:-}

if [ "$(id -g node)" -ne "$PGID" ]; then
    groupmod -o -g "$PGID" node
fi

if [ "$(id -u node)" -ne "$PUID" ]; then
    usermod -o -u "$PUID" node
fi

chown -R node:node /home/node/.local/share/opencode
chown -R node:node /home/node/.config/opencode
chown -R node:node /home/node/project

# Allow overriding via environment variables
PROXY_PORT=${OPENCODE_PROXY_PORT:-10000}
SERVER_PORT=${OPENCODE_SERVER_PORT:-10001}

if [[ "${OPENCODE_PROXY_PROMPT_MODE:-standard}" == "plugin-inject" ]]; then
    echo "Preparing opencode2api plugin-inject prompt mode..."
    mkdir -p /home/node/.config/opencode/plugin/opencode2api-empty
    cat > /home/node/.config/opencode/plugin/opencode2api-empty/index.js <<'EOF'
export const Opencode2apiEmptyPlugin = async () => ({})
export default Opencode2apiEmptyPlugin
EOF

    # Merge into opencode.json instead of overwriting it.
    #
    # /home/node/.config/opencode is normally bind-mounted from the host, and operators
    # keep their providers, models and instructions in this file. The previous version
    # did a plain `cat >`, so every restart silently wiped that file back to a three-key
    # stub — the container then came up with no usable provider/model configuration.
    # Here we only ensure the plugin is registered, leaving everything else untouched.
    CONFIG_FILE=/home/node/.config/opencode/opencode.json
    PLUGIN_PATH=/home/node/.config/opencode/plugin/opencode2api-empty/index.js
    node -e '
        const fs = require("fs");
        const file = process.argv[1];
        const pluginPath = process.argv[2];
        let cfg = {};
        if (fs.existsSync(file)) {
            try {
                cfg = JSON.parse(fs.readFileSync(file, "utf8")) || {};
            } catch (err) {
                console.error("[entrypoint] opencode.json is not valid JSON (" + err.message + "); leaving it untouched.");
                process.exit(0);
            }
        }
        const plugins = Array.isArray(cfg.plugin) ? cfg.plugin : [];
        if (!plugins.includes(pluginPath)) plugins.push(pluginPath);
        cfg.plugin = plugins;
        if (!Array.isArray(cfg.instructions)) cfg.instructions = [];
        if (!cfg.theme) cfg.theme = "system";
        fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
        console.log("[entrypoint] Registered plugin-inject plugin in " + file);
    ' "$CONFIG_FILE" "$PLUGIN_PATH"

    chown -R node:node /home/node/.config/opencode
fi

if [[ "$1" == "opencode" && "$2" == "serve" ]]; then
    echo "Initializing OpenCode-to-OpenAI (Server + Proxy)"
    
    echo "Starting OpenCode Server on internal port ${SERVER_PORT}..."
    gosu node opencode serve --hostname 0.0.0.0 --port ${SERVER_PORT} &
    SERVER_PID=$!
    
    echo "Waiting for OpenCode Server to become available..."
    MAX_RETRIES=60
    COUNT=0
    # Once OPENCODE_SERVER_PASSWORD is set, the server answers 401 to unauthenticated
    # probes, so this check must send the same basic-auth credentials the proxy uses
    # (see buildBackendAuthHeaders in src/proxy.js). Without them the probe never sees a
    # 2xx, and if the request instead hangs there is no output at all to diagnose with.
    # /global/health is the route documented by opencode; /health answers as well.
    HEALTH_URL="http://127.0.0.1:${SERVER_PORT}/global/health"
    CURL_AUTH=()
    if [ -n "${OPENCODE_SERVER_PASSWORD}" ]; then
        CURL_AUTH=(--user "opencode:${OPENCODE_SERVER_PASSWORD}")
    fi

    while true; do
        # --noproxy: this is a loopback call and must never go through an HTTP proxy.
        # If http_proxy is present in the environment, curl hands the request to the
        # proxy, which cannot reach the container's own 127.0.0.1 — the probe then fails
        # on every attempt and the proxy is never started.
        # --max-time keeps a half-open listener from hanging this loop indefinitely.
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --noproxy '*' \
            "${CURL_AUTH[@]}" "$HEALTH_URL" 2>/dev/null)
        CURL_STATUS=$?

        # 2xx means healthy. 401 means the password does not match and 404 means the
        # route moved — in both cases the listener is demonstrably accepting
        # connections, so continue and let the proxy report the real error. 000 means no
        # connection and 5xx is usually a proxy or gateway, so those are worth retrying.
        case "$HTTP_CODE" in
            2??|401|404)
                echo "OpenCode Server is up (${HEALTH_URL} -> HTTP ${HTTP_CODE})."
                break
                ;;
        esac

        if [ $COUNT -ge $MAX_RETRIES ]; then
            echo "Timeout waiting for OpenCode Server after ${MAX_RETRIES}s (last curl exit ${CURL_STATUS}, HTTP ${HTTP_CODE:-none})."
            kill $SERVER_PID 2>/dev/null
            exit 1
        fi

        if ! kill -0 $SERVER_PID 2>/dev/null; then
            echo "OpenCode Server process died unexpectedly."
            exit 1
        fi

        sleep 1
        COUNT=$((COUNT+1))
    done

    echo "Starting OpenAI Proxy on port ${PROXY_PORT}..."
    exec gosu node node index.js
else
    exec gosu node "$@"
fi