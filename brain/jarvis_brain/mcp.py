"""MCP 客户端：把第三方 MCP server 的工具接进来，当成 Jarvis 自己的工具用。

为什么是 MCP，而不是给每个服务写一个原生工具：上一期「指挥任意应用」已经给过一次
教训——写死的工具只覆盖当初想到的那几个。第三方服务比本机应用多一个数量级，
一个一个写永远追不上。MCP 是现成的生态，接一次拿到整片。

**传输只做 stdio。** 另外两种（SSE / Streamable HTTP）要处理会话恢复、重连和鉴权，
而本机场景下 server 全是 npx/uvx 拉起来的子进程。先把 stdio 做扎实。

「Brain 只用标准库」这条底线在这里照样成立：MCP 的 stdio 传输就是**按行分隔的
JSON-RPC 2.0**（不是 LSP 那套 Content-Length 头），`subprocess` + `json` + 两个读线程
就够，不需要官方 SDK。
"""
import json
import os
import re
import shutil
import subprocess
import threading
import time

# 协议版本按 MCP 规范填。server 在 initialize 的响应里回它自己支持的版本，
# 不一致时以它的为准——规范允许降级，我们不因为版本对不上就拒绝连接。
PROTOCOL_VERSION = "2025-06-18"

NAME_PREFIX = "mcp"
SEPARATOR = "__"

# 工具名给模型看，必须满足 OpenAI 兼容接口的 ^[a-zA-Z0-9_-]{1,64}$。
_SAFE_NAME = re.compile(r"[^a-zA-Z0-9_-]")

# ---------------------------------------------------------------- PATH
#
# ⚠️ 这段是 launchd 场景下的必需品，别当成"防御性代码"删掉。
# Brain 由 LaunchAgent 拉起，继承的 PATH 是 launchd 的默认值
# （`launchctl getenv PATH` 为空 → 子进程只有 /usr/bin:/bin:/usr/sbin:/sbin）。
# 而 MCP server 的启动器 npx / uvx，以及外部 agent 的 claude / codex，
# 本机实测**四个全都不在那四个目录里**：
#     npx -> /usr/local/bin   uvx -> ~/.local/bin
#     claude -> ~/.local-npm/bin   codex -> ~/bin
# 不补 PATH 的表现是每个 server 都以 FileNotFoundError 起不来，
# 而在终端里手动跑同一条命令完全正常——这种"终端能跑、App 里不行"最费时间。
#
# 不去跑 `zsh -lic 'echo $PATH'` 抓登录 shell 的 PATH：那要多花几百毫秒，
# 且用户的 rc 文件一旦有交互式内容（提示、read）会直接把 Brain 卡住。
# 宁可列一张明确的表，不够用时在 config 里加 mcp.extra_path。
_COMMON_BIN_DIRS = [
    "/opt/homebrew/bin", "/opt/homebrew/sbin",      # Apple Silicon Homebrew
    "/usr/local/bin", "/usr/local/sbin",            # Intel Homebrew / node 官方包
    "~/.local/bin",                                 # uv / pipx
    "~/.local-npm/bin",                             # npm prefix 被改过时
    "~/bin",
    "~/.cargo/bin",
    "~/.volta/bin", "~/.bun/bin",
    "/usr/bin", "/bin", "/usr/sbin", "/sbin",
]


def launch_env(extra_path=None, extra_env=None):
    """给子进程用的环境变量：补齐 PATH，并去掉会干扰的继承项。"""
    env = dict(os.environ)
    parts = []
    for entry in list(extra_path or []) + _COMMON_BIN_DIRS:
        path = os.path.expanduser(entry)
        if path not in parts:
            parts.append(path)
    for entry in (env.get("PATH") or "").split(":"):
        if entry and entry not in parts:
            parts.append(entry)
    env["PATH"] = ":".join(parts)
    # server 多半是 node/python 写的，行缓冲能让它的输出及时到我们手里。
    env.setdefault("PYTHONUNBUFFERED", "1")
    env.update(extra_env or {})
    return env


def _safe(part):
    return _SAFE_NAME.sub("_", str(part or ""))[:24]


