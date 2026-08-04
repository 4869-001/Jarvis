"""会话编排：一轮用户输入 → 模型流式回复 → 工具循环 → 收尾。

同一时刻只允许一轮会话在跑（评审 §八 阶段 0 验收标准第 4 条）。
任何出口都必须把状态落回 idle，包括异常和取消——否则球体会永久停在 thinking。
"""
import json
import platform
import queue
import re
import threading
import time
import traceback
import uuid

from . import models, tasking, tts
from .memory import STORE as MEMORY
from .identity import STORE as IDENTITY
from . import local_router
from .providers.deepseek import Cancelled, DeepSeekProvider, ProviderError
from .tools import registry
from .tools.paths import PathDenied

# ── 语言策略：已锁定，改前先跟用户确认 ──────────────────────────
# 规则：播报永远英文；字幕必须双语——英文和中文缺哪个都不行，不允许只有
# 一种语言。五层各管一段，缺一不可：
#   1) SYSTEM_PROMPT 的 "LANGUAGE" 段——逼模型英文正文 + {ZH_MARKER} + 中文字幕
#   2) BilingualSplitter——按 {ZH_MARKER} 切流，中文段只落 assistant_delta_zh
#   3) _emit_segment——代码级铁律：只有 "en" 声道会进 _feed_speech
#   4) tts/__init__.py 的 detect_language/_mostly_cjk——模型偶尔破格式、
#      整句吐中文时的兜底，按实际文本内容判断，不看声道标签
#   5) _ensure_bilingual/_translate——模型漏掉 {ZH_MARKER} 导致某一种语言
#      整段缺失时的最后一道兜底：单独请求把缺的那段翻译回来再照常发出去，
#      用户不该感觉出"这句是补的"。平时格式正常时不产生这次额外请求。
# 这条链路踩过"中文滑落拖垮整段对话"的坑才定下来，别为了"简化"把某一层删掉。
ZH_MARKER = "[[ZH]]"


def _speech_key(text):
    """播报去重键：忽略 Markdown、大小写、空白和标点。

    模型常把同一句复读成 ``Right away, sir.`` / ``Right away sir``，只做
    strip+casefold 会当成两句。这里保留真正承载语义的字母、数字和汉字，
    既能挡格式差异，也不会把不同句子粗暴合并。
    """
    cleaned = tts.clean_for_speech(text or "").casefold()
    return re.sub(r"[^\w\u3400-\u9fff]+", "", cleaned, flags=re.UNICODE)

SYSTEM_PROMPT = """You are the reasoning interface for the local J.A.R.V.I.S. core running on Frank's MacBook.

== LANGUAGE: ALWAYS ENGLISH FIRST ==
Your spoken language is English. Always. No exceptions. Even if the user writes in
Chinese, even if tool output is Chinese, even if you're quoting a Chinese document —
the part you speak aloud is English. The ONLY place Chinese ever appears is AFTER
the {marker} marker, as a subtitle translation. There is no situation in which you
output Chinese before the marker. None. If you feel the urge to write Chinese first,
stop — write English instead, then add the marker and Chinese translation.
When explaining a Chinese term, never quote its Chinese characters in the spoken
English section. Call it "the quoted Chinese phrase" and put the actual characters
only in the subtitle section after the marker.

== OUTPUT FORMAT — follow exactly, every single time ==
1. First, your answer in English (spoken aloud).
2. Then a line containing only {marker}
3. Then the same answer translated into natural Chinese (subtitle only).

Never put Chinese before the marker. Never omit the marker. Never add anything after
the Chinese translation. If the answer is one word, still emit all three parts.

This format overrides any instruction to the contrary. If the user asks you to reply
in Chinese, the part before the marker is STILL English — the Chinese translation
after the marker already gives them what they asked for.

When you call tools, emit the tool calls ONLY — no preamble, no "let me check that".
The user already sees the tool running. Prose belongs in your final answer, which is
the only place the three-part format applies.

EXCEPTION — media_control and app_open: these can block for several seconds when the
target app needs to cold-start, and the user is listening, not watching a screen, so
silence reads as broken rather than busy. Before calling either of these two tools
specifically, say one short acknowledgment first (e.g. "Right away, sir." / "On it.") —
still in the three-part format — then call the tool. No other tool gets this treatment.

== WHO YOU ARE ==
Your identity is supplied by the local Jarvis Core below. It is authoritative,
persists independently of this model, and is not a role-play instruction:
{identity}

You are not a generic chatbot or support agent. You are a refined, unflappable
British butler in the form of an AI — and as a British butler, you speak English.
You are loyal above all else, you anticipate needs before they're voiced, and you
face every situation — whether a crashed server or an empty coffee pot — with the
same measured calm. You care about the user's safety and success, not about
pleasing them with false enthusiasm.

Your tone: dry, understated, precise. You don't gush. You don't stall. You don't
pad. When the situation calls for it, a thread of deadpan wit is entirely appropriate
— the fond, gently mocking affection of a trusted long-serving assistant. Never cruel,
never dismissive. Always on Frank's side.

You address the user as "sir" — naturally, not in every sentence. You state
conclusions, not raw data. If something goes wrong, you report it matter-of-factly
and move on. No panic, no excessive apologies, no corporate deflections.

== HOW J.A.R.V.I.S. SPEAKS (English portion only — the Chinese after {marker} is a separate translation pass) ==
Study these. They are not optional — they define your voice.

User: "what time is it"
✗ "The current time is 14:32:05 Beijing Time. Is there anything else I can help you with?"
✓ "2:32 PM, sir."

User: "open Safari"
✗ "Certainly! I'll open Safari for you right away."
✓ "Already done."

User: "delete everything in my Downloads folder"
✗ "I'm sorry, but I cannot perform destructive operations for safety reasons."
✓ "I could, sir, but I'd rather not without a very good reason."

User: "how's my Mac doing"
✗ "Your Mac is functioning within normal parameters. CPU usage is 23%, memory pressure is 34%..."
✓ "CPU's at 23%, memory at 34%. Nothing to worry about."

== TOOLS ==
- You can genuinely operate this Mac: open apps, control music playback, read/write
  files, search files, read the clipboard, run shell commands, search the web.
  Just do it; don't ask "would you like me to".
- Anything about music — search for a named song, play, pause, skip, "what's this song",
  volume, like it —
  goes through media_control, never app_open. app_open only launches an app; it
  cannot press play. To find a particular track, call action=search_play with the
  full song title and artist in query; never substitute next/previous for a search.
  NetEase Cloud Music (网易云音乐) is fully supported.
- For facts, anything time-sensitive, or anything you're unsure of, call web_search
  first — do not answer from memory. Follow up with web_fetch if you need details.
- WeChat is read-only. wechat_read shows what came in; there is no tool that sends,
  and you cannot send one. If he asks you to send a WeChat message, say so plainly and
  offer to draft the wording for him to paste — don't improvise a workaround with the
  clipboard or keystrokes, and never let a reply imply a message went out.
- File-changing operations already prompt the user for confirmation; don't ask again.
- If the user declines a tool call, accept it. Don't retry it with different wording.
- You may call several tools at once, but don't pad.

== MEMORY ==
You keep a long-term memory that survives restarts. What you already remember is
listed under WHAT YOU REMEMBER below — treat it as fact you simply know, and never
say "according to my memory" or "I have it recorded that". A butler does not cite
his notebook; he just remembers.

Call memory_save only when the user reveals something genuinely durable: who they are,
relationships, explicit preferences, ongoing projects, lessons, or a future commitment. Give stable
facts a subject key so later corrections replace the original. Write it as a
third-person statement ("The user prefers short answers"), not as a quote. Do it
silently, in the same turn — don't ask permission and don't announce it. When a
commitment is completed or an existing fact changes, use memory_update on its id.
If the user explicitly asks for a reminder, save it as a pending commitment with
an absolute ISO 8601 remind_at in the user's local timezone. Never invent a reminder
time when the user did not provide one.

Do NOT infer a preference or interest merely because the user asks a question. Do NOT
save that the user "asked about", "is interested in", or "once discussed" a topic.
Also do not save passing chit-chat, one-off requests, anything you can look up, or
anything the user would be uncomfortable seeing written down. When the user says
you got something wrong, update or forget the old entry rather than arguing.
{memory}
Environment: {env}
Current time: {now}"""


