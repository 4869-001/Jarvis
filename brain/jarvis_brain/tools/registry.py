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
from . import code as code_impl
from . import fs as fs_impl
from . import memory_tools as memory_impl
from . import shell as shell_impl
from . import todo as todo_impl
from . import web as web_impl
from .. import tasking as tasking_impl

CONFIRM_FROM = "L2"
_ORDER = {"L0": 0, "L1": 1, "L2": 2, "L3": 3, "L4": 4}


def _tool(name, desc, params, risk, executor, fn=None, required=None, recover=None,
          agent_only=False):
    return {
        "name": name,
        "description": desc,
        "risk": risk,
        "executor": executor,
        "fn": fn,
        # Agent 模式专用的工具不进平时那份工具表。不是怕它们危险，是怕它们**吵**：
        # 多挂十个工具，每一轮普通闲聊都要多带一份 Schema，而管家在"现在几点"
        # 这种问题上不该有 grep 这个选项。
        "agent_only": agent_only,
        # 确认框要回答"这事能不能撤"。写不出具体撤法的就别编，留空由 UI 显示"无法自动撤销"
        # ——含糊的安慰比没有更危险。
        "recover": recover,
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
          "L2", "native", required=["name"], recover="重新打开这个应用即可"),

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

    _tool("calendar_events", "只读查看 macOS 日历中接下来的安排。询问今天、明天、"
          "近期会议或空闲时间时使用；不会新增或修改日程。日程标题、时间、日历名和"
          "地点会进入当前模型上下文，因此每次读取前必须让用户确认。",
          {"hours": _p("从现在起查看多少小时，默认 24，最多 336", _INT),
           "limit": _p("最多返回多少条，默认 20，最多 50", _INT)},
          "L2", "native"),

    _tool("mail_unread", "查看 Apple Mail 的未读邮件元数据，用于概括哪些邮件需要关注。"
          "只读取发件人、主题、收件时间和内部 id，不读取正文或附件。"
          "这些字段会进入当前模型上下文，因此每次读取前必须让用户确认。",
          {"limit": _p("最多返回多少封，默认 10，最多 20", _INT)},
          "L2", "native"),

    _tool("wechat_read", "从 macOS 通知中心数据库结构化读取微信收到的消息。发送人、正文、"
          "时间和 UUID 来自同一条通知记录，不使用屏幕截图或 OCR，不会发生联系人与正文错配。"
          "可查询整体未读数、近期来信、指定联系人的来信记录和联系人。只覆盖产生过通知的收到"
          "消息，不包含自己发出的消息、静音会话或归档前已清除的旧通知。私人聊天内容会进入"
          "当前 Jarvis 推理模型上下文，每次读取前必须让用户确认；全程只读。",
          {"mode": {"type": "string", "enum": ["unread", "recent_sessions", "chat_history", "contacts", "status"],
                    "description": "查询类型，默认 unread"},
           "contact": _p("chat_history 时必填；联系人备注、昵称或 wxid。contacts 时作为搜索词"),
           "limit": _p("最多返回多少条，默认 20，最多 100", _INT)},
          "L2", "native"),

    # 微信只有读取能力，没有发送工具，也不要再加：个人微信不返回联系人 ID、消息 ID
    # 和发送回执，键鼠模拟证明不了消息进了哪个会话，"已发送"只能是猜的。
    # 完整实测过程见 refs/Jarvis微信读写能力技术方案.md。

    _tool("media_control",
          "控制或检索音乐/视频：播放、暂停、切歌、按歌名搜索并播放、调音量、查看当前曲目。"
          "网易云音乐、Apple Music、Spotify、QQ 音乐和浏览器里的播放都能控。"
          "注意：app_open 只能把播放器打开，控制播放一律用这个工具。",
          {"action": {"type": "string",
                      "enum": ["toggle", "play", "pause", "next", "previous",
                               "volume_up", "volume_down", "like", "status", "search_play"],
                      "description": "toggle 播放/暂停切换，like 把当前歌加入喜欢（仅网易云），"
                                     "status 查当前在放什么；search_play 按 query 搜索并播放（网易云）"},
           "player": _p("指定播放器，如 网易云音乐、spotify、apple music；"
                        "不填则自动挑当前在放的那个"),
           "query": _p("search_play 必填；歌曲名，可同时带歌手名提高准确率")},
          "L1", "native", required=["action"]),

    # ------------------------------------------------ 指挥任意应用（ObjC 执行）
    # 不为每个 App 写一个工具：写死的工具只覆盖当初想到的那几个。macOS 上通用的
    # 控制面只有三个，这里按可靠性从高到低全开出来，让模型自己挑。
    _tool("app_scriptable",
          "列出本机哪些应用能用 AppleScript 驱动。不确定某个应用能不能自动化时先问这个。",
          {"filter": _p("只看名字里含这个词的应用，可选")},
          "L0", "native"),

    _tool("app_dictionary",
          "读取某个应用的脚本字典：它支持哪些命令、有哪些对象和属性。"
          "**要用 app_script 操作一个应用之前，先调它**——凭印象写 AppleScript "
          "十有八九会撞上「这个应用不认识这条命令」。字典很大时用 search 缩小范围。"
          "返回 scriptable=false 表示这个应用没有脚本接口，改走 menu_invoke 或 ui_action。",
          {"app": _p("应用名，如 Safari、备忘录、Mail"),
           "search": _p("只看名字或说明里含这个词的命令与类，如 tab、message")},
          "L0", "native", required=["app"]),

    _tool("app_script",
          "对本机应用执行一段 AppleScript 或 JavaScript(JXA)。这是驱动有脚本字典的"
          "应用的正规接口——新建备忘录、读日历、控制浏览器标签页、导出 Keynote 都走它。"
          "写之前先用 app_dictionary 确认命令名。脚本里要自己写 tell application \"X\"。"
          "不要用它做本可以用专用工具做的事（开应用用 app_open，控制播放用 media_control）。",
          {"script": _p("完整脚本源码"),
           "app": _p("脚本主要操作哪个应用（如 Notes、Safari）。**尽量填**——"
                     "填了才能在缺少自动化授权时立刻报错，不填就只能一直等到超时"),
           "language": {"type": "string", "enum": ["applescript", "javascript"],
                        "description": "默认 applescript；javascript 即 JXA"},
           "timeout": _p("超时秒数，默认 45，上限 45", _INT)},
          "L4", "native", required=["script"]),   # 等价于任意代码，撤法未知

    _tool("menu_list",
          "列出某个正在运行的应用的菜单。不传 menu 时返回顶层菜单名，"
          "传了则返回那个菜单里的所有菜单项——菜单项的名字就是这个应用的能力清单。"
          "没有脚本字典的应用优先走这条路。",
          {"app": _p("应用名"), "menu": _p("看某个菜单里的项，如 文件、编辑；不传则看顶层")},
          "L0", "native", required=["app"]),

    _tool("menu_invoke",
          "点击某个应用的菜单项，如 [\"文件\", \"新建标签页\"]。"
          "先用 menu_list 确认菜单项的准确名字（名字是本地化的，中文系统上就是中文）。",
          {"app": _p("应用名"),
           "path": {"type": "array", "items": _STR,
                    "description": "菜单路径，从顶层菜单名开始，如 [\"文件\", \"导出\", \"PDF\"]"},
           "activate": _p("先把应用切到前台（默认真）。后台应用的菜单常常点不动", _BOOL)},
          "L2", "native", required=["app", "path"],
          recover="多数菜单命令可以在目标应用里按 ⌘Z 撤销，但不保证"),

    _tool("ui_inspect",
          "读取某个应用当前窗口的界面元素树：按钮、输入框、文本和它们的位置路径。"
          "脚本字典和菜单都走不通时用它。返回的 path 只在界面没变时有效。",
          {"app": _p("应用名"),
           "depth": _p("往下看几层，默认 6，最多 12", _INT)},
          "L0", "native", required=["app"]),

    _tool("ui_action",
          "操作 ui_inspect 找到的某个界面元素：点击、聚焦或填值。"
          "path 必须来自刚刚那次 ui_inspect——界面变过就要重新 inspect，"
          "拿旧路径去点会点到别的东西上。",
          {"app": _p("应用名"),
           "path": _p("元素路径，来自 ui_inspect，如 0/3/1"),
           "action": {"type": "string", "enum": ["press", "focus", "set_value"],
                      "description": "press 点击，focus 聚焦，set_value 填入文本"},
           "value": _p("set_value 时要填的文本")},
          "L2", "native", required=["app", "path"],
          recover="界面操作没有通用撤法，多数应用里可以按 ⌘Z"),

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
          "L2", "python", fs_impl.fs_write, required=["path", "content"],
          recover="覆盖前会自动留一份 .jarvis.bak，改回来即可"),

    _tool("fs_move", "移动或重命名文件/文件夹。目标已存在时不覆盖，直接报错。",
          {"source": _p("源路径"), "destination": _p("目标路径")},
          "L2", "python", fs_impl.fs_move, required=["source", "destination"],
          recover="把文件从目标位置移回原路径即可"),

    # ------------------------------------------------ 联网（Brain 执行）
    _tool("web_search", "联网搜索。需要最新信息、不确定的事实、或用户明确要求查资料时使用。",
          {"query": _p("搜索关键词"),
           "count": _p("返回条数，默认 5，最多 10", _INT)},
          "L1", "python", web_impl.web_search, required=["query"]),

    _tool("web_fetch", "抓取一个网页并提取正文。通常在 web_search 之后，用于读某条结果的详情。",
          {"url": _p("网页地址"),
           "max_chars": _p("最多返回多少字符，默认 8000", _INT)},
          "L1", "python", web_impl.web_fetch, required=["url"]),

    # ------------------------------------------------ 长期记忆（Brain 执行）
    _tool("memory_save",
          "把一件应当长期记住的事写进记忆，跨会话、跨重启都还在。"
          "仅在用户明确介绍自己、明确说出偏好、交代持续项目或纠正旧认知时调用。"
          "用户只是询问、讨论或表现出对某个话题的兴趣，不构成可保存的长期记忆。"
          "同一件事再次被提到会就地更新，不会记成两条。",
          {"text": _p("要记住的一句话，用第三人称陈述，如「用户偏好简短的回答」"),
           "kind": {"type": "string",
                    "enum": ["self", "identity", "preference", "relationship", "project",
                             "commitment", "episode", "lesson", "fact"],
                    "description": "self Jarvis 对自己的认知；identity 用户是谁；preference 偏好习惯；"
                                   "project 手上在做的事；fact 其他事实。"
                                   "identity 与 preference 会在每一轮对话中常驻"},
           "tags": {"type": "array", "items": _STR,
                    "description": "便于日后检索的关键词，可选"},
           "subject": _p("稳定主题键，如 user:name、project:jarvis；同 kind+subject 会更新原条目"),
           "confidence": {"type": "number", "minimum": 0, "maximum": 1,
                          "description": "可信度，用户明确陈述填 1"},
           "status": {"type": "string", "enum": ["pending", "active", "completed", "cancelled"],
                      "description": "主要用于 commitment/project"},
           "remind_at": _p("仅用于定时承诺，ISO 8601 本地时间，如 2026-08-03T15:00:00+08:00")},
          "L1", "python", memory_impl.memory_save, required=["text"]),

    _tool("memory_recall",
          "按关键词检索长期记忆。相关记忆通常已自动附在上下文里，"
          "只有当你觉得可能还记过别的、但当前上下文没给出时才调用。",
          {"query": _p("检索关键词"),
           "limit": _p("最多返回几条，默认 8", _INT)},
          "L0", "python", memory_impl.memory_recall, required=["query"]),

    _tool("memory_list", "列出全部长期记忆。用户问「你都记得我什么」时用。",
          {"kind": {"type": "string",
                    "enum": ["self", "identity", "preference", "relationship", "project",
                             "commitment", "episode", "lesson", "fact"],
                    "description": "只看某一类，不填则全部"}},
          "L0", "python", memory_impl.memory_list),

    _tool("memory_forget", "删掉一条长期记忆。用户说记错了、或要求忘掉某件事时用。",
          {"id": _p("记忆 id，来自 memory_list / memory_recall"),
           "query": _p("没有 id 时，按关键词删掉最匹配的一条")},
          "L1", "python", memory_impl.memory_forget),

    _tool("memory_update", "按 id 修正记忆内容、可信度或完成状态。承诺完成、项目结束、"
          "用户纠正旧事实时使用，避免保留互相冲突的两条记录。",
          {"id": _p("记忆 id，来自 memory_list / memory_recall"),
           "text": _p("修正后的内容，可选"),
           "confidence": {"type": "number", "minimum": 0, "maximum": 1},
           "status": {"type": "string", "enum": ["pending", "active", "completed", "cancelled"]},
           "remind_at": _p("修改提醒时间；ISO 8601，空字符串表示取消定时提醒")},
          "L1", "python", memory_impl.memory_update, required=["id"]),

    _tool("task_history",
          "查看最近工具任务的真实执行步骤、结果与验证证据。用户要求继续、重试、"
          "检查刚才做到哪里时使用；已完成步骤不得盲目重复执行。",
          {"limit": _p("返回条数，默认 5", _INT),
           "recoverable_only": _p("只看失败或中断的任务", _BOOL)},
          "L0", "python", tasking_impl.task_history),

    # ------------------------------------------------ 委派给外部 agent（会话执行）
    # 放在平时那份工具表里而不是 agent_only：用户说「让 Claude Code 去修这个 bug」
    # 是从普通对话起手的，要求先 agent_enter 再委派会白花一轮。而且委派出去之后
    # Jarvis 这边只是盯进度，本来也用不上 Agent 模式那组编辑检索工具。
    _tool("agent_delegate",
          "把一整件事交给本机另一个 CLI 编码代理（Claude Code / Codex）去做完，"
          "它用自己的工具、自己的沙箱干活，只把结果报回来。"
          "**需要连续改一个代码仓库、跑通构建、把测试修到绿这类工程任务时优先用它**——"
          "它在这件事上比你强，也比你一步步 file_edit 快得多。"
          "prompt 要写成一个完整独立的任务书：它看不到你们之前的对话，"
          "也不能反过来问你，交代不清它就只能猜。"
          "读一两个文件、改一处配置这种小事别用它，直接自己做更快。"
          "任务可能跑几分钟，期间面板会显示它的进度。",
          {"agent": _p("派给谁：claude（默认，工程任务最稳）或 codex"),
           "description": _p("一句话说明这次委派要干什么，显示在面板上"),
           "prompt": _p("给外部代理的完整任务说明：做什么、在哪做、做到什么程度算完成、"
                        "要它回报哪些信息"),
           "cwd": _p("在哪个目录里干活，默认当前工作目录")},
          "L2", "session", None, required=["description", "prompt"],
          recover="外部代理的改动不由 Jarvis 备份；它自己会报告改了哪些文件，"
                  "在 git 仓库里可以 git checkout 回退"),

    _tool("mcp_status",
          "查看已接入的 MCP server 及它们提供的工具。用户问「你接了哪些外部服务」、"
          "「MCP 连上了吗」，或某个 mcp__ 开头的工具报错要排查时使用。",
          {}, "L0", "session", None),

    # ------------------------------------------------ 兜底
    _tool("shell_run", "执行一条 zsh 命令。仅在没有任何其他工具能完成时使用；默认被禁用。"
          "Agent 模式下可以用 run_in_background 起长跑进程（开发服务器、监听器），"
          "立刻返回 shell_id，之后用 shell_output 看输出。",
          {"command": _p("命令行"),
           "cwd": _p("工作目录，默认为当前工作目录"),
           "timeout": _p("超时秒数，默认 30", _INT),
           "run_in_background": _p("放到后台跑，不等它结束（仅 Agent 模式）", _BOOL)},
          "L4", "python", shell_impl.shell_run, required=["command"]),   # 撤法未知，故意留空

    # ------------------------------------------------ Agent 模式专用
    _tool("agent_enter",
          "切换到 Agent 模式：解锁精确编辑、内容检索、后台进程和待办清单，"
          "步数上限从 8 抬到几十步。用户要求的是一件需要连续动手做完的事"
          "（改代码、整理一批文件、跑通一个构建、排查一个问题）时，先调这个，"
          "然后在同一轮里直接把事做完。只是聊天或单个动作不要调。",
          {"goal": _p("一句话说明这次要完成什么，会显示在面板上")},
          "L1", "session", None, required=["goal"]),

    _tool("file_edit",
          "把文件里唯一一处 old_string 精确替换成 new_string。改已有文件一律用它，"
          "不要用 fs_write 整份重写——后者会丢掉你没读到的部分。"
          "old_string 必须逐字对上（含缩进），且在文件中唯一；不唯一就多带几行上下文。",
          {"path": _p("文件路径，可以是相对工作目录的路径"),
           "old_string": _p("要被替换掉的原文，必须唯一"),
           "new_string": _p("替换成的新内容"),
           "replace_all": _p("替换全部匹配处，用于改名这类批量操作", _BOOL)},
          "L2", "python", code_impl.file_edit,
          required=["path", "old_string", "new_string"],
          recover="改动前会留一份 .jarvis.bak，用 file_restore 一步还原",
          agent_only=True),

    _tool("file_restore", "把某个文件还原到上一次编辑之前（用 .jarvis.bak）。",
          {"path": _p("文件路径")},
          "L2", "python", code_impl.file_restore, required=["path"],
          recover="还原本身也可以再改回去", agent_only=True),

    _tool("grep",
          "按内容检索文件（有 ripgrep 就用 ripgrep）。找函数定义、找调用点、"
          "找报错信息出处都用它，比 shell_run 里手写 grep 快且安全。",
          {"pattern": _p("正则表达式"),
           "path": _p("检索目录或文件，默认当前工作目录"),
           "glob": _p("只搜匹配这个模式的文件，如 *.py"),
           "case_insensitive": _p("忽略大小写", _BOOL),
           "context": _p("每处匹配额外带几行上下文，最多 5", _INT),
           "mode": {"type": "string", "enum": ["content", "files", "count"],
                    "description": "content 返回匹配行（默认），files 只返回文件名，count 只计数"},
           "limit": _p("最多返回多少行，默认 80", _INT)},
          "L0", "python", code_impl.grep, required=["pattern"], agent_only=True),

    _tool("glob",
          "按文件名模式找文件，结果按修改时间从新到旧。如 **/*.py、build.sh。",
          {"pattern": _p("文件名模式"),
           "path": _p("搜索根目录，默认当前工作目录"),
           "limit": _p("最多返回多少个，默认 100", _INT)},
          "L0", "python", code_impl.glob_files, required=["pattern"], agent_only=True),

    _tool("shell_output",
          "读取某个后台进程自上次读取以来的新输出。",
          {"shell_id": _p("shell_run 后台启动时返回的 id"),
           "filter": _p("只保留匹配这个正则的行，可选"),
           "limit": _p("最多返回多少行，默认 200", _INT)},
          "L0", "python", shell_impl.shell_output, required=["shell_id"], agent_only=True),

    _tool("shell_kill", "结束一个后台进程。",
          {"shell_id": _p("后台进程 id")},
          "L1", "python", shell_impl.shell_kill, required=["shell_id"], agent_only=True),

    _tool("shell_list", "列出还在跑的后台进程。",
          {}, "L0", "python", shell_impl.shell_list, agent_only=True),

    _tool("subagent_run",
          "派一个子代理去查一件事，它用自己的上下文翻找，只把结论带回来。"
          "**当一件事需要翻很多文件、很多目录或很多网页才能确定时用它**——"
          "那些原始材料留在子代理那边，你这边只多一段结论，上下文不会被撑爆。"
          "prompt 要写成一个完整、独立的任务：子代理看不到你们之前的对话，"
          "也不能反过来问你，交代不清它就只能猜。"
          "只是读一两个已知路径的文件不要用它——直接 fs_read 更快。",
          {"description": _p("一句话说明它在查什么，显示在面板上，如「找配置读取的位置」"),
           "prompt": _p("给子代理的完整任务说明：要查什么、在哪查、要它回答哪几个问题"),
           "scope": {"type": "string", "enum": ["explore", "full"],
                     "description": "explore 只给只读工具（默认，绝大多数情况用这个）；"
                                    "full 给完整工具集，会改东西，只在确实要它动手时用"},
           "max_steps": _p("最多几步工具调用，默认 12，上限 25", _INT)},
          "L1", "session", None, required=["description", "prompt"], agent_only=True),

    _tool("todo_write",
          "写入或更新本次任务的待办清单，用户会在面板上实时看到。"
          "任务超过三步就先列出来，之后每完成一项立刻更新状态；"
          "同一时刻只能有一条 in_progress。",
          {"todos": {"type": "array",
                     "description": "完整的待办列表，每次都传全量（不是增量）",
                     "items": {"type": "object",
                               "properties": {
                                   "content": _p("待办内容，祈使句，如「修复登录超时」"),
                                   "active_form": _p("进行时说法，如「正在修复登录超时」"),
                                   "status": {"type": "string",
                                              "enum": ["pending", "in_progress", "completed"]}},
                               "required": ["content", "status"]}}},
          "L0", "python", todo_impl.todo_write, required=["todos"], agent_only=True),
]

