"""把一件事委派给本机的另一个 CLI agent（Claude Code / Codex）去做。

和 `subagent.py` 的分工，一句话：**子代理是"我自己换个上下文再想一遍"，
外部 agent 是"这活我不干，交给更专业的那个"。**

为什么需要它：Jarvis 的大脑是 DeepSeek，工具集是为"桌面管家"配的。真要连续改一个
代码仓库，Claude Code / Codex 在这件事上强得多，而且它们**自带**沙箱、diff 审阅、
git 集成和自己的一整套工具。与其把那些能力在 Jarvis 里重造一遍，不如把任务原样交出去，
Jarvis 只负责派活、盯进度、收结论——这正是管家该干的事。

设计上的三个决定：

1. **最终结果走各自的稳定契约，进度走尽力而为的事件流。**
   Claude Code 取 `--output-format stream-json` 里的 `result` 事件；
   Codex 取 `--output-last-message <file>` 写出的文件。两者都是官方承诺的输出口。
   `--json` 事件流的 schema 会随版本变，所以只拿它画进度条，认不出的事件直接忽略——
   **绝不让进度解析失败影响到最终结果**。
2. **复用子代理那套面板事件**（subagent_started/step/done），额外带一个 `external`
   字段标出是谁在跑。面板那边不必为它新写一套折叠区，而想区分显示时字段也在。
3. **权限档位从 Jarvis 当前档位映射过去，不单独配。** 用户在 Jarvis 顶栏调到 bypass，
   委派出去的 agent 才拿到对应的放行档；Jarvis 还在 ask 档时，外部 agent 只读。
   两套权限各配一份的话，早晚会出现"以为收紧了其实没有"的错位。
"""
import json
import os
import subprocess
import tempfile
import threading
import time
import uuid

from .mcp import launch_env
from .providers.deepseek import Cancelled

# 权限映射。Jarvis 档位 → 各家自己的说法。
# 注意 Jarvis 的 accept_edits 对应 Claude 的 acceptEdits、Codex 的 workspace-write：
# 都是"能改工作目录，但不能碰工作目录以外和网络"。
_PERMISSION = {
    "claude": {"ask": "manual", "accept_edits": "acceptEdits", "bypass": "bypassPermissions"},
    "codex": {"ask": "read-only", "accept_edits": "workspace-write",
              "bypass": "danger-full-access"},
}

# ⚠️ 2026-08-05 实测：委派进程是非交互的（stdin 关掉），外部 agent 弹出的权限
# 请求**没有任何人能应答**，它只能跳过那一步继续。表现是任务做了一半，而外部 agent
# 自己会如实说"这步需要授权"——但那句话埋在报告正文里，主模型很容易读漏，
# 把半成品当成功报给用户。所以这里显式给一条 note，让它必须正视这件事。
#
# 实测数据（Claude Code 2.1.220）：
#   manual      写文件和跑命令都被拒 → 基本只能读，等于一次侦察
#   acceptEdits 写文件放行、跑命令被拒 → 改得动代码，验证不了
#   dontAsk     比 manual 还严，Write 和 Bash 全拒（试过，不是能用的中间档）
#   bypassPermissions 全放行 → 才能真正把活干完
# 不因此把 accept_edits 偷偷提权到 bypass：那是拿用户的权限设置开玩笑。
_PERMISSION_NOTE = {
    "ask": "本次运行在 ask 档：外部代理不能写文件也不能执行命令，只能查看。"
           "它若说某步需要授权，那是真的没做——不要当成已完成。要它动手，"
           "让用户把 Jarvis 权限档切到 accept_edits 或 bypass 再委派一次。",
    "accept_edits": "本次运行在 accept_edits 档：外部代理能改文件，但**不能执行命令**，"
                    "所以它无法运行测试或验证自己的改动。报告里凡是提到需要授权、"
                    "被拒绝或未能验证的部分，都要如实转达给用户，并说明切到 bypass 档"
                    "可以让它跑完整。",
}

DEFAULT_AGENTS = {
    "claude": {
        "command": "claude",
        "kind": "claude",
        "description": "Claude Code：改代码、读大型代码库、跑测试并修到绿。最擅长工程任务。",
        "timeout": 900,
    },
    "codex": {
        "command": "codex",
        "kind": "codex",
        "description": "OpenAI Codex：改代码、跑命令，带自己的沙箱。可作为 Claude Code 的替代。",
        "timeout": 900,
    },
}


