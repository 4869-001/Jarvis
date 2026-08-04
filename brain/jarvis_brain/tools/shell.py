"""shell_run —— 默认关闭，开了也每次确认（Agent 模式的权限档位另算）。

这是整套工具里唯一无法用 Schema 约束语义的口子，所以默认要同时满足三条：
配置里显式打开、每次弹确认、命中黑名单直接拒。

tools.shell_unrestricted = true 会摘掉第三条（黑名单），剩下的两道闸还在。
摘掉它就等于把终端的权限交给模型，不可逆操作也拦不住了——这是用户明确要求
"和 CLI 一样"时才该开的档位。

Agent 模式还要多两件事，都在这里实现：
- **实时回显**：构建、测试这类命令跑几十秒，跑完才吐结果的话面板全程是死的。
  有 ctx["stream"] 时逐行往上送，面板照着画滚动输出。
- **后台进程**：`npm run dev`、`tail -f` 这种根本不会自己结束。run_in_background
  起了就返回一个 shell_id，之后用 shell_output 取增量、shell_kill 收工。
  子进程一律 start_new_session=True 单独成组——不这样的话超时后 kill 的只有
  /bin/zsh 本身，它 fork 出去的编译进程会变成孤儿继续吃 CPU。
"""
import collections
import os
import queue
import re
import signal
import subprocess
import threading
import time
import uuid

# 队列取空时的哨兵。用它和"进程输出结束"的 None 区分开：空转一圈只是为了
# 让超时和取消有机会被检查到，不代表命令跑完了。
_IDLE = object()

# 不可逆或提权的东西，即使用户点了确认也不执行
BLOCKED = [
    (re.compile(r"\brm\s+(-\w*\s+)*-\w*[rf]", re.I), "递归/强制删除"),
    (re.compile(r"\bsudo\b"), "提权"),
    (re.compile(r"\bmkfs|\bdiskutil\s+erase|\bdd\s+if=", re.I), "磁盘操作"),
    (re.compile(r":\(\)\s*\{.*\};\s*:"), "fork 炸弹"),
    (re.compile(r"\bshutdown\b|\breboot\b|\bhalt\b", re.I), "关机重启"),
    (re.compile(r"\bcurl\b.*\|\s*(ba)?sh|\bwget\b.*\|\s*(ba)?sh", re.I), "下载即执行"),
    (re.compile(r"\bchmod\s+(-\w+\s+)*777\b"), "开放全权限"),
    (re.compile(r"\b(launchctl|systemsetup|csrutil|spctl)\b", re.I), "系统配置"),
]

# 只读命令，Agent 的 accept_edits 档位下免确认。判的是整条命令的第一个词，
# 带管道或 && 的复合命令一律不算只读——`git log | xargs rm` 也是 git 开头。
READ_ONLY_PREFIXES = (
    "ls", "cat", "head", "tail", "wc", "file", "stat", "du", "df", "pwd", "which",
    "echo", "date", "uname", "whoami", "env", "printenv", "sw_vers", "ps", "top",
    "grep", "rg", "find", "fd", "sort", "uniq", "diff", "tree", "sed", "awk", "jq",
    "git status", "git log", "git diff", "git show", "git branch", "git remote",
    "git blame", "git stash list", "python3 -c", "node -e", "man", "type", "open -R",
)
_COMPOUND = re.compile(r"[;&|>]|\$\(|`")


def is_read_only(command):
    command = (command or "").strip()
    if not command or _COMPOUND.search(command):
        return False
    lowered = command.lower()
    return any(lowered == p or lowered.startswith(p + " ") for p in READ_ONLY_PREFIXES)


