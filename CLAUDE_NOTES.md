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

没做的（第二~四期，等用户排期）：通用 AppleScript/JXA 通道（让 Jarvis 指挥任意有脚本
字典的 App）、辅助功能 UI 操作兜底、子代理、面板宽屏工作台视图。

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
