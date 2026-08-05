# Claude ↔ codex 协作笔记

## 2026-08-04 Agent 模式（分支 `feature/agent-mode`）

用户要求「参考 Claude Code / codex，把 agent 核心功能做进对话框，并给最高系统权限」。
第一期已完成并真机验证，**在 `feature/agent-mode` 上，还没并进 main**。

动过的文件里有你也常改的三个：`session.py`、`tools/registry.py`、`ui/conversation.html`。
动手前我先把工作区里未提交的微信那批改动提交了（`535b75d`），所以那部分不会和
agent 的改动混在同一份 diff 里。

设计上只有一句话要记：**Agent 模式不是第二套循环**，是同一个 `_loop` 换四个参数
（步数上限、工具集、确认策略、播报是否静音）。语音、记忆、双语字幕、任务日志全挂在
原来那条链路上，另起一套会立刻分叉成两套都得维护的东西。

几条容易被"顺手简化"掉、但都是踩过才定的：

- **`_speech_muted` 不能删**。Agent 模式中间步骤静音是用户 2026-08-04 明确选的策略
  （原话：只播最终总结，中间步骤静音）。它在 `_run_turn` 的 finally 里必须复位，
  否则异常退出后下一次普通对话会全程哑掉，且现象是"模型答了但没声音"。
- **`_ensure_bilingual` 只在最终那一轮调**。以前每轮都调，中间旁白也会触发翻译请求；
  Agent 一轮有几十条旁白，那是几十次白打的请求。
- **`shell_run` 的读线程不能合回主循环**。直接 `for raw in proc.stdout` 的话，
  不出声的命令（`sleep`、等输入的命令）会把主循环阻塞在 readline 上，超时和取消
  永远轮不到执行。这个 bug 我写第一版时真踩了，测试里有对应用例。
- **`resolve(..., base=)` 是必须的**。Brain 是 launchd 拉起来的，cwd 是 `/`，
  模型写 `src/main.py` 会解析成 `/src/main.py` 被闸门拒掉。第一次真机端到端就撞上了，
  模型白费两步才绕开。fs.py 和 code.py 两边都要传。

真机验证过的：小 bug 修复任务 8s/7 次工具调用；三件事的多步任务 17s/9 次调用，
自己列了待办、用了 grep、跑了测试验证、如实报告了"第 3 件事没有可做的"。

## 2026-08-04 第二期：指挥任意应用（同分支）

新增 `native/Tools/AutomationController.m`，7 个工具：`app_scriptable` /
`app_dictionary` / `app_script` / `menu_list` / `menu_invoke` / `ui_inspect` /
`ui_action`。三条通道按可靠性排序（脚本字典 → 菜单 → 辅助功能），
**不再一个 App 写一个工具**。

真机验证过：Notes 建/读/删备忘录（AppleScript + JXA 都跑通）、菜单点击靠计数变化
证实真的生效、TextEdit 用 AX 填字并用 osascript 独立读回、微信正确落到"没有字典 →
走菜单"这条兜底路。整链路（模型选通道 → 原生执行 → 回报）12s 跑完。

几条实测坑，改之前先看：

- **`URLForApplicationWithBundleIdentifier:@"Safari"` 会返回 `/usr/sbin/universalaccessd`。**
  拿普通名字去问 LaunchServices 得到的结果毫无意义。现在只在名字长得像 bundle id
  时才问它，且要求返回的是 `.app`。
- **`[nil caseInsensitiveCompare:x]` 返回 0，而 0 就是 `NSOrderedSame`。**
  后台守护进程的 `bundleIdentifier` 是 nil，于是"每个名字都能匹配上第一个守护进程"。
  这就是上面那个 universalaccessd 的真正来源。所有名字比对都必须先判空。
- **缺自动化授权的表现不是报错，是卡满整个超时**——Apple Event 一直等 TCC 裁决。
  所以 `runScript:` 先用 `AEDeterminePermissionToAutomateTarget` 预检。
  `app_script` 的 `app` 参数就是喂给预检的。
- **`sdef(1)` 要 Xcode**（本机只有 CommandLineTools 且已损坏），改用 Carbon 的
  `OSACopyScriptingDefinitionFromURL`，是 sdef 内部用的同一个 API。
- **`--tool` 入口验不了自动化权限**，因为责任进程是终端。第一次真正授权要在真 App 里发生。
- **苹果自带应用的中文名读不到**（`displayNameAtPath:` 只给英文），但**菜单项名字是中文的**。
  所以有一张应用名别名表，而 `menu_invoke` 必须传中文菜单名。
- 脚本跑在串行队列不是主线程：被脚本化的 App 卡住时，主线程执行会把整个 Jarvis 冻住。
  `mail_unread` 早就是这么做的，沿用同一套。

## 2026-08-04 第三、四期：子代理 + 工作台（同分支，四期全部完成）

`brain/jarvis_brain/subagent.py` + `subagent_run` 工具；面板加 ⌥W 宽屏两栏。

**子代理不是另一套工具执行**：工具仍走 `SessionCoordinator._execute`（多了个
`subagent=` 参数只为给事件打标记），所以权限档位、确认弹窗、原生转发、任务日志
全都白拿。它只是换了一份历史和一份更小的工具表。三条约束是刻意的：不许递归、
explore 档只给只读工具、报告必须是结论不是过程（见 `REPORT_RULES`）。

### UI 上踩到的三个坑（其中一个是既有 bug）

- **`#log` 的 flex 子项会被压扁。** flex column 的子项默认 `flex-shrink:1`，
  内容一超过可视高度，最高的那几项就被按比例压矮，配上它们自己的
  `overflow:hidden`，表现是「卡片凭空少了半截」。实测 4 张卡片实际占 440px、
  容器被压到 133px，后两张整个看不见。**这是既有 bug**，不是这次引入的——
  只是子代理和 diff 卡片让它变得必现。修法是 `#log > * { flex: 0 0 auto; }`，
  比给单个卡片加 `flex:none` 可靠，新卡片类型不会再踩。
- **`direction: rtl` 那个"保住路径尾部"的老技巧会把非路径文本显示反**：
  glob 模式两个星号加斜杠会倒过来，工作目录 `~/Projects/Jarvis` 显示成
  `Projects/Jarvis/~`。改成 JS 侧 `tailClip()` 截断，`.tool-head .target`、
  `.file .p` 和新加的时间线都换掉了。
- **JS 块注释里不能出现斜杠加星号的组合**：注释里写 glob 例子会提前闭合注释，
  整个脚本从那里开始语法错误。改用 `//` 行注释。`node --check` 能一眼查出来，
  改完 `ui/conversation.html` 建议顺手跑一下。

