"""定稿音色后端 —— 中文 Kokoro v1.1-zh / zm_029，英文 Piper / jarvis-high。

依赖不在系统 Python 里（onnxruntime、kokoro-onnx、misaki[zh]、piper-tts），
所以跑在 voices/.venv 里，由这里以**常驻子进程**方式驱动 voices/synth_server.py。
常驻是必须的：每次新起进程要花约 3 秒加载模型，而播报是逐句的，
每句都付一遍这个代价就完全没法用了。

venv 不存在时抛 NotInstalled，上层自动退回 system 后端——
不能因为音色没装好就哑掉。

建 venv：
    cd ~/Projects/Jarvis/voices
    uv venv --python 3.13 .venv
    uv pip install --python .venv/bin/python kokoro-onnx soundfile "misaki[zh]" piper-tts
"""
import json
import os
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

    def _spawn(self):
        root = voices_dir()
        executable = python_executable(root)
        self.process = subprocess.Popen(
            [executable, os.path.join(root, "synth_server.py")],
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
                self._spawn()
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
    speed = cfg.get("zh_speed", 1.0) if lang == "zh" else cfg.get("en_length_scale", 1.0)
    reply = _worker.request({"lang": lang, "text": text, "out": out_path, "speed": speed})
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error") or "合成失败")
    if not os.path.exists(out_path):
        raise RuntimeError("合成进程报成功但没有产出文件")
    return out_path
