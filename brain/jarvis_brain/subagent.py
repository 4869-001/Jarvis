"""子代理：开一个独立上下文去查东西，只把结论带回来。

存在的唯一理由是**保护主上下文**。一次 grep 可能吐回 200 行、读三个文件又是几千
token，这些原始材料对主会话没有价值——它要的是"配置在哪读的、有没有第二处写入"
这种结论。把翻找过程隔离到子代理里，主会话只多一条几百字的报告。

和主循环的关系：子代理**不是**另一套工具执行。工具仍然走
`SessionCoordinator._execute`，因此权限档位、确认弹窗、原生工具转发、任务日志
全都照旧生效，子代理只是换了一份对话历史和一份更小的工具表。

三条约束是刻意的：
- **子代理不能再开子代理**。递归展开在这种单进程串行结构里只会把一轮对话拖到
  没边，而且没有任何一个真实需求需要三层。
- **explore 档位只给只读工具**。绝大多数子代理任务是"去查"，给它写权限只是
  在没有人盯着的上下文里多开一个口子。
- **报告必须是结论，不是过程**。见 REPORT_RULES——不这么要求的话，模型会把
  刚刚读到的文件内容原样抄回来，那就等于没隔离。
"""
import json
import time
import uuid

from .providers.deepseek import Cancelled
from .tools import registry

# explore 档位的工具白名单：只读 + 联网查。这里写死名字而不是按 risk 过滤，
# 因为 risk 管的是"会不会改坏东西"，这里要管的是"会不会有副作用"，
# 两者不完全重合（web_search 是 L1 但没有本机副作用，memory_save 也是 L1 但会写盘）。
EXPLORE_TOOLS = {
    "fs_list", "fs_read", "fs_search", "grep", "glob",
    "web_search", "web_fetch", "task_history", "memory_recall", "memory_list",
    "app_list_running", "app_scriptable", "app_dictionary", "menu_list", "ui_inspect",
    "system_info", "clipboard_read", "shell_list",
}

# 无论哪个档位都不给子代理的：会改变会话形态的，以及递归。
NEVER = {"agent_enter", "subagent_run", "todo_write"}

REPORT_RULES = """You are a sub-agent. You were given one specific job by the main
assistant, you do it with tools, and you return a report. The user never sees your
report directly — the main assistant reads it and acts on it.

Your report must be a CONCLUSION, not a transcript:
- State what you found, with the specific evidence that supports it: file paths with
  line numbers, exact names, exact values, exact command output that matters.
- Do not paste back whole files or long output. The whole point of you is that the
  main assistant does not have to read those.
- If you could not determine something, say so plainly and say what you tried. A
  confident wrong answer here is worse than "not found" — the main assistant cannot
  tell the difference and will act on it.
- No preamble, no "I will now", no closing offer of further help. Just the findings.
- Write in English. Plain prose or short bullets. No {marker} marker, no Chinese —
  this text is machine-read, not spoken."""


class SubAgent:
    """跑一次子任务。一个实例只用一次。"""

    def __init__(self, session, description, prompt, scope="explore", max_steps=12):
        self.session = session
        self.description = (description or "子任务")[:80]
        self.prompt = prompt or ""
        self.scope = scope if scope in ("explore", "full") else "explore"
        self.max_steps = max(1, min(int(max_steps or 12), 25))
        self.id = "sub_" + uuid.uuid4().hex[:8]
        self.tools_used = []

    # ------------------------------------------------------------ 工具表

    def tool_schema(self):
        selected = []
        for tool in registry.TOOLS:
            name = tool["name"]
            if name in NEVER:
                continue
            if self.scope == "explore" and name not in EXPLORE_TOOLS:
                continue
            selected.append(tool)
        return registry.openai_schema(selected)

    # ------------------------------------------------------------ 运行

    def run(self, generation):
        session = self.session
        marker_note = REPORT_RULES.format(marker="[[ZH]]")
        history = [{"role": "system", "content":
                    "%s\n\nWorking directory: %s\nScope: %s (%s)\nStep budget: %d tool rounds."
                    % (marker_note, session.agent.workspace, self.scope,
                       "read-only tools" if self.scope == "explore" else "full tool set",
                       self.max_steps)},
                   {"role": "user", "content": self.prompt}]

        session.emit({"type": "subagent_started", "id": self.id,
                      "description": self.description, "scope": self.scope,
                      "max_steps": self.max_steps})
        started = time.time()
        report = ""

        try:
            for step in range(self.max_steps + 1):
                session._assert_current_turn(generation)
                session.emit({"type": "subagent_step", "id": self.id, "step": step})

                tools = self.tool_schema() if step < self.max_steps else None
                parts = []
                tool_calls = []
                for kind, value in session.provider.stream(history, tools):
                    session._assert_current_turn(generation)
                    if kind == "text":
                        parts.append(value)
                        # 子代理的正文不进面板正文区、也不进播报——它是给模型看的。
                        # 面板只显示它在跑第几步、用了什么工具。
                    elif kind == "tool_calls":
                        tool_calls = value

                text = "".join(parts).strip()
                if not tool_calls:
                    report = text
                    break

                history.append({
                    "role": "assistant",
                    "content": text or None,
                    "tool_calls": [{
                        "id": call["id"] or ("sub_%d" % index),
                        "type": "function",
                        "function": {"name": call["name"],
                                     "arguments": call["arguments"] or "{}"},
                    } for index, call in enumerate(tool_calls)],
                })

                for index, call in enumerate(tool_calls):
                    call_id = call["id"] or ("%s_%d_%d" % (self.id, step, index))
                    self.tools_used.append(call["name"])
                    result = session._execute(call["name"], call["arguments"], call_id,
                                              generation, subagent=self.id)
                    history.append({
                        "role": "tool",
                        "tool_call_id": call_id,
                        "content": json.dumps(result, ensure_ascii=False)[:12000],
                    })
        except Cancelled:
            session.emit({"type": "subagent_done", "id": self.id, "cancelled": True,
                          "steps": len(self.tools_used)})
            raise

        elapsed = time.time() - started
        session.log("子代理 %s 用 %.1fs / %d 次工具：%s" % (
            self.description, elapsed, len(self.tools_used), ",".join(self.tools_used) or "无"))
        session.emit({"type": "subagent_done", "id": self.id,
                      "steps": len(self.tools_used),
                      "ms": int(elapsed * 1000),
                      "tools": self.tools_used})

        if not report:
            report = ("（子代理用完了 %d 步预算也没有给出结论。它调用过：%s。"
                      "别原样重试同一个任务，把范围缩小再问。）"
                      % (self.max_steps, "、".join(self.tools_used) or "无"))
        return {
            "description": self.description,
            "scope": self.scope,
            "steps": len(self.tools_used),
            "tools_used": self.tools_used,
            "report": report,
        }
