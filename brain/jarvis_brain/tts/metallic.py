"""金属感后处理。

结论来自 voices/README.md 的实测：**Jarvis 的声音主要来自这条链子，不是音色本身**。
所以两个后端共用它，系统音色也能出味。带限那条（highpass/lowpass）最关键，
去掉就不像"从扬声器里出来的"。
"""
import os
import shutil
import subprocess

CHAIN = (
    "aecho=0.8:0.85:20|45|70:0.45|0.32|0.12,"   # 三重超短延时 → 金属腔体/头盔感
    "chorus=0.4:0.6:45:0.2:0.18:1.2,"           # 轻微合唱 → "不完全是人"
    "bass=g=4:f=110,"                           # 胸腔厚度
    "treble=g=2.5,"                             # 齿音清晰
    "highpass=f=90,"                            # ↓ 带限，缺这条就不像
    "lowpass=f=8500"
)


def ffmpeg_path():
    local = os.path.expanduser("~/.local/bin/ffmpeg")
    if os.path.exists(local):
        return local
    return shutil.which("ffmpeg")


def apply(wav_in, wav_out):
    """过一遍金属链。没有 ffmpeg 就原样返回，不阻断播报。"""
    exe = ffmpeg_path()
    if not exe:
        return wav_in
    try:
        subprocess.run(
            [exe, "-y", "-loglevel", "error", "-i", wav_in, "-af", CHAIN, wav_out],
            capture_output=True, timeout=60, check=True,
        )
    except Exception:
        return wav_in
    return wav_out if os.path.exists(wav_out) else wav_in