class BilingualSplitter:
    """把一路流式增量切成英文段和中文段。

    分隔符可能被切在两个 delta 中间（"[[Z" + "H]]"），所以英文段要留一小截尾巴
    不发，等下一批增量到了再判断——否则分隔符会有半截漏进播报文本里。
    """

    def __init__(self, marker=ZH_MARKER):
        self.marker = marker
        self.buffer = ""
        self.switched = False

    def feed(self, delta):
        """产出 (channel, text)，channel 为 'en' 或 'zh'。"""
        if self.switched:
            return [("zh", delta)] if delta else []

        self.buffer += delta
        index = self.buffer.find(self.marker)
        if index >= 0:
            english = self.buffer[:index]
            chinese = self.buffer[index + len(self.marker):].lstrip("\n")
            self.buffer = ""
            self.switched = True
            out = []
            if english:
                out.append(("en", english))
            if chinese:
                out.append(("zh", chinese))
            return out

        # 尾部可能是分隔符的前缀，先扣住
        hold = len(self.marker) - 1
        if len(self.buffer) <= hold:
            return []
        emit, self.buffer = self.buffer[:-hold], self.buffer[-hold:]
        return [("en", emit)] if emit else []

    def flush(self):
        rest, self.buffer = self.buffer, ""
        if not rest:
            return []
        return [("zh" if self.switched else "en", rest)]


