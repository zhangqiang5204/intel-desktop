# Desktop interaction design

## Observable contract

One authorized operation has one desktop queue claim and one resource lifetime:

`queued → announce → claim → locate/read → edit → submit once → return focus → verify → release`

Read-only/background operations omit announce/claim and never take the keyboard.
The pre-claim announcement stays visible for at least one second while the original
window retains focus. Continuing physical typing prevents takeover; it does not
restart a waiting loop that eventually steals focus.

The nonactivating, mouse-transparent notice remains visible during foreground
operation. It says when control is active, and changes to “focus returned, checking
result” after a verified return. Operation finalization closes it on success,
known failure and cancellation. EOF/SIGTERM also close this helper's notice.
An uncertain capture stop is still reported as uncertain and retains the existing
capture/FIFO ownership; hiding a notice must never pretend that capture stopped.

## Owners and evidence

| Concern | Existing owner | Required evidence |
| --- | --- | --- |
| Queue, task identity, total duration | TaskRuntime | Actual enqueue/start/finish and native phases; metadata only |
| Original focus and user takeover | DesktopHelper/InputMonitor | Exact process/window, display topology and new physical activity |
| Prompt lifetime | DesktopHelper | Current task/operation; only its exact live noninteractive panel is exempt from visual occlusion |
| Recipient, complete draft and Send | ChatSession + native visual/AX owner | Current complete recipient/composer, secure-field checks and same-target identity |
| Native dialog transitions | Existing AX relationship binding | Fresh owner-published window/sheet/dialog identity; never title/PID similarity alone |
| Capture | Existing capture lifecycle owner | Confirmed stop callback before FIFO release; never timeout-as-success |
| Business success | Existing same-chat postcondition | Fresh increased exact message occurrence plus complete empty composer |

Each boundary has one owner. No additional queue, watchdog, model service or
completion platform is introduced. Generic applications retain current-model
AX/image-driven steps and current-digest parameterized plans. Their validated
dialog and selection behavior is preserved.

## Generic application completion

The current model keeps the user goal across bounded observe/action/verify stages.
A tool response assesses its own operation, not the entire instruction. Generic
observation supplies `continuation` with current context gaps and a read-only next
observation suggestion. Partial AX can be expanded; a missing image keeps usable
AX. When the privacy budget was actually expanded, another image request may use
the larger complete scope. No unchanged failed image is prescribed as a loop.
Native menus and safely masked pixels/visual OCR complement AX as needed.
Fresh owner-published dialogs require new controls and stages. The model proceeds
to the real requested outcome or the exact dependency it cannot resolve safely;
there is no additional goal owner, model service or background executor.

Temporary application-control sources remain metadata candidates. The existing
learning owner derives conversion/repair/verification/reuse entries and daily
text detail from current-source runtime proof. Raw code never becomes executable
by registration. Proven mechanical stages can be parameterized while dynamic
layout reasoning stays with the model. See the [execution guide](skills/intel-desktop/references/generic-apps.md).

The installed 0.1.74 generic acceptance expanded partial TextEdit AX to complete
AX plus a real masked target image, then ran a five-step selection/readback/restore
plan with fifteen real postconditions. The original value/selection and foreign
system focus were preserved. Its 2.111 s script duration and 332.486 s measured
model-driven acceptance episode are separate runtime entries. Neither is a
universal generic-app latency claim. Native source and the accepted 0.1.73 helper
are unchanged in this Python/Skill/report release.

## Failed foreground acquisition

An accepted app activation can land on that app's previously focused window while
the exact selected main window remains unfocused. This remains an input failure;
neither the other window nor an incomplete claim becomes input authority.

Before activation, native focus binds the selected window and the app root's
previous AXFocusedWindow, and atomically records physical-quiet and interaction
revisions while preparing its monitor. If this first acquisition fails after an
accepted activation and before any business input, its catch may return the saved
origin within the same native command, before the monitor is ended. Only the two
known landing references/frames are eligible. The actual front PID/window/frame,
task/operation, origin/window, topology and both activity revisions must still
match; any user activity, third window, ownership change or unavailable monitor
yields without restoration. Normal completed-claim restoration is unchanged.

The real guarded return receipt accompanies the original failure as
`error.details.focus_acquisition_return`. ChatSession consumes it without a second
restore request. The original business error and zero business-event count remain;
`claimComplete` is never set to manufacture a restore entitlement. Main-window
selection may use the public app-root AXFocusedWindow setter only when advertised
writable, followed by independent exact-reference verification. No other window
is closed, hidden or substituted.

