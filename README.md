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
│  MemoryStore（长期记忆，跨重启）                │
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
| 新会话 | `⌘⇧N`，或面板顶栏 `＋` |
| 停止当前任务 | `Esc`，或面板里的停止条 |
| 收起面板 | 无任务时按 `Esc`，或顶栏 `⌃`（只留一条顶栏） |
| 睡眠 | 顶栏 `☾`，停掉聆听与后台任务；再点一次唤醒 |
| 打断播报 | 按 `⌥V` 直接开口，或点停止条 |

## 构建

```bash
./native/make-signing-identity.sh  # 一次性：造固定签名身份（不做的话每次构建都要重新授权）
./native/build.sh                  # 编译 + 装到 ~/Applications + 重装 LaunchAgent + 重启
./native/build.sh --no-restart     # 只构建，不碰 launchd
```

**改了 `ui/`、`native/`、`brain/`、`models/` 任何一处都要重跑**——资源是拷进 `.app` 的。尤其注意：Brain 优先从 Bundle 加载，改 `.py` 后重启 Brain 不会生效，必须重新构建。

## 配置

`~/.jarvis/config.json`（菜单栏 → 打开配置文件）。改完从菜单栏「重启大脑」生效。

```jsonc
{
  "deepseek": { "model": "deepseek-chat" },       // api_key 留空，走 Keychain
  "search":   { "backend": "auto" },              // 有 tavily/brave key 就用，否则 DuckDuckGo
  "tools":    { "fs_roots": ["~"], "allow_shell": false,
                "shell_unrestricted": false,                // true = 摘掉命令黑名单
                "auto_approve": [] },                       // 写进来的工具不再弹确认

  "tts":      { "backend": "neural", "metallic": true,
                "max_chars_per_chunk": 80 },                // 长句切段合成，首音更早；0 = 关
  "wake_word":{ "enabled": true, "score": 1.5, "threshold": 0.25 },
  "memory":   { "enabled": true, "max_recall": 8 },           // 长期记忆，见下

  "voice_input": { "locale": "zh-CN",
                   "silence_timeout": 0.9,    // 说完之后静音多久收句
                   "final_wait": 0.6,         // 收句后等识别器终版结果的上限
                   "idle_timeout": 30.0,      // 一个字都没听到就自动关麦
                   "max_seconds": 60.0,       // 单句硬上限
                   "punctuation": true,
                   "contextual_strings": [] } // 额外的专有名词，提高这些词的识别率
}
```

面板透明度不在这个文件里——它由面板顶栏的 **◐** 滑块调，存在 `NSUserDefaults`
（`defaults read com.jarvis.desktop JarvisPanelOpacity`），改完立刻生效、重启保持。

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
（工具结果隔得太远时开头的提示压不住）。万一整句滑成中文，TTS 会跳过这句语音、
只保留屏幕文字；英文句中的短中文词则转成拼音，仍由 Jarvis 音色朗读。

## 工具

固定工具集，没有「让模型自己拼命令行」这条路（`shell_run` 除外，见下）。
平时 28 个；**Agent 模式 35 个**（见下一节），因为 grep/后台进程这类东西
不该出现在「现在几点」的候选项里，每一轮都带着它们的 Schema 也是白烧 token。

| 由谁执行 | 工具 |
|---|---|
| ObjC 宿主 | `app_open` `app_quit` `app_list_running` `url_open` `finder_reveal` `clipboard_read` `clipboard_write` `system_notify` `system_info` `calendar_events` `mail_unread` `wechat_read` `media_control` |
| Python Brain | `fs_list` `fs_read` `fs_search` `fs_write` `fs_move` `web_search` `web_fetch` `memory_save` `memory_recall` `memory_list` `memory_update` `memory_forget` `task_history` `shell_run` |
| 仅 Agent 模式 | `file_edit` `file_restore` `grep` `glob` `shell_output` `shell_kill` `shell_list` `todo_write` |
| 会话自身 | `agent_enter`（普通对话里发现「这活得连续动手做」时，模型自己切进 Agent 模式） |

原生那半留在 ObjC，因为 **TCC 权限按 app bundle 授予**：Python 子进程去发 Apple Events
会让授权归属漂到解释器上，弹窗写的是 "Python" 而不是 "J.A.R.V.I.S."。

