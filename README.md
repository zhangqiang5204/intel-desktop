# Intel Desktop

Native macOS desktop tools for Intel Macs, exposed through local stdio MCP. 面向 **Intel / x86_64、macOS 13+** 的本地原生桌面插件。

## 中文

普通应用由当前模型读取有界 AX 树、菜单和可选目标窗口图像，选择实际控件并验证结果。图像通过 ScreenCaptureKit 获取，普通应用由当前模型结合 AX 与图像识别局部文字；微信视觉适配使用本机 Vision OCR。工具本身不调用模型服务。WeChat/微信和 Feishu/飞书另有针对已识别布局的聊天流程，支持观察、定位、草稿、精确清理和明确授权的一次发送。AX 不可访问、窗口歧义、完整值缺失和未知结果会停止当前动作，不能据此宣传任意应用都已通过验收。

多个动作可通过 `desktop_batch`、`desktop_transaction` 或高层 chat 在同一个 FIFO 内完成，避免不同调用相互穿插。窗口、PID、几何、收件人和完整值证明在动作边界重新核对；选区使用精确文字或 UTF-16 range。前台操作尊重用户接管并按现有证明归还原焦点；显式后台路径有各自的焦点隔离条件。发送需要当前用户对精确收件人和内容的授权，posted events 不等于发送成功。

切换前台应用前，非激活接管提示保持原焦点 **1–2 秒**，等待键盘停手；持续输入时保留原焦点，同一 task 不重复提示。新打开的 dialog 必须重新 inspect，使用当前真实 AX 身份、parent/sheet/window 关联证明它属于已授权窗口；不能仅凭相同 PID 接受另一个窗口，已证明关联的 dialog 控件也可能由 remote PID 承载。本轮已在 TextEdit 实机完成“原文档 → 原生打开窗口 → 新窗口回读 → 取消 → 原文档回读 → 归还原焦点”，总耗时 4.63 秒；切换前提示等待 1.02 秒。此证据不覆盖其他应用或远程 PID 对话框。

模型临时脚本可登记为候选，记录摘要和真实失败；只有当前摘要匹配的参数化 `desktop_plan/v1` 才能通过明确后条件执行。原始 Python/Swift/shell 候选不会自动执行或重放。运行时记录 queue、native 和执行分项，以及 enqueue 至验证/焦点恢复完成的业务调用总耗时；跨调用任务用同 task 的明确终态 refs 登记首次 preflight 至实际 verified completion 的跨度，不累计 task ID 的全部历史。日志保留安全元数据，不复制聊天正文、调用值、图像或凭据。

### 构建与配置

需要 Python 3.9+、可用 `xcrun swiftc` 的 Xcode Command Line Tools 和支持这些系统框架的 macOS SDK。仓库不包含编译产物或额外 Python 依赖。在仓库根目录：

```bash
bash native/build.sh
python3 scripts/configure.py --check
python3 scripts/configure.py --format toml
```

