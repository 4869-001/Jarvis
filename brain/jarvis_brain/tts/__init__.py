"""语音合成入口。

两个后端，一条共用的金属后处理链：
    system —— `say`，零依赖，默认
    neural —— 定稿音色 zm_029 / jarvis-high，需要 voices/.venv

neural 出任何问题都自动退回 system。播报可以难听，但不能哑。
"""
import os
import re
import time
import uuid

from . import metallic, neural, system

CACHE_DIR = os.path.expanduser("~/.jarvis/tts")
_CJK = re.compile(r"[一-鿿㐀-䶿]")

# 句尾标点。按句合成才能边说边生成，不必等整段回复写完。
# 英文句号那条是必需的：只认 。！？ 的话，整段英文回复会被当成一句，
# 逐句播报就退化成"等全部写完再开口"。
# 要求句号前是小写字母或数字，是为了不切开 J.A.R.V.I.S. 这类缩写。
SENTENCE_END = re.compile(r"(?<=[。！？；;\n])|(?<=[a-z0-9][.!?])(?=\s)")


def detect_language(text, cfg=None):
    """配置里指定了语言就用指定的。

    现在 Jarvis 一律讲英文，而回复里可能夹着中文专有名词，
    靠自动检测会把整句切到中文音色上去。
    """
    forced = (cfg or {}).get("language")
    detected = "zh" if _CJK.search(text) else "en"
    if forced not in ("zh", "en"):
        return detected
    # 兜底：强制英文但内容其实是中文（模型偶尔会不守"英文在前"的格式），
    # 硬塞给 Piper 只会念出一串乱码。这时按内容走，宁可语言不对也别听着是坏的。
    if forced == "en" and _mostly_cjk(text):
        return "zh"
    return forced


def _mostly_cjk(text):
    letters = [ch for ch in text if ch.isalpha() or _CJK.match(ch)]
    if not letters:
        return False
    return sum(1 for ch in letters if _CJK.match(ch)) / len(letters) > 0.5


def split_sentences(text, min_length=6):
    """切句。太短的碎片并到下一句，免得"好的。"单独合成一次、听着一顿一顿。

    **返回的片段不做 strip。** 调用方会把最后一段当作残留缓冲、直接拼接下一批增量，
    一旦这里把尾部空格去掉，就会拼出 "Thefiles" 这种粘连词。空格在念的时候才去。
    """
    pieces, buffer = [], ""
    for chunk in SENTENCE_END.split(text):
        buffer += chunk
        if len(buffer.strip()) >= min_length:
            pieces.append(buffer)
            buffer = ""
    if buffer:
        pieces.append(buffer)
    return [piece for piece in pieces if piece.strip()]


def clean_for_speech(text):
    """去掉念出来很怪的东西：Markdown 记号、链接、代码块、纯符号行。"""
    text = re.sub(r"```.*?```", ", code omitted, ", text, flags=re.S)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)      # [文字](链接)
    text = re.sub(r"https?://\S+", ", link on screen, ", text)
    # 粗斜体必须先于列表记号处理：**粗体** 行首那两个星号会被 [#>\-*+]+ 当成列表符号吃掉
    text = re.sub(r"\*{1,3}([^*\n]+)\*{1,3}", r"\1", text)
    text = re.sub(r"^\s*[#>\-*+]+\s*", "", text, flags=re.M)    # 标题/列表/引用记号
    text = re.sub(r"[|_~]+", " ", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text.strip()


def _cache_path(suffix):
    os.makedirs(CACHE_DIR, exist_ok=True)
    return os.path.join(CACHE_DIR, "%s%s" % (uuid.uuid4().hex[:12], suffix))


def prune_cache(keep_seconds=600):
    """清掉十分钟前的 wav。宿主播完不负责删，统一删在这里，免得两边抢同一个文件。"""
    try:
        now = time.time()
        for name in os.listdir(CACHE_DIR):
            path = os.path.join(CACHE_DIR, name)
            if now - os.path.getmtime(path) > keep_seconds:
                os.unlink(path)
    except Exception:
        pass


def synthesize(text, cfg):
    """返回 (wav 路径, 实际用的后端说明)。文本清干净后为空则返回 (None, None)。"""
    text = clean_for_speech(text)
    if not text:
        return None, None

    lang = detect_language(text, cfg)
    backend = cfg.get("backend", "system")
    raw_path = _cache_path(".raw.wav")
    used = backend

    try:
        if backend == "neural":
            neural.synthesize(text, raw_path, lang, cfg.get("neural") or {})
        else:
            system.synthesize(text, raw_path, lang, cfg.get("system") or {})
    except neural.NotInstalled as exc:
        system.synthesize(text, raw_path, lang, cfg.get("system") or {})
        used = "system（定稿音色未安装：%s）" % str(exc)[:60]
    except Exception as exc:
        if backend != "neural":
            raise
        system.synthesize(text, raw_path, lang, cfg.get("system") or {})
        used = "system（neural 失败：%s）" % str(exc)[:80]

    if not cfg.get("metallic", True):
        return raw_path, used

    final = metallic.apply(raw_path, _cache_path(".wav"))
    if final != raw_path:
        try:
            os.unlink(raw_path)
        except Exception:
            pass
    return final, used
