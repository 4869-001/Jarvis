"""定稿音色后端 —— Piper / jarvis-high，中文词先转拼音后保持同一音色。

依赖不在系统 Python 里（onnxruntime、piper-tts、pypinyin），
所以跑在 voices/.venv 里，由这里以**常驻子进程**方式驱动 voices/synth_server.py。
常驻是必须的：每次新起进程要花约 3 秒加载模型，而播报是逐句的，
每句都付一遍这个代价就完全没法用了。

venv 不存在时抛 NotInstalled，上层自动退回 system 后端——
不能因为音色没装好就哑掉。

建 venv：
    cd ~/Projects/Jarvis/voices
    uv venv --python 3.13 .venv
    uv pip install --python .venv/bin/python soundfile piper-tts pypinyin
"""
import json
import os
import re
import subprocess
import threading

_CANDIDATES = [
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))), "..", "voices"),
    os.path.expanduser("~/Projects/Jarvis/voices"),
]

READY_TIMEOUT = 120.0      # 首次加载模型（含 jieba 词典）可能不快
SYNTH_TIMEOUT = 90.0


class NotInstalled(Exception):
    pass


class _Worker:
    """常驻的 synth_server.py。挂了下次调用会自动重开。"""

    def __init__(self):
        self.process = None
        self.lock = threading.Lock()

    def _spawn(self, preload_lang):
        root = voices_dir()
        executable = python_executable(root)
        # 参数保留是为了兼容旧协议；worker 现在始终只加载 Jarvis Piper。
        self.process = subprocess.Popen(
            [executable, os.path.join(root, "synth_server.py"), preload_lang],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, cwd=root, bufsize=1,
        )
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("合成进程启动即退出（venv 里的依赖可能不全）")
        handshake = json.loads(line)
        if not handshake.get("ok"):
            raise RuntimeError(handshake.get("error") or "合成进程未就绪")

    def request(self, payload):
        with self.lock:
            if self.process is None or self.process.poll() is not None:
                self._spawn(payload.get("lang") or "zh")
            try:
                self.process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
                self.process.stdin.flush()
                line = self.process.stdout.readline()
            except Exception as exc:
                self.process = None
                raise RuntimeError("合成进程通信失败：%s" % exc)

            if not line:
                self.process = None
                raise RuntimeError("合成进程中途退出")
            return json.loads(line)


_worker = _Worker()


def voices_dir():
    for candidate in _CANDIDATES:
        path = os.path.realpath(candidate)
        if os.path.exists(os.path.join(path, "synth_server.py")):
            return path
    raise NotInstalled("找不到 voices/ 目录")


def python_executable(root):
    venv = os.path.join(root, ".venv", "bin", "python3")
    if not os.path.exists(venv):
        raise NotInstalled(
            "定稿音色需要 voices/.venv。建法见 brain/jarvis_brain/tts/neural.py 顶部注释。")
    return venv


def synthesize(text, out_path, lang, cfg):
    speed = cfg.get("en_length_scale", 1.0)
    request_lang = "pinyin" if re.search(r"[一-鿿㐀-䶿]", text) else "en"
    reply = _worker.request({"lang": request_lang, "text": text, "out": out_path,
                             "speed": speed, "zh_speed": cfg.get("zh_speed", 1.0)})
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error") or "合成失败")
    if not os.path.exists(out_path):
        raise RuntimeError("合成进程报成功但没有产出文件")
    return out_path