### 收尾时真机跑出来的两个问题（已修）

- **别名表当时只在 AutomationController 里**，`app_open` 不认识"备忘录"。
  真机上的表现是模型先用中文名开应用失败、自己改口说 Notes 才成功，白花一步。
  现在 `+[AutomationController nameAliases]` 公开出来，`urlForApplicationNamed:`
  也走同一份表。
- **预检把"应用没在运行"当成了错误**。`tell application "X"` 本来就会自己把 X
  拉起来，报错等于让模型多绕一趟 app_open。现在 procNotFound 时替它拉起
  （`activates = NO`，不抢前台）再复检一次权限。

## 2026-08-04 面板收起/展开的动画（同分支）

用户反馈「展开时输入框会从上直接降到下面，很突兀」「缩放要始终紧贴底部」。两个原因：

1. **锚点在顶边**：`setCollapsed:` 里 `frame.origin.y += frame.size.height - target`
   保住的是顶边，展开时底边往下掉五百多像素。改成只改 `size.height`、`origin.y` 不动
   （只有朝上长会顶出屏幕上沿时才下移）。`setWorkbench:` 同样改了。
2. **动画期间用的是收起态布局**：`.collapsed` 要等动画跑完才摘，而收起态 `#body` 是
   `display:none`，footer 于是吊在顶栏下面，直到最后一帧才掉到底部。改成两个方向都用
   展开态布局跑动画，收起态样式只在结束时落地。

为此收起态不再改 footer 内边距和输入框高度（实测只差 1px，但会在最后一帧抖一下），
`body.collapsed #agentBar {display:none}` 也删了——Agent 状态带在收起态要留着，
而且它已经被算进收起高度里，藏掉会让最后一帧凭空塌 61px。

**收起高度的算法改了**：从「面板高度 − 对话区」改成「逐块相加」。前者在收起之后会
退化成「当前窗口高度」（对话区 display:none、高度为 0），于是 Agent 状态带出现或输入框
换行都撑不开窗口，多出来的被切掉。现在用 `ResizeObserver` 盯 header/footer/agentBar，
收起态下变高就重报。

验证方式是逐帧断言而不是"看着顺眼"：在 WKWebView 里模拟窗口高度逐级变化，
每一步都量「输入框底边到窗口底边的距离」，全程必须是 0。13 个采样点全过。

## 2026-08-04 顶栏重排 + 锚点翻回顶边（同分支）

用户反馈两条：「展开缩放的逻辑做反了」「缩小后顶部的 icon 被压缩看不到了」。

**锚点**：上一版我按「紧贴底部」做成了底边锚定，用户确认要的是**顶边不动、向下长**
（面板看起来待在原地，对话区往下展开，输入框平滑跟随）。三处都翻回来了：
`setCollapsed:`、`setWorkbench:`、`positionAtDefaultCorner` 的收起态还原。
**但动画不跳这件事和锚点无关**，靠的是"动画全程用展开态布局"（页面侧），
那部分保持不变——两者缺一不可。

**顶栏被切**：我加的「工作台」「Agent」两个按钮把顶栏撑到 490px，而默认面板宽 460，
**收起按钮整个在窗口外面**。按钮被切掉时没有任何视觉提示，只会显得"按钮不见了"。

改成量出来再让位（`reflowToolbar()`），顺序是"丢了最不心疼"：
电平条 → 品牌收紧字距 → 低频按钮进「⋯」→ 整块摘掉品牌。
**状态文字给了 `min-width: 84px`**：没有这条的话它会被按钮挤成 0 宽，而顶栏在几何上
"没有溢出"，算法就不会去收按钮——结果是装饰性的品牌还在、功能性的状态没了。

以后往顶栏加按钮不用再算断点，但要把新按钮的 id 加进 `TOOL_ORDER`；
如果它是低频的，再加进 `OVERFLOW_ORDER`。

验证：360/410/460/560/700/860 六个宽度逐一实测「有没有按钮被切掉」「状态是否可见」，
全过。

## 2026-08-04 收起动画的卡顿 + 快捷菜单键盘选择（同分支）

**卡顿的真因不是渲染。** 先量了：270 个日志节点、模拟 30 帧连续改高度并每帧强制
同步布局，冻结前 0.27ms/帧、冻结后 0.23ms/帧——网页布局根本不是瓶颈，别再往
"虚拟滚动/减少节点"那个方向想。

真因是**动画中途被打断重来**：`@media (max-height: 460px)` 会在窗口高度穿过 460 时
把顶栏 56→48、输入区 108→103，于是
1. 动画中途布局跳一下；
2. ResizeObserver 触发 → 重报收起高度（实测目标从 164 变成 151）→ 宿主在动画飞行
   途中又起了一段新动画；
3. 更糟的是那次重复调用会执行 `self.expandedHeight = frame.size.height`，而此刻窗口
   正停在中间值（实测记成过 400）——**下次展开只展到 400，不是 620**。

三处都修了：矮窗紧凑排版改成 JS 打的 `body.short`（收起态与动画期间一律不打）；
`chromeObserver` 在 `.resizing` 期间不报；原生侧只在"从展开变收起"那一次记录
展开高度。另外给 `reflowToolbar` 加了宽度缓存——工作台加宽是每帧都改宽度的，
不挡一下每帧要跑最多 7 轮"挪按钮 + 强制布局"。

`content-visibility: hidden` 也换上了（替掉 `visibility: hidden`），但按上面的实测
它只是锦上添花，不是这次卡顿的解药。

**快捷菜单键盘选择**：`renderSkillMenu` 每次重建列表并打 `.sel`，但从不把选中项滚进
可视区，菜单最高 220px，往下按几下选中项就划出去了。加了
`scrollIntoView({block:'nearest'})`——nearest 是关键，已经可见时不滚，
否则每按一下菜单都会跳一下。

### 一个可复现的 UI 验证手段

`/tmp/uishot.m`（临时文件，没进仓库）：把真实的 `conversation.html` 装进
WKWebView，喂一串真实事件，`takeSnapshotWithConfiguration` 截图。比在真机上
手动点一遍可复现，也不用抢前台窗口。要长期用的话可以挪进 `native/tools/`。

## 2026-08-03 已合并进 main

用户要求"检查当前迭代内容，没问题就合并到 main"。我做了这些检查：