def qualified_name(server, tool):
    """mcp__<server>__<tool>，和 Claude Code 的命名一致，用户一眼认得出来源。"""
    name = SEPARATOR.join((NAME_PREFIX, _safe(server), _safe(tool)))
    return name[:64]


def _same_content(structured, text):
    """structuredContent 是不是只是 text 的另一种包装。

    只认两种确定的情况：整体就是那段文本，或者是个单键 dict 且值就是那段文本。
    多键 dict 里恰好有一个键等于 text 的，仍然照给——那种情况下另外几个键是
    真信息，不能因为其中一个重复就把整份丢掉。
    """
    if not text:
        return False
    if isinstance(structured, str):
        return structured.strip() == text
    if isinstance(structured, dict) and len(structured) == 1:
        only = next(iter(structured.values()))
        return isinstance(only, str) and only.strip() == text
    return False


class MCPError(Exception):
    pass


class MCPServer:
    """一个 MCP server 子进程。一个实例对应 config 里的一条 server 配置。"""

    def __init__(self, name, spec, log, extra_path=None):
        self.name = name
        self.spec = spec or {}
        self.log = log
        self.extra_path = extra_path or []

        self.process = None
        self.tools = []                 # tools/list 的原始条目
        self.state = "stopped"          # stopped / starting / ready / error
        self.error = ""
        self.server_info = {}
        self.started_at = 0.0

        self._lock = threading.Lock()
        self._next_id = 0
        self._pending = {}              # id -> [Event, result_holder]
        self._stderr_tail = []
        self._closing = False

    # ------------------------------------------------------------ 生命周期

    def start(self, timeout=30):
        command = self.spec.get("command")
        if not command:
            raise MCPError("缺少 command")
        args = list(self.spec.get("args") or [])
        env = launch_env(self.extra_path, self.spec.get("env"))

        # 提前把可执行文件解析出来。不解析的话 FileNotFoundError 只会说
        # "No such file or directory: 'npx'"，看不出是 PATH 的问题还是真没装。
        resolved = shutil.which(command, path=env["PATH"])
        if not resolved:
            raise MCPError("找不到可执行文件 %s（PATH 里没有；装了的话把所在目录写进 "
                           "config 的 mcp.extra_path）" % command)

        cwd = self.spec.get("cwd")
        cwd = os.path.expanduser(cwd) if cwd else None

        self.state = "starting"
        self.started_at = time.time()
        self.process = subprocess.Popen(
            [resolved] + args,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, cwd=cwd, text=True, bufsize=1,
        )

        threading.Thread(target=self._read_stdout, daemon=True,
                         name="mcp-%s-out" % self.name).start()
        # ⚠️ stderr 必须**也**有人一直读。MCP server 普遍往 stderr 打日志，
        # 管道缓冲区（64KB）一满，子进程下一次写 stderr 就永久阻塞，
        # 表现是"server 跑着跑着就不响应了"，而进程还活着、stdout 也没关。
        threading.Thread(target=self._read_stderr, daemon=True,
                         name="mcp-%s-err" % self.name).start()

        try:
            result = self.request("initialize", {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},          # 我们不提供 sampling/roots/elicitation
                "clientInfo": {"name": "jarvis", "version": "1.0"},
            }, timeout=timeout)
            self.server_info = result.get("serverInfo") or {}
            # 规范要求握手完成后必须发这条通知，否则不少 server 拒绝服务后续请求。
            self._notify("notifications/initialized", {})
            listed = self.request("tools/list", {}, timeout=timeout)
            self.tools = list(listed.get("tools") or [])
        except Exception as exc:
            self.state = "error"
            self.error = str(exc)
            self.stop()
            raise

        self.state = "ready"
        self.error = ""
        return self.tools

    def stop(self):
        self._closing = True
        process = self.process
        if not process:
            self.state = "stopped"
            return
        try:
            if process.stdin and not process.stdin.closed:
                process.stdin.close()      # 关 stdin 是让 MCP server 优雅退出的标准信号
        except Exception:
            pass
        try:
            process.wait(timeout=3)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass
        self.process = None
        if self.state != "error":
            self.state = "stopped"
        # 挂起的请求要叫醒，否则调用方会一直等到自己的超时。
        with self._lock:
            pending = list(self._pending.values())
            self._pending.clear()
        for holder in pending:
            holder["error"] = "server 已退出"
            holder["event"].set()

    @property
    def alive(self):
        return bool(self.process and self.process.poll() is None)

    # ------------------------------------------------------------ 收发

    def _read_stdout(self):
        process = self.process
        try:
            for line in process.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    message = json.loads(line)
                except ValueError:
                    # 有些 server 会往 stdout 混打日志。这违反规范，但现实里存在，
                    # 不能因为一行脏数据就断掉整条连接——记下来跳过。
                    self.log("[mcp:%s] stdout 非 JSON：%s" % (self.name, line[:200]))
                    continue
                self._dispatch(message)
        except Exception as exc:
            if not self._closing:
                self.log("[mcp:%s] 读取中断：%s" % (self.name, exc))
        finally:
            if not self._closing:
                self.state = "error"
                self.error = self.error or ("进程退出：%s" % self.stderr_tail()[-300:])
                with self._lock:
                    pending = list(self._pending.values())
                    self._pending.clear()
                for holder in pending:
                    holder["error"] = "server 连接中断"
                    holder["event"].set()

    def _read_stderr(self):
        process = self.process
        try:
            for line in process.stderr:
                line = line.rstrip()
                if not line:
                    continue
                self._stderr_tail.append(line)
                if len(self._stderr_tail) > 50:
                    del self._stderr_tail[:-50]
        except Exception:
            pass

    def stderr_tail(self):
        return "\n".join(self._stderr_tail[-10:])

    def _dispatch(self, message):
        if "id" in message and ("result" in message or "error" in message):
            with self._lock:
                holder = self._pending.pop(message["id"], None)
            if holder:
                if "error" in message:
                    detail = message["error"] or {}
                    holder["error"] = "%s（code %s）" % (
                        detail.get("message") or "未知错误", detail.get("code"))
                else:
                    holder["result"] = message.get("result") or {}
                holder["event"].set()
            return

        method = message.get("method") or ""
        if "id" in message:
            # server → client 的请求。我们在 initialize 里没声明任何 capability，
            # 所以正常不该收到；真收到必须回一条错误而不是沉默——对方会一直等，
            # 卡住的是它那边的整个工具调用。
            self._send({"jsonrpc": "2.0", "id": message["id"],
                        "error": {"code": -32601,
                                  "message": "jarvis 未提供 %s" % method}})
            return
        if method.startswith("notifications/"):
            # tools/list_changed 之类。工具表变了就重新拉一次。
            if method == "notifications/tools/list_changed":
                threading.Thread(target=self._refresh_tools, daemon=True).start()

    def _refresh_tools(self):
        try:
            listed = self.request("tools/list", {}, timeout=15)
            self.tools = list(listed.get("tools") or [])
            self.log("[mcp:%s] 工具表已更新，%d 个" % (self.name, len(self.tools)))
        except Exception as exc:
            self.log("[mcp:%s] 刷新工具表失败：%s" % (self.name, exc))

    def _send(self, message):
        process = self.process
        if not process or not process.stdin or process.stdin.closed:
            raise MCPError("server 未运行")
        line = json.dumps(message, ensure_ascii=False) + "\n"
        with self._lock:
            process.stdin.write(line)
            process.stdin.flush()

    def _notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def request(self, method, params, timeout=60, cancelled=None):
        with self._lock:
            self._next_id += 1
            request_id = self._next_id
            holder = {"event": threading.Event(), "result": None, "error": None}
            self._pending[request_id] = holder

        try:
            self._send({"jsonrpc": "2.0", "id": request_id,
                        "method": method, "params": params or {}})
        except Exception:
            with self._lock:
                self._pending.pop(request_id, None)
            raise

        # 分片等待，好让用户按下取消时能及时脱身——MCP 调用可能是几十秒的网络请求，
        # 一口气 wait(timeout) 的话取消要等到超时才生效。
        deadline = time.time() + timeout
        while True:
            if holder["event"].wait(0.25):
                break
            if cancelled and cancelled():
                with self._lock:
                    self._pending.pop(request_id, None)
                # 告诉对方别做了。规范里这是通知，不等回复。
                try:
                    self._notify("notifications/cancelled",
                                 {"requestId": request_id, "reason": "用户取消"})
                except Exception:
                    pass
                raise MCPError("已取消")
            if time.time() > deadline:
                with self._lock:
                    self._pending.pop(request_id, None)
                raise MCPError("%s 超时（%ds）" % (method, timeout))

        if holder["error"]:
            raise MCPError(holder["error"])
        return holder["result"] or {}

    def call_tool(self, tool_name, arguments, timeout=60, cancelled=None):
        return self.request("tools/call",
                            {"name": tool_name, "arguments": arguments or {}},
                            timeout=timeout, cancelled=cancelled)


