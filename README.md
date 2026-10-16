# Intel Desktop

Native macOS desktop tools for Intel Macs, exposed through local stdio MCP. 面向 **Intel / x86_64、macOS 13+** 的本地原生桌面插件。

## 中文

**0.1.75 修复飞书提交后确认过早结束的问题。** 对已提交且已归还焦点的发送，如果同一目标的首次 AX 树或完整值暂时不齐，在原有 5 秒确认期限内继续只读核验；不重新输入、提交或抢回焦点。完整正文增加和空草稿仍是成功条件，身份、窗口、收件人或安全检查失败仍立即停止。正常首次确认成功不增加等待。本次未发送新测试消息；后台 AX 读取和离线重查测试分别记录，先前实机 Send 证明仍按原版本列出。

普通应用由当前模型读取有界 AX 树、菜单和可选目标窗口图像，选择实际控件并验证结果。图像通过 ScreenCaptureKit 获取，普通应用由当前模型结合 AX 与图像识别局部文字；微信视觉适配使用本机 Vision OCR。工具本身不调用模型服务。WeChat/微信和 Feishu/飞书另有针对已识别布局的聊天流程，支持观察、定位、草稿、精确清理和明确授权的一次发送。AX 不可访问、窗口歧义、完整值缺失和未知结果会停止当前动作，不能据此宣传任意应用都已通过验收。

**0.1.74 的通用应用路线允许较慢，但要持续推进到真实指令完成。** 当前模型按“观察 → 分析 → 小步操作 → 回读 → 判断剩余工作”循环，必要时混合 AX、目标窗口截图/视觉 OCR 与真实菜单；一次点击、工具返回或新对话框只结束一个阶段。`desktop_observe` 给出观察范围和下一次只读上下文建议，不替模型宣布用户任务完成。图像失败保留 AX；有界 AX 被截断时扩大读取后再判断。`include_menus:true` 为通用应用提供真实菜单。完整用法见 [通用应用执行指引](skills/intel-desktop/references/generic-apps.md)。

脚本分析现在列出 **转换、修复、继续验收、复用** 四类明细，包含当前源码摘要下的真实证明、失败和遗漏数量；日报文本直接显示可处理项。原始代码仍只收集为候选，参数化路线经真实后条件验证后优先用于下一次兼容任务，布局变化时继续由模型分析。周期维护消费这些明细后决定固化对象，分析器不自动运行未知脚本。

本次通用路线实机范围为 TextEdit 自有测试文档：首次 AX 截断使截图不可用，扩大上下文后取得完整 AX 和真实目标窗口图像，再完成五步选择/回读/恢复计划，15 个后条件全部通过，完整原文及原选区恢复，系统焦点保持不变。该脚本调用耗时 **2.11 s**；含模型分析、上下文扩展及登记的本次验收跨度另行登记，不能把 2.11 s 称作整个模型任务耗时。参数化来源已按当前摘要登记和实机验证；单次成功不冒充跨任务成熟证明。

多个动作可通过 `desktop_batch`、`desktop_transaction` 或高层 chat 在同一个 FIFO 内完成，避免不同调用相互穿插。窗口、PID、几何、收件人和完整值证明在动作边界重新核对；选区使用精确文字或 UTF-16 range。前台操作尊重用户接管并按现有证明归还原焦点；显式后台路径有各自的焦点隔离条件。发送需要当前用户对精确收件人和内容的授权，posted events 不等于发送成功。

切换前台应用前，非激活接管提示保持原焦点 **1–2 秒**，等待键盘停手；持续输入时保留原焦点，操作期间提示持续显示；归还后切换为后台确认提示，直到本次捕获与操作范围实际释放才关闭。新打开的 dialog 必须重新 inspect，使用当前真实 AX 身份、parent/sheet/window 关联证明它属于已授权窗口；不能仅凭相同 PID 接受另一个窗口，已证明关联的 dialog 控件也可能由 remote PID 承载。本轮已在 TextEdit 实机完成“原文档 → 原生打开窗口 → 新窗口回读 → 取消 → 原文档回读 → 归还原焦点”，总耗时 4.63 秒；切换前提示等待 1.02 秒。此证据不覆盖其他应用或远程 PID 对话框。

模型临时脚本可登记为候选，记录摘要和真实失败；只有当前摘要匹配的参数化 `desktop_plan/v1` 才能通过明确后条件执行。原始 Python/Swift/shell 候选不会自动执行或重放。运行时记录 queue、native 和执行分项，以及 enqueue 至验证/焦点恢复完成的业务调用总耗时；跨调用任务用同 task 的明确终态 refs 登记首次 preflight 至实际 verified completion 的跨度，不累计 task ID 的全部历史。日志保留安全元数据，不复制聊天正文、调用值、图像或凭据。