风险分级 L0–L4，**L2 起弹确认框**（`fs_write` / `fs_move` / `app_quit` / `shell_run`）。
写进 `tools.auto_approve` 的工具跳过确认。
日历、邮件和微信虽是只读，但结果会进入当前模型上下文，也按 L2 处理并在读取前确认。

## Agent 模式

⌥A 开关，或者让 Jarvis 自己调 `agent_enter` 进来。开着的时候顶栏下面多一条状态带：
**工作目录 / 权限档位 / 第几步 / 待办清单**——这四样是任务跑起来之后最需要随时看见的，
所以不藏进菜单。

它和普通对话共用同一个会话循环，只换四样东西：

| | 普通对话 | Agent 模式 |
|---|---|---|
| 步数上限 | 8 轮工具 | `agent.max_steps`（默认 60） |
| 工具集 | 28 个 | 35 个（多编辑、检索、后台进程、待办） |
| 确认 | L2 起一律弹框 | 按权限档位放宽，见下 |
| 播报 | 每段回复都念 | **只念最终结论**，中间步骤静音 |

另起一套循环会立刻分叉成两套都得维护的东西——语音、记忆、双语字幕、任务日志
全挂在原来那条链路上。所以是「同一条路，换四个参数」。

### 播报：只念最终结论

一轮 Agent 任务会产生几十条中间叙述和大段路径、代码、diff，全念一遍会把人淹掉。
所以中间步骤全程静音，只有**后面不再跟工具调用的那一次回答**才解除静音、
照常英文播报 + 中英双语字幕。语言规则本身一个字没改（见「语言」一节），
改的只是「哪些句子进 TTS」。

中间那句「接下来我要…」不进回答气泡，走 `agent_note` 显示成一行灰字：
留在气泡里的话，用户会以为任务已经做完了，而它后面还跟着十几个工具调用。

### 权限档位

| 档位 | 编辑文件 | 只读命令 | 写操作 / 退出应用 / 读私人数据 |
|---|---|---|---|
| 每步确认 `ask` | 确认 | 确认 | 确认 |
| 自动改文件 `accept_edits`（默认） | 直接跑 | 直接跑 | 确认 |
| 全免确认 `bypass` | 直接跑 | 直接跑 | 直接跑 |

「只读命令」按整条命令的第一个词判定，**带管道或 `&&` 的复合命令一律不算只读**
——`git log | xargs rm` 也是 git 开头。

确认框在 Agent 模式下多一个「本次会话内总是允许」：一个任务里同一类操作要点十几次头，
人就会直接去开 `bypass`，那是把所有闸一起拆了。这个按钮只放行这一个工具，
**只活在内存里，新会话即失效**——为了跑完手上这件事点的「总是」，
不该在下次开机后还静默生效。要持久化就写 `tools.auto_approve`。

### 上下文压缩

历史超过 `agent.compact_after`（默认 30 条）时，把最早的一批交给模型压成摘要，
保留最近 1/3 原文。摘要明确要求保住**改过哪些文件、跑过什么命令、结论是什么、
还有什么没做**——直接裁掉最早那些消息更省事，但 Agent 会因此忘记自己开头改过什么，
然后把做过的事再做一遍。宁可多打一次请求，也不能让它失忆。

### 工作目录

模型给的相对路径按它解析（Brain 是 launchd 拉起来的，cwd 是 `/`，
不给锚点的话 `src/main.py` 会解析到 `/src/main.py`）。工作目录下的
`JARVIS.md` / `CLAUDE.md` / `AGENTS.md` 会作为项目约定注入上下文，
第一层目录列表也一并给出去，省掉开局那次必然的 `fs_list`。

### 后台进程

`npm run dev`、`tail -f` 这种不会自己结束的东西用 `run_in_background` 起，
立刻返回 `shell_id`，之后 `shell_output` 取**增量**（取过就不再重复给，
否则上下文会被同一批日志灌满）、`shell_kill` 收工。
子进程一律 `start_new_session=True` 单独成组——不这样的话超时后 kill 掉的只有
`/bin/zsh` 本身，它 fork 出去的编译进程会变成孤儿继续吃 CPU。
**新会话会把所有后台进程收掉**：没人再管它们了，留着只会变成谁也不知道还在跑的东西。

### 配置

