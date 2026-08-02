#!/usr/bin/env python3
"""常驻 Jarvis Piper 合成进程 —— 模型只加载一次。

synth.py 每调一次就要重新加载 Piper，实测有明显固定加载开销。
对话是逐句播报的,这个代价每句都要付一遍,听感上就是一顿一顿的。
这里把模型常驻,由 Brain 通过 stdin/stdout 喂请求。

协议(JSON Lines):
    ←  {"lang":"zh","text":"晚上好","out":"/tmp/a.wav","speed":1.0}
    →  {"ok":true,"out":"/tmp/a.wav","seconds":1.2}
    →  {"ok":false,"error":"..."}

单独跑用 synth.py,那个仍然可用。
"""
import json
import os
import re
import sys
import warnings

warnings.filterwarnings("ignore")

HERE = os.path.dirname(os.path.abspath(__file__))

_piper = None


def _load_en():
    global _piper
    if _piper is None:
        from piper.voice import PiperVoice
        _piper = PiperVoice.load(
            f"{HERE}/en/jarvis-high.onnx",
            config_path=f"{HERE}/en/jarvis-high.onnx.json",
        )
    return _piper


def synth(lang, text, speed):
    import numpy as np
    voice = _load_en()
    chunks = [c.audio_float_array for c in voice.synthesize(text)]
    return np.concatenate(chunks), voice.config.sample_rate


def chinese_to_pinyin(text):
    """只转汉字片段，英文和标点原样保留；同一个 Piper 音色从头念到尾。"""
    from pypinyin import Style, lazy_pinyin

    def replace(match):
        return " " + " ".join(lazy_pinyin(match.group(0), style=Style.NORMAL)) + " "
    return re.sub(r"[一-鿿㐀-䶿]+", replace, text)


def main():
    import soundfile as sf

    # 启动就把要用的模型加载好——第一句话不该比后面的慢一大截。
    #
    # 始终只加载 Jarvis Piper；中文短词在进入模型前转成拼音。
    preload = sys.argv[1] if len(sys.argv) > 1 else "en"
    try:
        _load_en()
    except Exception as exc:
        print(json.dumps({"ok": False, "error": "预加载 %s 模型失败：%s" % (preload, exc)}), flush=True)

    print(json.dumps({"ok": True, "ready": True, "preloaded": preload}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            lang = request.get("lang", "zh")
            if lang == "pinyin":
                audio, rate = synth("en", chinese_to_pinyin(request["text"]),
                                    float(request.get("speed") or 1.0))
            else:
                audio, rate = synth("en", request["text"], float(request.get("speed") or 1.0))
            out = request["out"]
            os.makedirs(os.path.dirname(out), exist_ok=True)
            sf.write(out, audio, rate)
            reply = {"ok": True, "out": out, "seconds": round(len(audio) / rate, 2)}
        except Exception as exc:
            reply = {"ok": False, "error": str(exc)[:400]}
        print(json.dumps(reply, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
