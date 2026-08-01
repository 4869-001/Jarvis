"""工具注册表。

每个工具四件事定死：JSON Schema、风险等级、由谁执行、要不要确认。

executor = "native" 的工具由 ObjC 宿主执行，Brain 只负责转发。
原因不是"更可控"这种软理由，而是 TCC 权限按 app bundle 授予：
Python 子进程去发 Apple Events 或调 NSWorkspace，授权弹窗归属会漂移到解释器上。
留在宿主进程里，系统只认 Jarvis.app 一个 bundle。

风险等级：
    L0 只读            L1 良性副作用（可自行撤销）
    L2 改动文件        L4 任意命令
L2 起需要用户确认。
"""
from . import fs as fs_impl
from . import music as music_impl
from . import shell as shell_impl
from . import web as web_impl
from .music import music_play_favorite, media_control

CONFIRM_FROM = "L2"
_ORDER = {"L0": 0, "L1": 1, "L2": 2, "L3": 3, "L4": 4}


def _tool(name, desc, params, risk, executor, fn=None, required=None):
    return {
        "name": name,
        "description": desc,
        "risk": risk,
        "executor": executor,
        "fn": fn,
        "schema": {
            "type": "object",
            "properties": params,
            "required": required or [],
        },
    }


_STR = {"type": "string"}
_INT = {"type": "integer"}
_BOOL = {"type": "boolean"}


def _p(desc, kind=None):
    out = dict(kind or _STR)
    out["description"] = desc
    return out


TOOLS = [
    # ------------------------------------------------ 本机应用与系统（ObjC 执行）
    _tool("app_open", "打开或切换到一个 macOS 应用程序。",
          {"name": _p("应用名，如 Safari、备忘录、Visual Studio Code")},
          "L1", "native", required=["name"]),

    _tool("app_quit", "退出一个正在运行的应用程序。",
          {"name": _p("应用名")},
          "L2", "native", required=["name"]),

    _tool("app_list_running", "列出当前正在运行的、有界面的应用程序。",
          {}, "L0", "native"),

    _tool("url_open", "用默认浏览器打开一个网址。",
          {"url": _p("完整 URL")},
          "L1", "native", required=["url"]),

    _tool("finder_reveal", "在访达中定位并选中某个文件或文件夹。",
          {"path": _p("文件或文件夹路径")},
          "L1", "native", required=["path"]),

    _tool("clipboard_read", "读取当前剪贴板中的文本。",
          {}, "L0", "native"),

    _tool("clipboard_write", "把文本写入剪贴板。",
          {"text": _p("要写入的文本")},
          "L1", "native", required=["text"]),

    _tool("system_notify", "发一条 macOS 通知中心提醒。",
          {"title": _p("标题"), "body": _p("正文")},
          "L1", "native", required=["title"]),

    _tool("system_info", "获取本机状态：电量、内存压力、磁盘剩余、当前前台应用、时间。",
          {}, "L0", "native"),

    _tool("media_control", "控制网易云音乐播放：播放/暂停、下一首、上一首。",
          {"action": {
              "type": "string",
              "enum": ["play_pause", "next", "previous"],
              "description": "play_pause 播放/暂停切换，next 下一首，previous 上一首",
          }},
          "L1", "python", media_control, required=["action"]),

    _tool("music_play_favorite", "打开网易云音乐并直接播放「我喜欢的音乐」歌单。"
          "用户说「放音乐」「听歌」「打开网易云」时优先使用这个工具。",
          {}, "L1", "python", music_play_favorite),

    # ------------------------------------------------ 文件（Brain 执行）
    _tool("fs_list", "列出目录内容。",
          {"path": _p("目录路径，默认 ~"),
           "include_hidden": _p("是否包含隐藏文件", _BOOL),
           "limit": _p("最多返回多少条，默认 200", _INT)},
          "L0", "python", fs_impl.fs_list),

    _tool("fs_read", "读取文本文件内容。",
          {"path": _p("文件路径"),
           "max_chars": _p("最多读多少字符，默认 20000", _INT)},
          "L0", "python", fs_impl.fs_read, required=["path"]),

    _tool("fs_search", "按文件名在本机搜索文件（走 Spotlight，很快）。",
          {"query": _p("文件名关键词"),
           "scope": _p("限定在某个目录下搜索，可选"),
           "limit": _p("最多返回多少条，默认 30", _INT)},
          "L0", "python", fs_impl.fs_search, required=["query"]),

    _tool("fs_write", "写入或追加文本文件。覆盖已有文件时会自动留一份 .jarvis.bak。",
          {"path": _p("文件路径"),
           "content": _p("文件内容"),
           "mode": {"type": "string", "enum": ["overwrite", "append"],
                    "description": "overwrite 覆盖（默认），append 追加"}},
          "L2", "python", fs_impl.fs_write, required=["path", "content"]),

    _tool("fs_move", "移动或重命名文件/文件夹。目标已存在时不覆盖，直接报错。",
          {"source": _p("源路径"), "destination": _p("目标路径")},
          "L2", "python", fs_impl.fs_move, required=["source", "destination"]),

    # ------------------------------------------------ 联网（Brain 执行）
    _tool("web_search", "联网搜索。需要最新信息、不确定的事实、或用户明确要求查资料时使用。",
          {"query": _p("搜索关键词"),
           "count": _p("返回条数，默认 5，最多 10", _INT)},
          "L1", "python", web_impl.web_search, required=["query"]),

    _tool("web_fetch", "抓取一个网页并提取正文。通常在 web_search 之后，用于读某条结果的详情。",
          {"url": _p("网页地址"),
           "max_chars": _p("最多返回多少字符，默认 8000", _INT)},
          "L1", "python", web_impl.web_fetch, required=["url"]),

    # ------------------------------------------------ 兜底
    _tool("shell_run", "执行一条 zsh 命令。仅在没有任何其他工具能完成时使用；默认被禁用。",
          {"command": _p("命令行"),
           "cwd": _p("工作目录，默认 ~"),
           "timeout": _p("超时秒数，默认 30", _INT)},
          "L4", "python", shell_impl.shell_run, required=["command"]),
]

