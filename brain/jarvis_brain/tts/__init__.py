"""语音合成入口。

两个后端，一条共用的金属后处理链：
    system —— `say`，零依赖，默认
    neural —— 定稿音色 zm_029 / jarvis-high，需要 voices/.venv

neural 出任何问题都自动退回 system。播报可以难听，但不能哑。
"""
import hashlib
import json
import os
import re
import time
import uuid

from . import metallic, neural, system

CACHE_DIR = os.path.expanduser("~/.jarvis/tts")
# 按内容寻址的缓存，和上面那个"用完即弃"的临时目录分开：
# 临时文件 10 分钟就清，这里的要留着复用，清的规则完全不同。
PHRASE_DIR = os.path.join(CACHE_DIR, "phrases")
PHRASE_KEEP = 300                      # 最多留多少条，按最近使用淘汰
# 超过这个长度就不进缓存了：长句几乎不会一字不差地重复，白占磁盘
PHRASE_MAX_CHARS = 120

_CJK = re.compile(r"[一-鿿㐀-䶿]")

# 句尾标点。按句合成才能边说边生成，不必等整段回复写完。
# 英文句号那条是必需的：只认 。！？ 的话，整段英文回复会被当成一句，
# 逐句播报就退化成"等全部写完再开口"。
# 要求句号前是小写字母或数字，是为了不切开 J.A.R.V.I.S. 这类缩写。
SENTENCE_END = re.compile(r"(?<=[。！？；;\n])|(?<=[a-z0-9][.!?])(?=\s)")


def detect_language(text, cfg=None):
    """返回 (语言, 是否越过了配置强制的语言)。

    第二个值就是"这句其实是格式违规"的信号：Jarvis 固定讲英文，
    但模型偶尔不守"英文在前 + {marker} + 中文字幕"的格式、整句吐中文。
    调用方（tts.synthesize）现在看到 True 就直接跳过合成，不再退到中文音色——
    "播报必须是英文"是绝对规则，不接受"用对的音色说错的语言"这种妥协。
    """
    forced = (cfg or {}).get("language")
    detected = "zh" if _CJK.search(text) else "en"
    if forced not in ("zh", "en"):
        return detected, False
    if forced == "en" and mostly_cjk(text):
        return "zh", True
    return forced, False


def mostly_cjk(text):
    letters = [ch for ch in text if ch.isalpha() or _CJK.match(ch)]
    if not letters:
        return False
    return sum(1 for ch in letters if _CJK.match(ch)) / len(letters) > 0.5


# 从句边界。只在整句太长时才用它继续切——见 split_sentences 的说明。
CLAUSE_END = re.compile(r"(?<=[，、；：,;:])(?=\s*\S)")


