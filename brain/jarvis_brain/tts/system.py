"""系统音色后端 —— 走 `say`。

零依赖、零下载、必然可用，所以它是默认值。音色不如定稿的 jarvis-high，
但金属链一套上差距远比直觉小（见 metallic.py 的说明）。
"""
import subprocess

# 都是本机 `say -v '?'` 实测存在的名字
DEFAULT_ZH = "Li-mu"      # zh_CN 男声
DEFAULT_EN = "Daniel"     # en_GB 男声，评审文档里英文基准就是它


def synthesize(text, out_path, lang, cfg):
    voice = cfg.get("zh_voice", DEFAULT_ZH) if lang == "zh" else cfg.get("en_voice", DEFAULT_EN)
    rate = int(cfg.get("rate") or 180)

    command = ["say", "-v", voice, "-r", str(rate),
               "-o", out_path, "--data-format=LEI16@22050", text]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError("say 失败（音色 %s）：%s" % (voice, result.stderr.strip()[:200]))
    return out_path