BY_NAME = {tool["name"]: tool for tool in TOOLS}


def needs_confirmation(tool):
    return _ORDER.get(tool["risk"], 9) >= _ORDER[CONFIRM_FROM]


def openai_schema(tools=None):
    """转成 DeepSeek（OpenAI 兼容）要的 tools 数组。"""
    return [{
        "type": "function",
        "function": {
            "name": tool["name"],
            "description": tool["description"],
            "parameters": tool["schema"],
        },
    } for tool in (tools if tools is not None else TOOLS)]


def describe(name, arguments):
    """给确认弹窗和 UI 用的一句话人话描述。"""
    arguments = arguments or {}
    templates = {
        "app_open": "打开应用「{name}」",
        "app_quit": "退出应用「{name}」",
        "url_open": "打开网页 {url}",
        "finder_reveal": "在访达中显示 {path}",
        "clipboard_write": "写入剪贴板",
        "system_notify": "发送通知「{title}」",
        "fs_list": "列出 {path} 的内容",
        "fs_read": "读取 {path}",
        "fs_search": "搜索文件「{query}」",
        "fs_write": "写入文件 {path}",
        "fs_move": "把 {source} 移动到 {destination}",
        "media_control": "媒体控制：{action}",
        "music_play_favorite": "打开网易云音乐，播放「我喜欢的音乐」",
        "web_search": "联网搜索「{query}」",
        "web_fetch": "抓取网页 {url}",
        "shell_run": "执行命令：{command}",
    }
    template = templates.get(name)
    if not template:
        return name
    return template.format_map(_Blank(arguments))


class _Blank(dict):
    """模型漏传参数时不该炸掉描述，占位就行。"""
    def __missing__(self, key):
        return "?"
