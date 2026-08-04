"""Agent 模式的运行时状态与策略。

会话（session.py）仍然是那一个：Agent 模式不是另起一套循环，而是给同一个
工具循环换四样东西——**更长的步数预算、更大的工具集、按档位放宽的确认、
以及"中间步骤不播报"**。这样做的理由很实际：语音、记忆、双语字幕、任务日志
全都挂在原来那条链路上，另起一条会立刻分叉成两套都得维护的东西。

这里只管状态和策略，不碰模型调用——那仍然全在 SessionCoordinator 里。
"""
import os
import time

# 权限档位。ask 最保守，bypass 等于把终端交给模型。
MODES = ("ask", "accept_edits", "bypass")

# accept_edits 档位下免确认的"编辑类"工具。注意 app_quit / shell 写操作不在内：
# 前者会丢掉用户没保存的东西，后者不受 Schema 约束，都得单独点头。
EDIT_TOOLS = {"fs_write", "fs_move", "file_edit", "file_restore"}


class AgentRuntime:
    def __init__(self, cfg, emit, log):
        self.emit = emit
        self.log = log
        self.apply_config(cfg)
        self.todos = []
        self.steps = 0
        # 「本次会话内总是允许」的结果。故意只活在内存里：用户为了跑完手上这个
        # 任务点的"总是"，不该在下次开机后还静默生效。要持久化的是 config 里的
        # tools.auto_approve，那需要用户自己去写。
        self.session_allow = set()

    def apply_config(self, cfg):
        agent_cfg = cfg.get("agent") or {}
        self.cfg = agent_cfg
        self.enabled = bool(agent_cfg.get("enabled"))
        self.workspace = os.path.realpath(
            os.path.expanduser(agent_cfg.get("workspace") or "~"))
        mode = agent_cfg.get("permission_mode") or "accept_edits"
        self.permission_mode = mode if mode in MODES else "accept_edits"
        self.max_steps = int(agent_cfg.get("max_steps") or 60)
        self.compact_after = int(agent_cfg.get("compact_after") or 30)
        self.context_files = agent_cfg.get("context_files") or []
        self.stream_lines = int(agent_cfg.get("stream_lines") or 200)
        self.buffer_lines = int(agent_cfg.get("buffer_lines") or 2000)

    # ------------------------------------------------------------ 状态

    def payload(self):
        """发给面板的一份完整状态。顶栏的模式、档位、工作目录都读它。"""
        return {
            "enabled": self.enabled,
            "workspace": _tilde(self.workspace),
            "permission_mode": self.permission_mode,
            "max_steps": self.max_steps,
            "todos": self.todos,
        }

    def broadcast(self):
        self.emit({"type": "agent_state", **self.payload()})

    def set_enabled(self, enabled):
        if self.enabled == bool(enabled):
            return
        self.enabled = bool(enabled)
        if not self.enabled:
            self.todos = []
        self.log("Agent 模式：%s" % ("开" if self.enabled else "关"))
        self.broadcast()

    def set_permission_mode(self, mode):
        if mode not in MODES:
            return False
        self.permission_mode = mode
        self.log("权限档位：%s" % mode)
        self.broadcast()
        return True

    def set_workspace(self, path):
        target = os.path.realpath(os.path.expanduser((path or "").strip() or "~"))
        if not os.path.isdir(target):
            return False, "目录不存在：%s" % path
        self.workspace = target
        self.log("工作目录：%s" % target)
        self.broadcast()
        return True, _tilde(target)

    def set_todos(self, todos):
        self.todos = todos
        self.emit({"type": "agent_todos", "todos": todos})

    def reset_turn(self):
        self.steps = 0

    # ------------------------------------------------------------ 权限

    def requires_confirmation(self, name, tool, arguments, auto_approve):
        """这一次工具调用要不要弹确认框。

        四条闸依次问：配置里免了吗 → 本次会话里免了吗 → 风险够不够格 → 当前档位放不放。
        非 Agent 模式下只有前三条，行为和以前一模一样。
        """
        from .tools import registry
        from .tools import shell as shell_impl

        if name in auto_approve or name in self.session_allow:
            return False
        if not registry.needs_confirmation(tool):
            return False        # L0/L1 一直都不用确认
        if not self.enabled or self.permission_mode == "ask":
            return True
        if self.permission_mode == "bypass":
            return False
        # accept_edits：编辑类和只读命令放行，其余仍要点头
        if name in EDIT_TOOLS:
            return False
        if name == "shell_run" and shell_impl.is_read_only((arguments or {}).get("command")):
            return False
        return True

    def allow_for_session(self, name):
        self.session_allow.add(name)
        self.log("本次会话内免确认：%s" % name)

    # ------------------------------------------------------------ 上下文

    def project_context(self, max_chars=6000):
        """工作目录里的项目说明。CLI 编码助手的 CLAUDE.md 是同一个东西——
        没有它，模型每次都要重新摸索这个项目怎么构建、有什么约定。"""
        for name in self.context_files:
            path = os.path.join(self.workspace, name)
            if not os.path.isfile(path):
                continue
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    text = fh.read(max_chars + 1)
            except OSError:
                continue
            if not text.strip():
                continue
            suffix = "\n…（已截断）" if len(text) > max_chars else ""
            return "%s（工作目录里的项目说明，视为权威约定）：\n%s%s" % (
                name, text[:max_chars], suffix)
        return ""

    def prompt_block(self, marker):
        """拼进 system prompt 的 Agent 段。非 Agent 模式返回空串。"""
        if not self.enabled:
            return ""
        listing = _listing(self.workspace)
        context = self.project_context()
        block = AGENT_PROMPT.format(
            workspace=_tilde(self.workspace),
            listing=listing,
            mode=_MODE_NOTES[self.permission_mode],
            max_steps=self.max_steps,
            marker=marker,
        )
        if context:
            block += "\n\n== PROJECT CONTEXT ==\n" + context
        return block