class BackgroundShell:
    """一个还在跑的后台进程，外加它到目前为止的输出。"""

    def __init__(self, shell_id, command, cwd, proc, buffer_lines):
        self.id = shell_id
        self.command = command
        self.cwd = cwd
        self.proc = proc
        self.started = time.time()
        self.lines = collections.deque(maxlen=buffer_lines)
        self.cursor = 0            # 已经交给模型的行数
        self.total = 0
        self._lock = threading.Lock()
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        for raw in iter(self.proc.stdout.readline, ""):
            with self._lock:
                self.lines.append(raw.rstrip("\n"))
                self.total += 1
        self.proc.wait()

    @property
    def running(self):
        return self.proc.poll() is None

    def take(self, pattern=None, limit=200):
        """取走还没给过模型的输出。取过就不再重复给——长跑进程每次都回全量的话，
        上下文会被同一批日志灌满。"""
        with self._lock:
            available = list(self.lines)
            # deque 满了会从头丢，丢掉的那些不能再算进未读
            dropped = self.total - len(available)
            start = max(self.cursor - dropped, 0)
            fresh = available[start:]
            self.cursor = self.total
        if pattern:
            try:
                regex = re.compile(pattern)
                fresh = [line for line in fresh if regex.search(line)]
            except re.error as exc:
                return ["正则无效：%s" % exc]
        return fresh[-limit:]

    def kill(self):
        if not self.running:
            return False
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except Exception:
            self.proc.terminate()
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            except Exception:
                self.proc.kill()
        return True


SHELLS = {}
_SHELLS_LOCK = threading.Lock()


def _gate(args, ctx):
    """返回 (command, cwd) 或抛出装着错误字典的 _Refused。"""
    if not ctx["allow_shell"]:
        raise _Refused({"error": "shell_run 已在配置里关闭。要启用：把 ~/.jarvis/config.json 的 "
                                 "tools.allow_shell 改为 true。"})

    command = (args.get("command") or "").strip()
    if not command:
        raise _Refused({"error": "缺少 command"})

    if not ctx.get("shell_unrestricted"):
        for pattern, why in BLOCKED:
            if pattern.search(command):
                raise _Refused({"error": "命令被拦截（%s），不执行：%s。"
                                         "确实需要就把 ~/.jarvis/config.json 的 "
                                         "tools.shell_unrestricted 改成 true。" % (why, command)})

    raw_cwd = args.get("cwd") or ctx.get("workspace") or "~"
    cwd = os.path.expanduser(raw_cwd)
    if not os.path.isabs(cwd):
        cwd = os.path.join(ctx.get("workspace") or os.path.expanduser("~"), cwd)
    if not os.path.isdir(cwd):
        cwd = ctx.get("workspace") or os.path.expanduser("~")
    return command, cwd


class _Refused(Exception):
    def __init__(self, payload):
        super().__init__(payload.get("error", ""))
        self.payload = payload


def _spawn(command, cwd):
    return subprocess.Popen(
        ["/bin/zsh", "-c", command],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, cwd=cwd,
        start_new_session=True,          # 自成进程组，超时能连子孙一起收掉
    )