### 构建与配置

需要 Python 3.9+、可用 `xcrun swiftc` 的 Xcode Command Line Tools 和支持这些系统框架的 macOS SDK。Git 仓库不包含编译产物或额外 Python 依赖；版本发布的 Intel 压缩包另附已编译 helper。预编译包见 [GitHub Releases](https://github.com/zhangqiang5204/intel-desktop/releases/tag/v0.1.75)。0.1.75 为 Python 发送确认修复，发布包沿用已验收的 0.1.73 原生 helper；状态中的 `plugin_version` 与 helper 的 `version` 分别标识两者。在仓库根目录：

```bash
bash native/build.sh
python3 scripts/configure.py --check
python3 scripts/configure.py --format toml
```

配置脚本只打印当前 Python 和仓库位置对应的绝对路径配置；检查模式不构建、不调用 native、不写用户设置。将打印的 MCP 配置审阅后加入你选择的客户端配置。目录或 Python 位置变更后重新生成。Codex 插件清单使用 `${PLUGIN_ROOT}`，该内置占位符有 [OpenAI 官方文档](https://developers.openai.com/plugins/deploy/desktop-only) 依据；同时保留 `.codex-plugin/plugin.json` / `.mcp.json` 兼容清单。这里的源码发布不等于已进入官方插件目录。

首次真实桌面使用仍需由用户在 macOS 设置中授予实际运行程序所需的 Accessibility、Input Monitoring 和 Screen Recording 权限。插件不修改 TCC，也不会因安装而获得其他应用或业务授权。后台聊天适配依赖应用和系统行为，Feishu 粘贴路径会短暂租用并按 ownership 恢复剪贴板；不要将其称作剪贴板隔离。

### 有限事务与参数化脚本

[plans/](plans/) 提供仅占位符示例：WeChat 和 Feishu 当前收件人的后台草稿→完整读回→精确 owned clear→完整空值读回，以及 TextEdit 后台选区→读回→恢复原 UTF-16 选区。新增 WeChat 非聊天页的模型所选本地会话导航计划：当前 Search 与字面行标签确认→一次侧栏导航→归还→完整收件人与空 composer 后条件；不输入聊天文字、不发送。先验证当前窗口、完整值和安全焦点，再登记当前摘要、传入本次参数。每个已声明检查立即执行，失败停止后续输入；这些计划不导航、不发送、不保留业务参数。示例源码和离线测试不代表本次真实应用已经通过。

### 0.1.73 交互设计

[INTERACTION_DESIGN.md](INTERACTION_DESIGN.md) 定义接管、定位、输入、提交、归还、后台确认和释放的同一条流程，并区分调用总耗时与输入后的等待。保留已验证选区、原生对话框、完整值与安全检查。

微信空草稿的 Send 使用原生原子点击与输入，保留点击后的新画面核验，省去相邻调用的重复采帧；Return 后返回不可继续输入的提交回执，立即安全归还，再后台验证真实聊天结果。飞书非聊天页可以通过当前完整 AX 中唯一合格搜索按钮进入既有会话定位流程；没有 composer 不会被当成空草稿。接管失败只在同次零业务输入、原窗口和物理输入基线均未变化时归还，保留原失败结果。

接管提示不激活窗口、不接收鼠标；整个操作期间持续显示，归还后更新为“正在确认”。只豁免本 helper 当前提示的精确窗口身份，不忽略其他应用或同进程的其他窗口。成功、失败、取消和退出均沿实际资源释放关闭提示；未决捕获继续显示正在结束，不伪称释放成功。

### 验证与现状

```bash
python3 scripts/run_tests.py
python3 scripts/run_native_self_tests.py
python3 scripts/run_capture_connection_tests.py
```

Python 测试使用 fake native 和临时 SQLite，不打开应用、不发送消息。依赖私有实机 UI 记录的用例未导出；可独立构造的相关场景使用合成 fixture。native 驱动只允许几何、精确选区、焦点 claim、submit guard、接管/dialog 逻辑和合成图像/window-snapshot 的无 GUI 自测试，不启动 live capture 或 live acceptance。实际权限、应用布局、多屏图像以及 UI 交接仍需单独实机验证。

0.1.73 已通过安装版本的微信和飞书实机发送验收。已定位目标会话的本次单次测量：

| 测量 | 微信 | 飞书 |
| --- | ---: | ---: |
| 完整 Send（接管提示、识别、输入、归还、后台确认及释放） | 9.33 s | 3.05 s |
| 输入事件结束 → Return | 1.17 s | 未取得 HID 时间戳 |
| 完整草稿校验 → 提交 | 59 ms | 33 ms（调用边界） |
| 提交 → 焦点归还 | 240 ms（Return 事件起） | 149 ms（提交调用结束起） |
| 含本次工具预检的任务日志总时长 | 9.41 s | 3.13 s |

两端均以同一聊天完整正文增加一次精确消息、完整空草稿证明成功。微信归还至原应用，原窗口引用不可用；飞书归还至原应用确切窗口。提示在操作及归还后的后台核验期间持续显示，操作结束后关闭；本 helper 捕获生命周期计数归零。另一次飞书从非聊天页搜索进入目标会话的完整调用为 **9.91 s**。导航冷启动与已定位会话分别计时，不把前者计作稳态性能。以上为单次观测，不是所有布局或负载下的保证；微信的校验仍约占输入到发送间的 1.17 秒。当前候选通过 **684 项 Python 回归、576 项原生纯检查和捕获连接故障注入检查**；这些离线检查与上述实机验收分别计证。

0.1.72 基线已通过真实微信发送、正文与空输入框确认、原窗口焦点归还；飞书相同发送路径也已完成真实发送与后台完整 AX 确认。下表均为历史单次实测，不是普遍性能保证：

| 测量 | 实测 |
| --- | ---: |
| 微信输入完成 → Return 事件 | 1.39 s |
| 微信完整草稿校验完成 → Return 事件 | 54 ms |
| 微信整个 Send 调用（含识别、接管提示、后台确认、归还） | 10.77 s |
| 飞书完整草稿校验完成 → 提交调用 | 33 ms |
| 飞书整个 Send 调用（含接管提示、完整确认、归还） | 3.05 s |

微信已复用同次输入后取得的完整画面证明，避免发送前再做一轮截图；证明的窗口、草稿、焦点和时效检查仍保留。飞书提交后先归还原焦点，再后台确认；发送确认使用同一聊天正文下的完整 AX 值，可处理视口把文本裁成 1 点高的情况，侧栏预览和草稿不计入正文。菜单读取仅在实际导航需要时执行，菜单诊断失败不会污染聊天正文的完整性证明。

非空选区实机验收使用 TextEdit 的精确第二次文字出现，UTF-16 选区、完整原文和原选区均回读并恢复，总耗时 746 ms。该选择实现未随版本号变化；TextEdit 对话框和切换前提示的实机范围见上文。其他应用或跨进程对话框仍需按真实结果判断。仓库不收录本机验收正文、原始日志、runtime 数据、用户配置或历史工作文件。

截图流只在同一队列操作内复用。操作成功、失败或取消后，先等待本次流停止，再释放跨会话队列。实际发送和后台只读验收均确认：结束后生命周期计数归零；最后的系统 Control Center 录屏归属更新为空。60 秒空闲定时器仅作异常退出时的后备释放。冷启动若返回已观察到的 `-3805` 连接中断，只允许在原截止时间内重新核验目标后重建一次截图；不重试输入、超时或其他错误。已打开的旧 MCP 进程保留原先代码，新会话加载当前安装代码。

微信和飞书在已知提交后只请求一次安全归还，并仅后台确认；微信首次确认出现暂时不同的草稿外观时，在原 5 秒期限内只读复看一次，持续异常仍返回未知。飞书前台聊天流程在关闭已有搜索窗后沿用首次 claim，避免把原归还目标覆盖成飞书自身；业务结果未知仍只请求一次原生安全归还。业务完成但归还未证实时返回 `ok:false`、`scope_completed:false`，保留已验证草稿或 Send 证据，不重放。实机焦点验收覆盖正常返回、注入业务未知后的返回，均回到原应用确切窗口且无聊天输入；完整 MCP `read` 流程实测 2.33 秒、`focus_lifecycle:restored`。0.1.72 基线的 661 项 Python 回归、570 项原生纯检查及 7 项捕获连接故障注入检查通过。

已有会话不会自动重新加载本地 Python 代码；当前 `desktop_status` 返回 `plugin_runtime_features`。旧连接缺少该元数据时，当前任务可以使用随包 `desktop_client.py` 打开新标准 MCP 连接，不能重放旧操作。微信系统录屏指示仍须独立核实；本 helper 的活跃流为零不能证明同一启动器下所有捕获都已结束。

## English

Version **0.1.75** keeps observing temporary incomplete AX reads after a Feishu submission within the original five-second confirmation deadline, after focus has already been returned. It never resubmits or reacquires focus. Complete same-chat body and empty-composer proof remain required; target identity and safety failures still stop immediately. The normal first-read success path adds no delay. This repair has offline retry tests and read-only app observation; no new live Send was performed. Historical live Send results remain attributed to their tested versions.

Intel Desktop runs a persistent Swift helper behind a standard-library Python MCP server. For ordinary apps, the current model uses bounded Accessibility trees, menu paths and optional window images to choose meaningful actions, then verifies the actual result. Target-window capture uses ScreenCaptureKit. The current model combines AX with image text for ordinary apps; the WeChat visual adapter uses local Vision OCR. The helper makes no model-service calls. Recognized WeChat and Feishu layouts also have dedicated chat workflows; generic app support does not imply every layout has been tested.

Version **0.1.74** makes the generic route explicit: the current model continues observe/analyze/act/verify stages to the requested outcome. A tool call, sparse AX, missing chat adapter or new dialog is a stage boundary. Generic observations preserve AX when an image is unavailable, suggest fresh context and support native menus. Script analysis and daily text reports expose conversion/repair/verification/reuse entries backed by the current registered digest; they never execute unknown collected code. An installed TextEdit test recovered from partial AX to complete AX plus masked pixels, then completed a five-step parameterized selection/readback/restoration plan with fifteen checks in 2.11 seconds. Its longer model-driven acceptance span is recorded separately. This Python/Skill/report update retains the accepted native 0.1.73 helper, reported separately from `plugin_version`.

One queued batch, transaction or high-level workflow holds the FIFO across its steps. Current PID/window/geometry/value evidence, exact semantic selectors and takeover checks govern each action. Model-created scripts are collected as candidates; only a current-digest parameterized plan with real per-step and final postconditions can run. Registration, posted events and stale success flags never authorize replay. A Send needs current-human authorization for the exact recipient/content and fresh same-chat message-plus-empty-composer proof.

Before foreground activation, a nonactivating handoff notice keeps the original focus for **1–2 seconds** and waits for typing to stop; continued input preserves that focus, and the same task does not repeat the notice. Reinspect every new dialog and prove its current AX relationship to the authorized window. A matching PID alone is insufficient; genuinely associated controls may have a remote PID. TextEdit was live-tested through document → native Open window → fresh dialog inspection → Cancel → original document → saved focus return (4.63 seconds, including a 1.02-second pre-activation notice). Cross-process dialogs and other apps are outside that live proof.

Build with `bash native/build.sh` on an Intel Mac running macOS 13 or newer, with Python 3.9+ and a suitable Xcode SDK. `scripts/configure.py` prints installation-specific JSON or Codex TOML without writing user settings. The plugin manifests use the documented `${PLUGIN_ROOT}` placeholder. Grant macOS permissions explicitly for the responsible program; the Git repository contains source; the Intel release archive also includes the compiled helper.

Run `python3 scripts/run_tests.py` for offline fake-backend regressions. After building, `python3 scripts/run_native_self_tests.py` runs only whitelisted non-GUI native guards. Live app acceptance remains separate. Background adapters are app/system dependent; the Feishu paste route temporarily uses and ownership-restores the clipboard.

Runtime metadata separates queue/native/execution timings and measures complete workflow invocations. Script management calls are tool timings; historical script calls without action evidence remain unclassified. Explicit task totals use named same-task terminal operations from first recorded preflight to verified completion, including failed attempts and focus restoration. They do not include unmeasured earlier model/user time or unrelated history. Daily analysis reports coverage gaps and never optimizes code or executes scripts automatically.

The installed **0.1.73** WeChat live Send took **9.33 seconds** including recognition, the takeover notice, verification, focus return and release. Input completion to Return was **1.17 seconds**, complete draft proof to Return was **59 ms**, and Return to verified application-focus return was **240 ms**. Its original window reference was unavailable. The Feishu steady-chat Send took **3.05 seconds**, with **33 ms** from complete draft proof to submit and **149 ms** from submit-call completion to exact-window focus return. A separate Feishu non-chat startup/search Send took **9.91 seconds**. Both adapters proved an increased complete exact body message and a complete empty composer. The operation notice remained visible during control and background verification, then closed with this helper's capture counters at zero. Recorded task spans including their tool preflight were **9.41 seconds** and **3.13 seconds**. Nonempty TextEdit selection/readback/restoration previously passed in **746 ms**; its implementation is retained. These single observations are not a general latency guarantee or evidence that all apps, dialogs and handoffs pass. No local runtime, live message content, raw acceptance logs, credentials, personal configuration, historical workspace or compiled framework is included.

Source and relocated offline-test provenance is recorded in [SOURCE_MANIFEST.json](SOURCE_MANIFEST.json). Licensed under [MIT](LICENSE), copyright zhangqiang5204.
