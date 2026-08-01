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
        # shell.run 默认关闭。要开自己改这里，且每次仍需确认。
        "allow_shell": False,
        "max_output_chars": 12000,
    },
    "tts": {
        "enabled": True,
        # neural = 定稿音色（中文 zm_029 / 英文 jarvis-high），需要 voices/.venv；
        # system = 系统 `say`，零依赖。neural 出任何问题都自动回退 system，不会哑。
        "backend": "neural",
        # Jarvis 一律讲英文，所以固定英文音色（Piper jarvis-high）。
        # 设成 null 则按文本内容自动判断。
        "language": "en",
        "metallic": True,           # 金属滤镜链。关掉就是普通朗读，不像 Jarvis
        "system": {"zh_voice": "Li-mu", "en_voice": "Daniel", "rate": 180},
        "neural": {"zh_speed": 1.0, "en_length_scale": 1.0},
    },
    "wake_word": {
        # 常听「贾维斯 / Jarvis」。词表在 models/kws-jarvis.txt，加词只改那个文件。
        # score 提升分越高越容易命中，threshold 越低越容易命中——都要按实测调。
        "enabled": True,
        "score": 1.5,
        "threshold": 0.25,
    },
    "voice_input": {
        "enabled": True,
        "locale": "zh-CN",          # SFSpeechRecognizer 的语言。本机中英都支持离线
        "prefer_on_device": True,
        "silence_timeout": 1.6,     # 静音多久自动结束一句
        "max_seconds": 30.0,
    },
    "session": {
        # 一轮对话里最多连续调多少次工具，防止模型自己转圈
        "max_tool_rounds": 8,
        "history_limit": 40,
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