配置脚本只打印当前 Python 和仓库位置对应的绝对路径配置；检查模式不构建、不调用 native、不写用户设置。将打印的 MCP 配置审阅后加入你选择的客户端配置。目录或 Python 位置变更后重新生成。Codex 插件清单使用 `${PLUGIN_ROOT}`，该内置占位符有 [OpenAI 官方文档](https://developers.openai.com/plugins/deploy/desktop-only) 依据；同时保留 `.codex-plugin/plugin.json` / `.mcp.json` 兼容清单。这里的源码发布不等于已进入官方插件目录。

首次真实桌面使用仍需由用户在 macOS 设置中授予实际运行程序所需的 Accessibility、Input Monitoring 和 Screen Recording 权限。插件不修改 TCC，也不会因安装而获得其他应用或业务授权。后台聊天适配依赖应用和系统行为，Feishu 粘贴路径会短暂租用并按 ownership 恢复剪贴板；不要将其称作剪贴板隔离。

### 有限事务与参数化脚本

[plans/](plans/) 提供三个仅占位符示例：WeChat 和 Feishu 当前收件人的后台草稿→完整读回→精确 owned clear→完整空值读回，以及 TextEdit 后台选区→读回→恢复原 UTF-16 选区。先验证当前窗口、完整值和安全焦点，再登记当前摘要、传入本次参数。每个已声明检查立即执行，失败停止后续输入；这些计划不导航、不发送、不保留业务参数。示例源码和离线测试不代表本次真实应用已经通过。

### 验证与现状

```bash
python3 scripts/run_tests.py
python3 scripts/run_native_self_tests.py --list
# 以下命令仅在完成 native build 后运行纯 native 自测试：
python3 scripts/run_native_self_tests.py
```

Python 测试使用 fake native 和临时 SQLite，不打开应用、不发送消息。依赖私有实机 UI 记录的用例未导出；可独立构造的相关场景使用合成 fixture。native 驱动只允许几何、精确选区、焦点 claim、submit guard、接管/dialog 逻辑和合成图像/window-snapshot 的无 GUI 自测试，不启动 live capture 或 live acceptance。实际权限、应用布局、多屏图像以及 UI 交接仍需单独实机验证。

已有一次真实 Send A 和一次 Send B 验收：

| 测量 | A | B |
| --- | ---: | ---: |
| Send 调用总耗时 | 10.22 s | 10.30 s |
| 输入完成 → Return 事件 | 2.18 s | 2.08 s |

这两个数据点不代表普遍性能保证。最新 continuous-input 候选尚未实机验收，不能宣称发送延迟已解决；TextEdit 对话框连续操作及切换前提示已按上方范围实机通过，其他应用仍需按真实结果判断。仓库不收录本机验收正文、原始日志、runtime 数据、用户配置或历史工作文件。

截图流只在同一队列操作内复用。操作成功、失败或取消后，先等待本次流停止，再释放跨会话队列。两轮实机只读验收均确认：操作内 1 条流，结束后立即 0 条流；完整草稿和会话一致、无输入事件。60 秒空闲定时器仅作异常退出时的后备释放。已打开的旧 MCP 进程保留原先代码，新会话加载当前安装代码。

## English

Intel Desktop runs a persistent Swift helper behind a standard-library Python MCP server. For ordinary apps, the current model uses bounded Accessibility trees, menu paths and optional window images to choose meaningful actions, then verifies the actual result. Target-window capture uses ScreenCaptureKit. The current model combines AX with image text for ordinary apps; the WeChat visual adapter uses local Vision OCR. The helper makes no model-service calls. Recognized WeChat and Feishu layouts also have dedicated chat workflows; generic app support does not imply every layout has been tested.

One queued batch, transaction or high-level workflow holds the FIFO across its steps. Current PID/window/geometry/value evidence, exact semantic selectors and takeover checks govern each action. Model-created scripts are collected as candidates; only a current-digest parameterized plan with real per-step and final postconditions can run. Registration, posted events and stale success flags never authorize replay. A Send needs current-human authorization for the exact recipient/content and fresh same-chat message-plus-empty-composer proof.

Before foreground activation, a nonactivating handoff notice keeps the original focus for **1–2 seconds** and waits for typing to stop; continued input preserves that focus, and the same task does not repeat the notice. Reinspect every new dialog and prove its current AX relationship to the authorized window. A matching PID alone is insufficient; genuinely associated controls may have a remote PID. These additions have offline evidence only at this snapshot, pending native build and live acceptance.

Build with `bash native/build.sh` on an Intel Mac running macOS 13 or newer, with Python 3.9+ and a suitable Xcode SDK. `scripts/configure.py` prints installation-specific JSON or Codex TOML without writing user settings. The plugin manifests use the documented `${PLUGIN_ROOT}` placeholder. Grant macOS permissions explicitly for the responsible program; this repository contains source, not a permission bypass or a prebuilt helper.

Run `python3 scripts/run_tests.py` for offline fake-backend regressions. After building, `python3 scripts/run_native_self_tests.py` runs only whitelisted non-GUI native guards. Live app acceptance remains separate. Background adapters are app/system dependent; the Feishu paste route temporarily uses and ownership-restores the clipboard.

Runtime metadata separates queue/native/execution timings and measures complete workflow invocations. Script management calls are tool timings; historical script calls without action evidence remain unclassified. Explicit task totals use named same-task terminal operations from first recorded preflight to verified completion, including failed attempts and focus restoration. They do not include unmeasured earlier model/user time or unrelated history. Daily analysis reports coverage gaps and never optimizes code or executes scripts automatically.

The measured Send A/B totals were **10.22/10.30 seconds**, with **2.18/2.08 seconds** from input completion to Return. The latest continuous-input candidate has not been live-tested. These observations are not a general latency guarantee or evidence that all apps, dialogs and handoffs pass. No local runtime, live message content, raw acceptance logs, credentials, personal configuration, historical workspace or compiled framework is included.

Source and relocated offline-test provenance is recorded in [SOURCE_MANIFEST.json](SOURCE_MANIFEST.json). Licensed under [MIT](LICENSE), copyright zhangqiang5204.
