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
