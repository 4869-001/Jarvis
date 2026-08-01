#!/usr/bin/env python3
"""Jarvis 定稿音色合成 —— 中英文各一条,输出可直接播放的 wav。

环境(不需要 torch):
    uv venv --python 3.13
    uv pip install kokoro-onnx soundfile "misaki[zh]" piper-tts

用法:
    python synth.py zh "晚上好,先生。"
    python synth.py en "Good evening, sir."
    python synth.py zh "..." --raw               # 跳过金属处理
    python synth.py zh "..." --out /tmp/a.wav    # 指定输出路径
    python synth.py zh "..." --speed 1.1         # zh 是 Kokoro speed,en 是 Piper length_scale

Brain 调用时走 `--raw --out`:金属链统一在 tts/metallic.py 里加,
免得同一条滤镜在两个地方各写一份、日后改参数只改到一处。
"""
import argparse
import os
import subprocess
import sys
import tempfile
import warnings

warnings.filterwarnings("ignore")

HERE = os.path.dirname(os.path.abspath(__file__))

# 金属感滤镜链 —— 中英文共用,详见 README.md
METALLIC = (
    "aecho=0.8:0.85:20|45|70:0.45|0.32|0.12,"
    "chorus=0.4:0.6:45:0.2:0.18:1.2,"
    "bass=g=4:f=110,"
    "treble=g=2.5,"
    "highpass=f=90,"
    "lowpass=f=8500"
)


def synth_zh(text, speed=1.0):
    """Kokoro v1.1-zh + zm_029。注音必须走 misaki,espeak 的 cmn 声调是错的。"""
    from kokoro_onnx import Kokoro
    from misaki import zh

    k = Kokoro(f"{HERE}/zh/kokoro-v1.1-zh.onnx", f"{HERE}/zh/voices-zm_029.bin")
    phonemes, _ = zh.ZHG2P()(text)
    return k.create(phonemes, voice="zm_029", speed=speed, is_phonemes=True)


def synth_en(text, length_scale=1.0):
    """Piper jarvis-high。length_scale 越大越慢。"""
    import numpy as np
    from piper.voice import PiperVoice

    voice = PiperVoice.load(
        f"{HERE}/en/jarvis-high.onnx",
        config_path=f"{HERE}/en/jarvis-high.onnx.json",
    )
    chunks = [c.audio_float_array for c in voice.synthesize(text)]
    return np.concatenate(chunks), voice.config.sample_rate


def apply_metallic(wav_in, wav_out):
    """过一遍 ffmpeg 金属链。没有 ffmpeg 就原样返回,不阻断合成。"""
    exe = os.path.expanduser("~/.local/bin/ffmpeg")
    if not os.path.exists(exe):
        exe = "ffmpeg"
    try:
        subprocess.run(
            [exe, "-y", "-loglevel", "error", "-i", wav_in, "-af", METALLIC, wav_out],
            check=True,
        )
        return True
    except Exception as e:
        print(f"金属处理失败,用原声: {e}", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("lang", choices=["zh", "en"])
    parser.add_argument("text")
    parser.add_argument("--raw", action="store_true", help="跳过金属处理")
    parser.add_argument("--out", help="输出路径,默认 ./jarvis_<lang>.wav")
    parser.add_argument("--speed", type=float, default=1.0)
    args = parser.parse_args()

    audio, sr = (synth_zh if args.lang == "zh" else synth_en)(args.text, args.speed)

    import soundfile as sf

    out = os.path.abspath(args.out or f"jarvis_{args.lang}.wav")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if args.raw:
        sf.write(out, audio, sr)
    else:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            sf.write(tmp.name, audio, sr)
            if not apply_metallic(tmp.name, out):
                sf.write(out, audio, sr)
            os.unlink(tmp.name)

    print(f"→ {out}  ({len(audio) / sr:.1f}s)")


if __name__ == "__main__":
    main()
