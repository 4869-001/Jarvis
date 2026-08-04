"""Agent 模式的编辑与检索工具。

和 fs.py 的分工：fs.py 是"给人看的文件操作"（列目录、整份读写、移动），
这里是"给 agent 改代码用的"——精确到一处字符串的替换、按内容检索、按模式找文件。

三条设计取舍，都是照着 CLI 编码助手的实测经验来的：

1. **编辑用唯一字符串替换，不用行号**。行号在模型读到文件、想清楚要改什么、
   真正发出编辑请求这三步之间会被自己的上一次编辑改掉，按行号改是自伤。
   old_string 不唯一时直接报错并要求带更多上下文，绝不"改第一处"猜意图。
2. **每次编辑都留 .jarvis.bak 并回一份 diff**。面板据此画彩色 diff 和撤销按钮；
   模型据此确认改动真的落在预期位置——写完不校验是这类工具最常见的翻车点。
3. **检索优先用 ripgrep，没有就退 BSD grep**。这台机器上 `rg` 是个 zsh 函数
   （指向 claude），不是二进制，所以不能只看 `which`，必须真跑一次
   `--version` 看输出里有没有 "ripgrep"。
"""
import difflib
import fnmatch
import hashlib
import os
import shutil
import subprocess

from .paths import PathDenied, display, resolve

MAX_DIFF_LINES = 400
_SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", ".mypy_cache",
              "dist", "build", ".next", "DerivedData", ".jarvis"}

_RIPGREP = None


def _ripgrep():
    """返回 ripgrep 可执行文件路径，没有则返回空串。结果缓存，只探一次。"""
    global _RIPGREP
    if _RIPGREP is not None:
        return _RIPGREP
    _RIPGREP = ""
    seen = set()
    for candidate in ("/opt/homebrew/bin/rg", "/usr/local/bin/rg", shutil.which("rg") or ""):
        if not candidate or candidate in seen or not os.path.isfile(candidate):
            continue
        seen.add(candidate)
        try:
            out = subprocess.run([candidate, "--version"], capture_output=True,
                                 text=True, timeout=5)
        except Exception:
            continue
        # 这台机器上 PATH 里的 rg 可能是别的程序伪装的，认准自报家门那一行
        if out.returncode == 0 and "ripgrep" in (out.stdout or "").lower():
            _RIPGREP = candidate
            break
    return _RIPGREP


def _workspace(ctx):
    return ctx.get("workspace") or os.path.expanduser("~")


def _read_text(path):
    with open(path, "rb") as fh:
        blob = fh.read()
    if b"\x00" in blob[:4096]:
        raise PathDenied("二进制文件，拒绝编辑：%s" % display(path))
    return blob.decode("utf-8", "replace")


def _diff(before, after, path, limit=MAX_DIFF_LINES):
    lines = list(difflib.unified_diff(
        before.splitlines(), after.splitlines(),
        fromfile=path, tofile=path, lineterm="", n=3))
    truncated = len(lines) > limit
    return "\n".join(lines[:limit]), truncated


def file_edit(args, ctx):
    """把文件里唯一一处 old_string 换成 new_string。

    old_string 为空字符串时是"新建文件"——但那条路交给 fs_write，这里明确拒绝，
    免得模型用一个语义含糊的编辑把整份文件冲掉。
    """
    path = resolve(args.get("path", ""), ctx["fs_roots"], must_exist=True,
                   base=_workspace(ctx))
    if os.path.isdir(path):
        return {"error": "这是目录：%s" % display(path)}

    old = args.get("old_string")
    new = args.get("new_string")
    if old is None or new is None:
        return {"error": "缺少 old_string 或 new_string"}
    if old == "":
        return {"error": "old_string 不能为空。新建文件请用 fs_write。"}
    if old == new:
        return {"error": "old_string 和 new_string 完全相同，没有改动"}

    before = _read_text(path)
    occurrences = before.count(old)
    if occurrences == 0:
        return {"error": "在 %s 里找不到要替换的内容。请先 fs_read 确认原文"
                         "（注意缩进和空白必须逐字对上）。" % display(path)}

    replace_all = bool(args.get("replace_all"))
    if occurrences > 1 and not replace_all:
        return {"error": "old_string 在 %s 里出现了 %d 次，无法确定改哪一处。"
                         "请补足前后文让它唯一，或显式传 replace_all=true。"
                         % (display(path), occurrences)}

    after = before.replace(old, new) if replace_all else before.replace(old, new, 1)

    try:
        shutil.copy2(path, path + ".jarvis.bak")
        backup = display(path + ".jarvis.bak")
    except Exception:
        backup = None

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(after)

    # 写完回读校验：磁盘上的内容才是事实，内存里算出来的 after 不是。
    written = _read_text(path)
    verified = written == after
    patch, truncated = _diff(before, after, display(path))
    added = sum(1 for line in patch.splitlines()
                if line.startswith("+") and not line.startswith("+++"))
    removed = sum(1 for line in patch.splitlines()
                  if line.startswith("-") and not line.startswith("---"))

    return {
        "path": display(path),
        "replaced": occurrences if replace_all else 1,
        "added_lines": added,
        "removed_lines": removed,
        "diff": patch,
        "diff_truncated": truncated,
        "verified": verified,
        "sha256": hashlib.sha256(written.encode("utf-8")).hexdigest(),
        "backup": backup,
    }