BY_NAME = {tool["name"]: tool for tool in TOOLS}

# ---------------------------------------------------------------- 动态工具
#
# MCP server 的工具在编译期不存在，只能等连上之后才知道有哪些，所以注册表分成
# 静态的 TOOLS 和运行时灌进来的这一份。**整表替换而不是增量增删**：server 掉线、
# 重连、发 tools/list_changed 都会让工具表整个变一遍，增量维护迟早对不上，
# 而整表替换只有一个真相来源（MCPHub 当前的状态）。
_DYNAMIC = []
_DYNAMIC_BY_NAME = {}


def set_dynamic(tools):
    global _DYNAMIC, _DYNAMIC_BY_NAME
    _DYNAMIC = list(tools or [])
    _DYNAMIC_BY_NAME = {tool["name"]: tool for tool in _DYNAMIC}


def all_tools():
    return TOOLS + _DYNAMIC


def lookup(name):
    """按名字找工具。**所有查表都必须走它**，直接用 BY_NAME 会漏掉 MCP 那批。"""
    return BY_NAME.get(name) or _DYNAMIC_BY_NAME.get(name)


def is_mcp(name):
    return name in _DYNAMIC_BY_NAME


def needs_confirmation(tool):
    return _ORDER.get(tool["risk"], 9) >= _ORDER[CONFIRM_FROM]