```jsonc
"agent": {
  "enabled": false,             // 重启后的默认状态；面板 ⌥A 随时切
  "workspace": "~",
  "permission_mode": "accept_edits",
  "max_steps": 60,
  "compact_after": 30,
  "context_files": ["JARVIS.md", "CLAUDE.md", "AGENTS.md"],
  "stream_lines": 200,          // 单条命令实时回显给面板的最大行数
  "buffer_lines": 2000          // 后台进程保留的输出行数
}
```

### 微信读取（只读，没有发送能力）

原则：**读可以不完整，但必须真实。**
完整推导见 [`refs/Jarvis微信读写能力技术方案.md`](refs/Jarvis微信读写能力技术方案.md)。

`wechat_read` 不截屏、不使用 OCR，也不注入微信进程。Jarvis 宿主在获得“完全磁盘访问”
后，只读 macOS 通知中心数据库里 `com.tencent.xinwechat` 的结构化 plist：会话名、群内
发言人、正文、时间和 UUID 来自同一条通知原子记录，因此不会把联系人和另一条消息错配。

通知按 UUID 去重归档到 `~/.jarvis/wechat/notifications.json`（目录权限 `0700`、文件
权限 `0600`），最多保留 2000 条。支持 `unread`、`recent_sessions`、`chat_history`、
`contacts` 和 `status`；`chat_history` 必须指定 `contact`，不认识的 mode 直接报错而不是
悄悄按默认值查。覆盖边界必须如实显示：只能读取产生过 macOS 通知的收到消息，不能读取
自己发出的消息、静音会话或启用归档前已从通知中心清除的旧消息；`unread` 是按徽标数从
最新通知里截取的近似值，不是微信标记的未读。

**没有微信发送工具，也不要再加。** 三条自动化路径都实测封死：聊天区是自绘界面，
Accessibility 树只有关闭/最小化按钮；窗口内容捕获被微信屏蔽；本地库是 SQLCipher 加密、
密钥在进程内存里，读它要关 SIP。剩下键鼠模拟那条路能把事件投出去，但拿不到联系人 ID、
消息 ID 和发送回执——**程序按了回车，不等于微信发给了对的人**，"已发送"只能靠猜。

实测还撞上一个更基本的障碍：微信关掉窗口不退进程，此时 `CGWindowList` 照样报出一个
尺寸像模像样的窗口、AX 也报得出坐标，但它从未被合成绘制，那块屏幕上画的是壁纸。
激活、`open -a`、点「窗口 → 聊天」菜单都恢复不了。按坐标盲点的后果是点到别的应用上。

要自动发送，只能走企业微信 / 微信客服等提供稳定联系人 ID 和发送回执的官方 API。
`shell_run` 默认禁用，开启后仍有命令黑名单（rm -rf / sudo / 磁盘操作 / 下载即执行 …），
`tools.shell_unrestricted = true` 可以摘掉黑名单、并把超时上限从 120s 放宽到 600s。
文件工具全部经过路径闸门：越出 `fs_roots` 或命中 `.ssh` / Keychains 一律拒绝。

### 播放器控制

`media_control`：`toggle` / `play` / `pause` / `next` / `previous` / `volume_up` /
`volume_down` / `like` / `status` / `search_play`。默认自动挑当前在放的播放器，也可以
`player` 点名。检索播放使用 action=search_play、query=歌曲名、player=netease。

**网易云音乐没有 AppleScript 字典**，`tell application "网易云音乐" to playpause` 这条路
根本不存在——这就是它以前只能被打开、不能被控制的原因。实际走的是三条通道：

| 通道 | 用在哪 | 要什么权限 |
|---|---|---|
| MediaRemote（私有框架，`dlopen`） | 默认路径，播放/暂停/切歌 | 辅助功能 |
| System Events 点「控制」菜单 | 总线被浏览器抢走时、以及喜欢/App 内音量 | 辅助功能 + 自动化（系统事件） |
| 媒体键 HID 事件 | 前两条都不适用时兜底 | 辅助功能 |

调一个原生工具而不惊动整个 App：

```bash
~/Applications/Jarvis.app/Contents/MacOS/Jarvis --tool media_control action=status
~/Applications/Jarvis.app/Contents/MacOS/Jarvis --tool media_control action=play player=netease
```

⚠️ **这个入口验证不了权限。** 从终端里跑，TCC 的"责任进程"是终端而不是 Jarvis.app，
借的是终端已有的辅助功能/完全磁盘访问授权。它只能验业务逻辑，权限要看 App 自己的
启动日志：`grep 辅助功能权限 /tmp/jarvis.log`。