class MCPHub:
    """管所有 MCP server：启动、工具表汇总、按名字派发调用。"""

    def __init__(self, cfg, log):
        self.cfg = cfg
        self.log = log
        self.servers = {}               # name -> MCPServer
        self._index = {}                # 限定名 -> (server_name, 原始工具名)
        self._lock = threading.Lock()
        self._generation = 0            # 工具表版本号，变了 Session 才重建 schema

    @property
    def settings(self):
        return self.cfg.get("mcp") or {}

    @property
    def enabled(self):
        return bool(self.settings.get("enabled"))

    def start_async(self):
        """后台连接。**不能同步连**：npx 第一次跑要下载包，几十秒起步，
        同步连会让 Jarvis 在启动时整个卡住，而且一个坏 server 就能拖垮全部。"""
        if not self.enabled:
            return
        specs = self.settings.get("servers") or {}
        for name, spec in specs.items():
            if not isinstance(spec, dict) or spec.get("enabled") is False:
                continue
            threading.Thread(target=self._start_one, args=(name, spec),
                             daemon=True, name="mcp-start-%s" % name).start()

    def _start_one(self, name, spec):
        server = MCPServer(name, spec, self.log, self.settings.get("extra_path"))
        with self._lock:
            old = self.servers.get(name)
            self.servers[name] = server
        if old:
            old.stop()
        started = time.time()
        try:
            tools = server.start(timeout=int(self.settings.get("startup_timeout") or 30))
        except Exception as exc:
            self.log("[mcp:%s] 启动失败：%s%s" % (
                name, exc, ("\n" + server.stderr_tail()) if server.stderr_tail() else ""))
            return
        self._reindex()
        self.log("[mcp:%s] 就绪，%.1fs，%d 个工具：%s" % (
            name, time.time() - started, len(tools),
            ", ".join(t.get("name", "?") for t in tools[:12]) or "无"))

    def _reindex(self):
        with self._lock:
            index = {}
            for server_name, server in self.servers.items():
                if server.state != "ready":
                    continue
                for tool in server.tools:
                    raw = tool.get("name")
                    if not raw:
                        continue
                    index[qualified_name(server_name, raw)] = (server_name, raw)
            self._index = index
            self._generation += 1

    @property
    def generation(self):
        return self._generation

    # ------------------------------------------------------------ 工具表

    def tool_specs(self):
        """转成 registry 认识的形状。风险等级从 MCP 的 annotations 推断。"""
        specs = []
        with self._lock:
            servers = list(self.servers.items())
        per_server = self.settings.get("servers") or {}

        for server_name, server in servers:
            if server.state != "ready":
                continue
            server_cfg = per_server.get(server_name) or {}
            agent_only = bool(server_cfg.get("agent_only"))
            for tool in server.tools:
                raw = tool.get("name")
                if not raw:
                    continue
                annotations = tool.get("annotations") or {}
                # readOnlyHint 是 server 自己的声明，只能当参考不能当保证——
                # 所以只用它把只读工具降到 L0 免确认，其余一律 L2 起。
                # 反过来"声明了不是只读就放行"是不存在的，默认就是要确认。
                if annotations.get("readOnlyHint") is True:
                    risk = "L0"
                elif annotations.get("destructiveHint") is True:
                    risk = "L4"
                else:
                    risk = "L2"
                schema = tool.get("inputSchema") or {"type": "object", "properties": {}}
                if not isinstance(schema, dict) or schema.get("type") != "object":
                    schema = {"type": "object", "properties": {}}
                title = annotations.get("title") or tool.get("title") or ""
                description = (tool.get("description") or title or raw).strip()
                specs.append({
                    "name": qualified_name(server_name, raw),
                    "description": "[%s] %s" % (server_name, description[:900]),
                    "risk": risk,
                    "executor": "mcp",
                    "fn": None,
                    "agent_only": agent_only,
                    "recover": server_cfg.get("recover") or "",
                    "schema": schema,
                    "mcp": {"server": server_name, "tool": raw},
                })
        return specs

    # ------------------------------------------------------------ 调用

    def call(self, qualified, arguments, timeout=None, cancelled=None):
        with self._lock:
            target = self._index.get(qualified)
            server = self.servers.get(target[0]) if target else None
        if not target or not server:
            return {"error": "MCP 工具 %s 不存在（server 可能已退出）" % qualified}
        if server.state != "ready":
            return {"error": "MCP server %s 当前不可用：%s" % (
                target[0], server.error or server.state)}

        timeout = int(timeout or self.settings.get("call_timeout") or 60)
        try:
            raw = server.call_tool(target[1], arguments, timeout=timeout, cancelled=cancelled)
        except MCPError as exc:
            return {"error": "MCP %s 调用失败：%s" % (qualified, exc)}
        return self._shape(raw)

    @staticmethod
    def _shape(raw):
        """把 MCP 的 content 数组压成给模型看的形状。

        规范允许 text / image / audio / resource 几种块。模型这条链路只吃文本，
        非文本块转成一句说明——直接丢掉的话模型会以为工具什么都没返回。
        """
        if not isinstance(raw, dict):
            return {"result": raw}
        pieces = []
        for block in raw.get("content") or []:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "text":
                pieces.append(block.get("text") or "")
            elif kind == "resource":
                resource = block.get("resource") or {}
                pieces.append(resource.get("text")
                              or "[资源 %s]" % (resource.get("uri") or "?"))
            else:
                pieces.append("[%s 内容，未取回]" % (kind or "未知"))
        text = "\n".join(piece for piece in pieces if piece).strip()

        if raw.get("isError"):
            return {"error": text or "MCP 工具报告执行失败"}

        out = {"result": text} if text else {}
        # structuredContent 是新版规范里的结构化返回，有就一并给模型——它比散文好用。
        # 但**规范建议 server 把结构化结果同时序列化进 text 块**以兼容老客户端，
        # 于是常见情况是两份一模一样的内容。实测 @modelcontextprotocol/server-filesystem
        # 的 structuredContent 就是 {"content": <和 text 一字不差>}，照单全收等于
        # 每次调用都把结果双倍塞进上下文。相同就只留 text。
        structured = raw.get("structuredContent")
        if structured is not None and not _same_content(structured, text):
            out["data"] = structured
        return out or {"result": ""}

    # ------------------------------------------------------------ 状态

    def status(self):
        with self._lock:
            servers = list(self.servers.items())
        configured = self.settings.get("servers") or {}
        rows = []
        for name, spec in configured.items():
            server = dict(servers).get(name)
            if spec.get("enabled") is False:
                rows.append({"name": name, "state": "disabled", "tools": 0})
                continue
            if not server:
                rows.append({"name": name, "state": "starting", "tools": 0})
                continue
            rows.append({
                "name": name,
                "state": server.state,
                "tools": len(server.tools) if server.state == "ready" else 0,
                "tool_names": [t.get("name") for t in server.tools][:40],
                "error": server.error[:300] if server.error else "",
                "server_info": server.server_info,
            })
        return {"enabled": self.enabled, "servers": rows}

    def stop_all(self):
        with self._lock:
            servers = list(self.servers.values())
            self.servers.clear()
            self._index.clear()
        for server in servers:
            server.stop()