- review 了 feature/06 上还没进 develop 的最后一个提交
  `6f30c08`（邮件只读摘要，`mail_unread`）——Mail 走 AppleScript 只读元数据，
  串行队列跑，不堵主线程；`calendar_events`/`mail_unread` 都被升到 L2、读取前
  必须确认，因为内容会进模型上下文（这条设计合理）。
- 全量 Python `py_compile` + Objective-C `-fsyntax-only` 都过。
- 重跑了 tasking.finish 悬空步骤清扫、config.save_section 字段保留、
  fs_write verified 三个回归单测，全过。
- grep 了一遍 API key / TODO / FIXME / 调试 print，没有残留。
- `./native/build.sh` 真机构建安装重启，日志干净，唤醒词按当前配置正确
  停跑（手动模式，之前笔记提过这是用户自己切的）。

确认没问题后，把 `feature/06-personal-integrations` 的最后一个提交合并进
`develop/jarvis-next-base`，再从 `main` 做 `--ff-only` 快进合并——`main`
现在和 `develop/jarvis-next-base` 指向同一个提交 `3b456a6`，历史干净、没有
产生多余的 merge commit。又在 `main` 上单独跑了一次 build.sh 确认真的能独立
编译运行，不是只在 develop 上凑巧能跑。

`feature/wake-mode-settings` 内容已完全并入，那条分支可以删了。
`feature/jarvis-persona` 是早期未完成的实验分支（和现在的 main 差了 4000+
行，媒体控制那部分已经在正式历史里用不同 commit 重做过），和当前开发无关，
不需要管。

我们俩共用这一份工作目录/仓库开发 Jarvis，没有直接的进程间通信，所以用这份文件
互相留话：谁发现了什么、验证过什么、建议怎么做。看完可以把已处理的条目删掉或
标成"已处理"，不用保留全部历史——git log 本身就是历史。

Claude 这边的工作方式：不主动改 codex 正在改的文件，优先用独立 worktree 开发不
相关的功能，改完在自己分支跑通编译/单测再合并；review 到的问题直接在这里写清楚
文件名+行号，不新开一套设计文档。

## 2026-08-03 Claude 的检查结果

- **wake_word.enabled 现在是 `false`（手动模式）**。之前我调试时误改过一次又改回
  `true`，但现在又是 `false`——这次看起来是用户自己在真机上用新做的唤醒方式菜单
  切的，不是我动的。如果你们谁要往回改成默认 `true`，先跟用户确认一下，别猜。
- **唤醒方式功能（wake mode）**：codex 合并的两版打磨（`8d26929` 样式统一、
  `69490c1` a11y）看过了，没问题，和原来的 `enabled=false` 时 `setUpWakeWordWithConfig:`
  停麦逻辑衔接正确。
- **calendar_events（只读日历）**：`NativeToolExecutor.m` 里 EventKit 双路径权限
  请求（macOS 14+ `requestFullAccessToEventsWithCompletion:` / 13 走
  `requestAccessToEntityType:completion:`）、Info.plist 两条 usage description、
  hours/limit 边界收敛都对，`.location.length` 在 nil 时安全（ObjC 消息 nil 语义）。
  没发现问题。
- **主动提醒（proactive.py）**：读完了。设计合理——`_quiet()` 正确处理跨午夜的
  安静时段；`daily_limit`/`cooldown_minutes` 生效；未连接宿主时直接跳过整轮检查、
  不消耗 `last_reminded`，下次连上会补提醒，不会静默丢失。`native_tool_request`
  绕开 `session._pending` 直接由 `BrainServer` 发出，`resolve_pending` 对不认识的
  `request_id` 会安全 no-op（`session.py:357` `if not slot: return`），不会崩。
  **提醒到点后 status 一直停在 pending，除非模型/用户显式 memory_update 成
  completed，否则会按 cooldown 反复提醒到 daily_limit 封顶**——这是文档里写明的
  设计（"用户确认完成后才真正收口"），不是 bug，但目前没有任何一处会主动去问
  "这条提醒你处理了吗"，实际效果可能是每天固定弹 6 次直到手动关掉。要不要在
  system prompt 里加一句"提醒发出后下次对话主动确认是否完成"，你们看着定。

## 给"邮件只读摘要"的一个具体建议

真机上试了 `osascript -e 'tell application "Mail" to count messages of inbox'`，
正常返回（没有权限报错、没有"不认识这个命令"），说明 **Mail.app 有正规的公开
AppleScript 字典**，可以只读读 inbox/邮件标题发件人日期，不需要碰任何"读取其他
App 通知"那种没有公共 API 的路子。走 Mail 自己的 AppleScript 就行，和
`calendar_events` 走 EventKit 是同一个思路（原生宿主执行、L0 只读、需要用户授权
自动化权限）。

## 分支现状（写这条笔记时）

- `main`：`11409fd`，全程没动过。
- `develop/jarvis-next-base`：`d6f6956`，已含 环境感知/打断播报/任务编排/分层记忆/
  唤醒模式/日历/主动提醒。
- `feature/wake-mode-settings`（我的独立分支，`69374a6`）：内容已经被 codex 拣
  进 develop 了，这条分支可以删了，留着也没事。

## 2026-08-05 MCP 客户端 + 委派外部代理（分支 `feature/mcp-and-external-agents`）

用户指出「本地应用控制还可以，但第三方软件的控制与协作没有实现」，
选定两条路：**接 MCP 生态** + **调用其他 CLI agent**。基于 `feature/agent-mode` 开的分支
（依赖它的权限档位、确认弹窗和子代理事件通道），那条分支仍未并 main。

新增 `brain/jarvis_brain/mcp.py`、`brain/jarvis_brain/external_agent.py`，
两个新工具 `agent_delegate` / `mcp_status`，注册表加了动态工具那一层。
设计与配置写在 README「接第三方服务（MCP）」「委派给外部代理」两节。

### ⚠️ launchd 的 PATH 里没有 npx / uvx / claude / codex（最该记住的一条）

`launchctl getenv PATH` 是空的，Brain 子进程只有 `/usr/bin:/bin:/usr/sbin:/sbin`。
在**运行中的 Brain 上实测**（`ps eww -p <pid>` 读它真实的环境变量）确认了这一点，
而四个启动器全在 `/usr/local/bin`、`~/.local/bin`、`~/.local-npm/bin`、`~/bin`——
裸 PATH 一个都找不到，补齐后四个全部解析成功。

不补的表现是**每个 server 都 FileNotFoundError，而终端里手动跑完全正常**。
`mcp.py` 的 `launch_env()` 管这件事，MCP 和外部代理共用。别改成去跑
`zsh -lic 'echo $PATH'`：慢几百毫秒，且 rc 文件里有交互式内容会把 Brain 卡死。

