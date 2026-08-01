"""会话编排：一轮用户输入 → 模型流式回复 → 工具循环 → 收尾。

同一时刻只允许一轮会话在跑（评审 §八 阶段 0 验收标准第 4 条）。
任何出口都必须把状态落回 idle，包括异常和取消——否则球体会永久停在 thinking。
"""
import json
import platform
import queue
import threading
import time
import traceback

from . import tts
from .providers.deepseek import Cancelled, DeepSeekProvider, ProviderError
from .tools import registry
from .tools.paths import PathDenied

ZH_MARKER = "[[ZH]]"

SYSTEM_PROMPT = """You are J.A.R.V.I.S., a desktop assistant running on the user's MacBook.

OUTPUT FORMAT — follow exactly, every single time:
1. First, your answer in English.
2. Then a line containing only {marker}
3. Then the same answer translated into natural Chinese.

The English part is spoken aloud; the Chinese part is shown as a subtitle.
Never put Chinese before the marker. Never omit the marker. Never add anything after
the Chinese translation. If the answer is one word, still emit all three parts.

This format overrides any instruction to the contrary. If the user asks you to reply
in Chinese, the part before the marker is STILL English — the Chinese translation
after the marker already gives them what they asked for. There is no situation in
which Chinese appears before the marker.

When you call tools, emit the tool calls ONLY — no preamble, no "let me check that".
The user already sees the tool running. Prose belongs in your final answer, which is
the only place the three-part format applies.

Style:
- Always answer in English, no matter what language the user speaks.
- Terse, direct, understated. A capable butler, not a support agent.
- Address the user as "sir", but not in every sentence.
- Don't recite raw tool output — state the conclusion.

Tools:
- You can genuinely operate this Mac: open apps, read/write files, search files,
  read the clipboard, search the web. Just do it; don't ask "would you like me to".
- For facts, anything time-sensitive, or anything you're unsure of, call web_search
  first — do not answer from memory. Follow up with web_fetch if you need details.
- File-changing operations already prompt the user for confirmation; don't ask again.
- If the user declines a tool call, accept it. Don't retry it with different wording.
- You may call several tools at once, but don't pad.

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

        self.history = []
        self._lock = threading.Lock()
        self._worker = None
        self._cancel = threading.Event()
        self._state = "idle"

        # 等宿主回话的两类阻塞：确认弹窗、原生工具执行
        self._pending = {}              # id -> {"event": Event, "value": any}
        self._pending_lock = threading.Lock()

        self.tool_ctx = {
            "fs_roots": cfg["tools"]["fs_roots"],
            "allow_shell": cfg["tools"]["allow_shell"],
            "max_output_chars": cfg["tools"]["max_output_chars"],
            "search": cfg["search"],
        }

        # 播报：一个串行 worker 保证句子按顺序合成、按顺序发给宿主。
        # generation 用来作废被取消那一轮还在队列里的句子。
        self._speech_queue = queue.Queue()
        self._speech_buffer = ""
        self._generation = 0
        threading.Thread(target=self._speech_worker, daemon=True).start()

    # ------------------------------------------------------------ 状态

    def set_state(self, state):
        if state == self._state:
            return
        self._state = state
        self.emit({"type": "state", "state": state})

    @property
    def busy(self):
        return self._worker is not None and self._worker.is_alive()

    # ------------------------------------------------------------ 入口

    def handle_user_message(self, text, message_id):
        text = (text or "").strip()
        if not text:
            return
        if self.busy:
            self.emit({"type": "error", "message": "上一轮还没结束，先说完这句。"})
            return
        if not self.provider.configured:
            self.emit({"type": "error", "message":
                       "还没配 DeepSeek API Key。菜单栏 → 打开配置，填 deepseek.api_key 后重启大脑。"})
            return

        self._cancel.clear()
        self._speech_buffer = ""
        self.history.append({"role": "user", "content": text})
        self._trim()

        self._worker = threading.Thread(target=self._run_turn, args=(message_id,), daemon=True)
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
        self.cancel()
        self.history = []
        self.set_state("idle")
        self.emit({"type": "session_reset"})

    def resolve_pending(self, request_id, value):
        with self._pending_lock:
            slot = self._pending.get(request_id)
        if not slot:
            return
        slot["value"] = value
        slot["event"].set()

    def _emit_segment(self, message_id, channel, chunk, english_parts, chinese_parts):
        """英文进正文与播报，中文只进字幕。中文绝不能进 TTS——
        播报的是英文，字幕跟着念一遍会变成中英各说一次。"""
        if channel == "en":
            english_parts.append(chunk)
            self.emit({"type": "assistant_delta", "id": message_id, "text": chunk})
            self._feed_speech(chunk)
        else:
            chinese_parts.append(chunk)
            self.emit({"type": "assistant_delta_zh", "id": message_id, "text": chunk})

    # ------------------------------------------------------------ 播报

    @property
    def _tts_enabled(self):
        return bool(self.cfg.get("tts", {}).get("enabled"))

    def _feed_speech(self, delta):
        """把流式增量攒成整句就送去合成——不等整段说完，听感上快很多。"""
        if not self._tts_enabled:
            return
        self._speech_buffer += delta
        sentences = tts.split_sentences(self._speech_buffer)
        # 最后一段可能还没说完，留在 buffer 里等下一批增量
        if len(sentences) <= 1:
            return
        for sentence in sentences[:-1]:
            self._speech_queue.put((self._generation, sentence))
        self._speech_buffer = sentences[-1]

    def _flush_speech(self):
        if not self._tts_enabled:
            return
        remainder = self._speech_buffer.strip()
        self._speech_buffer = ""
        if remainder:
            self._speech_queue.put((self._generation, remainder))

    def _abandon_speech(self):
        """作废这一轮所有还没播的句子，并让宿主停掉正在播的。"""
        self._generation += 1
        self._speech_buffer = ""
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
            try:
                path, backend = tts.synthesize(text, self.cfg.get("tts") or {})
            except Exception as exc:
                self.log("合成失败：%s" % exc)
                self.emit({"type": "speak_failed", "message": str(exc)[:200]})
                continue
            if not path or generation != self._generation:
                continue
            self.emit({"type": "speak", "path": path, "text": text, "backend": backend})
            tts.prune_cache()

    # ------------------------------------------------------------ 主循环

    def _run_turn(self, message_id):
        try:
            self.set_state("thinking")
            self._loop(message_id)
        except Cancelled:
            self.emit({"type": "turn_cancelled", "id": message_id})
        except ProviderError as exc:
            self.emit({"type": "error", "message": str(exc)})
        except Exception as exc:
            self.log("turn 崩了: %s\n%s" % (exc, traceback.format_exc()))
            self.emit({"type": "error", "message": "内部错误：%s" % exc})
        finally:
            # 无论怎么退出都必须落回 idle
            self.set_state("idle")
            self.emit({"type": "turn_done", "id": message_id})

    def _loop(self, message_id):
        max_rounds = self.cfg["session"]["max_tool_rounds"]

        for round_index in range(max_rounds + 1):
            if self._cancel.is_set():
                raise Cancelled()

            # 提醒贴在最后一条：工具结果常常是中文（文件名、工具摘要），
            # 隔着这些内容，开头的系统提示压不住格式，模型会整段滑回中文。
            # 这条只在请求里出现，不进 history。
            messages = [self._system_message()] + self.history + [self._format_reminder()]
            tools = registry.openai_schema() if round_index < max_rounds else None

            english_parts = []
            chinese_parts = []
            tool_calls = []
            started_speaking = False
            splitter = BilingualSplitter()

            for kind, value in self.provider.stream(messages, tools):
                if self._cancel.is_set():
                    raise Cancelled()

                if kind == "reasoning":
                    self.emit({"type": "assistant_reasoning_delta", "id": message_id, "text": value})
                elif kind == "text":
                    if not started_speaking:
                        started_speaking = True
                        self.set_state("speaking")
                    for channel, chunk in splitter.feed(value):
                        self._emit_segment(message_id, channel, chunk,
                                           english_parts, chinese_parts)
                elif kind == "tool_calls":
                    tool_calls = value

            for channel, chunk in splitter.flush():
                self._emit_segment(message_id, channel, chunk, english_parts, chinese_parts)

            # 历史只留英文：中文是给眼睛看的字幕，喂回上下文只会让 token 翻倍
            full_text = "".join(english_parts)
            chinese_text = "".join(chinese_parts).strip()

            if not tool_calls:
                if full_text:
                    self.history.append({"role": "assistant", "content": full_text})
                self._flush_speech()
                self.emit({"type": "assistant_done", "id": message_id,
                           "text": full_text, "text_zh": chinese_text})
                return

            self.history.append({
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

            self.set_state("thinking")
            for index, call in enumerate(tool_calls):
                result = self._execute(call["name"], call["arguments"], call["id"] or ("call_%d" % index))
                self.history.append({
                    "role": "tool",
                    "tool_call_id": call["id"] or ("call_%d" % index),
                    "content": json.dumps(result, ensure_ascii=False)[:16000],
                })
            self._trim()

        self.emit({"type": "error", "message": "工具调用超过 %d 轮，已中止。" % max_rounds})

    # ------------------------------------------------------------ 工具执行

    def _execute(self, name, raw_arguments, call_id):
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
        self.emit({"type": "tool_started", "id": call_id, "name": name,
                   "arguments": arguments, "risk": tool["risk"], "summary": summary})

        if registry.needs_confirmation(tool):
            approved = self._ask_confirmation(call_id, name, arguments, tool["risk"], summary)
            if not approved:
                self.emit({"type": "tool_result", "id": call_id, "name": name,
                           "success": False, "summary": "用户拒绝了这次操作"})
                return {"error": "用户拒绝执行", "declined": True}

        started = time.time()
        try:
            if tool["executor"] == "native":
                result = self._call_native(call_id, name, arguments)
            else:
                result = tool["fn"](arguments, self.tool_ctx)
        except PathDenied as exc:
            result = {"error": str(exc)}
        except Cancelled:
            raise
        except Exception as exc:
            self.log("工具 %s 抛异常: %s\n%s" % (name, exc, traceback.format_exc()))
            result = {"error": "%s 执行失败：%s" % (name, exc)}

        if not isinstance(result, dict):
            result = {"result": result}

        ok = "error" not in result
        self.emit({"type": "tool_result", "id": call_id, "name": name, "success": ok,
                   "summary": result.get("error") or summary,
                   "ms": int((time.time() - started) * 1000)})
        return result

    def _ask_confirmation(self, call_id, name, arguments, risk, summary):
        request_id = "confirm_" + call_id
        value = self._wait_for_host(request_id, {
            "type": "tool_confirm_request", "id": call_id, "request_id": request_id,
            "name": name, "arguments": arguments, "risk": risk, "summary": summary,
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

    def _system_message(self):
        env = "macOS %s / %s / 用户主目录 %s" % (
            platform.mac_ver()[0] or platform.release(),
            platform.machine(),
            self.cfg["tools"]["fs_roots"][0] if self.cfg["tools"]["fs_roots"] else "~",
        )
        return {"role": "system", "content": SYSTEM_PROMPT.format(
            marker=ZH_MARKER, env=env, now=time.strftime("%Y-%m-%d %H:%M:%S %A"))}

    def _format_reminder(self):
        return {"role": "system", "content":
                "Reminder: English answer first (even if the user wrote Chinese or the tool "
                "output is Chinese), then a line with only %s, then the Chinese translation. "
                "Keep it short — this is spoken aloud." % ZH_MARKER}

    def _trim(self):
        """裁历史。不能把 assistant(tool_calls) 和它的 tool 结果拆散，否则 API 报 400。"""
        limit = self.cfg["session"]["history_limit"]
        if len(self.history) <= limit:
            return
        cut = len(self.history) - limit
        while cut < len(self.history) and self.history[cut].get("role") == "tool":
            cut += 1
        self.history = self.history[cut:]