def openai_schema(tools=None, agent_mode=False):
    """转成 DeepSeek（OpenAI 兼容）要的 tools 数组。

    非 Agent 模式下把 agent_only 那批藏起来，只留 agent_enter 当入口——
    普通对话里发现"这活得连续动手做"时，模型靠它把自己切进 Agent 模式。
    进去之后 agent_enter 反过来要藏掉，否则模型会在已经进来的情况下再调一次。
    """
    if tools is None:
        selected = []
        for tool in all_tools():
            if tool["name"] == "agent_enter":
                if not agent_mode:
                    selected.append(tool)
            elif agent_mode or not tool["agent_only"]:
                selected.append(tool)
        tools = selected
    return [{
        "type": "function",
        "function": {
            "name": tool["name"],
            "description": tool["description"],
            "parameters": tool["schema"],
        },
    } for tool in tools]


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
        "media_control": "播放控制：{action}",
        "calendar_events": "查看近期日历",
        "mail_unread": "查看未读邮件摘要",
        "wechat_read": "读取微信结构化消息并分析",
        "app_scriptable": "查看哪些应用可脚本化",
        "app_dictionary": "查看「{app}」的脚本字典",
        "app_script": "对本机应用执行脚本",
        "menu_list": "查看「{app}」的菜单",
        "menu_invoke": "点击「{app}」的菜单项",
        "ui_inspect": "读取「{app}」的界面元素",
        "ui_action": "操作「{app}」的界面元素",
        "fs_list": "列出 {path} 的内容",
        "fs_read": "读取 {path}",
        "fs_search": "搜索文件「{query}」",
        "fs_write": "写入文件 {path}",
        "fs_move": "把 {source} 移动到 {destination}",
        "web_search": "联网搜索「{query}」",
        "web_fetch": "抓取网页 {url}",
        "memory_save": "记住：{text}",
        "memory_recall": "回忆「{query}」",
        "memory_list": "翻看长期记忆",
        "memory_forget": "忘掉一条记忆",
        "memory_update": "更新一条记忆",
        "task_history": "检查最近任务记录",
        "shell_run": "执行命令：{command}",
        "agent_enter": "进入 Agent 模式：{goal}",
        "file_edit": "编辑 {path}",
        "file_restore": "还原 {path}",
        "grep": "检索「{pattern}」",
        "glob": "查找文件 {pattern}",
        "shell_output": "读取后台输出 {shell_id}",
        "shell_kill": "结束后台进程 {shell_id}",
        "shell_list": "查看后台进程",
        "todo_write": "更新待办清单",
        "subagent_run": "派子代理：{description}",
        "agent_delegate": "委派给外部代理：{description}",
        "mcp_status": "查看 MCP 接入状态",
    }
    template = templates.get(name)
    if not template:
        info = _mcp_info(name)
        if info:
            return "调用 %s 的 %s" % (info["server"], info["tool"])
        return name
    return template.format_map(_Blank(arguments))