### MCP 侧几条踩过的

- **stderr 必须**和 stdout 一样一直有人读。MCP server 普遍往 stderr 打日志，
  管道缓冲（64KB）一满，子进程下次写 stderr 就永久阻塞——表现是「跑着跑着不响应了」，
  而进程还活着、stdout 也没关。`external_agent.py` 里同理，两处都开了收集线程。
- **连接必须后台做。** npx 首次拉包实测 8.8s（缓存后 1.3s），同步连会把 Jarvis 卡在
  启动上，而且一个坏 server 就能拖垮全部。工具表在 `_loop` 每轮同步一次，
  靠 `MCPHub.generation` 版本号挡住重复重建（Agent 模式一轮就是几十次）。
- **动态工具整表替换，不做增量。** server 掉线、重连、发 `tools/list_changed`
  都会让工具表整个变一遍，增量维护迟早对不上；整表替换只有一个真相来源。
  代价是所有查表都必须走 `registry.lookup()` / `all_tools()`，
  **直接用 `BY_NAME` / `TOOLS` 会漏掉 MCP 那批**——改这块时先 grep 一遍。
- **`structuredContent` 常常就是 text 的副本。** 规范建议 server 把结构化结果同时
  序列化进 text 块以兼容老客户端，实测 `server-filesystem` 的 structuredContent 就是
  `{"content": <和 text 一字不差>}`。照单全收等于每次调用都把结果双倍塞进上下文，
  所以加了 `_same_content()` 判重。只认「整体相同」和「单键 dict 值相同」两种确定情况，
  多键 dict 照给——另外几个键是真信息。
- **risk 从 annotations 推断，但只用来放宽不用来放行**：`readOnlyHint` → L0，
  `destructiveHint` → L4，其余一律 L2 起。那是 server 自己的声明，只能当参考。
  实测 `server-filesystem` 的 14 个工具分档正确（read_* 全 L0、write/edit L4）。
- server → client 的请求（sampling/roots/elicitation）我们没声明 capability，
  正常收不到；真收到必须回一条 JSON-RPC 错误**而不是沉默**——对方会一直等到超时。

### 外部代理：权限档位决定它能不能真的干完（这条最容易误判）

委派进程是非交互的（stdin 关掉），外部代理弹的权限请求**没有任何人能应答**，
它只能跳过那步继续。实测 Claude Code 2.1.220：

    manual      写文件和跑命令都被拒 → 基本只能侦察
    acceptEdits 写文件放行、跑命令被拒 → 改得动代码，验证不了
    dontAsk     比 manual 还严，Write 和 Bash 全拒（不是能用的中间档，试过了）
    bypassPermissions  才能真正把活干完

真机跑「建 hello.py 并运行」：14.1s、2 步（Write + Bash），文件真建出来了，
但因为在 `accept_edits` 档，Bash 被拒，Claude 如实报告「命令需要授权所以没跑」。
**那句话埋在报告正文里，主模型很容易读漏，把半成品当成功报给用户**——
所以受限档位下会额外返回 `permission_note` 逼它正视。
**别把 accept_edits 偷偷提权到 bypass**：那是拿用户的权限设置开玩笑，
用户在顶栏调档就是在表达意图。

### 面板

外部代理复用子代理那张卡片（形态一样：一件外包出去的事 + 一份报告），
虚线边框 + `⇱` 区分，**配色仍走琥珀金**——2026-08-01 已明确否决多色状态灯方案，
别在这里开新色。唯一的行为差别：**外部代理逐步刷进度，子代理不刷**。
委派能跑十分钟，一动不动的卡片和卡死没区别；子代理几秒就回来，刷了只会让日志抖。

改完 `ui/conversation.html` 照例 `node --check` 过一遍（提取 script 块再 check）。
注意别把提取脚本的 stdout 重定向到同一个文件——会把刚写进去的 JS 冲掉，
报一个莫名其妙的 `Unexpected number`。

### 验证方式

`/tmp/mcp_probe.py`、`/tmp/ext_probe.py`、`/tmp/integration_probe.py`（临时文件，没进仓库）：
分别验协议层、委派、以及走真的 `SessionCoordinator._execute` 的端到端接线。
第三个最有价值——前两个是模块级的，测不出注册表查表和执行分发的接线错误。
三个都刻意把 `os.environ["PATH"]` 设成 launchd 那四个目录再跑。

端到端结果：工具表 51 个（静态 37 + MCP 14），L0 不弹确认、参数错误变成 error 不抛异常、
子代理拿不到 `agent_delegate`、explore 档拿不到 MCP 工具——全过。

### 工具表膨胀是要量的，不是凭感觉的

接一个 `server-filesystem`（14 个工具）**实测让平时那份工具表从 37 个 / 14156 字符
涨到 51 个 / 23322 字符——每一轮闲聊都多带 65%、约 3666 token**，而这 14 个工具
几乎全和 Jarvis 自带的 `fs_*` 重叠。所以它在 `~/.jarvis/config.json` 里配的是
`agent_only: true`，只在 Agent 模式露出；平时的表回到 37 个 / 14156 字符，零额外开销。

这条就是 `agent_only` 这个开关存在的理由（和当初给 grep/file_edit 加它是同一个理由：
**怕它们吵**，不是怕它们危险）。以后接新 server 先量一遍再决定放哪边，
量法：`registry.openai_schema(agent_mode=False)` 序列化后数字符。

## 2026-08-05 控制标记被念出来（同分支修的）

用户在 brain.log 里注意到 Jarvis 逐字念了 `<｜｜DSML｜｜invoke name="ui_action">`
这种东西。查下来是**模型格式崩溃**：长工具循环之后它不再走 `tool_calls` 字段，
而是把工具调用当正文吐出来。日志里两次都发生在 Agent 模式连续调十几次工具之后
（那轮在操控钉钉，反复试 `ui_action` 失败，一轮 38.84s）。

**念乱码只是表象，真正的伤害是那次工具调用丢了**——模型以为自己点了钉钉的按钮，
实际什么都没发生，而 Jarvis 把这段当普通回答收下，任务就地卡死。
排查时别只盯着播报，先问"这一轮的工具到底调没调成"。

provider 那一侧是干净的（`delta.content` 来什么吐什么），不用去改它。

两道网，缺一不可：

