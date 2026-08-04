"""文件工具。全部经 paths.resolve 过闸，写操作在 policy 层要确认。"""
import hashlib
import os
import shutil
import subprocess
import time

from .paths import display, resolve

TEXT_SUFFIXES = {
    ".txt", ".md", ".markdown", ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg",
    ".py", ".js", ".ts", ".tsx", ".jsx", ".m", ".h", ".c", ".cpp", ".swift", ".sh",
    ".html", ".css", ".xml", ".csv", ".log", ".plist", ".sql", ".rb", ".go", ".rs", ".java",
}


def _base(ctx):
    """相对路径的锚点。Agent 模式下模型天然会写 `src/main.py` 这种相对路径，
    而 Brain 是 launchd 拉起来的、cwd 是 `/`——不给锚点就会解析成 `/src/main.py`
    然后被闸门拒掉。真机端到端跑第一次就撞上了这个，模型白费两步才绕开。"""
    return ctx.get("workspace")


def fs_list(args, ctx):
    path = resolve(args.get("path", "~"), ctx["fs_roots"], must_exist=True, base=_base(ctx))
    if not os.path.isdir(path):
        return {"error": "不是目录：%s" % display(path)}

    show_hidden = bool(args.get("include_hidden"))
    entries = []
    for name in sorted(os.listdir(path)):
        if name.startswith(".") and not show_hidden:
            continue
        full = os.path.join(path, name)
        try:
            st = os.lstat(full)
        except OSError:
            continue
        entries.append({
            "name": name,
            "type": "dir" if os.path.isdir(full) else "file",
            "size": st.st_size,
            "modified": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime)),
        })

    limit = int(args.get("limit") or 200)
    return {
        "path": display(path),
        "count": len(entries),
        "truncated": len(entries) > limit,
        "entries": entries[:limit],
    }


def fs_read(args, ctx):
    path = resolve(args.get("path", ""), ctx["fs_roots"], must_exist=True, base=_base(ctx))
    if os.path.isdir(path):
        return {"error": "这是目录，用 fs_list：%s" % display(path)}

    max_chars = min(int(args.get("max_chars") or 20000), ctx["max_output_chars"])
    suffix = os.path.splitext(path)[1].lower()
    size = os.path.getsize(path)

    if suffix not in TEXT_SUFFIXES and size > 2 * 1024 * 1024:
        return {"error": "文件过大或非文本（%s，%d 字节），拒绝读取" % (suffix or "无后缀", size)}

    with open(path, "rb") as fh:
        blob = fh.read(max_chars * 4)
    if b"\x00" in blob[:4096]:
        return {"error": "二进制文件，拒绝读取：%s" % display(path)}

    text = blob.decode("utf-8", "replace")
    return {
        "path": display(path),
        "size": size,
        "truncated": len(text) > max_chars,
        "content": text[:max_chars],
    }


def fs_write(args, ctx):
    path = resolve(args.get("path", ""), ctx["fs_roots"], base=_base(ctx))
    content = args.get("content")
    if content is None:
        return {"error": "缺少 content"}

    mode = args.get("mode", "overwrite")
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)

    existed = os.path.exists(path)
    # 覆盖已有文件先留一份 .bak，误操作还能捞回来
    if existed and mode == "overwrite":
        try:
            shutil.copy2(path, path + ".jarvis.bak")
        except Exception:
            pass

    with open(path, "a" if mode == "append" else "w", encoding="utf-8") as fh:
        fh.write(content)

    # 写成功不等于落盘内容正确。流式计算哈希，避免为了验证大文件再整份读进内存。
    expected = content.encode("utf-8")
    digest = hashlib.sha256()
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        if mode == "append" and len(expected) <= size:
            fh.seek(-len(expected), os.SEEK_END) if expected else fh.seek(0, os.SEEK_END)
            verified = fh.read() == expected
        else:
            verified = size == len(expected) and digest.digest() == hashlib.sha256(expected).digest()

    return {
        "path": display(path),
        "mode": mode,
        "bytes": len(content.encode("utf-8")),
        "verified": verified,
        "sha256": digest.hexdigest(),
        "backup": display(path + ".jarvis.bak") if (existed and mode == "overwrite") else None,
    }


def fs_move(args, ctx):
    source = resolve(args.get("source", ""), ctx["fs_roots"], must_exist=True, base=_base(ctx))
    destination = resolve(args.get("destination", ""), ctx["fs_roots"], base=_base(ctx))

    if os.path.isdir(destination):
        destination = os.path.join(destination, os.path.basename(source))
    if os.path.exists(destination):
        return {"error": "目标已存在，未覆盖：%s" % display(destination)}

    os.makedirs(os.path.dirname(destination), exist_ok=True)
    shutil.move(source, destination)
    verified = os.path.exists(destination) and not os.path.exists(source)
    return {"from": display(source), "to": display(destination), "verified": verified}


def fs_search(args, ctx):
    """走 Spotlight。比自己递归遍历快几个数量级，且不吃 CPU。"""
    query = (args.get("query") or "").strip()
    if not query:
        return {"error": "缺少 query"}

    scope = args.get("scope")
    cmd = ["mdfind"]
    if scope:
        cmd += ["-onlyin", resolve(scope, ctx["fs_roots"], must_exist=True, base=_base(ctx))]
    cmd.append(query if args.get("raw_query") else "kMDItemDisplayName == '*%s*'cd" % query)

    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return {"error": "Spotlight 查询超时"}

    hits = [line for line in out.stdout.splitlines() if line.strip()]
    inside = []
    for hit in hits:
        try:
            inside.append(display(resolve(hit, ctx["fs_roots"])))
        except Exception:
            continue        # 命中了范围外的东西就直接不告诉模型
        if len(inside) >= int(args.get("limit") or 30):
            break

    return {"query": query, "count": len(inside), "results": inside}
