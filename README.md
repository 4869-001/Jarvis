# J.A.R.V.I.S.

macOS 桌面助手。壁纸层的球体、对话面板、菜单栏、DeepSeek 大脑、本机工具执行、语音
——全部在一个 `Jarvis.app` 里，不是几个脚本拼起来的。

```
┌──────────────────────────────────────────────┐
│ Jarvis.app · Objective-C                     │
│  OrbWindow           → ui/wallpaper.html     │
│  ConversationPanel   → ui/conversation.html  │
│  MenuBar / 全局快捷键 / 权限                   │
│  AudioHub → 唤醒词(sherpa-onnx) + 识别(SFSpeech)│
│  SpeechPlayer（播报 + 振幅驱动球体）            │
│  NativeToolExecutor（NSWorkspace / 剪贴板 …）  │
│  BrainProcessManager + BrainIPCClient        │
└───────────────────┬──────────────────────────┘
                    │ Unix Domain Socket / JSON Lines
┌───────────────────▼──────────────────────────┐
│ Python Brain（只用标准库）                     │
│  SessionCoordinator（状态机 / 工具循环）        │
│  DeepSeek Provider（流式 + 工具调用）           │
│  ToolRouter → 风险分级 → 确认                  │
│  TTS：定稿音色 / 系统音色 → ffmpeg 金属链        │
└──────────────────────────────────────────────┘
```

## 用起来

| 操作 | 方式 |
|---|---|
| 打开对话 | `⌥Space`，或菜单栏图标 → 对话…，或双击 App |
| 说话 | `⌥V`，或说「贾维斯」，或点面板里的麦克风 |
| 新会话 | `⌘⇧N` |
| 收起面板 | `Esc` |
| 打断播报 | 按 `⌥V` 直接开口，或点面板里的停止键 |

## 构建

```bash
./native/build.sh              # 编译 + 装到 ~/Applications + 重装 LaunchAgent + 重启
./native/build.sh --no-restart # 只构建，不碰 launchd
```

**改了 `ui/`、`native/`、`brain/`、`models/` 任何一处都要重跑**——资源是拷进 `.app` 的。尤其注意：Brain 优先从 Bundle 加载，改 `.py` 后重启 Brain 不会生效，必须重新构建。

## 配置

`~/.jarvis/config.json`（菜单栏 → 打开配置文件）。改完从菜单栏「重启大脑」生效。

```jsonc
{
  "deepseek": { "model": "deepseek-chat" },       // api_key 留空，走 Keychain
  "search":   { "backend": "auto" },              // 有 tavily/brave key 就用，否则 DuckDuckGo
  "tools":    { "fs_roots": ["~"], "allow_shell": false },
  "tts":      { "backend": "neural", "metallic": true },
  "wake_word":{ "enabled": true, "score": 1.5, "threshold": 0.25 },
  "voice_input": { "locale": "zh-CN", "silence_timeout": 1.6 }
}
```

### API Key

```bash
cd brain && python3 -m jarvis_brain set-key      # 存进 Keychain
```

**不要指望环境变量**：App 由 LaunchAgent 拉起，拿不到 shell 的 `DEEPSEEK_API_KEY`。
Brain 启动日志会写明 key 是从哪读到的。

## 语言

**Jarvis 一律用英文回答**，不管你用什么语言问、用什么语言唤醒它。
面板里英文正文下方跟一行中文字幕。

实现上是一次调用出两份：模型先写英文，再用 `[[ZH]]` 分隔，然后写中文翻译。
Brain 按分隔符把流拆成两路——**只有英文那路进 TTS**，中文只进字幕。
不另开一次翻译请求，所以英文能立刻流式出来并开始播报。

三处容易塌的地方都堵过了：用户明确要求「用中文回答」、工具结果里全是中文、
以及模型在调工具那一轮写中文前言。系统提示之外还在每次请求末尾贴一条格式提醒
（工具结果隔得太远时开头的提示压不住）。万一还是漏了中文，TTS 会按内容
改用中文音色，不会把中文硬塞给英文引擎念成乱码。

## 工具

17 个，固定工具集，没有「让模型自己拼命令行」这条路。

| 由谁执行 | 工具 |
|---|---|
| ObjC 宿主 | `app_open` `app_quit` `app_list_running` `url_open` `finder_reveal` `clipboard_read` `clipboard_write` `system_notify` `system_info` |
| Python Brain | `fs_list` `fs_read` `fs_search` `fs_write` `fs_move` `web_search` `web_fetch` `shell_run` |

原生那半留在 ObjC，因为 **TCC 权限按 app bundle 授予**：Python 子进程去发 Apple Events
会让授权归属漂到解释器上，弹窗写的是 "Python" 而不是 "J.A.R.V.I.S."。

风险分级 L0–L4，**L2 起弹确认框**（`fs_write` / `fs_move` / `app_quit` / `shell_run`）。
`shell_run` 默认禁用，开启后仍有命令黑名单（rm -rf / sudo / 磁盘操作 / 下载即执行 …）。
文件工具全部经过路径闸门：越出 `fs_roots` 或命中 `.ssh` / Keychains 一律拒绝。

## 语音

