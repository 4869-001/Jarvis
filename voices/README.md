# Jarvis 音色资产

已定稿的中英文音色 + 金属感后处理配置。2026-08-01 确定。

## 目录

| 路径 | 说明 | 大小 |
|------|------|------|
| `en/jarvis-high.onnx` | 英文音色，Piper 格式 | 114MB |
| `en/jarvis-high.onnx.json` | Piper 配置（必须与 onnx 同目录） | 7KB |
| `zh/kokoro-v1.1-zh.onnx` | 中文合成器，Kokoro v1.1-zh | 343MB |
| `zh/voices-zm_029.bin` | 中文音色，只含 `zm_029` 的最小 npz | 375KB |
| `synth.py` | 中英文合成脚本，已跑通 | — |
| `samples/` | 你确认的两个金属处理 mp3 | 65KB |

## 中文：zm_029

Kokoro v1.1-zh 的 45 个中文男声里，按基频排序筛出最低沉的 8 个试听后选定。

**注音必须走 `misaki[zh]`，不能用 espeak 的 `cmn`** —— espeak 的中文 G2P 声调基本是错的，听着不像普通话。

```python
from kokoro_onnx import Kokoro
from misaki import zh

k = Kokoro('voices/zh/kokoro-v1.1-zh.onnx', 'voices/zh/voices-zm_029.bin')
ps, _ = zh.ZHG2P()('晚上好，先生。')
audio, sr = k.create(ps, voice='zm_029', is_phonemes=True)   # sr = 24000
```

依赖：`kokoro-onnx`、`soundfile`、`misaki[zh]`。**不需要 torch**（onnxruntime 路线）。

> 官方的 `voices-v1.1-zh.bin` 是 54MB / 103 个音色的 npz。`kokoro-onnx` 会
> `np.load()` 它并校验文件存在（传 numpy 数组给 `voice=` 也绕不过这个检查），
> 所以这里重打了一个只含 `zm_029` 的 npz，375KB。

## 英文：jarvis-high

来自 <https://huggingface.co/jgkawell/jarvis>，专门为 Jarvis 音色训练的 Piper 模型（en_GB）。

```python
from piper.voice import PiperVoice
voice = PiperVoice.load('voices/en/jarvis-high.onnx',
                        config_path='voices/en/jarvis-high.onnx.json')
```

依赖：`piper-tts`（注意包名，`pip install piper` 装的是无关的 pypiper）。

## 金属感后处理

**这是 Jarvis 声音的主要来源，比选哪个音色更关键。** 合成完的 PCM 过一遍这条 ffmpeg 滤镜链：

```
aecho=0.8:0.85:20|45|70:0.45|0.32|0.12,
chorus=0.4:0.6:45:0.2:0.18:1.2,
bass=g=4:f=110,
treble=g=2.5,
highpass=f=90,
lowpass=f=8500
```

| 滤镜 | 作用 |
|------|------|
| `aecho` 20/45/70ms 三重超短延时 | 金属腔体 / 头盔感 |
| `chorus` | 轻微合唱，"不完全是人"的层次 |
| `bass g=4 f=110` | 胸腔厚度 |
| `treble g=2.5` | 齿音清晰 |
| `highpass 90` + `lowpass 8500` | 带限 —— "从扬声器里出来"的关键，缺这条就不像 |

中英文共用同一条链。出处：`~/Projects/JarvisRefs/assistant-x-openclaw` 的 `assistants.json`。

### 语速

**未定稿。** 当前样本是原速。调速不要用 ffmpeg 的 `atempo`（时间拉伸，音质和停顿都会劣化），
应该在合成阶段控制：

- Piper：`length_scale`，值越大越慢（`1.0` 原速，`1.1` 慢 10%）
- Kokoro：`k.create(..., speed=1.0)`，值越大越快

## 试听样本

`samples/` —— 中英文定稿音色各一个金属处理版，是你确认时听的那两个文件。

## 合成脚本

```bash
uv venv --python 3.13
uv pip install kokoro-onnx soundfile "misaki[zh]" piper-tts

python voices/synth.py zh "晚上好，先生。"
python voices/synth.py en "Good evening, sir."
python voices/synth.py zh "..." --raw     # 跳过金属处理
```

两条链路 2026-08-01 实测跑通。