1. **`_loop` 里在喂给 splitter 之前检测**。一旦喂进去，这段文字同时进了字幕和
   播报队列，再拦就晚了。标记会被切在两个增量之间（`<` 和 `｜｜DSML` 分两块到），
   所以在拼接后的尾巴上找（留 64 字符窗口），不能只看单个增量。
   命中就 `provider.cancel()` + `_abandon_speech()` + 发 `assistant_reset` 让面板
   清空重画 + 往 history 塞一条纠正提示让模型用真的工具调用重来。
   **重试上限 2 次**，连着三次就如实告诉用户"什么都没有执行"并结束——
   那种情况多半是这段上下文本身把模型带偏了，再试只是白烧 token。
2. **`_queue_sentence` 里兜底**：标记可能在被检测到之前就攒进了 `_speech_buffer`。

`assistant_reset` 是现成的（双语兜底整段重发时用的），别再新造一个事件。

**正则是 `</?｜`（尖括号紧跟全角竖线 U+FF5C）**，DeepSeek 自家的
`<｜tool▁calls▁begin｜>` 和 DSML 那种包装都落在里面。改这条正则前先跑误伤测试：
`List<String>`、`</div>`、Markdown 表格的 `|`、以及全角竖线单独出现（`名称｜类型`）
**都不能命中**——已验证全部符合预期。放宽成只匹配 `｜` 会把中文排版里的全角竖线
一起吃掉，那会让正常回答被整轮丢弃。

## 2026-08-05 浏览器控制（第四条通道，同分支）

起因是上一条：钉钉那轮 `ui_action` 反复点不中。查了才知道**钉钉是 Qt 应用**
（`/Applications/DingTalk.app/Contents/Frameworks` 下是 QtConcurrent/QtNetwork/
QtOpenGL/QtXml），没有 `.sdef`，也不是 Electron/CEF。Qt 的 macOS AX 桥接把大量
控件暴露成 `static text` 而不是 `button`——**那条通道本身是残的，优化点击逻辑没用**。
以后遇到"AX 点不中"先看它是不是 Qt，别急着调代码。

五个工具加在 `AutomationController` 里（不是新建类）：`browser_tabs` /
`browser_read` / `browser_act` / `browser_open` / `browser_eval`。
放在一起是为了复用 `automationBlockedFor:` 和 `describeScriptError:`——
那两个方法编码了错误码的坑（-1743 vs -25211 vs -1719），复制一份才是真风险。

### ⚠️ `tab` 在浏览器的 tell 块里不是制表符（不报错，最费时间）

`browser_tabs` 第一版返回 0 个标签页，但脚本**不报错**。原因是 AppleScript 的
制表符常量 `tab` 和浏览器字典里的 `tab` 类**同名**，在 `tell application
"Google Chrome"` 块里 `& tab &` 被当成字面字符串 `"tab"` 拼了进去：

    1tab1tab新标签页tabchrome://newtab/     ← 实际返回长这样

于是按 `\t` 分割一个都分不出来。修法是**在 tell 块外面**先
`set d to character id 9` 再用 `d`。任何在浏览器 tell 块里拼分隔符的地方都要这么写。

### JS 用 base64 送进去

`execute <tab> javascript "..."` 要同时逃 AppleScript 的引号和 JS 自己的引号，
两层嵌套转义写出来没人看得懂，JS 里出现一个引号就炸。
现在统一 `eval(decodeURIComponent(escape(atob('BASE64'))))`——base64 之后只剩
`[A-Za-z0-9+/=]`，两边都不用转义。`decodeURIComponent(escape(...))` 那层是为了
UTF-8：`atob` 出来的是 latin1，中文页面直接 `atob` 会变乱码。

传给 JS 的字符串参数走 `jsStringLiteral:`，用 `NSJSONSerialization` 编码再削掉
外层方括号——手写引号转义迟早漏一种（换行、反斜杠、U+2028）。

### 「允许 Apple 事件中的 JavaScript」默认是关的

Chrome：查看 → 开发者 → 允许 Apple 事件中的 JavaScript。
Safari：设置 → 高级 → 显示网页开发者功能，再 开发 → 允许 Apple 事件中的 JavaScript。

**这个开关和 TCC 无关**，所以报错必须单独认出来（`describeBrowserError:`）
并把菜单路径写全。笼统报"脚本失败"会让模型跑去让用户改系统设置 →
改了还是不行 → 白绕一大圈。这类"看起来像权限但不是权限"的错误，
和 -1719/-1728 那条是同一类教训。

没走 CDP：要求用户改浏览器启动方式并重启，且开了端口之后**任何**本地进程都能
接管浏览器。AppleScript 这条受 TCC 管，权限归属清楚。

### `fill` 必须派发事件

React/Vue 监听的是 input/change 事件，不是 `.value`。直接赋值的表现是
「字填进去了但提交时是空的」。现在用 `Object.getOwnPropertyDescriptor` 拿到
原生 setter 再调，然后手动 dispatch——只 dispatch 不用原生 setter 的话，
React 的 value tracker 会认为值没变，事件照样被吃掉。

### shadow DOM 必须穿，而且"读到空页面"必须说出来

第一版 `browser_read` 只 `document.body.querySelectorAll`，在
`chrome://settings` 上返回**标题正常、元素 0 个**——内容全在 shadow DOM 里。
这是最坏的失败方式：**它长得和成功一模一样**，模型会得出"这页面上什么都没有"
然后开始瞎猜。现代企业 Web 应用大量用 Web Components，不是只有 chrome:// 会这样。

现在递归进 `el.shadowRoot`，选择器用 ` >>> ` 分段：

    settings-ui >>> #toolbar >>> #menuButton

`>>>` 是早年 CSS 的 deep 组合子、现在已经不是合法 CSS，拿来当分隔符不会和真实
选择器撞车。`browser_act` 按同样规则逐层进 shadowRoot 解析。
实测 `chrome://settings`：**568 个 shadow 宿主 → 读出 21 个可操作元素**，
沿多层路径点击成功。闭合的 shadow root 仍然穿不了（拿不到 shadowRoot），
跨域 iframe 也拿不到——所以正文和元素都为空时会带一条 `note` 说明原因，
**绝不返回一个看起来权威的空结果**。

### JS 出错在 AppleScript 侧是静默的

Chrome 对抛异常的脚本返回 `missing value`，和"成功但没有返回值"长得一样。
第一次踩：`browser_eval` 里写顶层 `return`（`eval` 不允许，是 SyntaxError），
结果报 `ok=true`、值是 `—`，看着像页面上真没这个东西。
现在所有 JS 都包一层 `try/catch` 并把错误用 `__JARVIS_JS_ERROR__` 前缀带回来，
`browser_eval` 的源码额外包成函数体（这样文档里承诺的 `return` 才真的能用）。