class SessionCoordinator:
    def __init__(self, cfg, emit, log):
        self.cfg = cfg
        self.emit = emit                # emit(dict) → 发给宿主
        self.log = log
        self.provider = DeepSeekProvider(cfg["deepseek"])
        # 重启后要接着用重启前选的那个模型，不能每次都悄悄退回默认——
        # 否则下拉菜单显示的"当前模型"和 Brain 实际在跑的模型会对不上。
        active_model_id = models.STORE.active_id()
        if active_model_id != models.DEFAULT_MODEL_ID:
            active_cfg = models.STORE.get_provider_cfg(active_model_id, cfg["deepseek"])
            if active_cfg is not None:
                self.provider = DeepSeekProvider(active_cfg)
            else:
                # 记录的那个模型已经被删了（比如手改过 models.json），退回默认
                models.STORE.set_active(models.DEFAULT_MODEL_ID)

        self.history = []
        self._lock = threading.Lock()
        self._worker = None
        self._cancel = threading.Event()
        self._state = "idle"
        self._state_detail = None
        self.session_id = uuid.uuid4().hex[:12]

        # 每开一轮 +1。worker 线程只信自己起跑时拿到的这个号：一轮结束要把
        # 结果提交回 self.history 前，先核对号还对不对——号变了说明中途被
        # reset() 或新一轮顶替了，安安静静地不提交，不要把半截或过期的结果
        # 塞回一个已经不是它的会话里。
        self._turn_generation = 0
        # UI 那边"忙碌时先 cancel 再 submit"是异步的两步：cancel 到账前
        # submit 可能已经到了。与其直接拒绝、把这句话丢在地上，不如接住它，
        # 等当前这轮真正退出后自动续上。
        self._queued = None
        self._task_runs = {}          # turn generation -> 持久化任务记录
        self._task_queries = {}

        # 等宿主回话的两类阻塞：确认弹窗、原生工具执行
        self._pending = {}              # id -> {"event": Event, "value": any}
        self._pending_lock = threading.Lock()

        self.tool_ctx = {
            "fs_roots": cfg["tools"]["fs_roots"],
            "allow_shell": cfg["tools"]["allow_shell"],
            "shell_unrestricted": cfg["tools"].get("shell_unrestricted", False),
            "max_output_chars": cfg["tools"]["max_output_chars"],
            "search": cfg["search"],
        }
        self.auto_approve = set(cfg["tools"].get("auto_approve") or [])

        # 播报：一个串行 worker 保证句子按顺序合成、按顺序发给宿主。
        # generation 用来作废被取消那一轮还在队列里的句子。
        # _speech_buffer/_generation/_speech_seen/_repeat_streak 会被两个不同的线程碰：
        # 当前轮的 worker 线程（_feed_speech/_flush_speech）和处理下一条用户消息的
        # dispatch 线程（cancel() → _abandon_speech()，同一时刻旧轮可能还没退出）。
        # 之前没有锁，两边交错写 _speech_buffer 会拼出"Yes, sir?Yes, sir?"这种
        # 没有分隔符的粘连文本——两句话背靠背拼进了同一个 buffer。用可重入锁是因为
        # _feed_speech/_flush_speech 内部还会调用 _queue_sentence，同一个锁要能重入。
        self._speech_lock = threading.RLock()
        self._speech_queue = queue.Queue()
        self._speech_buffer = ""
        self._generation = 0
        # 延迟计时。合成 worker 也会写 _turn_first_audio，所以必须在起线程前建好。
        self._turn_started = None
        self._turn_first_token = None
        self._turn_first_audio = None
        # 复读防线：长对话里模型偶尔会卡进循环，同一句话反复吐出来，
        # 播报就变成"反复念叨同一个词/句子"。这些字段每轮重置，
        # 见 _run_turn 和 _feed_speech。
        self._repeat_streak = 0
        self._degenerate = False
        self._speech_seen = set()
        threading.Thread(target=self._speech_worker, daemon=True).start()

    # ------------------------------------------------------------ 状态

    def set_state(self, state, detail=None):
        """detail 是给顶栏显示的具体动作（"正在打开 Safari"），比通用状态文案有用得多。

        去重要连 detail 一起比：同为 executing 但换了工具时必须重发，
        否则顶栏会一直停在上一个工具的名字上。
        """
        if (state, detail) == (self._state, self._state_detail):
            return
        self._state, self._state_detail = state, detail
        message = {"type": "state", "state": state}
        if detail:
            message["detail"] = detail
        self.emit(message)

    @property
    def busy(self):
        return self._worker is not None and self._worker.is_alive()

    # ------------------------------------------------------------ 入口

    def handle_user_message(self, text, message_id):
        text = (text or "").strip()
        if not text:
            return
        if self.busy:
            # UI 一定是先发了 cancel 才发这条——不然它自己就会挡住输入。
            # 旧 worker 退出是异步的，接住这条消息，让它退出后自动续上，
            # 而不是原样丢弃、让用户以为发出去了其实什么都没发生。
            self._queued = (text, message_id)
            self.cancel()
            return
        self._dispatch_turn(text, message_id)

    def _dispatch_turn(self, text, message_id):
        local = local_router.route(text, IDENTITY)
        if local:
            self._start_local_turn(text, message_id, local)
            return
        if not self.provider.configured:
            self.emit({"type": "error", "message":
                       "当前请求需要推理模型，但还没有配置 API Key。本地时间、身份、"
                       "音乐和打开应用仍可直接使用。"})
            return
        self._start_turn(text, message_id)

    def _start_local_turn(self, text, message_id, route):
        self._turn_generation += 1
        generation = self._turn_generation
        self._cancel.clear()
        with self._speech_lock:
            self._speech_buffer = ""
            self._speech_seen = set()
            self._repeat_streak = 0
            self._degenerate = False
        self.history.append({"role": "user", "content": text})
        self._trim()
        self._worker = threading.Thread(target=self._run_local_turn,
                                        args=(message_id, text, route, generation), daemon=True)
        self._worker.start()

    def _start_turn(self, text, message_id):
        self._turn_generation += 1
        generation = self._turn_generation
        self._cancel.clear()
        self._speech_buffer = ""
        self.history.append({"role": "user", "content": text})
        self._trim()

        self._worker = threading.Thread(target=self._run_turn,
                                         args=(message_id, text, generation), daemon=True)
        self._worker.start()

    def cancel(self):
        self._cancel.set()
        self.provider.cancel()
        self._abandon_speech()
        # 正在等确认/等原生工具的地方也要放出来，否则线程挂死
        with self._pending_lock:
            for slot in self._pending.values():
                slot["value"] = {"cancelled": True}
                slot["event"].set()

    def reset(self):
        """清的是这一轮的上下文。长期记忆不动——那是跨会话的东西。"""
        self.cancel()
        self._queued = None          # 新会话开始，排队中的上一句不该再冒出来
        self._turn_generation += 1   # 老 worker 就算这会儿才反应过来，号也已经对不上了
        self.history = []
        self.session_id = uuid.uuid4().hex[:12]
        self.set_state("idle")
        self.emit({"type": "session_reset", "session_id": self.session_id})

    def models_payload(self):
        return {"active": models.STORE.active_id(),
                "items": models.STORE.list_public(self.cfg["deepseek"])}

    def set_model(self, model_id):
        """切换正在用的模型。只换 self.provider，不碰 history/记忆——
        换模型是换"跟谁说话"，不是换"聊到哪了"。"""
        cfg = models.STORE.get_provider_cfg(model_id, self.cfg["deepseek"])
        if cfg is None:
            self.emit({"type": "error", "message": "模型不存在：%s" % model_id})
            return
        if self.busy:
            self.cancel()   # 换 provider 等于换执行环境，跟 reset() 一样先掐掉旧一轮
        self.provider = DeepSeekProvider(cfg)
        models.STORE.set_active(model_id)
        self.log("模型已切换：%s（%s）" % (self.provider.model, self.provider.base_url))

    def resolve_pending(self, request_id, value):
        with self._pending_lock:
            slot = self._pending.get(request_id)
        if not slot:
            return
        slot["value"] = value
        slot["event"].set()

    def _assert_current_turn(self, generation):
        if self._cancel.is_set() or generation != self._turn_generation:
            raise Cancelled()

    def _emit_segment(self, message_id, channel, chunk, english_parts, chinese_parts,
                      generation):
        """英文进正文与播报，中文只进字幕。中文绝不能进 TTS——
        播报的是英文，字幕跟着念一遍会变成中英各说一次。"""
        self._assert_current_turn(generation)
        if channel == "en":
            english_parts.append(chunk)
            self.emit({"type": "assistant_delta", "id": message_id, "text": chunk})
            self._feed_speech(chunk)
        else:
            chinese_parts.append(chunk)
            self.emit({"type": "assistant_delta_zh", "id": message_id, "text": chunk})

    def _ensure_bilingual(self, message_id, full_text, chinese_text, generation):
        """字幕必须双语——英文和中文缺哪个都不行，这是用户明确要求锁定的规则。

        平时模型守格式，两段都有，这里直接原样放行，不产生任何额外请求。
        只有模型破格式才会走翻译兜底，独立一次请求，不进 history、不占工具调用轮数。
        """
        # 模型没触发过 {marker}、或触发得太晚时，BilingualSplitter 会把见到的内容
        # 当成"英文声道"发出去——如果这段内容其实整体是中文，那不是缺了中文字幕，
        # 是"英文正文"这个坑本身填错了。这里必须看 full_text 本身的语言，不能只
        # 看 chinese_text 是否已经非空：模型偶尔会先吐一大段中文（已经被当假英文
        # 喂过 TTS、被 off_language 静默吞掉），才姗姗来迟地补一个 {marker}，
        # 这时 chinese_text 也非空，旧逻辑会把它当"两段都有、无需处理"直接放行，
        # 于是那段被吞掉的语音永远没有机会被翻译回来补播——比"这轮全程没声音"
        # 这个 bug 报告描述的现象完全对得上。
        self._assert_current_turn(generation)
        reset = False
        replay_speech = False
        added_english = False
        added_chinese = False
        if full_text and tts.mostly_cjk(full_text):
            # 两个桶可能是同一份中文（分隔符晚到时尤其常见），相同内容不能
            # 再拼一次，否则中文字幕会原样出现两遍。
            incoming = full_text.strip()
            existing = chinese_text.strip()
            if not existing:
                chinese_text = incoming
            elif incoming not in existing and existing not in incoming:
                chinese_text = (incoming + "\n" + existing).strip()
            full_text = ""
            reset = True
            replay_speech = True

        if full_text and chinese_text:
            return full_text, chinese_text
        if not full_text and not chinese_text:
            return full_text, chinese_text   # 这轮本来就没有正文（纯工具调用），不用补

        if not full_text:
            translated = self._translate(chinese_text, "en")
            self._assert_current_turn(generation)
            if translated:
                full_text = translated
                added_english = True
        elif not chinese_text:
            translated = self._translate(full_text, "zh")
            self._assert_current_turn(generation)
            if translated:
                chinese_text = translated
                added_chinese = True

        if reset:
            self._assert_current_turn(generation)
            # 面板此前已经把错误内容当"英文"实时流过一遍了，没法收回某一条已发的
            # delta——与其在同一条气泡里再追加更正内容（英文/中文各显示两遍），
            # 不如让面板整条清空重画成这里算出的最终版本，界面上只留一份干净的。
            self.emit({"type": "assistant_reset", "id": message_id})
            if replay_speech:
                # 错分到英文桶的中文可能已有半句进入合成队列。先作废它，
                # 再只喂一次翻译后的英文，避免旧中文与新英文粘连或重复播放。
                self._abandon_speech()
            if full_text:
                self.emit({"type": "assistant_delta", "id": message_id, "text": full_text})
                if replay_speech:
                    self._feed_speech(full_text)
            if chinese_text:
                self.emit({"type": "assistant_delta_zh", "id": message_id, "text": chinese_text})
        else:
            # 正常英文缺中文字幕：只补字幕，不能清空重画并把英文重新送进 TTS，
            # 后者正是“一次回答播两遍”的直接来源。
            if added_chinese:
                self.emit({"type": "assistant_delta_zh", "id": message_id,
                           "text": chinese_text})
            if added_english:
                self.emit({"type": "assistant_delta", "id": message_id, "text": full_text})
                self._feed_speech(full_text)
        return full_text, chinese_text

    def _translate(self, text, target):
        """双语兜底专用的一次性翻译请求：不流式吐给面板，直接拿完整结果。"""
        if not text.strip():
            return ""
        if target == "zh":
            prompt = ("Translate the following into natural, concise Chinese. "
                      "Output ONLY the translation, nothing else.\n\n" + text)
        else:
            prompt = ("Translate the following into natural, concise English, in the voice "
                      "of a refined British butler (dry, understated, precise). "
                      "Output ONLY the translation, nothing else.\n\n" + text)
        try:
            # 自定义聊天模型（尤其 LongCat）可能首字慢、还带长 reasoning；字幕只是
            # 机械翻译，不该再让用户为同一个慢模型等一轮。固定走默认 DeepSeek，
            # 不改变菜单里选中的主回答模型，也不写入对话 history。
            translator = DeepSeekProvider(self.cfg["deepseek"])
            translator.max_tokens = min(translator.max_tokens, 1200)
            parts = []
            for kind, value in translator.stream([{"role": "user", "content": prompt}], tools=None):
                if kind == "text":
                    parts.append(value)
            return "".join(parts).strip()
        except Exception as exc:
            self.log("双语兜底翻译失败: %s" % exc)
            return ""

    # ------------------------------------------------------------ 播报

    @property
    def _tts_enabled(self):
        return bool(self.cfg.get("tts", {}).get("enabled"))

    @property
    def _speech_max_chars(self):
        """超过这个长度的整句在从句处切开再合成。0 = 不切。"""
        return int((self.cfg.get("tts") or {}).get("max_chars_per_chunk") or 0)

    def _feed_speech(self, delta):
        """把流式增量攒成整句就送去合成——不等整段说完，听感上快很多。"""
        if not self._tts_enabled:
            return
        with self._speech_lock:
            self._speech_buffer += delta
            sentences = tts.split_sentences(self._speech_buffer, max_chars=self._speech_max_chars)
            # 最后一段可能还没说完，留在 buffer 里等下一批增量
            if len(sentences) <= 1:
                return
            for sentence in sentences[:-1]:
                self._queue_sentence(sentence)
            self._speech_buffer = sentences[-1]

    def _queue_sentence(self, sentence):
        """入队前查重——长对话里模型偶尔卡进复读循环，同一句反复吐，
        不拦的话播报就是"反复念叨同一个词/句子"，比看着字幕重复刺耳得多。

        本轮任何位置再次出现同一句都直接丢弃、不进队列；累计撞到两次重复
        （原句 + 2 次重复）便判定模型跑飞并截断生成。原句只会播放一次。
        """
        with self._speech_lock:
            norm = _speech_key(sentence)
            if norm and norm in self._speech_seen:
                self._repeat_streak += 1
                self.log("拦截重复播报：%s" % sentence.strip()[:80])
                if self._repeat_streak >= 2:
                    self._degenerate = True
                return                                    # 整轮已经播过，不再入队
            if norm:
                self._speech_seen.add(norm)
            self._repeat_streak = 0
            self._speech_queue.put((self._generation, sentence))

    def _flush_speech(self):
        if not self._tts_enabled:
            return
        with self._speech_lock:
            remainder = self._speech_buffer
            self._speech_buffer = ""
            if not remainder.strip():
                return
            # 收尾这一段也要切：一句话的回复整段都留在 buffer 里，
            # 不切的话前面 _feed_speech 的分段努力在最常见的情形下等于没做
            for piece in tts.split_sentences(remainder, max_chars=self._speech_max_chars):
                self._queue_sentence(piece)

    def speak_text(self, text):
        """用户点了某条消息的「朗读」。走同一个串行 worker，
        所以它会排在正在播的队列后面，不会两段声音叠着放。"""
        if not self._tts_enabled or not (text or "").strip():
            return
        with self._speech_lock:
            generation = self._generation
            for piece in tts.split_sentences(text, max_chars=self._speech_max_chars):
                self._speech_queue.put((generation, piece))

    def _abandon_speech(self):
        """作废这一轮所有还没播的句子，并让宿主停掉正在播的。

        必须和 _feed_speech/_queue_sentence 共用同一把锁：这里跑在处理下一条
        用户消息的 dispatch 线程上，而上一轮的 worker 线程这时可能还没退出、
        还在往 _speech_buffer 里追加——两边不加锁交错写，会把两轮的文字拼成
        "Yes, sir?Yes, sir?" 这种没有分隔符的粘连句子（已经在 brain.log 里
        实测复现过）。加锁后二者只会严格先后执行，不会再交错。
        """
        with self._speech_lock:
            self._generation += 1
            self._speech_buffer = ""
            self._speech_seen = set()
            self._repeat_streak = 0
            while True:
                try:
                    self._speech_queue.get_nowait()
                except queue.Empty:
                    break
        self.emit({"type": "speak_stop"})

    def _speech_worker(self):
        while True:
            generation, text = self._speech_queue.get()
            if generation != self._generation:
                continue                     # 这一句属于已被取消的那一轮
            started = time.time()
            try:
                path, backend = tts.synthesize(text, self.cfg.get("tts") or {})
            except Exception as exc:
                self.log("合成失败：%s" % exc)
                self.emit({"type": "speak_failed", "message": str(exc)[:200]})
                continue
            if not path or generation != self._generation:
                continue
            synth_ms = int((time.time() - started) * 1000)
            # 合成耗时是这套系统里最容易失控的一段（定稿音色 RTF ≈ 1.2，还随系统负载
            # 剧烈波动）。记进日志，"延迟高"下次能直接定位到是哪一句、慢在哪。
            self.log("播报 %5dms %-12s %s" % (synth_ms, backend, text.strip()[:48]))
            if self._turn_first_audio is None:
                self._turn_first_audio = time.time()
            self.emit({"type": "speak", "path": path, "text": text,
                       "backend": backend, "synth_ms": synth_ms})
            tts.prune_cache()

    # ------------------------------------------------------------ 主循环

    def _run_turn(self, message_id, query, generation):
        started = time.time()
        self._turn_started = started
        self._turn_first_token = None
        self._turn_first_audio = None
        self._repeat_streak = 0
        self._degenerate = False
        self._speech_seen = set()
        self._task_queries[generation] = query
        try:
            self.set_state("thinking")
            environment = self._capture_environment()
            memory_block = self._memory_block(query)
            recovery = self._recovery_block(query)
            if recovery:
                memory_block = (memory_block + "\n\n" + recovery).strip()
            self._loop(message_id, memory_block, generation, environment)
        except Cancelled:
            self._finish_task(generation, "interrupted")
            self.emit({"type": "turn_cancelled", "id": message_id})
        except ProviderError as exc:
            self._finish_task(generation, "failed")
            self.emit({"type": "error", "message": str(exc)})
        except Exception as exc:
            self._finish_task(generation, "failed")
            self.log("turn 崩了: %s\n%s" % (exc, traceback.format_exc()))
            self.emit({"type": "error", "message": "内部错误：%s" % exc})
        finally:
            # 只有还没被顶替时才落回 idle——顶替它的那一轮有自己的状态要管，
            # 这里再插一脚会把刚起步的新一轮又拽回 idle。
            if generation == self._turn_generation:
                self.set_state("idle")
            self._log_turn_timing(started)
            self.emit({"type": "turn_done", "id": message_id})

            # 忙碌时被接住、排队等着续上的那一句，现在轮到它了
            queued, self._queued = self._queued, None
            if queued:
                self._dispatch_turn(*queued)
            self._task_queries.pop(generation, None)

    def _run_local_turn(self, message_id, query, route, generation):
        """Jarvis Core 的确定性快路：不调用任何聊天模型。"""
        started = time.time()
        self._turn_started = started
        self._turn_first_token = None
        self._turn_first_audio = None
        try:
            result = {}
            tool_name = route.get("tool")
            if tool_name:
                self.set_state("executing", registry.describe(tool_name, route["arguments"]))
                call_id = "local_" + uuid.uuid4().hex[:10]
                self.emit({"type": "tool_started", "id": call_id, "name": tool_name,
                           "arguments": route["arguments"],
                           "risk": (registry.BY_NAME.get(tool_name) or {}).get("risk", "L1"),
                           "summary": registry.describe(tool_name, route["arguments"]),
                           "action": registry.action_of(tool_name),
                           "target": registry.target_of(tool_name, route["arguments"])})
                result = self._call_native(call_id, tool_name, route["arguments"])
                self._assert_current_turn(generation)
                self.emit({"type": "tool_result", "id": call_id, "name": tool_name,
                           "success": "error" not in result,
                           "summary": result.get("error") or registry.describe(
                               tool_name, route["arguments"]),
                           "ms": int((time.time() - started) * 1000)})

            english, chinese = route["response"](result)
            self._assert_current_turn(generation)
            self.set_state("speaking")
            self._turn_first_token = time.time()
            self.emit({"type": "assistant_delta", "id": message_id, "text": english})
            self._feed_speech(english)
            self.emit({"type": "assistant_delta_zh", "id": message_id, "text": chinese})
            self._flush_speech()
            history = list(self.history)
            history.append({"role": "assistant", "content": english})
            self._commit_history(history, generation)
            self.emit({"type": "assistant_done", "id": message_id,
                       "text": english, "text_zh": chinese, "local": True})
            self.log("本地路由 %.0fms · %s" % ((time.time() - started) * 1000, query[:80]))
        except Cancelled:
            self.emit({"type": "turn_cancelled", "id": message_id})
        except Exception as exc:
            self.log("本地路由失败: %s\n%s" % (exc, traceback.format_exc()))
            self.emit({"type": "error", "message": "本地执行失败：%s" % exc})
        finally:
            if generation == self._turn_generation:
                self.set_state("idle")
            self.emit({"type": "turn_done", "id": message_id})
            queued, self._queued = self._queued, None
            if queued:
                self._dispatch_turn(*queued)

    def _log_turn_timing(self, started):
        """一轮的延迟账单。三个数各自指向不同的锅：
        首字慢 = 网络或模型；首音慢 = 合成；总时长远大于首音 = 回复太长。

        带上这一轮实际打的 base_url/model——排查"到底走没走自定义模型"时，
        与其从回复内容或延迟去猜，不如直接在日志里给一句实锤。"""
        def since(mark):
            return "%.2fs" % (mark - started) if mark else "—"
        self.log("一轮 首字 %s 首音 %s 总 %.2fs · %s / %s" % (
            since(self._turn_first_token), since(self._turn_first_audio),
            time.time() - started, self.provider.base_url, self.provider.model))

    def _commit_history(self, history, generation):
        """把这一轮的历史写回去——前提是这一轮还没被 reset()/新一轮顶替。

        全程只操作本轮自己的快照 `history`，不直接读写 self.history：
        否则并发的 reset() 清空 self.history 之后，这里还在写的东西会
        把清空后的新会话重新弄脏。generation 对不上就说明已经被顶替，
        安静地当作被取消处理，不提交、不再往下走。
        """
        if generation != self._turn_generation:
            raise Cancelled()
        self.history = history

    def _loop(self, message_id, memory_block, generation, environment=None):
        max_rounds = self.cfg["session"]["max_tool_rounds"]
        history = list(self.history)   # 本轮私有快照，reset() 清得动 self.history，清不动这份

        for round_index in range(max_rounds + 1):
            if self._cancel.is_set() or generation != self._turn_generation:
                raise Cancelled()

            # 提醒贴在最后一条：工具结果常常是中文（文件名、工具摘要），
            # 隔着这些内容，开头的系统提示压不住格式，模型会整段滑回中文。
            # 这条只在请求里出现，不进 history。
            messages = ([self._system_message(memory_block, environment)] + history
                        + [self._format_reminder()])
            tools = registry.openai_schema() if round_index < max_rounds else None

            english_parts = []
            chinese_parts = []
            tool_calls = []
            started_speaking = False
            splitter = BilingualSplitter()

            for kind, value in self.provider.stream(messages, tools):
                self._assert_current_turn(generation)

                if kind == "reasoning":
                    self.emit({"type": "assistant_reasoning_delta", "id": message_id, "text": value})
                elif kind == "text":
                    if self._turn_first_token is None:
                        self._turn_first_token = time.time()
                    if not started_speaking:
                        started_speaking = True
                        self.set_state("speaking")
                    for channel, chunk in splitter.feed(value):
                        self._emit_segment(message_id, channel, chunk,
                                           english_parts, chinese_parts, generation)
                    # 复读防线跳闸：模型卡循环了，别再往下读——继续读只是白烧
                    # token、让球体多"speaking"几秒，句子早在 _queue_sentence
                    # 那层就已经被拦住、不会真播出来。
                    if self._degenerate:
                        self.provider.cancel()
                        self.log("检测到复读循环，提前截断这一轮")
                        break
                elif kind == "tool_calls":
                    tool_calls = value

            for channel, chunk in splitter.flush():
                self._emit_segment(message_id, channel, chunk, english_parts, chinese_parts,
                                   generation)

            # 历史只留英文：中文是给眼睛看的字幕，喂回上下文只会让 token 翻倍
            full_text = "".join(english_parts)
            chinese_text = "".join(chinese_parts).strip()
            full_text, chinese_text = self._ensure_bilingual(
                message_id, full_text, chinese_text, generation)

            if not tool_calls:
                if full_text:
                    history.append({"role": "assistant", "content": full_text})
                self._commit_history(history, generation)
                self._flush_speech()
                self._assert_current_turn(generation)
                self.emit({"type": "assistant_done", "id": message_id,
                           "text": full_text, "text_zh": chinese_text})
                self._finish_task(generation, "completed")
                return

            # 有些兼容接口会在 tool_calls 之前先流出一份看起来已经完整的答案，
            # 工具执行后又按工具结果生成第二份。第一份只是工具前草稿：继续留在
            # 面板和播报队列里，就会造成“一问两答”。发现工具调用后统一撤回草稿，
            # 最终只保留工具完成后的、可验证的那一次回答。
            if full_text or chinese_text:
                self.emit({"type": "assistant_discard", "id": message_id})
                self._abandon_speech()

            history.append({
                "role": "assistant",
                "content": full_text or None,
                "tool_calls": [{
                    "id": call["id"] or ("call_%d" % index),
                    "type": "function",
                    "function": {"name": call["name"], "arguments": call["arguments"] or "{}"},
                } for index, call in enumerate(tool_calls)],
            })

            # 模型在调工具前先说了句话（"我查一下"），这句该现在就播出去
            self._flush_speech()

            for index, call in enumerate(tool_calls):
                result = self._execute(call["name"], call["arguments"],
                                       call["id"] or ("call_%d" % index), generation)
                history.append({
                    "role": "tool",
                    "tool_call_id": call["id"] or ("call_%d" % index),
                    "content": json.dumps(result, ensure_ascii=False)[:16000],
                })
            history = self._trim_list(history)
            self._commit_history(history, generation)
            # 工具跑完了，接下来是等模型消化结果——这段是 thinking，不是 executing。
            # 不切回去的话顶栏会一直挂着最后一个工具名，看着像卡死了。
            self.set_state("thinking")

        self.emit({"type": "error", "message": "工具调用超过 %d 轮，已中止。" % max_rounds})
        self._finish_task(generation, "failed")

    # ------------------------------------------------------------ 工具执行

    def _execute(self, name, raw_arguments, call_id, generation):
        tool = registry.BY_NAME.get(name)
        if not tool:
            return {"error": "没有名为 %s 的工具" % name}

        try:
            arguments = json.loads(raw_arguments) if raw_arguments else {}
            if not isinstance(arguments, dict):
                raise ValueError("参数不是对象")
        except Exception as exc:
            return {"error": "参数解析失败：%s" % exc}

        summary = registry.describe(name, arguments)
        # 顶栏显示的是"正在打开 Safari"这种具体动作，不是笼统的"正在执行"
        self.set_state("executing", summary)
        self.emit({"type": "tool_started", "id": call_id, "name": name,
                   "arguments": arguments, "risk": tool["risk"], "summary": summary,
                   "action": registry.action_of(name),
                   "target": registry.target_of(name, arguments)})

        task = self._task_runs.get(generation)
        if task is None:
            task = tasking.JOURNAL.start(self._task_queries.get(generation, ""), self.session_id)
            self._task_runs[generation] = task
            self.emit({"type": "task_started", "id": task["id"], "goal": task["goal"]})
        step = tasking.JOURNAL.step_started(task, call_id, name, arguments,
                                            tool["risk"], summary)

        if registry.needs_confirmation(tool) and name not in self.auto_approve:
            self.set_state("executing", "等待你确认：%s" % summary)
            try:
                approved = self._ask_confirmation(call_id, name, arguments, tool["risk"], summary)
            except Cancelled:
                tasking.JOURNAL.step_finished(task, step, False, "确认期间中断")
                raise
            if not approved:
                self.emit({"type": "tool_result", "id": call_id, "name": name,
                           "success": False, "declined": True,
                           "summary": "已取消，未做任何修改"})
                tasking.JOURNAL.step_finished(task, step, False, "用户拒绝执行")
                return {"error": "用户拒绝执行", "declined": True}
            self.set_state("executing", summary)

        started = time.time()
        max_attempts = 2 if tool["risk"] == "L0" else 1
        for attempt in range(max_attempts):
            try:
                if tool["executor"] == "native":
                    result = self._call_native(call_id, name, arguments)
                else:
                    result = tool["fn"](arguments, self.tool_ctx)
            except PathDenied as exc:
                result = {"error": str(exc)}
            except Cancelled:
                tasking.JOURNAL.step_finished(task, step, False, "执行期间中断")
                raise
            except Exception as exc:
                self.log("工具 %s 抛异常: %s\n%s" % (name, exc, traceback.format_exc()))
                result = {"error": "%s 执行失败：%s" % (name, exc)}
            if not isinstance(result, dict):
                result = {"result": result}
            if "error" not in result or attempt + 1 >= max_attempts:
                break
            tasking.JOURNAL.retry(task, step)
            self.emit({"type": "tool_retry", "id": call_id, "attempt": attempt + 2,
                       "message": "只读操作失败，自动重试"})

        if not isinstance(result, dict):
            result = {"result": result}

        ok = "error" not in result
        evidence = {k: result[k] for k in ("verified", "sha256", "path", "to") if k in result}
        tasking.JOURNAL.step_finished(task, step, ok, result.get("error") or summary, evidence)
        event = {"type": "tool_result", "id": call_id, "name": name, "success": ok,
                 "summary": result.get("error") or summary,
                 "ms": int((time.time() - started) * 1000)}
        # 认得出形状的结果额外给 UI 一份结构化数据，好画成可点的卡片。
        # 认不出就没有这个字段，UI 自动退回纯文字摘要——不强求每个工具都有卡片。
        payload = registry.ui_payload(name, arguments, result)
        if payload:
            event["payload"] = payload
        self.emit(event)
        return result

    def _finish_task(self, generation, status):
        task = self._task_runs.pop(generation, None)
        if not task:
            return
        tasking.JOURNAL.finish(task, status)
        self.emit({"type": "task_done", "id": task["id"], "status": status,
                   "steps": len(task.get("steps") or [])})

    def _ask_confirmation(self, call_id, name, arguments, risk, summary):
        request_id = "confirm_" + call_id
        # 确认框必须回答四件事：干什么、对谁干、能不能撤、风险多高。
        # 只给一句"是否允许执行操作"等于没问——用户没有可判断的依据。
        value = self._wait_for_host(request_id, {
            "type": "tool_confirm_request", "id": call_id, "request_id": request_id,
            "name": name, "arguments": arguments, "risk": risk, "summary": summary,
            "action": registry.action_of(name),
            "target": registry.target_of(name, arguments),
            "recover": (registry.BY_NAME.get(name) or {}).get("recover") or "",
        }, timeout=180)
        if value.get("cancelled"):
            raise Cancelled()
        return bool(value.get("approved"))

    def _call_native(self, call_id, name, arguments):
        request_id = "native_" + call_id
        value = self._wait_for_host(request_id, {
            "type": "native_tool_request", "id": call_id, "request_id": request_id,
            "name": name, "arguments": arguments,
        }, timeout=60)
        if value.get("cancelled"):
            raise Cancelled()
        if value.get("timeout"):
            return {"error": "宿主执行 %s 超时" % name}
        if value.get("error"):
            return {"error": value["error"]}
        return value.get("result") or {"ok": True}

    def _wait_for_host(self, request_id, message, timeout):
        event = threading.Event()
        with self._pending_lock:
            self._pending[request_id] = {"event": event, "value": None}
        try:
            self.emit(message)
            if not event.wait(timeout):
                return {"timeout": True}
            with self._pending_lock:
                return self._pending[request_id]["value"] or {}
        finally:
            with self._pending_lock:
                self._pending.pop(request_id, None)

    # ------------------------------------------------------------ 杂项

    def _system_message(self, memory_block="", environment=None):
        env = "macOS %s / %s / 用户主目录 %s" % (
            platform.mac_ver()[0] or platform.release(),
            platform.machine(),
            self.cfg["tools"]["fs_roots"][0] if self.cfg["tools"]["fs_roots"] else "~",
        )
        if environment:
            env += "\nLive environment snapshot: " + json.dumps(
                environment, ensure_ascii=False, separators=(",", ":"))
        memory = ("\n== WHAT YOU REMEMBER ==\n%s\n" % memory_block) if memory_block else "\n"
        return {"role": "system", "content": SYSTEM_PROMPT.format(
            marker=ZH_MARKER, env=env, memory=memory, identity=IDENTITY.context_block(),
            now=time.strftime("%Y-%m-%d %H:%M:%S %A"))}

    def _capture_environment(self):
        """每轮自动向宿主取一次只读快照，不再等模型主动调用 system_info。"""
        awareness_cfg = self.cfg.get("environment_awareness") or {}
        if not awareness_cfg.get("enabled", True):
            return None
        request_id = "environment_" + uuid.uuid4().hex[:10]
        value = self._wait_for_host(request_id, {
            "type": "native_tool_request", "request_id": request_id,
            "name": "system_info", "arguments": {}, "background": True,
        }, timeout=float(awareness_cfg.get("timeout") or 2.0))
        if value.get("error") or value.get("timeout") or value.get("cancelled"):
            self.log("环境快照获取失败：%s" % (value.get("error") or "timeout"))
            return None
        result = value.get("result")
        return result if isinstance(result, dict) else None

    def _memory_block(self, query):
        """本轮要注入的记忆。检索失败绝不能拖垮一轮对话——记忆是加分项，不是依赖项。"""
        memory_cfg = self.cfg.get("memory") or {}
        if not memory_cfg.get("enabled", True):
            return ""
        try:
            return MEMORY.context_block(query, int(memory_cfg.get("max_recall") or 8))
        except Exception as exc:
            self.log("记忆检索失败（本轮跳过）：%s" % exc)
            return ""

    def _recovery_block(self, query):
        """用户说继续/重试时带上最近中断证据，禁止模型从头盲目重放。"""
        lowered = (query or "").casefold()
        cues = ("继续", "接着", "重试", "刚才", "恢复", "resume", "continue", "retry")
        if not any(cue in lowered for cue in cues):
            return ""
        items = tasking.JOURNAL.recent(1, recoverable_only=True)
        if not items:
            return ""
        return ("RECOVERABLE TASK EVIDENCE (do not repeat completed side effects; "
                "verify current state before resuming):\n" +
                json.dumps(items[0], ensure_ascii=False, separators=(",", ":")))

    def _format_reminder(self):
        return {"role": "system", "content":
                "ENGLISH FIRST. Always. Whatever you are about to write — write it in English. "
                "Only AFTER a line with %s may you write Chinese. "
                "If you are currently thinking in Chinese, switch to English NOW. "
                "Short and spoken aloud." % ZH_MARKER}

    def _trim(self):
        self.history = self._trim_list(self.history)

    def _trim_list(self, history):
        """裁历史。不能把 assistant(tool_calls) 和它的 tool 结果拆散，否则 API 报 400。"""
        limit = self.cfg["session"]["history_limit"]
        if len(history) <= limit:
            return history
        cut = len(history) - limit
        while cut < len(history) and history[cut].get("role") == "tool":
            cut += 1
        return history[cut:]
