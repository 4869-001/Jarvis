# 借鉴代码

从两个开源 Jarvis 项目里挑出来的、值得直接抄的部分。**这些是参考副本，不参与构建**，
壁纸本体（`ui/` + `native/`）跟它们零关系。放这里是为了将来做语音时不用再回去翻源仓库。

共 120KB。

## 出处与协议

| 来源 | 协议 | 约束 |
|------|------|------|
| [RubinTry/assistant-x-openclaw](https://github.com/RubinTry/assistant-x-openclaw) | MIT | 保留版权声明即可，商用无限制 |
| [isair/jarvis](https://github.com/isair/jarvis) | **自定义非商业协议** | 仅限个人/教育/研究；副本须保留版权声明；**衍生作品必须沿用同样条款**；商用需单独授权 |

协议原文在 `licenses/`。自用没问题，但 isair 那份的传染性条款意味着：
**抄它的代码进你的项目，你的项目也会被绑定到非商业协议**。真要商用就重写，别抄。

---

## `wake/` —— 唤醒

### `kws-jarvis.txt` （openclaw，MIT）★ 最值钱

sherpa-onnx KWS 的自定义唤醒词表，直接解决「贾维斯 / jiaweisi / 家卫视」的模糊唤醒：

```
j iǎ w éi s ī  :3.0 #0.02 @贾维斯
JH AA1 R V AH0 S :3.0 #0.02 @Jarvis
```

格式：`音素序列 :提升分 #阈值 @显示名`。中文用带声调拼音，英文用 CMU ARPAbet，
**两种混在同一个文件里，一个模型同时听**。

比 Porcupine 好在：完全免费本地，自定义中文唤醒词不要 AccessKey，模型仅 3.3M。
配套模型 `sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20`（k2-fsa 的 GitHub Release）。

### `wake_detection.py` （isair，117 行）

唤醒后的二级模糊纠错：`difflib` 逐 token 比对别名表，阈值 0.78。
**零内部耦合**，只依赖标准库 + 一个 `debug_log`，换掉那行 import 就能拿走。

### `hotwords.txt` / `text_corrections.txt` （openclaw，MIT）

ASR 热词表 + 识别结果纠错兜底。提升专有名词识别率，成本极低，容易被忽略。

## `echo/echo_detection.py` （isair，567 行）★ 最值钱

防止 TTS 播报把自己再唤醒一次。**这是全部参考代码里最难自己写对的一块**：

- TTS 精确时长跟踪 + 能量基线尖峰判别（区分真人插话 vs 扬声器回声）
- 文本重叠「打捞」：识别到回声尾巴时，保留用户真实追问的部分
- 注释里记了实战坑，比如 Whisper 的回声幻觉会吐出 `…regions like Steneti`

同样零内部耦合，只依赖 `rapidfuzz`。

## `llm/` （isair）

`backend.py`（155 行）+ `openai_compatible.py`（495 行）= 一个写完的 Provider 抽象层。
带一个容易踩的坑修复：`strip_nonstandard_message_fields` —— 严格服务端
（llama.cpp / vLLM）会因为消息里的多余字段返 400。

## `tools/` （isair）

`base.py`（116 行）工具接口，`selection.py`（431 行）工具路由。
后者解决的问题是：工具几十个时全塞进 prompt，小模型会瞎调；
它用 keyword / embedding / LLM 三种策略筛到 3–8 个。

`registry.py` **没抄** —— 它开头硬 import 了一排 builtin 工具，会把整棵依赖树拖进来。
看思路自己写 80 行更划算。

## `tts/tts_piper.py` （openclaw，MIT）

金属感后处理的实现（ffmpeg 滤镜链装配 + 失败回退原声）。
滤镜链本身已经抄进 `../voices/README.md`，这里留实现是为了看它怎么处理
「没有 ffmpeg 时不阻断合成」这类边界。

---

## 没抄的，以及为什么

| | 原因 |
|---|---|
| isair 的 `memory/`（2000+ 行图谱记忆） | 跟需求无关，纯负担 |
| isair 的 `desktop_app/`（PyQt6 界面） | 球体用 WebGL，不需要 |
| isair 的 nutrition / weather / location / web_search | 无关功能 |
| openclaw 的 `openclaw_bridge*.py`（1259 行） | 强绑 OpenClaw Gateway，而它已经卸了 |
| openclaw 的 `assistant_overlay/`（Flutter HUD） | 要装 Flutter SDK，球体不需要 |
| openclaw 的 `src/main.py`（2665 行） | 单文件把 KWS/ASR/TTS/状态机全塞一起，不可读 |

## 源仓库位置

完整仓库还在本地，需要翻更多代码时去这两处：

- `~/Projects/JarvisRefs/assistant-x-openclaw`（15MB，git 完整）
- `~/WorkBuddy/2026-07-31-13-07-14/jarvis`（11MB，无 .git，打包下载的）