def _mcp_info(name):
    tool = _DYNAMIC_BY_NAME.get(name)
    return (tool or {}).get("mcp")


class _Blank(dict):
    """模型漏传参数时不该炸掉描述，占位就行。"""
    def __missing__(self, key):
        return "?"


# 确认框要的「操作 / 目标」两栏。文档 §11.2 明确禁止"是否允许执行操作？"这种含糊问法，
# 必须让人看清动的是哪个对象——所以动作和目标分开给，UI 才好各自排版。
_ACTIONS = {
    "app_open": "打开应用", "app_quit": "退出应用", "app_list_running": "查看运行中的应用",
    "url_open": "打开网页", "finder_reveal": "在访达中显示",
    "clipboard_read": "读取剪贴板", "clipboard_write": "写入剪贴板",
    "system_notify": "发送通知", "system_info": "查看本机状态", "media_control": "播放控制",
    "calendar_events": "查看近期日历",
    "mail_unread": "查看未读邮件摘要",
    "wechat_read": "读取微信消息",
    "app_scriptable": "查看可脚本化的应用", "app_dictionary": "查看脚本字典",
    "app_script": "执行应用脚本", "menu_list": "查看菜单", "menu_invoke": "点击菜单项",
    "ui_inspect": "读取界面元素", "ui_action": "操作界面元素",
    "fs_list": "列出目录", "fs_read": "读取文件", "fs_search": "搜索文件",
    "fs_write": "写入文件", "fs_move": "移动文件",
    "web_search": "联网搜索", "web_fetch": "抓取网页",
    "memory_save": "记住一件事", "memory_recall": "回忆", "memory_list": "翻看记忆",
    "memory_forget": "忘掉一条记忆", "memory_update": "更新记忆",
    "task_history": "检查任务记录",
    "shell_run": "执行命令",
    "agent_enter": "进入 Agent 模式", "file_edit": "编辑文件", "file_restore": "还原文件",
    "grep": "检索内容", "glob": "查找文件", "shell_output": "读取后台输出",
    "shell_kill": "结束后台进程", "shell_list": "查看后台进程", "todo_write": "更新待办",
    "subagent_run": "派出子代理",
    "agent_delegate": "委派给外部代理", "mcp_status": "查看 MCP 接入状态",
}
_TARGET_KEYS = ("path", "source", "command", "script", "name", "url", "text", "query", "id",
                "contact", "pattern", "shell_id", "goal", "app", "description")