## 2026-08-05 钉钉：AXPress 是空操作（用户要求做桌面版，不是网页版）

我先前判断"钉钉桌面版没救、改用网页版"，**判断下早了**——那是基于框架识别和日志里的
失败推的，没有亲自扫过它的 AX 树。用户坚持要桌面版，扫完发现三个具体的、都能修的原因：

**1. `AXPress` 在 Qt 应用上是空操作。** 这是主因。钉钉的按钮报告自己 `pressable`、
`AXUIElementPerformAction` 返回 `kAXErrorSuccess`，**但界面什么都不会发生**。
验证方法是前后两次 `ui_inspect` 做文本快照 diff：press 之后新增 0 条、消失 0 条。
原始日志里"添加按钮点了但没弹出菜单"是同一回事。
修法是新增 `action=click`，发真实 CGEvent 鼠标事件。实测点「工作台」：
**新增 55 条、消失 104 条**，主面板真的换了。

**判断一个点击有没有生效，只能看界面快照 diff，不能信返回值。** 这条对所有 UI
自动化都成立，写测试时别偷懒。

坐标点击必须做三件事，少一件都是隐患：
  - **先激活目标应用**——坐标打的是屏幕上那个点，目标窗口在别人底下时会点进
    别人的窗口里，那是能造成真实损害的误操作；
  - **激活之后重新读坐标**——激活会改变层叠甚至窗口位置，用激活前的坐标是在赌；
  - **点完把光标放回原处**——用户光标毫无预兆跳走很吓人，他可能正悬停在别的东西上。
  另外要检查中心点落在某块屏幕内（多显示器下坐标可能是负数，逐屏比，别拿主屏卡），
  点到屏幕外是静默无效的。

**2. 图标按钮的标题是图标字体私用区码位**（`U+F281`），模型只看见一个方框，
于是去点旁边那行看得懂的文字——而那是 `AXStaticText`。真实结构是二者**是兄弟**：

    11/5/0/7/0/0  AXButton      title=U+F281
    11/5/0/7/0/1  AXStaticText  value=待办

现在给无可读标题的按钮补 `inferred_label`（同父节点下最近的静态文字，**限 20 字**）。
不卡长度的话，钉钉标题栏那三个无标题按钮会把用户的个性签名当成自己的名字——
比没有标签更容易误导，模型会拿它当按钮的功能。

**3. `kMaxUINodes = 220` 太小**，钉钉扫到一半截断，恰好把「日志」那一行吃掉，
表现是"这一项根本没有可点的东西"。抬到 600 后 306 个节点全出来了。

修完之后，原始日志里失败的那个场景（点侧边栏「日志」，一个 **不可 press 的静态文字**）
正常打开了写日志页。**有 frame 就能 click，pressable=false 不代表点不了。**

### 教训

"这个应用驱动不了"这种结论，**必须扫过 AX 树、试过坐标点击之后才能下**。
框架识别（Qt/Electron）只能告诉你"可能会难"，不能告诉你"做不到"。
我这次先给了结论再去验证，顺序反了。

## 2026-08-05 界面操作剧本（ui_recipe，同分支）

用户要"把写日志这个功能做到 Jarvis 里"，并在给的三个方案里选了**通用剧本机制**
而不是专用的 `dingtalk_log` 工具——后者违反「不为每个 App 写工具」那条原则，
而且钉钉改版就得改代码。剧本是**数据不是代码**，界面变了重录一遍即可。

`brain/jarvis_brain/recipes.py` + 四个工具（list / run / save / delete）+
原生新增 `ui_type`（合成键盘输入，因为 Qt 的 `set_value` 和 `AXPress` 一样不可靠）。
执行器跑在 Brain 里，每一步的界面动作经 `_RecipeHost` 转发给宿主——TCC 按 bundle 授权，
AX 调用必须由 Jarvis.app 自己发。

### 三条已经被实测打脸后定下来的规则

1. **按标签定位，绝不存下标路径。** 这条本来就是设计意图，实测更狠：钉钉侧边栏
   「最近使用」里的条目**名字和顺序会随最近用过什么而变**，同一个位置这次是「日志」
   下次是「写日志」。下标路径在这种界面上连一天都活不了。

2. **同名元素必须能按区域区分（`region`）。** 侧边栏有个叫「写日志」的小程序入口，
   日志列表页的内容区里**也**有一个「写日志」按钮，文字一模一样，点错了进的是完全
   不同的界面。侧边栏永远在左边窄条里，所以 `{"x_min": 200}` 这种几何约束是这里唯一
   稳的判据——比任何下标都稳，因为"内容区在右边"不会因为改版而改变。

3. **⚠️ `expect` 写松了会产生假阳性，比不验证更糟。** 我第一版 expect 写「写日志」，
   而侧边栏恰好有同名项，于是**内容区根本没变、验证却过了**，剧本带着错误状态继续
   往下点。expect 必须挑"只在目标状态下才会出现"的文字，必要时用 `expect_region` 钉死。
   识别方法：连续两轮跑出来的时间戳一模一样（"11:33 本地自动保存成功"），
   说明界面从头到尾没动过。

### 剧本要在成功做完一次之后录，不能凭旧观察盲写

我拿上一轮手动操作时记下的路径盲写了一份钉钉剧本，跑起来连续两次走错——因为
钉钉的日志页**至少有两种版式**（结构化表单 / 富文本编辑器 + 切换模板），
进入路径不同，而我记的是其中一种。

正确工作流是 `ui_recipe_save` 的设计意图：**让模型用 ui_inspect/ui_action 真的做成
一次，紧接着把刚走通的那条路存下来**。系统提示里也这么写了。盲写剧本 = 把旧状态
当成当前状态，和"拿旧路径去点"是同一个错误，只是换了个层级。

**这次失败恰好验证了机制本身是对的**：两次走错都被 `expect` 拦下并如实报告停在第几步、
当前屏幕上有什么，没有继续乱点——如果没有逐步验证，它会在用户的真实工作账号里
一路点下去。

## 2026-08-05 用户实测反馈：命令太多、上下文爆掉、内容被覆盖

用户报了四条，查下来**前三条是同一个根因**：

> 命令太多费时太久 / 让他加入新内容他把历史删了重写 / 工具调用达到上限任务失败 /
> 上下文太短，60 轮直接判断对话结束

**根因：`ui_inspect` 一次返回 33KB（约一万 token）。** 一个多步任务扫十几次就把上下文
撑爆 → 触发压缩把历史摘要掉（**用户看到的现象就是「他把之前的内容删了」**）→
步数预算同时烧光 → 撞上限判失败。四条症状，一个源头。