The operation's existing notice stays visible while capture drain is unresolved,
using its ending/yielded stage. `_finish_operation`, EOF and SIGTERM close it only
after capture drain completes; input monitoring stops on shutdown without an
additional queue, watchdog or UI for read-only operations.

## Send implementation

The existing atomic high-level Send entry owns navigation through finalization.
It preserves unrelated drafts and never retries an unknown Send.

A known app may start on a non-chat page. When the request names an exact
destination, a fresh complete Feishu main-window AX tree with no exposed composer
and exactly one existing recognized search button may enter the existing search
modal navigation. Absence of a composer is not an empty-draft proof. Only the
actual selected result's complete recipient/composer permits message input.
An incomplete tree or ambiguous/unknown search control cannot enable this route.

WeChat feed pages can have a real title while no composer exists. Without a
verified Send control, text at the usual composer coordinates is never a draft.
The current model obtains the target image and chooses one bounded navigation
step using fresh AX/local-OCR controls. It verifies the resulting real chat before
returning to the Send adapter. This retains generic model-driven continuation
instead of adding a content-specific guessed editor or clearing feed text.

For WeChat with an empty verified composer, a capability-gated native edit combines
the composer click and typing. It reads a new frame after the click, checks the
entire expected empty composer, recipient, security and target again, then types
within that same command. This removes the redundant standalone click result and
the next RPC's duplicate guard capture. Normal draft/clear and old-helper behavior
remain compatible. The complete post-type composer/header/security proof and
one-use continuous-submit proof remain required.

After Return is posted, native Send returns a posting receipt with identity and
event timing. It does not construct another actionable snapshot or OCR the
composer before returning control. ChatSession restores the saved focus once,
then performs the existing read-only same-chat confirmation. A posted receipt is
never business success. Feishu keeps its already validated early-return/AX path.

## Performance and acceptance

These budgets apply to short single-line messages in an already located,
uncontended chat. Navigation, queue contention and continuous human typing are
reported separately. They are measurement targets, not claimed results.

| Measure | Baseline | Candidate target |
| --- | --- | --- |
| Announcement | 1–2 s | Preserve 1–2 s |
| WeChat whole invocation | 10.77 s | 8–9.5 s or better |
| WeChat Return posting to focus return | About 0.92 s | ≤0.4 s |
| Feishu whole invocation | 3.05 s | Preserve around 3 s |
| Feishu submit-call end to focus return | 0.182 s | ≤0.4 s |
| Capture and notice after operation | Capture 0; notice previously transient | Capture 0, notice hidden; no task-owned active lease |

Input-end-to-Return is measured separately from complete-draft-proof-to-Return;
the latter cannot conceal time spent verifying the draft. Whole invocation includes
queue, reaction time, verification and resource release. A task completion record
references its actual operation(s), including failed attempts of the same episode.

Preserve prior real nonempty-selection and native-dialog acceptance where the
change cannot affect it. Recheck affected focus/prompt behavior with a safe real
native stage; do not resend old test messages or rerun unchanged proofs merely
because the release version changed. Final Send acceptance uses the installed
standard MCP connection, one new authorized message per app, exact full-value
postconditions, saved-focus verification, and resource/notice status. An unknown
outcome is inspected without replay.

### Installed 0.1.73 observations

WeChat's already-located-chat Send measured 9.325 s. Input-event completion to
Return was 1.171 s, full-draft proof to Return 58.984 ms, and Return to verified
application-focus return 240.296 ms. The original window reference was unavailable;
the original application/PID was restored. Feishu's steady-chat Send measured
3.049 s, with 32.707 ms from full-draft proof to submit-call start and 148.600 ms
from submit-call completion to exact-window focus return. Its separate non-chat
startup/navigation Send measured 9.912 s. These are single measured observations,
with navigation costs reported separately.

Both Sends proved one increased exact body occurrence and a complete empty
composer after return. Every sampled native boundary retained the controlling or
verifying notice; operation finalization hid it and all capture lifecycle counts
were zero. The task logger recorded preflight-to-verified-completion spans of
9.410 s and 3.132 s. Earlier failed attempts remain separate real runtime entries;
a development acceptance episode is not reported as ordinary Send latency.

An earlier WeChat attempt stopped at draft comparison and did not send. Subsequent
read-only complete draft/body observations confirmed no test message to replay.
Mismatch errors now identify the exact comparison phase, value lengths, equality
booleans and known event counts without recording either value. Unknown glyphs and
changed drafts still stop input; diagnostics do not relax value proof.

Implementation is limited to this design's deltas. A newly observed failure must
be traced to its responsible boundary before another modification; unrelated
cleanup and architectural rewrites are outside this change.
