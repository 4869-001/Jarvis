"""Unix Domain Socket + JSON Lines 服务端。

Brain 是服务端，宿主 App 是客户端。宿主负责拉起 Brain 进程，
但连接由宿主发起——这样 Brain 崩了重启后，宿主只要重连即可，不必重建 socket。

一次只服务一个客户端（就一个宿主 App）。新连接进来会顶掉旧的。
"""
import json
import os
import socket
import threading
import time

from . import config
from . import memory
from .identity import STORE as IDENTITY
from . import models
from .proactive import ProactiveReminderEngine
from . import tts as tts_module
from .session import SessionCoordinator

PROTOCOL_VERSION = 1


class BrainServer:
    def __init__(self, cfg, socket_path=None):
        self.cfg = cfg
        self.socket_path = socket_path or config.SOCKET_PATH
        self.listener = None
        self.client = None
        self._client_lock = threading.Lock()
        self.session = SessionCoordinator(cfg, self.emit, self.log)
        self.reminders = ProactiveReminderEngine(cfg.get("proactive") or {}, memory.STORE,
                                                  self.emit, self.log,
                                                  lambda: self.client is not None)

    # ------------------------------------------------------------ 日志

    def log(self, message):
        # 只写 stdout。宿主已经把 stdout 重定向到 ~/.jarvis/brain.log，
        # 这边再自己开一个文件句柄就会两个偏移量互相覆盖。
        print("[%s] %s" % (time.strftime("%H:%M:%S"), message), flush=True)

    # ------------------------------------------------------------ 发送

    def emit(self, message):
        # 状态同时落一份到 ~/.jarvis/state：宿主没连上时球体仍能跟着动，
        # 也留给外部脚本一个零成本的驱动口子。
        if message.get("type") == "state":
            try:
                with open(config.STATE_PATH, "w", encoding="utf-8") as fh:
                    fh.write(message["state"])
            except Exception:
                pass

        blob = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
        with self._client_lock:
            sock = self.client
            if sock is None:
                return
            try:
                sock.sendall(blob)
            except Exception:
                self.client = None

    # ------------------------------------------------------------ 监听

    def serve_forever(self):
        os.makedirs(config.JARVIS_DIR, exist_ok=True)
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)

        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.socket_path)
        os.chmod(self.socket_path, 0o600)
        self.listener.listen(4)
        # 用 session.provider 实际在用的那个，不是配置里的默认值——
        # 上次选了自定义模型的话，重启后接着用的是那个，日志得如实反映。
        self.log("Brain 就绪，监听 %s（模型 %s @ %s，key 来源：%s，音色 %s）" % (
            self.socket_path,
            self.session.provider.model,
            self.session.provider.base_url,
            self.cfg.get("_key_source", "?"),
            self.cfg["tts"]["backend"] if self.cfg["tts"]["enabled"] else "关闭",
        ))
        self._prewarm_tts()
        self.reminders.start()

        try:
            while True:
                conn, _ = self.listener.accept()
                with self._client_lock:
                    old, self.client = self.client, conn
                if old is not None:
                    try:
                        old.close()
                    except Exception:
                        pass
                self.log("宿主已连接")
                threading.Thread(target=self._serve_client, args=(conn,), daemon=True).start()
        finally:
            self.shutdown()

    def _prewarm_tts(self):
        """后台把定稿音色的模型先加载起来。

        不预热的话第一句要多等一秒多加载模型，而第一句恰恰是最容易被感知到慢的那句。

        现在只有 Piper Jarvis 一个神经音色；中文短词也走它，不再按语言加载第二个模型。
        """
        if not (self.cfg["tts"]["enabled"] and self.cfg["tts"]["backend"] == "neural"):
            return

        lang = "en"
        sample = "At your service."

        def warm():
            from .tts import neural
            started = time.time()
            try:
                path = os.path.join(tts_module.CACHE_DIR, "_prewarm.wav")
                neural.synthesize(sample, path, lang, self.cfg["tts"].get("neural") or {})
                os.unlink(path)
                self.log("定稿音色已预热（%s，%.1fs）" % (lang, time.time() - started))
            except neural.NotInstalled as exc:
                self.log("定稿音色未安装，将使用系统音色：%s" % exc)
            except Exception as exc:
                self.log("定稿音色预热失败，将使用系统音色：%s" % exc)

        threading.Thread(target=warm, daemon=True).start()

    def shutdown(self):
        self.reminders.stop()
        try:
            if self.listener:
                self.listener.close()
        except Exception:
            pass
        try:
            if os.path.exists(self.socket_path):
                os.unlink(self.socket_path)
        except Exception:
            pass

    # ------------------------------------------------------------ 收

    def _ready_event(self):
        """宿主靠这条消息拿到全部运行期配置——语音、唤醒词、记忆规模都在里面。
        只在一处拼装：以前连接和 reload 各拼一份，加字段时漏掉一边过。"""
        try:
            remembered = len(memory.STORE.all())
        except Exception:
            remembered = 0
        return {
            "type": "ready",
            "protocol": PROTOCOL_VERSION,
            "session_id": self.session.session_id,
            "model": self.session.provider.model,
            "configured": self.session.provider.configured,
            "config_path": config.CONFIG_PATH,
            "allow_shell": self.cfg["tools"]["allow_shell"],
            "voice_input": self.cfg["voice_input"],
            "wake_word": self.cfg["wake_word"],
            "memory": {"enabled": (self.cfg.get("memory") or {}).get("enabled", True),
                       "count": remembered},
            "identity": {"name": IDENTITY.data["name"],
                         "creator": IDENTITY.data["creator"],
                         "created_at": IDENTITY.data["created_at"],
                         "path": IDENTITY.path},
            "tts": {"enabled": self.cfg["tts"]["enabled"],
                    "backend": self.cfg["tts"]["backend"]},
            "models": self.session.models_payload(),
        }

    def _serve_client(self, conn):
        self.emit(self._ready_event())
        self.session.set_state("idle")

        buffer = b""
        try:
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if line.strip():
                        self._dispatch(line)
        except Exception as exc:
            self.log("客户端读取中断：%s" % exc)
        finally:
            self.log("宿主断开")
            was_current = False
            with self._client_lock:
                if self.client is conn:
                    self.client = None
                    was_current = True
            try:
                conn.close()
            except Exception:
                pass
            # 新连接会先替换并关闭旧连接。旧连接的线程随后才走到 finally；
            # 它已经不是当前宿主，不能顺手取消新宿主刚发起的那一轮。
            if was_current:
                self.session.cancel()

    def _dispatch(self, line):
        try:
            message = json.loads(line.decode("utf-8"))
        except Exception as exc:
            self.log("收到坏消息：%s" % exc)
            return

        kind = message.get("type")
        if kind == "user_message":
            self.session.handle_user_message(message.get("text"), message.get("id") or "msg")
        elif kind == "cancel":
            self.session.cancel()
        elif kind == "new_session":
            self.session.reset()
        elif kind == "tool_confirm_response":
            self.session.resolve_pending(message.get("request_id"),
                                         {"approved": bool(message.get("approved"))})
        elif kind == "native_tool_result":
            self.session.resolve_pending(message.get("request_id"), {
                "result": message.get("result"),
                "error": message.get("error"),
            })
        elif kind == "speak_text":
            self.session.speak_text(message.get("text"))
        elif kind == "set_model":
            self.session.set_model(message.get("id"))
            self.emit({"type": "models", **self.session.models_payload()})
        elif kind == "add_model":
            try:
                models.STORE.add(message.get("label"), message.get("base_url"),
                                 message.get("api_key"), message.get("model"))
            except ValueError as exc:
                self.emit({"type": "error", "message": str(exc)})
            self.emit({"type": "models", **self.session.models_payload()})
        elif kind == "update_model":
            model_id = message.get("id")
            try:
                models.STORE.update(model_id, message.get("label"), message.get("base_url"),
                                    message.get("api_key"), message.get("model"))
                if models.STORE.active_id() == model_id:
                    self.session.set_model(model_id)
            except ValueError as exc:
                self.emit({"type": "error", "message": str(exc)})
            self.emit({"type": "models", **self.session.models_payload()})
        elif kind == "remove_model":
            model_id = message.get("id")
            was_active = (models.STORE.active_id() == model_id)
            try:
                models.STORE.remove(model_id)
            except ValueError as exc:
                self.emit({"type": "error", "message": str(exc)})
            else:
                # 删的是正在用的那个：ModelStore 自己的 active 指针已经回落到
                # default，但 session.provider 还是那个指向已删模型的旧实例，
                # 必须显式切一次才能让真正在跑的 provider 也跟着回落。
                if was_active:
                    self.session.set_model(models.DEFAULT_MODEL_ID)
            self.emit({"type": "models", **self.session.models_payload()})
        elif kind == "set_wake_word":
            # 唤醒方式：自动唤醒词监听（默认，闲置省电/2 分钟自动恢复）
            # 或仅手动 ⌥V（关掉常驻麦克风采集）。落盘后原样回推，宿主立即生效。
            enabled = bool(message.get("enabled"))
            self.cfg["wake_word"]["enabled"] = enabled
            config.save_section("wake_word", {"enabled": enabled})
            self.emit({"type": "wake_word", **self.cfg["wake_word"]})
        elif kind == "ping":
            self.emit({"type": "pong", "t": time.time()})
        elif kind == "reload_config":
            self._reload()
        else:
            self.log("未知消息类型：%s" % kind)

    def _reload(self):
        self.cfg = config.load()
        self.session.cfg = self.cfg
        self.reminders.cfg = self.cfg.get("proactive") or {}
        # 重载配置不能悄悄退回默认模型：active 指针和菜单仍指向自定义模型时，
        # Provider 也必须用同一条配置，否则 UI 与真实 API 会发生分叉。
        active_id = models.STORE.active_id()
        provider_cfg = models.STORE.get_provider_cfg(active_id, self.cfg["deepseek"])
        if provider_cfg is None:
            active_id = models.DEFAULT_MODEL_ID
            models.STORE.set_active(active_id)
            provider_cfg = self.cfg["deepseek"]
        self.session.provider = type(self.session.provider)(provider_cfg)
        self.session.tool_ctx.update({
            "fs_roots": self.cfg["tools"]["fs_roots"],
            "allow_shell": self.cfg["tools"]["allow_shell"],
            "shell_unrestricted": self.cfg["tools"].get("shell_unrestricted", False),
            "max_output_chars": self.cfg["tools"]["max_output_chars"],
            "search": self.cfg["search"],
        })
        self.session.auto_approve = set(self.cfg["tools"].get("auto_approve") or [])
        self.log("配置已重载")
        self.emit(self._ready_event())