## 长期记忆

Jarvis 的自我身份不再依赖模型提示词，权威文件是 ~/.jarvis/identity.json：名称、
创造者 Frank、诞生日 2026-08-01、职责、称呼与原则都由本地 Brain 读取。切换
DeepSeek、Claude 或其他兼容模型不会改变这份身份。

低歧义指令先走本地快速路由，不请求聊天模型：身份/诞生日/运行时长、时间日期、
网易云搜索播放与常用播放控制、打开应用。复杂对话才进入当前配置的模型，因此即使
API 暂时不可用，这些基础能力仍能工作。

跨会话、跨重启都还在的一小撮事实与经历——"这个人是谁、他偏好什么、手上在做什么、
还有哪些承诺没有完成"。
和 `session.history` 分得很清：那是这一轮的短期上下文，按「新会话」就没了；这里的不会。

存在 `~/.jarvis/memory.json`，纯文本，可以直接看、直接改、直接删。

```jsonc
{"id": "592e070f", "text": "用户偏好简短的回答", "kind": "preference",
 "subject": "user:reply-style", "source": "user", "confidence": 1.0,
 "tags": ["style"], "created": 1785590139, "updated": 1785590139, "used": 3}
```

| kind | 含义 | 是否常驻上下文 |
|---|---|---|
| `self` | Jarvis 对自己的认知：诞生日、创造者、身份 | ✅ 每轮都注入 |
| `identity` | 用户是谁：姓名、称呼、身份、设备 | ✅ 每轮都注入 |
| `preference` | 偏好与习惯 | ✅ 每轮都注入 |
| `relationship` | 人物及其与用户的关系 | 按当前这句话检索 |
| `project` | 手上在做的事 | 按当前这句话检索 |
| `lesson` | 从成功或失败中形成的经验 | 按当前这句话检索 |
| `fact` | 其他事实 | 按当前这句话检索 |
| `episode` | 重要的共同经历或已完成任务 | 按当前这句话检索 |
| `commitment` | 承诺、待办、未来事项 | pending 时每轮最多注入 5 条 |

**检索是关键词重叠，不是向量。** 中文按 2-gram 切、英文按词切，分数用 query 长度归一，
再按新鲜度微调。几百条这个量级完全够用，而且零依赖——上向量就得引嵌入模型，
会把 Brain「只用标准库」这条底线打掉。`identity` / `preference` 不参与检索、直接常驻，
因为这两类不该靠关键词碰运气。

**写入只走 `memory_save` 工具，不做隐式抓取。** 隐式抓取会把闲聊噪音塞满记忆，
而且用户无从知道 Jarvis 到底记了什么。同一 `kind + subject` 会**就地更新**；没有
`subject` 时再用 token Jaccard ≥ 0.6 判断，避免"我叫 X"改成"我叫 Y"留下冲突记录。
承诺完成或事实被纠正时用 `memory_update` 修改原条目。重要多步骤/写操作任务完成后，
系统只沉淀一条简短 `episode`，详细工具证据仍留在受限的 `tasks.json`，不会复制进长期记忆。

上限 500 条、单条 600 字、文件最大 512 KB、每轮注入最多 8000 字；超限按
(命中次数, 更新时间) 淘汰，`self`/`identity`/`preference`（内置身份 + 常驻类别）永不淘汰。
记忆文件坏掉不会让 Brain 起不来——改名成 `.corrupt` 后从空的重新开始。

### 主动提醒

用户明确说“在某个时间提醒我”时，Jarvis 会保存一条带 `remind_at` 的 pending
`commitment`。到点后由 Brain 本地检查并调用 macOS 通知，不需要额外请求模型。
默认安静时段 22:30–08:00、同一事项两次提醒至少间隔 120 分钟、每天最多 6 次；
这些值可在 `config.json` 的 `proactive` 段调整。没有明确时间的普通承诺不会主动弹窗。

## 对话面板

按 `Jarvis_对话框功能与交互逻辑.md` 实现。八个状态、停止入口、权限确认、文件结果卡片
都是**真事件驱动**的，没有演示分支——面板上出现的每一条都对应后端真发生过的事。

### 状态