def split_sentences(text, min_length=6, max_chars=None):
    """切句。太短的碎片并到下一句，免得"好的。"单独合成一次、听着一顿一顿。

    `max_chars` 给了的话，超长的整句会继续在**从句边界**切开。这不是为了好听——
    恰恰相反，分开合成的语调会比整句略平。是为了首句能早点出声：
    定稿音色在这台机器上 RTF ≈ 1.2（合成一句话的时间和念完它一样长），
    一句 5 秒的话要等 6 秒才响第一个音；从中间断开之后第一段两秒就能开口。
    只对超长句生效，短句仍然整句合成，语调不受影响。

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

    if max_chars:
        pieces = [part for piece in pieces
                  for part in _split_long(piece, min_length, max_chars)]
    return [piece for piece in pieces if piece.strip()]


def _split_long(piece, min_length, max_chars):
    if len(piece.strip()) <= max_chars:
        return [piece]
    out, buffer = [], ""
    for chunk in CLAUSE_END.split(piece):
        buffer += chunk
        # 攒够 min_length 才断，免得切出 "好，" 这种一个词的碎片
        if len(buffer.strip()) >= min_length and len(buffer.strip()) >= max_chars // 2:
            out.append(buffer)
            buffer = ""
    if buffer:
        out.append(buffer)
    return out or [piece]


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


def clean_for_english_speech(text):
    """挡住 Piper 不支持的汉字，免得逐字念成 "Chinese letter"。"""
    text = re.sub(r'["“「『]\s*[一-鿿㐀-䶿]+\s*["”」』]',
                  "the quoted Chinese phrase", text)
    text = re.sub(r"[一-鿿㐀-䶿]+", "the Chinese phrase", text)
    return re.sub(r"[ \t]{2,}", " ", text).strip()


def _cache_path(suffix):
    os.makedirs(CACHE_DIR, exist_ok=True)
    return os.path.join(CACHE_DIR, "%s%s" % (uuid.uuid4().hex[:12], suffix))


def prune_cache(keep_seconds=600):
    """清掉十分钟前的临时 wav。宿主播完不负责删，统一删在这里，免得两边抢同一个文件。

    跳过子目录——phrases/ 是内容寻址的长期缓存，归 prune_phrases 管，
    按这里的 10 分钟规则清会让缓存等于不存在。
    """
    now = time.time()
    try:
        names = os.listdir(CACHE_DIR)
    except OSError:
        return
    for name in names:
        path = os.path.join(CACHE_DIR, name)
        try:
            if os.path.isdir(path):
                continue
            if now - os.path.getmtime(path) > keep_seconds:
                os.unlink(path)
        except OSError:
            continue


def _phrase_key(text, lang, cfg):
    """同样的文本、同样的合成参数 → 同一个 key。参数变了必须变 key，
    否则改了语速/关掉金属链之后还会拿到旧声音。"""
    payload = json.dumps([text, lang, cfg.get("backend"), bool(cfg.get("metallic", True)),
                          cfg.get("neural") or {}, cfg.get("system") or {}],
                         ensure_ascii=False, sort_keys=True)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:20]


def _phrase_hit(key):
    path = os.path.join(PHRASE_DIR, key + ".wav")
    if not os.path.exists(path):
        return None
    try:
        os.utime(path, None)         # 记一次使用，淘汰时按 mtime 排
    except OSError:
        pass
    return path


def prune_phrases(keep=PHRASE_KEEP):
    try:
        entries = [(os.path.getmtime(os.path.join(PHRASE_DIR, n)), n)
                   for n in os.listdir(PHRASE_DIR)]
    except OSError:
        return
    if len(entries) <= keep:
        return
    entries.sort(reverse=True)
    for _, name in entries[keep:]:
        try:
            os.unlink(os.path.join(PHRASE_DIR, name))
        except OSError:
            pass


def synthesize(text, cfg):
    """返回 (wav 路径, 实际用的后端说明)。文本清干净后为空则返回 (None, None)。"""
    text = clean_for_speech(text)
    if not text:
        return None, None

    lang, off_language = detect_language(text, cfg)

    # 2026-08-02 用户把"播报必须是英文"收紧成绝对规则：宁可这句没声音，
    # 也不能把中文念出来——哪怕音色是对的。以前这里退到系统中文音色把它
    # 念完，现在直接跳过合成。文本已经通过字幕正常显示了，用户不会"看不到"，
    # 只是这一句没有语音；比"中英文混杂播报"符合要求得多。
    if off_language:
        return None, None

    # system 后端没有混合音色拼接能力，至少别把汉字交给英文 voice。
    # neural 后端会在 synth_server 内按中英文片段切换，并统一走 Jarvis 后处理。
    if lang == "en" and _CJK.search(text) and cfg.get("backend", "system") != "neural":
        text = clean_for_english_speech(text)

    backend = cfg.get("backend", "system")

    # 短句缓存。Jarvis 的说话风格决定了短句复现率很高——"Already done."、
    # "At your service, sir."、报时那几种句式。定稿音色合成一句要好几秒，
    # 命中缓存就是 0 秒，这是短回复上最直接的一段延迟。
    cacheable = len(text) <= PHRASE_MAX_CHARS
    key = _phrase_key(text, lang, cfg) if cacheable else None
    if key:
        hit = _phrase_hit(key)
        if hit:
            return hit, backend + "·缓存"

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
        final = raw_path
    else:
        final = metallic.apply(raw_path, _cache_path(".wav"))
        if final != raw_path:
            try:
                os.unlink(raw_path)
            except Exception:
                pass

    # 只缓存"正常合成出来的"。退回 system 的那些不缓存——下次 neural 可能就好了，
    # 缓存下来会让一次偶发失败永久留在耳朵里。
    if key and used == backend:
        try:
            os.makedirs(PHRASE_DIR, exist_ok=True)
            cached = os.path.join(PHRASE_DIR, key + ".wav")
            os.replace(final, cached)
            prune_phrases()
            return cached, used
        except OSError:
            pass
    return final, used