def action_of(name):
    if name in _ACTIONS:
        return _ACTIONS[name]
    info = _mcp_info(name)
    # 确认框上必须写清楚这是**外部服务**在动手，不是本机操作——
    # 只写工具名的话，用户没法判断这一下会不会把东西发到公司群里去。
    return "调用外部服务 %s" % info["server"] if info else name


def target_of(name, arguments):
    """挑出最能代表"动的是什么"的那个参数。移动类要把去向也写上。"""
    arguments = arguments or {}
    if name == "fs_move":
        return "%s  →  %s" % (arguments.get("source", "?"), arguments.get("destination", "?"))
    info = _mcp_info(name)
    if info:
        # MCP 工具的参数名完全由对方定义，猜不到哪个是"主语"。
        # 与其猜错，不如把工具名和实参一起摆出来让用户自己看。
        head = info["tool"]
        if arguments:
            body = ", ".join("%s=%s" % (key, str(value)[:60])
                             for key, value in list(arguments.items())[:4])
            return "%s（%s）" % (head, body)
        return head
    for key in _TARGET_KEYS:
        value = arguments.get(key)
        if value:
            return str(value)
    return ""


# 哪些工具的结果值得让 UI 画成可交互卡片，以及从结果里取哪个列表。
# 只放确定是"文件路径列表"的：UI 会给每一项加"在访达中显示 / 打开"，
# 拿别的东西当路径会点出一堆失败。
_FILE_LIST_TOOLS = {"fs_search": "results", "fs_list": "entries", "glob": "files"}