| 状态 | 顶栏 | 触发 |
|---|---|---|
| `idle` | 琥珀常亮 · 准备就绪 | 无任务 |
| `listening` | 亮白快脉冲 + 音频条 | 麦克风开着 |
| `transcribing` | 金色快脉冲 · 正在识别 | 麦克风已关，在等终版结果 |
| `thinking` | 琥珀慢呼吸 | 等模型 |
| `executing` | 中速脉冲 · **正在打开 Safari** | 跑工具，顶栏写的是具体动作 |
| `speaking` | 暖白 | 流式回复 / 播报中 |
| `sleeping` | 灰 + 遮罩 | 点了 ☾ |
| `error` | 红 | 当前任务失败 |

文档 §4.1 给每个状态指定了青/紫/琥珀/暖白，这里**刻意没照做**：面板和桌面上那颗球
必须看着是同一个东西。状态改用亮度和脉冲节奏区分，只有 `error`（红）和 `sleeping`（灰）
离开琥珀家族，因为这两个本来就该跳出来。

状态由**宿主裁决**，优先级 `sleeping > transcribing > listening > speaking > Brain 状态`。
Brain 可以用 `detail` 把通用文案覆盖成具体动作（`{"state":"executing","detail":"正在打开 Safari"}`）。

### 顶栏

`◐` 透明度 · `☾` 睡眠 · `＋` 新会话 · `⌃` 收起

- **睡眠 ≠ 收起。** 睡眠会停掉麦克风、唤醒词、模型请求和播报，文字和语音提交都被挡住；
  收起只是把窗口缩成一条顶栏，语音唤醒照常工作。
- **收起高度由页面量出来传给宿主**（`collapse` 消息带 `header`），不是两边各写一个常数。
  收起时要临时放开 `NSPanel.minSize`，否则 `setFrame` 被静默钳回 360，看着像「点了没反应」。
- 新会话清当前上下文并换 `session_id`，**长期记忆不动**。

### 工具卡片与确认

工具卡片头部是「动作 · 目标」（`打开应用 · Safari`），下面是步骤。
步骤只记真实发生过的系统动作——文档 §10.2 要求「仅展示可验证的系统动作」，
所以不会出现「正在校验工具权限」这种没人能验证的步骤。

`fs_search` / `fs_list` 的结果会渲染成**可多选的文件卡片**，选中后可「在访达中显示」或
「打开所选」。走宿主的 `NSWorkspace` 而不是 `open(1)`：TCC 按 bundle 归属，
从宿主进程发起授权才算在 Jarvis.app 头上。一条没选时两个按钮是灰的。

确认框必须回答四件事——动作、目标、**能不能撤**、风险等级：

```
需要确认 · 风险 L2
操作    移动文件
目标    ~/Desktop/a.txt  →  ~/Desktop/b.txt
可恢复  把文件从目标位置移回原路径即可
```

撤法写不出来的（`shell_run`）显示红色的「无法自动撤销」，**不编**。
含糊的安慰比没有更危险。取消后卡片写「已取消，未做任何修改」。

### 键盘

`Enter` 发送 · `⌥Enter` 换行 · `⌘⇧N` 新会话 · `⌥A` Agent 模式 · `⌥Space` 面板 · `⌥V` 说话。

`Esc` 有优先级，顺序不能反：**确认框 > 停止收音 > 停止任务 > 收起面板**。
任务跑着的时候按 Esc 却把面板收了，是最容易吓到人的一种。

### 语音与输入框

实时转写**直接落进输入框**（文档 §8.1），接在开麦前已有的内容后面。
这样识别失败时那半句还留在手边可以改，而不是凭空消失。收到终版文本后输入框清空、
消息上屏。没听清则把开麦前的原文放回去。

---

## 语音

| 环节 | 实现 | 状态 |
|---|---|---|
| 唤醒词 | sherpa-onnx KWS，中英双语 3M 模型，词表 `models/kws-jarvis.txt` | 中英文均可，离线语料命中 8/9、误触 1/11，真机已触发过 |
| 采集 | `AudioHub`：AVAudioEngine + `setVoiceProcessingEnabled:`（AEC/降噪/AGC） | ✅ |
| 识别 | `SFSpeechRecognizer`，本机 zh-CN / en-US / en-GB **均支持离线** | ✅ |
| 收句 | 自适应噪声门 + 文本停顿双判据，收句后再等终版结果 | ✅ |
| 播报 | Piper `jarvis-high`；短中文词转拼音 → ffmpeg 金属链 | ✅ |
| 回声抑制 | 半双工门（播报/收音时暂停唤醒）+ 系统 Voice Processing | ✅ 前两层 |

