"""shell_run —— 默认关闭，开了也每次确认。

这是整套工具里唯一无法用 Schema 约束语义的口子，所以它必须同时满足三条：
配置里显式打开、每次弹确认、命中黑名单直接拒。
"""
import os
import re
import subprocess

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


def shell_run(args, ctx):
    if not ctx["allow_shell"]:
        return {"error": "shell_run 已在配置里关闭。要启用：把 ~/.jarvis/config.json 的 "
                         "tools.allow_shell 改为 true。"}

    command = (args.get("command") or "").strip()
    if not command:
        return {"error": "缺少 command"}

    for pattern, why in BLOCKED:
        if pattern.search(command):
            return {"error": "命令被拦截（%s），不执行：%s" % (why, command)}

    cwd = os.path.expanduser(args.get("cwd") or "~")
    if not os.path.isdir(cwd):
        cwd = os.path.expanduser("~")

    try:
        proc = subprocess.run(
            ["/bin/zsh", "-c", command],
            capture_output=True, text=True, timeout=min(int(args.get("timeout") or 30), 120),
            cwd=cwd,
        )
    except subprocess.TimeoutExpired:
        return {"error": "命令超时：%s" % command}

    limit = ctx["max_output_chars"]
    return {
        "command": command,
        "cwd": cwd,
        "exit_code": proc.returncode,
        "stdout": proc.stdout[:limit],
        "stderr": proc.stderr[:limit],
    }