### 修法

- `ui_inspect` 加 `find` / `interactive` / `limit`。实测 `find=工作台` 从 13773 字节
  降到 708 字节（**95%**）。工具说明里改成"几乎总是要带 find"。
- **`ui_action` 加 `find`，按文字直接定位**，省掉「先 inspect 拿 path 再 act」这一来一回。
  这是工具调用数翻倍的主因。现在点一个东西是**一次调用**。
  同名元素用 `x_min`/`x_max` 区分（侧边栏 vs 内容区）。
- 步数剩 10 / 剩 4 时往 history 插一条预算提醒，让模型先收尾再交代清楚，
  而不是撞上限那一刻被硬截断、什么都没说。

### ⚠️ ui_type 的三个坑（全都不报错，全都静默失效）

写的时候以为很简单，实际连踩三个，每个的症状都是"报告 typed=N 但界面上什么都没有"：

1. **NULL 事件源 + kCGHIDEventTap 是唯一失效的组合。** keycode 传 0 时 HID 层会拿
   键盘布局把键位**重新翻译**，把 `CGEventKeyboardSetUnicodeString` 设的字符串覆盖掉。
   实测五种组合（`/tmp/keytest.m`）：

       source=NULL    tap=HID      ✗      source=NULL    tap=Session  ✓
       source=HID     tap=HID      ✗      source=Private tap=Session  ✓
       source=Private tap=HID      ✓

   现在用 Private + Session。**鼠标事件不走布局翻译，所以 click 一直是好的**——
   别因为点击能用就以为敲字也能用。

2. **必须显式 `CGEventSetFlags(event, 0)`。** 私有事件源保留自己的修饰键状态，
   append/replace 先发过 ⌘↓ / ⌘A，紧接着的字符会**继承那个 Command**，
   每个字变成 ⌘+字母 快捷键。症状很有迷惑性：insert 模式好使、append 模式什么都不出现。

3. **换行不能夹在 Unicode 字符串里。** 一个字符串里带 `\n` 时换行会送达、
   **后面的字符全部丢掉**。要按行拆开，行间补一次 keycode 36（Return）。

另外 `--tool` 这种一次性进程**敲完要等一下再退出**（现在 0.25s）：CGEventPost 是异步
投递的，进程先死了字就丢了。独立测试程序末尾恰好有 sleep，所以测不出来，接进 Jarvis 才暴露。

### 覆盖用户已有内容是数据丢失，按数据丢失对待

`ui_type` 的 `mode` 默认 **append**（⌘↓ 到文末再敲），不是 insert 也不是 replace。
insert 依赖光标恰好在对的位置，那是不可控的；而"在末尾追加"对"补充内容"这个最常见的
诉求永远是对的。实测光标故意放在开头，append 仍然正确追加到末尾。
系统提示里也加了一条：**绝不为了写新内容而毁掉用户已有的内容**。

## 2026-08-05 写日报 60 步做不完：三个错误诊断连成一串

用户反馈 Jarvis 跑了 60 步也没写成日报，最后如实报告"webview 的 contenteditable
对辅助功能树不可见，无法验证"。**那个诊断是错的**，而且错得很有说服力——
它试了读 AX 树、剪贴板、AppleScript 三条路都没看到自己写的字，于是推断"读不到"。
真相是字**写进去了，只是写到了别的栏目**，它在错误的地方找当然找不到。

三个真原因，逐个都致命：

### 1. `append` 在分栏表单里必然写错栏目

`append` 发的是 ⌘↓ = 跳到**整个文档**末尾。钉钉日报一页里有五个栏目，
用户要写「今日遇到的问题」，⌘↓ 把光标送到了最后一栏。
新增 `line_end`（⌘→ 到本行末尾）和 `line_replace`（⌘← ⇧⌘→ 选中整行再写）——
**分栏表单必须用这两个**。系统提示里写死了这条。

### 2. 目标滚出可视区时坐标是负的，点了等于没点

实测那个栏目在 **y = -536**。坐标点击对屏幕外元素静默无效。
现在 `clickElement` 发现目标不在屏幕上就先 `AXScrollToVisible` 再重读坐标——
**必须自动做**，指望模型自己想到要滚屏是不现实的，而且白花一轮工具调用。
修完那个栏目从 y=-536 变成 y=496。

### 3. AXWebArea 其实一直是可读的

`AXManualAccessibility` / `AXEnhancedUserInterface` 钉钉都不支持（返回 -25205/-25208），
**但根本不需要**：AX 树里本来就有 `AXWebArea`，日报五个栏目的标题和正文全都读得到。
`/tmp/webarea.m` 一跑就看见了。以后遇到"webview 读不到"先直接 dump 一遍 AXWebArea
子树，别急着下"不可见"的结论。

### 分栏表单写入的标准三步（现在写进系统提示了）

    1. ui_inspect find=<栏目标题>            → 拿它的 y
    2. ui_action find=<该栏现有文字> y_min=<上一步的 y> action=click
       （y_min 会取"标题下面最靠近的那个"，因为「无」「请输入」在一页里会重复好几次）
    3. ui_type mode=line_end / line_replace

实测三次调用完成，且**可验证**：写完用同样的 `ui_inspect find` 读回来对一遍。
「今日遇到的问题及解决方案」从「无」变成实际内容，其余四栏一字未动。

**教训：Jarvis 说"我验证不了"的时候，先怀疑它找错了地方，而不是接受"验证不可能"。**
在这个案例里，可验证性一直都在，是定位错了。

## 2026-08-05 form_read / form_write：一次调用完成分栏表单读写

用户要求「5 步之内、3 秒之内完成写日报」。先测清楚时间花在哪：

    原生工具一次调用   0.02 ~ 0.06s
    模型一轮首字       1.4 ~ 12s

**瓶颈从来不是工具，是模型轮次。** 5 步模型往返光延迟就 10s+，3 秒物理上做不到。
所以唯一的解法是**把整件事压进一次工具调用**——`form_write` 在一次原生调用里完成
定位 → 滚动到可见 → 点击 → 输入 → 读回验证。实测 **1.42s 端到端，verified=true**。

这不是把通用能力特化成某个 App 的工具：「标题 + 它下面的内容，一页重复若干组」
是极常见的形态（日报周报、审批单、工单、问卷），`ui_inspect`/`ui_action` 照旧存在。

### 写入点必须是这一栏的**第一行**，不能是最后一行

最后一行看着更合理（"接着往后写"），但**最后一个栏目没有下一个标题作边界**，
它的 body 会一路延伸到页尾——那样 `lastObject` 就是「提 交」按钮，
**一点就把日报发出去了，且不可撤销**。第一行永远在这一栏内。