### 识别准确率与速度

四件事分别针对准确率和延迟，都在 `native/Audio/VoiceInputController.m`：

- **专有名词提示**（`contextualStrings`）：唤醒词、固定术语 + **当前在跑的所有应用名**，
  每次开麦重取一遍。识别器对"贾维斯""网易云音乐"这类专名本来最容易听错，
  提前告诉它有这些词之后基本一次听对。这是性价比最高的一招。
- **`taskHint = Dictation` + `addsPunctuation`**：选错 hint 会让识别器用错语言模型，
  短句尤其明显；标点让字幕好读，也让 TTS 的断句更自然。
- **自适应噪声门取代固定阈值**：Voice Processing 的 AGC 会把安静房间的底噪也拉到
  任何固定阈值之上，于是"距上次有声"永远在刷新，静音判定形同虚设。改成跟着环境走的门
  （底噪跌得快、涨得慢）之后，`silence_timeout` 才敢从 1.6s 降到 0.9s。
  吵闹环境（电视、空调）音频永远不会静，所以另有一条兜底：识别器 2.2×`silence_timeout`
  没吐出新字就收句。
- **收句后等终版结果**（`final_wait`）：以前是直接 `cancel` 掉识别任务、用最后一版
  partial。终版经过重打分、带标点，明显更准。代价 ≤0.6s，而静音等待省下的 0.7s
  把它抵掉还有富余——**净效果是又快又准**。

延迟上还去掉了两处固定开销：授权状态改成先看同步的 `authorizationStatus`
（以前每次开麦都发两趟 XPC 请求授权），`SFSpeechRecognizer` 改成复用并在启动时预热
（冷启动第一次开麦要现加载语言资源，能明显感觉到卡一下）。

`idle_timeout`（默认 30s）：开麦后一直没识别出任何文字就自动关麦——
麦克风一关，没有其他 tap 时 `AudioHub` 会顺手把 `AVAudioEngine` 停掉。
判据必须按**开麦后的绝对时长**算，不能按"距上次有声"，理由同上：AGC 会把它刷到永不超时。

### 定稿音色

```bash
cd voices && uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python soundfile piper-tts pypinyin
```

没建 venv 也能跑——会自动回退系统 `say`，只是不像 Jarvis。
合成走常驻进程 `voices/synth_server.py`：每次新起进程要 3.0 秒加载模型，常驻后约 1.0 秒/句。

**金属感来自 ffmpeg 滤镜链，不是音色本身**（`aecho` 三重超短延时 + `chorus` +
`bass`/`treble` + `highpass=90,lowpass=8500`，带限那条最关键）。

### 延迟：瓶颈在合成，不在模型

觉得"对话慢"时先看 `~/.jarvis/brain.log`，每轮都有一行账单：

```
一轮 首字 0.60s 首音 6.14s 总 1.22s
播报  5248ms neural       I run this Mac for you, sir — open apps,
```

三个数各指一口锅：**首字**慢 = 网络或模型；**首音**慢 = 合成；**总时长**远大于首音 = 回复太长。
实测 DeepSeek 首字 0.5~0.7s、整轮文本 1s 出头——**文本这段从来不是问题**。

问题在合成：`jarvis-high` 是 Piper 的 **high 档**模型，这台 M2 Air 上 **RTF ≈ 1.2**
——合成一句话的时间不比念完它短，系统一忙恶化到 3~5 倍。这是模型体量决定的，
换 medium 档能快约 4 倍，但那就不是定稿的那个音色了。在保留音色的前提下能做的四件事都做了：

| 改动 | 效果 |
|---|---|
| 只预热单一 Piper 音色 | 不再携带或加载第二套中文模型，避免无效常驻内存 |
| 短句按内容缓存（`~/.jarvis/tts/phrases/`） | 重复的句子 0.00s，跨重启有效。最多 200 条且总量不超过 50MB |
| 长句在从句处切段（`tts.max_chars_per_chunk`，默认 80） | 首音提前约一半；代价是分段处语调略平。设 0 关掉 |
| 中文边界处理 | 短词转拼音；整句中文格式错误只显示、不播报 |

