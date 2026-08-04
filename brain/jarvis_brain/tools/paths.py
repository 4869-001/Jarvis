"""路径闸门。

模型给的路径一律先过这里：展开 ~ / 解析软链 / 判断是否落在允许的根目录内 /
挡掉几个明确不该碰的地方。越界返回异常，不做"尽力而为"的猜测。
"""
import os

# 即便在 fs_roots 之内也一律拒绝。凭据和本程序自己的配置。
DENY_SUFFIXES = (
    "/.ssh",
    "/.gnupg",
    "/.aws",
    "/library/keychains",
    "/.jarvis/config.json",
    "/.config/gh/hosts.yml",
)


class PathDenied(Exception):
    pass


def resolve(raw, roots, must_exist=False, base=None):
    """base 是相对路径的锚点（agent 模式下的工作目录）。

    不给 base 时相对路径会按 Brain 进程的 cwd 解析——那是 launchd 拉起来的
    进程，cwd 是 `/`，模型写 `src/main.py` 会解析到 `/src/main.py` 然后报
    "不在允许范围内"。Agent 模式下模型天然会用相对路径，所以必须有锚点。
    """
    if not raw or not isinstance(raw, str):
        raise PathDenied("路径为空")

    raw = raw.strip()
    expanded = os.path.expanduser(raw)
    if base and not os.path.isabs(expanded) and not raw.startswith("~"):
        expanded = os.path.join(base, expanded)
    path = os.path.realpath(expanded)

    lowered = path.lower() + "/"
    for bad in DENY_SUFFIXES:
        if (bad + "/") in lowered:
            raise PathDenied("拒绝访问敏感路径：%s" % raw)

    for root in roots:
        if path == root or path.startswith(root.rstrip("/") + "/"):
            break
    else:
        raise PathDenied("路径不在允许范围内：%s（允许：%s）" % (raw, "、".join(roots)))

    if must_exist and not os.path.exists(path):
        raise PathDenied("路径不存在：%s" % raw)
    return path


def display(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home) else path