| 环节 | 实现 | 状态 |
|---|---|---|
| 唤醒词 | sherpa-onnx KWS，中英双语 3M 模型，词表 `models/kws-jarvis.txt` | 中英文均可，离线语料命中 8/9、误触 1/11，真机已触发过 |
| 采集 | `AudioHub`：AVAudioEngine + `setVoiceProcessingEnabled:`（AEC/降噪/AGC） | ✅ |
| 识别 | `SFSpeechRecognizer`，本机 zh-CN / en-US / en-GB **均支持离线** | ✅ |
| 播报 | 中文 Kokoro `zm_029` / 英文 Piper `jarvis-high` → ffmpeg 金属链 | ✅ |
| 回声抑制 | 半双工门（播报/收音时暂停唤醒）+ 系统 Voice Processing | ✅ 前两层 |

### 定稿音色

```bash
cd voices && uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python kokoro-onnx soundfile "misaki[zh]" piper-tts
```

没建 venv 也能跑——会自动回退系统 `say`，只是不像 Jarvis。
合成走常驻进程 `voices/synth_server.py`：每次新起进程要 3.0 秒加载模型，常驻后约 1.0 秒/句。

**金属感来自 ffmpeg 滤镜链，不是音色本身**（`aecho` 三重超短延时 + `chorus` +
`bass`/`treble` + `highpass=90,lowpass=8500`，带限那条最关键）。

## 排障

| 现象 | 看哪里 |
|---|---|
| 面板打不开 / 图标没了 | `/tmp/jarvis.log` |
| 说了没反应、回复不对 | `~/.jarvis/brain.log` |
| 唤醒词不触发 | `/tmp/jarvis.log` 里「唤醒词输入峰值」，接近 0 就是采集或重采样断了 |
| 球体卡在某个状态 | `~/.jarvis/state`；菜单栏「重启大脑」 |
| 改完代码没生效 | `./native/build.sh`（Python 也要重打包！见踩坑第一条） |
| 完全重来 | `./native/build.sh` |

终端里直接跟大脑对话（不用起 App）：

```bash
cd brain && python3 -m jarvis_brain chat      # 交互
python3 -m jarvis_brain doctor                # 自检：key / 搜索 / 模型连通性
```

## 踩过的坑（都是实测，别再踩一遍）

- **改了 Python 代码必须重新构建。** Brain 优先从 `Jarvis.app/Contents/Resources/brain/`
  加载代码（`JarvisPaths.m` 的 `brainDirectory` 先查 Bundle 再查项目目录）。改了 `.py`
  文件直接重启 Brain **不会生效**——跑的仍是 Bundle 里上次构建时的旧副本。
  症状：新工具报「宿主不认识」、改过的逻辑没变化。修：`./native/build.sh` 重打包。
- **麦克风降混必须自己做。** 这台 M2 Air 输入是 3 声道，开 Voice Processing 后变 7 声道；
  7 声道没有标准布局，`AVAudioConverter` 对它降混会**静默产出全零**且不报错。
  取通道 0 手动降混，下游只做采样率转换。
- **日志只能有一个写入方。** Brain 自己写文件 + NSTask 重定向到同一文件 =
  两个独立偏移量互相覆盖。现在 Brain 只 print，宿主用 `O_APPEND` 接。
- **Brain 需要 ppid 看门狗。** `launchctl bootout` 杀宿主时来不及回收子进程，
  孤儿 Brain 会和新 Brain 抢 socket。macOS 没有 PDEATHSIG，只能自己盯 ppid。
- **收音超时不能按「距上次有声」算。** Voice Processing 的 AGC 会把安静房间的底噪
  拉到阈值以上，那样麦克风永远关不掉。没有转写结果时必须按开麦后的绝对时长判。
- **面板毛玻璃要用 `NSVisualEffectView`。** WKWebView 关掉 `drawsBackground` 后，
  CSS 的 `backdrop-filter` 没有可模糊的内容。
- **球体状态由宿主裁决**（收音 > 播报 > 大脑状态）。直接照搬 Brain 的 state，
  会在音频还在播时就提前熄掉。
- **嵌入的 dylib 要单独签名**，否则进程被 `SIGKILL (Code Signature Invalid)` 秒杀。
- **面板不能用 `NSWindowStyleMaskNonactivatingPanel`。** 那样鼠标点面板不激活 App，
  面板虽成了 key window，键盘事件仍发给前台程序，症状是「点了输入框但打不出字」。
- **测唤醒词的样本必须补尾部静音。** 流式解码靠尾部空白帧把命中定稿；
  音频一喂完就没有后续帧，短样本永远不触发——这是测试方法的坑，不是模型的问题。
  我曾据此误判「英文无法唤醒」，实际英文一直是能用的。
- 本机 **Swift 工具链已损坏**（CommandLineTools 的 modulemap 重复定义 `SwiftBridging`），
  任何 import 系统框架的 Swift 都编不过。ObjC 不受影响，所以全用 ObjC。

## 目录

```
native/     ObjC 宿主（AppDelegate / Window / Audio / Bridge / Process / Tools / MenuBar）
brain/      Python 大脑（只用标准库）
ui/         wallpaper.html（球体）、conversation.html（对话面板）
voices/     定稿音色模型 + 合成脚本 + .venv
models/     唤醒词模型与音素词表
vendor/     sherpa-onnx 头文件与 dylib
refs/       开源参考代码（见 refs/README.md 的协议说明）
```
