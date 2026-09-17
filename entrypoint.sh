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
    MAX_RETRIES=30
    COUNT=0
    while ! curl -s http://127.0.0.1:${SERVER_PORT}/health > /dev/null; do
        if [ $COUNT -ge $MAX_RETRIES ]; then
            echo "Timeout waiting for OpenCode Server."
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
    echo "OpenCode Server is up!"

    echo "Starting OpenAI Proxy on port ${PROXY_PORT}..."
    exec gosu node node index.js
else
    exec gosu node "$@"
fi