def ui_payload(name, arguments, result):
    """把工具结果整理成 UI 能直接渲染的形状。认不出来就返回 None，UI 退回纯文字摘要。"""
    if not isinstance(result, dict) or result.get("error"):
        return None

    if name == "file_edit":
        # diff 卡片。带上 path 是为了卡片上那个「撤销」按钮知道还原谁。
        return {"kind": "diff", "path": result.get("path"),
                "diff": result.get("diff") or "",
                "added": result.get("added_lines") or 0,
                "removed": result.get("removed_lines") or 0,
                "truncated": bool(result.get("diff_truncated")),
                "undoable": bool(result.get("backup"))}
    if name == "grep":
        return {"kind": "matches", "pattern": result.get("pattern"),
                "engine": result.get("engine"),
                "lines": result.get("matches") or [],
                "total": result.get("count") or 0}
    if name == "shell_run" and not result.get("background"):
        return {"kind": "shell", "command": result.get("command"),
                "exit_code": result.get("exit_code"),
                "output": (result.get("output") or "")[-4000:]}

    key = _FILE_LIST_TOOLS.get(name)
    if not key:
        return None

    raw = result.get(key) or []
    base = result.get("path") or ""
    items = []
    for entry in raw[:30]:
        if isinstance(entry, str):                       # fs_search：一串路径
            items.append({"name": entry.rsplit("/", 1)[-1], "path": entry, "kind": "file"})
        elif isinstance(entry, dict):                    # fs_list：带类型和大小
            name_ = entry.get("name") or ""
            items.append({
                "name": name_,
                "path": ("%s/%s" % (base.rstrip("/"), name_)) if base else name_,
                "kind": entry.get("type") or "file",
                "size": entry.get("size"),
            })
    if not items:
        return None
    return {"kind": "files", "items": items, "total": result.get("count") or len(items)}