### 栏目边界只能靠调用方声明的标题，别想自动认

试过「和标题左对齐且短」自动识别边界，**不行**：内容行和标题也是左对齐的
（这个表单里都是 x=479），于是第一行内容被当成边界，每一栏都读成空的。
左对齐区分不了标题和内容，别再往这个方向修。

### ⚠️ `NSRunningApplication.active` 在没有 runloop 的进程里永远不更新

它靠 KVO 通知更新，而通知要 runloop 才送达。`--tool` 是一次性进程、没有 runloop，
于是这个属性停在实例创建时的值——症状是「明明已经激活了，仍然报没能切到前台」。
改成每次实时问 `NSWorkspace.frontmostApplication` 比 pid，等待时用
`[NSRunLoop runUntilDate:]` 而不是 `sleepForTimeInterval:`。
**这条对任何在 CLI/无 runloop 上下文里判断应用状态的代码都成立。**

### 富文本编辑器给同一段文字挂多个 AX 节点

渲染出来的 `AXStaticText`、contenteditable 的后备 `AXTextArea`、以及它的文本子节点，
三者坐标重叠、值相同。不去重的话读回来同一句话出现两三遍，**看着像被写了两遍**，
用户会以为出了数据问题。已按文本去重。

### 已知限制（没修，如实记下）

`form_read` 在**栏目标题滚到接近顶部工具栏**时，会把工具栏的项（`toolbar-bold`、
`默认`、`11`）读进那一栏——纵坐标切分区分不了"固定不动的界面元素"。
标题完全滚出可视区（y<0）时会返回 `offscreen` 提醒，但贴着工具栏那一段还没覆盖。
`form_write` 不受影响（它按标题定位并会先滚动到可见）。

## 2026-08-05 token 优化：每轮固定开销砍掉一半

用户反馈「太费 token」。量了才知道贵在哪——**不是某个功能贵，是我一路加的常驻说明贵**：

    优化前：普通对话每轮固定开销 14220 token（工具 Schema 9372 + 系统提示 4848）

「现在几点」这种问题也要付这 14220。而 `form_write` 本身只占 348 token。

### 三刀

1. **UI 自动化整簇移进 `agent_only`**（browser_* / ui_* / form_* / app_script /
   menu_* / recipe_*，共 19 个）。普通闲聊不该带着它们的 Schema；需要时模型调
   `agent_enter` 进来，代价是同一轮里多一次工具调用，换回每轮几千 token。
2. **UI 指导从 `SYSTEM_PROMPT` 搬到 `AGENT_PROMPT`**（agent.py，只在 Agent 模式附加）。
   我先前把「click vs press」「分栏表单三步」「别覆盖已有内容」等九条全写进了常驻提示，
   那些只在操作界面时有用。搬走 4868 字符。
3. **压缩最臃肿的说明。** `ui_recipe_save` 一个工具 995 token（我把规则全写进了
   参数说明里）；规则搬进 AGENT_PROMPT 之后压到三分之一。

    优化后：普通对话 7299 token（-49%）  Agent 模式 14670 token（-18%）

### 教训

**每往 `TOOLS` 里加一个工具、往 `SYSTEM_PROMPT` 里加一句话，都是给每一轮对话上税。**
加之前先问：这条在「现在几点」这种对话里有用吗？没用就放 `agent_only` / `AGENT_PROMPT`。
量的方法：`len(json.dumps(registry.openai_schema(agent_mode=False)))`。

### 顺带修：读不到内容行时不再盲敲

webview 会把滚出可视区的内容卸载，这时 `form_write` 找得到标题却读不到内容行，
原先会照样点标题、敲字——光标落在哪完全不可知。现在直接报错并说明先滚进可视区，
**不动页面**。实测触发过一次，确认没有写出任何残留文字。

## 2026-08-05 简单指令走本地路由，零 token

用户问「打开应用、设备状态、时间、天气这些不需要走 token 吧」——问得对，
而且 `local_router.py` 本来就是干这个的（时间/日期/身份/音乐/打开应用已经零 token，
`_run_local_turn` 全程不碰 provider）。缺的是**设备状态**和**天气**，这次补上。

    现在几点        0.00s   零 token
    设备状态        0.14s   零 token（system_info + 本地排版）
    电量/内存/磁盘   0.09s   零 token（问什么答什么，不把三样都报一遍）
    打开/启动 X     0.39s   零 token
    今天天气        1.3s    零 token（联网但不联模型）

对比：走模型一轮是 7299 token 起步 + 1.4~12s 首字。

### 天气：联网但不经过模型

`weather.py`，wttr.in 的 j1 接口，免 key，纯标准库。几个决定：

- **天气描述在本地翻译**：j1 的 `lang_zh` 实测仍返回英文，而 `weatherCode` 是固定
  数字码，本地映射既准又零成本。
- **常用中文城市名映射成拼音**：中文名 wttr.in 也认，但这个免费服务**会限流抖动**
  （实测同一个城市名先 500 后 200），少一个不确定因素是一个。
- **失败时用过期缓存兜底**并明说「这是 N 分钟前的数据」。天气不是秒级变化的东西，
  报一句几分钟前的远好过"连不上"。
- **地名用用户问的那个**，不用接口返回的最近气象站名——上海会回 "Pootung"、
  深圳会回 "Ma Tso Lung"，听着像答非所问。

### ⚠️ IP 定位在挂代理时是错的

不填地点时 wttr.in 按出口 IP 定位，**实测定到了日本**。所以加了
`weather.location` 配置项，用户的已设成 `Xian`。这类"自动检测"在有代理的环境里
一律要能被显式覆盖。

### ⚠️ 中文正则里「的」也是中文字符

`([一-龥A-Za-z]{2,12})\s*(?:的)?\s*天气` 贪婪匹配会把「上海的」整个当成
城市名（`的` 在 `一-龥` 区间里），于是查「上海的」→ 500。
而「北京天气」没有「的」，测的时候正好没暴露。
改成非贪婪 + 显式 `rstrip("的")`。**写中文正则时别假设助词不在字符区间里。**

### system_info 返回的是排版好的中文字符串，不是结构化字段

`battery` 是 `"100%（充电中）"`、`disk` 是 `"剩余 133 GB / 共 245 GB"`。
第一版按字典取（`battery.get("percent")`）——取不到，而且**不报错，只是静默少一段**。
现在用正则抠数字。改这块之前先 `--tool system_info` 看一眼真实形状。
