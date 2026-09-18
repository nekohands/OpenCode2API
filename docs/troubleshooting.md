# 🔧 故障排查

<p align="center">
  <img src="https://img.shields.io/badge/version-1.5.0-blue" alt="Version">
</p>

---

## ❓ 常见问题

### 1️⃣ 请求卡住

| 项目 | 说明 |
|:-----|:-----|
| **症状** | 模型列表接口正常，但实际请求无响应 |
| **解决方案** | 设置 `USE_ISOLATED_HOME=false` 让 OpenCode 复用本机登录态 |

```bash
USE_ISOLATED_HOME=false
# 或
OPENCODE_USE_ISOLATED_HOME=false
```

---

### 2️⃣ 模型不存在

| 项目 | 说明 |
|:-----|:-----|
| **症状** | 返回 `model_not_found` 错误 |
| **解决方案** | 检查可用模型列表，确认模型 ID 正确 |

```bash
curl http://127.0.0.1:10000/v1/models
```

---

### 3️⃣ 没有推理输出

| 项目 | 说明 |
|:-----|:-----|
| **症状** | 发送了 `reasoning_effort` 但没有推理输出 |
| **解决方案** | 使用 `stream: true` 的 Responses API |

---

### 4️⃣ 工具调用意外触发

| 项目 | 说明 |
|:-----|:-----|
| **症状** | 客户端意外触发了 OpenCode 工具调用 |
| **解决方案** | 保持 `DISABLE_TOOLS=true` |

---

### 5️⃣ 端口冲突

| 项目 | 说明 |
|:-----|:-----|
| **症状** | `Error: listen EADDRINUSE: address already in use` |
| **解决方案** | 更改端口或检查端口占用 |

```bash
# 检查端口占用
lsof -i :10000
lsof -i :10001

# 更改端口
OPENCODE_PROXY_PORT=10002
OPENCODE_SERVER_PORT=10003
```

---

### 6️⃣ OpenCode 未安装

| 项目 | 说明 |
|:-----|:-----|
| **症状** | `Cannot verify OpenCode installation` |
| **解决方案** | 安装 OpenCode CLI |

```bash
# Windows
npm install -g opencode-ai

# Linux/macOS
curl -fsSL https://opencode.ai/install | bash
```

---

### 7️⃣ Docker 容器无法启动

| 项目 | 说明 |
|:-----|:-----|
| **症状** | 容器启动失败或立即退出 |
| **解决方案** | 检查日志和配置 |

```bash
# 查看日志
docker compose logs

# 检查端口
netstat -tulpn | grep -E '10000|10001'
```

---

### 8️⃣ 认证失败

| 项目 | 说明 |
|:-----|:-----|
| **症状** | 返回 `401 Unauthorized` |
| **解决方案** | 确认 `API_KEY` 配置正确 |

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" ...
```

---

### 9️⃣ 报 `OpenCode's free tier can only be used from within OpenCode`

```json
{"error":{"message":"Error from provider (Console): OpenCode's free tier can only be used from within OpenCode","type":"APIError"}}
```

**这不是本项目的报错,是上游 OpenCode Zen 的。** 上游对请求做客户端指纹校验
(`User-Agent` 与 `x-opencode-*` 请求头),只放行看起来由 OpenCode 客户端发出的请求,
免费额度被明确限制为「只能在 OpenCode 内使用」。上游 issue:`anomalyco/opencode#49433`。

因此:

- **本项目无法通过改代码解决它。** 网上流传的"办法"是伪造这些请求头,让上游误以为请求来自
  官方客户端 —— 那是刻意规避服务方的访问控制,违反其使用条款,也可能导致账号被封。
  本项目不做这件事,也不会提供这类代码。
- **可用的替代**:同一账号下走其他渠道的模型不受影响。实测 `deepseek-v4-flash`、
  `ag/deepseek-v4-flash` 正常返回,`ag/claude-opus-4-8`、`gemini-3.8-flash` 等也在列。
- **若持有 OpenCode Zen 的付费套餐**,免费额度限制不适用;请确认后端使用的是付费凭据。
- 该报错在流式路径下可能被吞成**空完成**(`finish_reason: stop` 且 `completion_tokens: 0`),
  客户端表现为「成功但内容为空」。遇到空回复时,先用非流式请求复现,才能看到真正的错误信息。

> 换模型时注意模型名可能被网关改写:opencode2api 的 `opencode/mimo-v2.5-free`
> 在 new-api 里可能叫 `mimo-v2.5`。用错名字会得到
> `Model not found: opencode/<名字>`,那是模型名问题,不是渠道故障。

## 🔍 调试模式

开启调试日志:

```bash
# 环境变量
DEBUG=true
# 或
OPENCODE_PROXY_DEBUG=true
```

调试日志会输出详细的请求和响应信息。

---

## 🆘 获取帮助

- 🐛 [GitHub Issues](https://github.com/TiaraBasori/opencode2api/issues)
