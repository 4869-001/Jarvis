"""配置读取。

优先级：环境变量 > ~/.jarvis/config.json > 内置默认值。
API Key 额外支持从 Keychain 读（`security find-generic-password -s jarvis-deepseek -w`），
这样 config.json 里可以不落明文。
"""
import copy
import json
import os
import subprocess

JARVIS_DIR = os.path.expanduser("~/.jarvis")
CONFIG_PATH = os.path.join(JARVIS_DIR, "config.json")
SOCKET_PATH = os.path.join(JARVIS_DIR, "brain.sock")
STATE_PATH = os.path.join(JARVIS_DIR, "state")
LOG_PATH = os.path.join(JARVIS_DIR, "brain.log")

KEYCHAIN_SERVICE = "jarvis-deepseek"

DEFAULTS = {
    "provider": "deepseek",
    "deepseek": {
        "api_key": "",
        "base_url": "https://api.deepseek.com",
        "model": "deepseek-chat",
        "temperature": 0.7,
        "max_tokens": 4096,
        # 长对话里模型偶尔会卡进复读循环（同一句话反复吐），frequency_penalty
        # 按 token 已出现次数罚分，是压这个毛病最直接的旋钮。0.4 是"明显抑制
        # 复读、但不影响正常措辞多样性"的经验值，别调到 1 以上——遣词会变得生硬。
        "frequency_penalty": 0.4,
    },
    "search": {
        # auto = 有 key 用 tavily/brave，没有就退 duckduckgo
        "backend": "auto",
        "tavily_api_key": "",
        "brave_api_key": "",
        "max_results": 5,
    },
    "tools": {
        # 文件工具的活动范围。越界一律拒绝，不给模型越权的机会。
        "fs_roots": ["~"],
        # shell_run 默认关闭。要开自己改这里，且每次仍需确认。
        "allow_shell": False,
        # True 时不再拦 rm -rf / sudo / 关机这类命令，只剩确认弹窗这一道闸。
        # 想要"和终端里一样"的权限就开它——代价是模型一次判断失误就可能不可逆。
        "shell_unrestricted": False,
        # 免确认的工具名单。写进来的工具不再弹确认框，直接执行。
        # 例：["fs_write", "shell_run"]。空表示所有 L2 及以上都要点确认。
        "auto_approve": [],
        "max_output_chars": 12000,
    },
    "environment_awareness": {
        # 每轮把前台应用、电源、内存、磁盘和屏幕布局作为只读上下文交给模型。
        # 全部在本机采集；设为 false 可完全停止采集与注入。
        "enabled": True,
        "timeout": 2.0,
    },
    "tts": {
        "enabled": True,
        # neural = Piper jarvis-high（短中文词转拼音），需要 voices/.venv；
        # system = 系统 `say`，零依赖。neural 出任何问题都自动回退 system，不会哑。
        "backend": "neural",
        # Jarvis 一律讲英文，所以固定英文音色（Piper jarvis-high）。
        # 设成 null 则按文本内容自动判断。
        "language": "en",
        "metallic": True,           # 金属滤镜链。关掉就是普通朗读，不像 Jarvis
        # 超过这么多字符的整句，先在从句处切开再逐段合成。
        # 定稿音色在 M2 Air 上 RTF ≈ 1.2——合成一句话的时间和念完它一样长，
        # 所以长句是"开口前那段沉默"的主要来源。切开之后第一段能早得多地出声，
        # 代价是分段处语调略平。0 = 不切（整句合成，语调最自然但首音最慢）。
        "max_chars_per_chunk": 80,
        "system": {"zh_voice": "Li-mu", "en_voice": "Daniel", "rate": 180},
        "neural": {"zh_speed": 1.0, "en_length_scale": 1.0},
    },
    "wake_word": {
        # 常听「贾维斯 / Jarvis」。词表在 models/kws-jarvis.txt，加词只改那个文件。
        # score 提升分越高越容易命中，threshold 越低越容易命中——都要按实测调。
        "enabled": True,
        "score": 1.5,
        "threshold": 0.25,
        # 播报期间仍监听唤醒词；用户说 Jarvis/贾维斯即可停播并接管对话。
        # AudioHub 的 Voice Processing 会先做回声消除，降低自触发概率。
        "barge_in": True,
    },
    "voice_input": {
        "enabled": True,
        "locale": "zh-CN",          # SFSpeechRecognizer 的语言。本机中英都支持离线
        # 离线识别快、不联网，但准确率略低于服务端。识别老是差一点就把它设成 false
        # ——代价是要联网，且每句多 200~400ms。
        "prefer_on_device": True,
        # 说过话之后，静音多久算说完。靠自适应噪声门判定，所以可以比固定阈值时短。
        "silence_timeout": 0.9,
        # 收句后再等多久拿识别器的终版结果（终版比最后一版 partial 准，且带标点）。
        # 等不到就用 partial，不会卡住。
        "final_wait": 0.6,
        # 开麦后一直没识别出任何文字就自动关麦，省电省内存。用户要求 30s。
        "idle_timeout": 30.0,
        # 单句上限。到点强制收句，防止一直有背景人声时永远关不掉。
        "max_seconds": 60.0,
        "punctuation": True,        # 让识别器自己加标点，字幕更好读
        # 喂给识别器的专有名词，显著提高这些词的召回。应用名会自动补进来。
        "contextual_strings": [],
    },
    "memory": {
        # 长期记忆：跨会话、跨重启。存在 ~/.jarvis/memory.json，可以直接看、直接改。
        "enabled": True,
        # 每轮按当前这句话检索回来的条数上限（identity/preference 类另外常驻）
        "max_recall": 8,
    },
    "proactive": {
        "enabled": True,
        "check_interval": 30,
        "quiet_start": "22:30",
        "quiet_end": "08:00",
        "cooldown_minutes": 120,
        "daily_limit": 6,
    },
    "session": {
        # 一轮对话里最多连续调多少次工具，防止模型自己转圈
        "max_tool_rounds": 8,
        "history_limit": 40,
    },
    "mcp": {
        # 接第三方 MCP server，把它们的工具当成 Jarvis 自己的工具用。
        # servers 的形状和 Claude Code 的 mcpServers 一致，可以直接抄过来：
        #   "servers": {
        #     "filesystem": {
        #       "command": "npx",
        #       "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Projects"],
        #       "agent_only": false        // true = 只在 Agent 模式露出，别把平时的工具表撑大
        #     }
        #   }
        "enabled": True,
        "servers": {},
        # ⚠️ Brain 由 launchd 拉起，PATH 里没有 npx/uvx（本机实测它们在
        # /usr/local/bin 和 ~/.local/bin）。mcp.py 内置了一张常见目录表，
        # 装在别处时把目录写这里。外部 agent 共用这张表。
        "extra_path": [],
        # npx 第一次跑要下载包，给宽一点；连接是后台做的，不阻塞 Jarvis 启动。
        "startup_timeout": 60,
        "call_timeout": 60,
    },
    "external_agents": {
        # 把整件事委派给本机另一个 CLI agent。权限档位跟随 Jarvis 当前档位，
        # 不在这里单独配——两套权限各配一份早晚会错位。
        "enabled": True,
        "agents": {
            "claude": {"enabled": True},
            # codex 默认关着：两个都开的话模型每次都要先纠结派给谁，
            # 而绝大多数情况下派给哪个都行。要用就把它打开。
            "codex": {"enabled": False},
        },
    },
    "agent": {
        # Agent 模式：长程任务循环（面板 ⌥A 开关，这里是重启后的默认值）。
        # 开启后工具集扩展出编辑/检索/进程那一组，步数上限抬高，中间步骤不播报。
        "enabled": False,
        # 工作目录。模型给的相对路径按它解析，项目上下文文件也从这里读。
        "workspace": "~",
        # ask         每个 L2+ 操作都确认（最保守）
        # accept_edits 文件编辑与只读命令免确认，shell 写操作和退出应用仍确认
        # bypass      全免确认。等于把终端交给模型，顶栏会亮红标识
        "permission_mode": "accept_edits",
        # 一轮任务最多几步工具调用。到顶不报错，而是让模型收尾并交回控制权。
        "max_steps": 60,
        # history 超过这么多条就把最早的一批压成摘要。长任务撞不到上下文上限，
        # 代价是早期细节只剩摘要——所以压缩产物里明确保留"已改过哪些文件"。
        "compact_after": 30,
        # 工作目录下这几个文件会作为项目上下文注入（取第一个存在的）
        "context_files": ["JARVIS.md", "CLAUDE.md", "AGENTS.md"],
        # 单个命令实时回显给面板的最大行数，以及后台进程保留的输出行数
        "stream_lines": 200,
        "buffer_lines": 2000,
    },
}