_MODE_NOTES = {
    "ask": "every file change and command needs the user's click. Expect pauses.",
    "accept_edits": "file edits and read-only commands run without asking; "
                    "commands that write, install, or quit apps still need a click.",
    "bypass": "nothing asks for confirmation. Be correspondingly careful — "
              "an irreversible mistake has no gate in front of it.",
}


AGENT_PROMPT = """
== AGENT MODE — you are executing, not chatting ==
Working directory: {workspace}
{listing}
Permission: {mode}
Step budget: {max_steps} tool rounds for this task.

How you work here:
- Do the whole job. Investigate, change, verify, then report — in one turn, without
  stopping to ask "shall I proceed?". The user already asked; the permission gate
  above is what protects them, not a question from you.
- Before any non-trivial task (3+ steps), call todo_write with the plan, then keep it
  current: exactly one item in_progress, mark items completed the moment they're done.
  For a one-step task, skip it entirely — a todo list for "read one file" is noise.
- Find things with grep and glob, not by shelling out to find/grep. Read a file before
  you edit it; edit with file_edit (exact unique string), not by rewriting the whole
  file with fs_write. fs_write is for new files.
- VERIFY. After edits, run whatever this project already uses — its build, its tests,
  a syntax check, a re-read of the edited region. Never report success from the fact
  that a tool returned without an error; report it from evidence you actually looked at.
- Long-running commands (dev servers, watchers) go in the background with
  run_in_background, then shell_output to check on them. Never block on them.
- Independent tool calls go out together in one batch. Sequential ones don't.
- If you get stuck or something looks wrong, stop and say so with the evidence. Do not
  invent a plausible-sounding result, do not silently work around a blocker, and do not
  keep retrying the same failing call with different wording.

Narration while you work:
- Between tool calls, at most one short English line saying what you're about to do.
  No {marker} marker there, no Chinese, no bullet lists, no restating the plan — the
  user sees every tool call and its result already.
- Only your FINAL answer, the one with no tool calls after it, uses the full
  three-part format. Make it a real report: what you changed (with paths), what you
  verified and how, and anything you deliberately left undone."""


def _listing(workspace, limit=40):
    """工作目录的第一层。给模型一个落脚点，省掉开局那次必然的 fs_list。"""
    try:
        names = sorted(os.listdir(workspace))
    except OSError:
        return ""
    visible = [n for n in names if not n.startswith(".")][:limit]
    if not visible:
        return ""
    marked = []
    for name in visible:
        full = os.path.join(workspace, name)
        marked.append(name + "/" if os.path.isdir(full) else name)
    tail = " …" if len(names) > limit else ""
    return "Top level: " + "  ".join(marked) + tail


def _tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home) else path


COMPACT_PROMPT = """You are compacting the earlier part of an agent session so it can
keep working within its context window. Write a dense factual summary in English of
the conversation below. It must preserve, in this order:

1. What the user asked for, in their own terms, including any constraints they stated.
2. Every file that was created, edited, moved, or deleted — full paths, and what changed.
3. Commands that were run and what they proved (tests passing, build failing, etc).
4. Decisions made and the reason, especially ones the user approved or rejected.
5. What is still not done.

Facts only. No preamble, no "the assistant then". If something was tried and abandoned,
say that it was abandoned and why — otherwise it will be tried again."""


def compaction_marker(summary):
    return {"role": "system", "content":
            "== EARLIER IN THIS SESSION (compacted at %s) ==\n%s\n"
            "== END OF COMPACTED HISTORY — the messages below are verbatim ==" % (
                time.strftime("%H:%M"), summary)}