def shell_run(args, ctx):
    try:
        command, cwd = _gate(args, ctx)
    except _Refused as refused:
        return refused.payload

    ceiling = 600 if ctx.get("shell_unrestricted") else 120
    timeout = min(int(args.get("timeout") or 30), ceiling)
    limit = ctx["max_output_chars"]

    if args.get("run_in_background"):
        if not ctx.get("agent_mode"):
            return {"error": "后台进程只在 Agent 模式下可用"}
        proc = _spawn(command, cwd)
        shell_id = "sh_" + uuid.uuid4().hex[:8]
        shell = BackgroundShell(shell_id, command, cwd, proc,
                                int(ctx.get("buffer_lines") or 2000))
        with _SHELLS_LOCK:
            SHELLS[shell_id] = shell
        return {"shell_id": shell_id, "command": command, "cwd": cwd, "background": True,
                "note": "已在后台启动。用 shell_output 取输出，shell_kill 结束它。"}

    stream = ctx.get("stream")
    cancelled = ctx.get("cancelled")
    proc = _spawn(command, cwd)
    deadline = time.time() + timeout
    collected = []
    pending = []
    last_flush = time.time()
    timed_out = False
    stream_budget = int(ctx.get("stream_lines") or 200)

    def flush():
        nonlocal pending, last_flush
        if pending and stream:
            stream("\n".join(pending) + "\n")
        pending = []
        last_flush = time.time()

    # 读输出必须放在单独的线程里。直接在这里 `for raw in proc.stdout` 的话，
    # 一条不出声的命令（`sleep 5`、等输入的交互式命令）会把主循环阻塞在
    # readline 上，超时和取消这两个判断根本轮不到执行——症状是"设了 30 秒
    # 超时，结果卡了十分钟"。实测复现过，别改回去。
    lines = queue.Queue()

    def reader():
        try:
            for raw in iter(proc.stdout.readline, ""):
                lines.put(raw)
        finally:
            lines.put(None)

    threading.Thread(target=reader, daemon=True).start()

    try:
        while True:
            try:
                raw = lines.get(timeout=0.2)
            except queue.Empty:
                raw = _IDLE
            if raw is None:
                break                       # 进程的输出到头了
            if raw is not _IDLE:
                collected.append(raw)
                if stream and stream_budget > 0:
                    pending.append(raw.rstrip("\n"))
                    stream_budget -= 1
            # 攒一小批再发：一行一条 IPC 消息会把面板刷爆
            if pending and (len(pending) >= 20 or time.time() - last_flush > 0.25):
                flush()
            if time.time() > deadline:
                timed_out = True
                break
            if cancelled and cancelled():
                break
    finally:
        flush()

    if timed_out or (cancelled and cancelled()):
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            proc.kill()
        output = "".join(collected)[-limit:]
        if timed_out:
            return {"error": "命令超时（%ds）：%s" % (timeout, command),
                    "command": command, "cwd": cwd, "output": output}
        return {"error": "已取消：%s" % command, "command": command, "output": output}

    proc.wait()
    output = "".join(collected)
    return {
        "command": command,
        "cwd": cwd,
        "exit_code": proc.returncode,
        "truncated": len(output) > limit,
        # 截断留尾不留头：报错信息、测试结论几乎总在最后
        "output": output[-limit:],
    }


def shell_output(args, ctx):
    shell_id = (args.get("shell_id") or "").strip()
    with _SHELLS_LOCK:
        shell = SHELLS.get(shell_id)
    if not shell:
        return {"error": "没有这个后台进程：%s" % shell_id}
    lines = shell.take(args.get("filter"), int(args.get("limit") or 200))
    return {
        "shell_id": shell_id,
        "command": shell.command,
        "running": shell.running,
        "exit_code": None if shell.running else shell.proc.returncode,
        "elapsed": round(time.time() - shell.started, 1),
        "new_lines": len(lines),
        "output": "\n".join(lines),
    }


def shell_kill(args, ctx):
    shell_id = (args.get("shell_id") or "").strip()
    with _SHELLS_LOCK:
        shell = SHELLS.get(shell_id)
    if not shell:
        return {"error": "没有这个后台进程：%s" % shell_id}
    was_running = shell.kill()
    with _SHELLS_LOCK:
        SHELLS.pop(shell_id, None)
    return {"shell_id": shell_id, "command": shell.command,
            "killed": was_running, "note": "" if was_running else "它本来就已经结束了"}


def shell_list(args, ctx):
    with _SHELLS_LOCK:
        shells = list(SHELLS.values())
    return {"count": len(shells), "shells": [{
        "shell_id": s.id, "command": s.command, "running": s.running,
        "elapsed": round(time.time() - s.started, 1), "lines": s.total,
    } for s in shells]}


def kill_all():
    """会话重置 / Brain 退出时收干净，别留一堆孤儿构建进程。"""
    with _SHELLS_LOCK:
        shells = list(SHELLS.values())
        SHELLS.clear()
    for shell in shells:
        try:
            shell.kill()
        except Exception:
            pass