def _deep_merge(base, override):
    out = copy.deepcopy(base)
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def _keychain_api_key():
    """返回 (key, 说明)。说明用于日志——Key 找不到时最费时间的就是猜它去哪了。"""
    try:
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as exc:
        return "", "Keychain 读取异常：%s" % exc
    if result.returncode != 0:
        return "", "Keychain 无此条目或不可读（rc=%d %s）" % (
            result.returncode, (result.stderr or "").strip()[:120])
    return result.stdout.strip(), "Keychain"


def load():
    raw = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
        except Exception as exc:  # 配置坏了不该让整个 Brain 起不来
            raw = {"_config_error": str(exc)}

    cfg = _deep_merge(DEFAULTS, raw)

    key = (os.environ.get("DEEPSEEK_API_KEY") or "").strip()
    source = "环境变量 DEEPSEEK_API_KEY"
    if not key:
        key = (cfg["deepseek"].get("api_key") or "").strip()
        source = "config.json"
    if not key:
        key, source = _keychain_api_key()
    cfg["deepseek"]["api_key"] = key
    cfg["_key_source"] = source if key else ("未找到 Key（%s）" % source)

    base = os.environ.get("DEEPSEEK_BASE_URL")
    if base:
        cfg["deepseek"]["base_url"] = base
    model = os.environ.get("DEEPSEEK_MODEL")
    if model:
        cfg["deepseek"]["model"] = model

    cfg["tools"]["fs_roots"] = [
        os.path.realpath(os.path.expanduser(p)) for p in cfg["tools"]["fs_roots"]
    ]
    workspace = os.path.realpath(os.path.expanduser(cfg["agent"].get("workspace") or "~"))
    if not os.path.isdir(workspace):
        workspace = os.path.expanduser("~")
    cfg["agent"]["workspace"] = workspace
    return cfg


def write_template():
    """首次运行时落一份带注释位的模板，方便用户填 key。已存在则不动。"""
    os.makedirs(JARVIS_DIR, exist_ok=True)
    if os.path.exists(CONFIG_PATH):
        return False
    template = copy.deepcopy(DEFAULTS)
    with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
        json.dump(template, fh, ensure_ascii=False, indent=2)
    os.chmod(CONFIG_PATH, 0o600)
    return True


def save_section(section, values):
    """把 config.json 里某个顶层字段的几个键改掉，其余字段（含用户手改的部分）原样保留。

    只用来落用户在前端点出来的设置（如唤醒方式），不走这里的字段不受影响。
    """
    raw = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
        except Exception:
            raw = {}
    current = raw.get(section)
    if not isinstance(current, dict):
        current = {}
    current.update(values)
    raw[section] = current
    os.makedirs(JARVIS_DIR, exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(raw, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG_PATH)
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except OSError:
        pass