**⚠️ 中文滑落会拖垮整段对话。** 模型偶尔不守"英文在前"、整句吐中文，
现在没有第二套中文模型：英文回复中的短中文词转成拼音后继续使用 Jarvis 音色；
如果模型整句输出中文，则屏幕正常显示，但跳过该句播报，避免又慢又不像同一个人。

嫌慢又不想换音色，`tts.backend` 改 `system` 是随时可退的一档：
同条件三句话实测 11s vs 定稿音色 64s。

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
- **`launchctl bootout` 是异步的。** 它返回时进程可能还活着；不等就 `bootstrap`，
  launchd 认下新 pid，**旧进程从此脱离管理、永远不退**。两个宿主各拉一个 Brain 抢
  同一个 `brain.sock`，后绑定的顶掉先绑定的，面板一直显示「未连接」，
  brain.log 疯狂刷「宿主已连接 / 宿主断开 / Bad file descriptor」。
  两道防线：build.sh 在 bootout 后**轮询等进程真的消失**（超时强杀）；
  App 启动时**终止所有同 bundle id 的其它实例**（新的赢——它才是 launchd 认的那个）。
  后者同时也挡住"从访达或系统设置里双击了 Jarvis.app"这条路。
- **收音超时不能按「距上次有声」算。** Voice Processing 的 AGC 会把安静房间的底噪
  拉到阈值以上，那样麦克风永远关不掉。没有转写结果时必须按开麦后的绝对时长判。
- **面板毛玻璃要用 `NSVisualEffectView`。** WKWebView 关掉 `drawsBackground` 后，
  CSS 的 `backdrop-filter` 没有可模糊的内容。
- **毛玻璃层和 WKWebView 必须是兄弟，不能是父子。** 调透明度改的是
  `NSVisualEffectView.alphaValue`，网页要是它的子视图，文字会跟着一起淡掉——
  那就成了"调可读性"而不是"调透明度"。两层平铺在一个容器 NSView 里，网页在上。
  同时页面那层暗色衬底也要跟着走：只调毛玻璃，浅色壁纸下文字会糊；只调衬底，
  背后永远是一块磨砂。
- **球体状态由宿主裁决**（收音 > 播报 > 大脑状态）。直接照搬 Brain 的 state，
  会在音频还在播时就提前熄掉。
- **嵌入的 dylib 要单独签名**，否则进程被 `SIGKILL (Code Signature Invalid)` 秒杀。
- **ad-hoc 签名会让辅助功能权限每次构建后失效。** designated requirement 是
  `cdhash H"…"`，二进制一改就变，TCC 存的授权立刻不匹配——但**系统设置里的开关看着还是开的**，
  `AXIsProcessTrusted()` 却返回 false。症状是"权限明明给了，播放器还是控制不了"。
  修法是用固定的自签身份（`./native/make-signing-identity.sh`），requirement 变成
  `certificate leaf = H"…"`，只跟证书绑定，重新构建不影响。
- **`--tool` 从终端跑测不出权限问题。** TCC 按"责任进程"归属，终端启动的子进程算终端头上，
  会借到终端已有的授权。看 App 真实权限只能看它自己的启动日志。
- **bash 变量后面紧跟中文标点要加花括号。** `"$NAME」"` 里的 `」` 是多字节字符，
  bash 会把它算进变量名，`set -u` 下直接 `unbound variable`。写 `${NAME}」`。
- **`MRMediaRemoteSendCommand` 返回真 ≠ 播放器照做了。** 它报的是"命令送出去了"。
  网易云冷启动后的头几秒，菜单已经在了、菜单项也报 `enabled`，这时候不管是发总线命令
  还是点"播放"菜单，都会安静地什么都不发生。唯一可靠的做法是**点完回读播放状态，
  没生效就再点一次**（`MediaController` 里 `netEaseBecomesPlaying:` / 最多 5 次）。
- **收起面板前要放开 `NSPanel.minSize`。** 它是 360×360，`setFrame` 到 56px 高会被
  **静默钳回**——没有报错、没有日志，看着就是「点了收起没反应」。
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
ui/         wallpaper.html（球体）、conversation.html（对话面板，配色与球体同源）
voices/     定稿音色模型 + 合成脚本 + .venv
models/     唤醒词模型与音素词表
vendor/     sherpa-onnx 头文件与 dylib
refs/       开源参考代码（见 refs/README.md 的协议说明）
```