def file_restore(args, ctx):
    """把上一次编辑撤销回来——面板 diff 卡片上的「撤销」就是调它。"""
    path = resolve(args.get("path", ""), ctx["fs_roots"], base=_workspace(ctx))
    backup = path + ".jarvis.bak"
    if not os.path.exists(backup):
        return {"error": "没有备份可恢复：%s" % display(backup)}
    shutil.copy2(backup, path)
    return {"path": display(path), "restored_from": display(backup), "verified": True}


def _grep_with_ripgrep(binary, pattern, target, args, limit):
    mode = args.get("mode") or "content"
    cmd = [binary, "--no-heading", "--color", "never", "--max-columns", "400"]
    if args.get("case_insensitive"):
        cmd.append("-i")
    if mode == "files":
        cmd.append("--files-with-matches")
    elif mode == "count":
        cmd.append("--count-matches")
    else:
        cmd.append("--line-number")
        context = int(args.get("context") or 0)
        if context > 0:
            cmd += ["-C", str(min(context, 5))]
    if args.get("glob"):
        cmd += ["--glob", args["glob"]]
    cmd += ["--max-count", str(limit), "-e", pattern, target]
    return cmd


def _grep_with_bsd(pattern, target, args, limit):
    mode = args.get("mode") or "content"
    cmd = ["/usr/bin/grep", "-r", "-I", "-E"]
    if args.get("case_insensitive"):
        cmd.append("-i")
    if mode == "files":
        cmd.append("-l")
    elif mode == "count":
        cmd.append("-c")
    else:
        cmd.append("-n")
        context = int(args.get("context") or 0)
        if context > 0:
            cmd += ["-C", str(min(context, 5))]
    if args.get("glob"):
        cmd += ["--include", args["glob"]]
    for skip in _SKIP_DIRS:
        cmd += ["--exclude-dir", skip]
    cmd += ["-e", pattern, target]
    return cmd


def grep(args, ctx):
    """按内容检索。默认在工作目录下递归找。"""
    pattern = (args.get("pattern") or "").strip()
    if not pattern:
        return {"error": "缺少 pattern"}

    target = resolve(args.get("path") or _workspace(ctx), ctx["fs_roots"],
                     must_exist=True, base=_workspace(ctx))
    limit = min(int(args.get("limit") or 80), 300)

    binary = _ripgrep()
    cmd = (_grep_with_ripgrep(binary, pattern, target, args, limit) if binary
           else _grep_with_bsd(pattern, target, args, limit))

    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return {"error": "检索超时：%s" % pattern}
    # grep/rg 的退出码 1 是"没匹配"，不是错误；2 才是真出错
    if out.returncode >= 2 and not out.stdout:
        return {"error": "检索失败：%s" % (out.stderr or "").strip()[:300]}

    lines = [line for line in out.stdout.splitlines() if line.strip()]
    home = os.path.expanduser("~")
    lines = [line.replace(home + "/", "~/") for line in lines]
    truncated = len(lines) > limit
    return {
        "pattern": pattern,
        "path": display(target),
        "engine": "ripgrep" if binary else "grep",
        "count": len(lines),
        "truncated": truncated,
        "matches": lines[:limit],
    }


def glob_files(args, ctx):
    """按文件名模式找文件，按修改时间从新到旧排。

    自己走 os.walk 而不是 pathlib.rglob：要在进目录之前就剪掉 node_modules
    /.git 这些，rglob 会先把它们整个遍历完再过滤，大仓库上能卡十几秒。
    """
    pattern = (args.get("pattern") or "").strip()
    if not pattern:
        return {"error": "缺少 pattern"}
    root = resolve(args.get("path") or _workspace(ctx), ctx["fs_roots"],
                   must_exist=True, base=_workspace(ctx))
    limit = min(int(args.get("limit") or 100), 500)

    # "**/*.py" 与 "*.py" 都该匹配任意层级下的 .py，模型两种都会写
    tail = pattern.split("/")[-1] if pattern.startswith("**/") else pattern
    match_full = "/" in tail

    hits = []
    for current, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in _SKIP_DIRS and not d.startswith(".")]
        for name in files:
            full = os.path.join(current, name)
            probe = os.path.relpath(full, root) if match_full else name
            if not fnmatch.fnmatch(probe, tail):
                continue
            try:
                hits.append((os.path.getmtime(full), full))
            except OSError:
                continue
        if len(hits) > limit * 5:      # 够排序了，别为了完美把整棵树走完
            break

    hits.sort(reverse=True)
    return {
        "pattern": pattern,
        "path": display(root),
        "count": len(hits),
        "truncated": len(hits) > limit,
        "files": [display(full) for _, full in hits[:limit]],
    }
