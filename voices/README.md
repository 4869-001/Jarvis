# Jarvis 音色资产

已定稿的 Piper Jarvis 英文音色 + 金属感后处理配置。中文短词先转无声调拼音，
仍由同一个音色合成，不再加载第二套中文模型。

## 目录

| 路径 | 说明 | 大小 |
|------|------|------|
| `en/jarvis-high.onnx` | 英文音色，Piper 格式 · **不在 git 里，见下** | 114MB |
| `en/jarvis-high.onnx.json` | Piper 配置（必须与 onnx 同目录） | 7KB |

## ⚠️ 模型不入库，克隆后要自己放

`en/jarvis-high.onnx` 有 114MB，超过 GitHub 单文件 100MB 的硬限制，已从版本库里
剔除（`.gitignore` 挡着）。**不放这个文件，合成会在首次播报时失败。**

从下面「英文：jarvis-high」一节的出处下载，放到 `voices/en/jarvis-high.onnx`
即可——`.onnx.json` 配置仍在库里，两个文件必须同目录。

历史上这里还有过一个 328MB 的中文 Kokoro 模型，早已不用（中文短词改走拼音 +
同一英文音色），2026-08-06 连同它在 git 历史里的副本一起清掉了：仓库从 420MB
降到 29MB。别再把 `.onnx` 提交进来。
| `synth.py` | 英文及中文拼音合成脚本 | — |
| `samples/` | 你确认的两个金属处理 mp3 | 65KB |

## 中文处理

汉字片段通过 `pypinyin` 转成无声调拼音，再交给 `jarvis-high`。优点是全程保持
同一音色、只常驻一个模型；代价是长中文句和多音字不如中文 TTS 自然，因此它只适合
回复中的短中文词。完整回答仍要求英文播报、中文字幕。

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

所有播报共用同一条链。出处：`~/Projects/JarvisRefs/assistant-x-openclaw` 的 `assistants.json`。

### 语速

**未定稿。** 当前样本是原速。调速不要用 ffmpeg 的 `atempo`（时间拉伸，音质和停顿都会劣化），
应该在合成阶段控制：

- Piper：`length_scale`，值越大越慢（`1.0` 原速，`1.1` 慢 10%）

## 试听样本

`samples/` —— 中英文定稿音色各一个金属处理版，是你确认时听的那两个文件。

## 合成脚本

```bash
uv venv --python 3.13
uv pip install soundfile piper-tts pypinyin

python voices/synth.py zh "晚上好，先生。"  # 转拼音后仍使用 Jarvis 音色
python voices/synth.py en "Good evening, sir."
python voices/synth.py zh "..." --raw     # 跳过金属处理
```

Piper 与拼音链路已实测跑通。