class ExternalAgentRun:
    """跑一次委派。一个实例只用一次。"""

    def __init__(self, session, agent_name, spec, description, prompt, cwd=None):
        self.session = session
        self.agent_name = agent_name
        self.spec = spec
        self.description = (description or "外部任务")[:80]
        self.prompt = prompt or ""
        self.cwd = cwd
        self.id = "ext_" + uuid.uuid4().hex[:8]

        self.kind = spec.get("kind") or agent_name
        self.steps = 0
        self.tools_used = []
        self._last_message = ""
        self._result = None
        self._meta = {}

    # ------------------------------------------------------------ 命令行

    def _build(self, workspace, permission, last_message_file):
        command = self.spec.get("command") or self.agent_name
        args = [command]

        if self.kind == "claude":
            args += ["-p", self.prompt,
                     "--output-format", "stream-json", "--verbose"]
            mode = _PERMISSION["claude"].get(permission)
            if mode:
                args += ["--permission-mode", mode]
            if self.spec.get("model"):
                args += ["--model", self.spec["model"]]
            # Claude Code 的工作目录靠进程 cwd 定，不需要额外参数。
        elif self.kind == "codex":
            args += ["exec", self.prompt, "--json",
                     "--cd", workspace,
                     "--output-last-message", last_message_file,
                     # 委派过来的任务经常在非 git 目录里（整理文件、写脚本），
                     # 不加这条 codex 会直接拒绝启动。
                     "--skip-git-repo-check"]
            mode = _PERMISSION["codex"].get(permission)
            if mode:
                args += ["--sandbox", mode]
            if self.spec.get("model"):
                args += ["-m", self.spec["model"]]
        else:
            # 自定义 agent：argv 模板里用 {prompt} / {cwd} 占位。
            template = self.spec.get("args") or ["{prompt}"]
            args += [str(part).format(prompt=self.prompt, cwd=workspace)
                     for part in template]

        args += list(self.spec.get("extra_args") or [])
        return args

    # ------------------------------------------------------------ 运行

    def run(self, generation):
        session = self.session
        workspace = os.path.expanduser(self.cwd or session.agent.workspace)
        if not os.path.isdir(workspace):
            return {"error": "工作目录不存在：%s" % workspace}

        permission = session.agent.permission_mode
        timeout = int(self.spec.get("timeout") or 900)

        handle, last_message_file = tempfile.mkstemp(prefix="jarvis-ext-", suffix=".txt")
        os.close(handle)

        args = self._build(workspace, permission, last_message_file)
        env = launch_env(self.spec.get("extra_path"), self.spec.get("env"))

        session.emit({"type": "subagent_started", "id": self.id,
                      "description": self.description,
                      "scope": self.agent_name, "external": self.agent_name,
                      "permission": permission, "cwd": workspace,
                      "max_steps": 0})
        session.log("委派给 %s：%s（%s，权限 %s）" % (
            self.agent_name, self.description, workspace, permission))
        started = time.time()

        try:
            process = subprocess.Popen(
                args, cwd=workspace, env=env, text=True, bufsize=1,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except FileNotFoundError:
            os.unlink(last_message_file)
            return {"error": "没找到 %s。装了的话把它所在目录写进 config 的 "
                             "mcp.extra_path（外部 agent 共用同一张 PATH 表）"
                             % (self.spec.get('command') or self.agent_name)}
        except Exception as exc:
            os.unlink(last_message_file)
            return {"error": "启动 %s 失败：%s" % (self.agent_name, exc)}

        stderr_tail = []
        # stderr 必须有人读，理由和 MCP 那边一样：管道满了子进程就永久阻塞。
        threading.Thread(target=self._drain, args=(process.stderr, stderr_tail),
                         daemon=True, name="ext-%s-err" % self.agent_name).start()

        cancelled = False
        try:
            for line in process.stdout:
                if session._cancel.is_set() or generation != session._turn_generation:
                    cancelled = True
                    break
                if time.time() - started > timeout:
                    stderr_tail.append("（Jarvis 侧超时 %ds，已终止）" % timeout)
                    break
                self._consume(line.strip())
        finally:
            if cancelled or process.poll() is None:
                self._terminate(process)

        elapsed = time.time() - started

        # Codex 的最终答案在文件里；Claude 的在 result 事件里，前面已经收下了。
        if self._result is None and os.path.exists(last_message_file):
            try:
                with open(last_message_file, "r", encoding="utf-8") as fh:
                    text = fh.read().strip()
                if text:
                    self._result = text
            except Exception:
                pass
        try:
            os.unlink(last_message_file)
        except OSError:
            pass

        if cancelled:
            session.emit({"type": "subagent_done", "id": self.id, "cancelled": True,
                          "external": self.agent_name, "steps": self.steps})
            raise Cancelled()

        report = (self._result or self._last_message or "").strip()
        exit_code = process.poll()

        session.emit({"type": "subagent_done", "id": self.id,
                      "external": self.agent_name,
                      "steps": self.steps, "ms": int(elapsed * 1000),
                      "tools": self.tools_used[:40]})
        session.log("%s 跑完 %.1fs / %d 步，退出码 %s" % (
            self.agent_name, elapsed, self.steps, exit_code))

        if not report:
            detail = "\n".join(stderr_tail[-8:])[:600]
            return {"error": "%s 没有给出结果（退出码 %s）%s" % (
                self.agent_name, exit_code, ("\n" + detail) if detail else ""),
                "agent": self.agent_name, "steps": self.steps}

        out = {
            "agent": self.agent_name,
            "description": self.description,
            "cwd": workspace,
            "permission": permission,
            "steps": self.steps,
            "seconds": round(elapsed, 1),
            "report": report[:20000],
        }
        note = _PERMISSION_NOTE.get(permission)
        if note:
            out["permission_note"] = note
        out.update(self._meta)
        if exit_code not in (0, None):
            # 有结果但退出码非零：结果照给，同时把这件事说清楚，
            # 别让主模型把一次失败当成功往下走。
            out["exit_code"] = exit_code
            out["warning"] = "进程以非零退出码结束，报告可能不完整"
        return out

    @staticmethod
    def _drain(stream, sink):
        try:
            for line in stream:
                line = line.rstrip()
                if line:
                    sink.append(line)
                    if len(sink) > 60:
                        del sink[:-60]
        except Exception:
            pass

    def _terminate(self, process):
        try:
            process.terminate()
            process.wait(timeout=5)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass

    # ------------------------------------------------------------ 事件流

    def _consume(self, line):
        """解析进度事件。**任何解析失败都必须静默吞掉**——事件 schema 会随
        对方版本变，而进度只是锦上添花，最终结果不依赖这里的任何一行。"""
        if not line:
            return
        try:
            event = json.loads(line)
        except ValueError:
            return
        if not isinstance(event, dict):
            return
        try:
            if self.kind == "claude":
                self._consume_claude(event)
            elif self.kind == "codex":
                self._consume_codex(event)
        except Exception:
            pass

    def _note_step(self, label=None):
        self.steps += 1
        if label:
            self.tools_used.append(label)
        self.session.emit({"type": "subagent_step", "id": self.id,
                           "external": self.agent_name,
                           "step": self.steps, "label": label or ""})

    def _consume_claude(self, event):
        kind = event.get("type")
        if kind == "assistant":
            for block in (event.get("message") or {}).get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    self._note_step(block.get("name"))
                elif block.get("type") == "text":
                    text = (block.get("text") or "").strip()
                    if text:
                        self._last_message = text
        elif kind == "result":
            # 官方承诺的终局事件。subtype != success 时 result 里通常是错误说明，
            # 照样收下——它比我们自己编一句"失败了"有用得多。
            self._result = (event.get("result") or "").strip() or self._result
            for key, target in (("num_turns", "turns"),
                                ("total_cost_usd", "cost_usd"),
                                ("duration_ms", "agent_ms")):
                if event.get(key) is not None:
                    self._meta[target] = event[key]
            if event.get("subtype") and event["subtype"] != "success":
                self._meta["status"] = event["subtype"]

    def _consume_codex(self, event):
        kind = event.get("type") or ""
        item = event.get("item") or {}
        if kind in ("item.started", "item.completed"):
            item_type = item.get("item_type") or item.get("type") or ""
            if kind == "item.started" and item_type in ("command_execution", "file_change",
                                                        "mcp_tool_call", "web_search"):
                self._note_step(item_type)
            if item_type in ("agent_message", "assistant_message"):
                text = (item.get("text") or "").strip()
                if text:
                    self._last_message = text
        elif kind == "turn.completed":
            usage = event.get("usage") or {}
            if usage:
                self._meta["tokens"] = usage.get("output_tokens")
        elif kind == "error":
            message = (event.get("message") or "").strip()
            if message:
                self._meta["status"] = message[:200]


def available(cfg):
    """配置里启用了哪些外部 agent。名字 → spec。"""
    settings = cfg.get("external_agents") or {}
    if not settings.get("enabled"):
        return {}
    out = {}
    for name, spec in (settings.get("agents") or {}).items():
        if not isinstance(spec, dict) or spec.get("enabled") is False:
            continue
        merged = dict(DEFAULT_AGENTS.get(name) or {})
        merged.update(spec)
        merged.setdefault("command", name)
        merged.setdefault("kind", name)
        out[name] = merged
    return out
