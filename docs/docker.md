# 🐳 Docker 部署

<p align="center">
  <img src="https://img.shields.io/badge/version-1.5.0-blue" alt="Version">
</p>

---

## 🚀 快速开始

### 1️⃣ 克隆项目

```bash
git clone https://github.com/TiaraBasori/opencode2api.git
cd opencode2api
```

### 2️⃣ 配置环境变量

```bash
cp .env.example .env
# 编辑 .env 文件，设置你的配置
```

### 3️⃣ 启动服务

```bash
docker compose up -d
```

### 4️⃣ 验证

```bash
# 健康检查
curl http://127.0.0.1:10000/health

# 获取模型列表
curl -H "Authorization: Bearer $API_KEY" http://127.0.0.1:10000/v1/models
```

---

## ⚙️ 配置说明

### .env 文件

```env
# 必需配置
API_KEY=change-me
OPENCODE_SERVER_PASSWORD=change-me-too

# 安全相关
DISABLE_TOOLS=true

# 可选配置（下面三项是默认值，通常不需要修改）
OPENCODE_PROXY_PROMPT_MODE=standard
OPENCODE_PROXY_OMIT_SYSTEM_PROMPT=false
OPENCODE_PROXY_AUTO_CLEANUP_CONVERSATIONS=false
```

> ⚠️ 这三项每一项都会**静默改变行为**，排障时很难定位，请确认理解后再开：
>
> | 配置 | 打开后的效果 |
> |:-----|:-------------|
> | `OPENCODE_PROXY_PROMPT_MODE=plugin-inject` | 启动时会改写 `/home/node/.config/opencode/opencode.json`（该目录通常从宿主机挂载，改动会落盘到宿主机） |
> | `OPENCODE_PROXY_OMIT_SYSTEM_PROMPT=true` | 丢弃客户端传来的**全部** system prompt |
> | `OPENCODE_PROXY_AUTO_CLEANUP_CONVERSATIONS=true` | 按 `OPENCODE_PROXY_CLEANUP_MAX_AGE_MS`（默认 24 小时）**删除**历史会话存储 |

---

## 📦 卷挂载

| 卷名 | 容器内路径 | 说明 |
|:-----|:----------|:-----|
| `opencode-data` | `/home/node/.local/share/opencode` | OpenCode 数据目录 |
| `opencode-config` | `/home/node/.config/opencode` | OpenCode 配置目录 |
| 项目目录 | `/home/node/project` | 项目源代码 |

---

## 🔨 自定义构建

### 构建镜像

```bash
docker build -t my-opencode2api .
```

### 运行单个容器

```bash
docker run -d \
  -p 10000:10000 \
  -p 10001:10001 \
  -e API_KEY=your-key \
  -e OPENCODE_SERVER_PASSWORD=your-password \
  -v opencode-data:/home/node/.local/share/opencode \
  -v opencode-config:/home/node/.config/opencode \
  my-opencode2api
```

---

## 📝 生产部署建议

### 移除源码挂载

如果不需要在容器内修改代码，可以移除项目目录的挂载:

```yaml
# docker-compose.yml
volumes:
  - opencode-data:/home/node/.local/share/opencode
  - opencode-config:/home/node/.config/opencode
  # 移除这一行
  # - .:/home/node/project
```

---

## 📊 日志管理

### 查看日志

```bash
docker compose logs -f
```

### 日志轮转

推荐使用 Docker 的日志驱动配置:

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"
```

---

## ✅ 健康检查

镜像内置了健康检查，compose 里也可以显式声明：

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:10000/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```

> ⚠️ 两点容易踩：
>
> 1. **探 `/health`，不要探 `/v1/models`。** 后者需要 `Authorization: Bearer`，探测请求不带
>    凭证会返回 401，把一个完全正常的容器标记成 unhealthy。`/health` 是唯一免鉴权的操作端点。
> 2. **用 `curl`，不要用 `wget`。** `curl` 在 Dockerfile 里是显式安装的；`wget` 是否存在于
>    基础镜像 `node:lts-slim` 随版本变化，不保证。

---

## ❓ 常见问题

### 容器无法启动 / 反复重启

```bash
docker compose logs --tail=100 opencode
```

按报错对症：

| 现象 | 原因与处理 |
|:-----|:-----------|
| `Address already in use` | `ipv4_address` 撞上了 Docker 网关。**`.1` 通常是网段网关**，容器固定 IP 请从 `.2` 起。用 `docker network inspect <net> --format '{{range .IPAM.Config}}{{.Subnet}} {{.Gateway}}{{end}}'` 确认 |
| `Timeout waiting for OpenCode Server` | 后端 `opencode serve` 30 秒内没起来。看日志里 opencode 自己的输出；常见于数据目录权限问题，或 `OPENCODE_SERVER_PORT` 改了但 `OPENCODE_SERVER_URL` 没跟着改 |
| 启动即退出，日志提到 postinstall | 镜像里的 opencode 是坏的。构建时已用 `opencode --version` 校验过，正常不会出现；若出现请重建镜像 |

### 容器是 healthy 但外面访问不了

如果前面有 Traefik / Nginx 之类的反代，按顺序检查：

1. **Traefik 选了错误的网络。** 容器接入多个网络时必须显式声明，否则 Traefik 可能取到另一个
   网段的 IP，表现为 502：

   ```yaml
   - "traefik.docker.network=docker-net"
   ```

2. **不要给这个服务挂 `buffering` 中间件。** 这是 SSE 网关，buffering 会等整个响应缓冲完才
   转发，`/v1/chat/completions` 的流式输出会退化成「等模型全部生成完才返回」，客户端通常直接
   超时。`compress` 中间件对 SSE 也可能有问题。

3. 反代侧的读超时不要小于 `OPENCODE_PROXY_REQUEST_TIMEOUT_MS`（默认 180000ms）。

### healthcheck 显示 unhealthy

见上面「健康检查」—— 九成是探了 `/v1/models`（401）或用了 `wget`。

### 挂载的 opencode.json 被改写

`OPENCODE_PROXY_PROMPT_MODE=plugin-inject` 会在启动时向
`/home/node/.config/opencode/opencode.json` 注册一个空插件，而该目录通常是从宿主机挂载的，
改动会**落盘到宿主机**。当前版本是合并写入（保留已有的 provider / model / instructions），
但仍请确认这是你要的行为；不需要就保持默认的 `standard`。

### 挂载权限问题

确保 PUID/PGID 配置正确（默认 1000:1000）。容器以 root 启动，入口脚本按 PUID/PGID 调整
`node` 用户，并对数据目录、配置目录、项目目录执行 `chown -R`。宿主机目录文件极多时这一步
可能耗时较久。

### 怎么快速确认容器本身是好的

绕开反代，直接在容器里打自己：

```bash
docker compose exec opencode curl -s http://localhost:10000/health
docker compose exec opencode curl -s -H "Authorization: Bearer $API_KEY" http://localhost:10000/v1/models
```

两条都通，说明容器没问题，故障在反代 / 网络层。

