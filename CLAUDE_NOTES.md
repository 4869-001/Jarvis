# Claude ↔ codex 协作笔记

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
