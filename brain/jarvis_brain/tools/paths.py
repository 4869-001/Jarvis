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


def resolve(raw, roots, must_exist=False):
    if not raw or not isinstance(raw, str):
        raise PathDenied("路径为空")

    path = os.path.realpath(os.path.expanduser(raw.strip()))

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
