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

服务配置了健康检查:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:10000/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```

---

## ❓ 常见问题

### 容器无法启动

检查日志:
```bash
docker compose logs
```

### 挂载权限问题

确保 PUID/PGID 配置正确 (默认 1000:1000)。
