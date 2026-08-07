# Swift-shared-core on Windows — gating feasibility audit

Status: **analysis only.** Written 2026-07-26 against the working tree at
`e449fec` + uncommitted changes. Nothing here was executed on Windows — see
§6.3 for the spike that settles the empirical questions.

Scope audited (13 files, 3,470 total lines / **2,076 non-comment lines**):

| File | total | code | Role |
|---|---:|---:|---|
| `ClaudeAPI/Client.swift` | 427 | 310 | claude.ai calls (~120 of those lines are embedded JS) |
| `ClaudeAPI/Models.swift` | 181 | 76 | DTOs |
| `ClaudeAPI/DeepLinks.swift` | 35 | 10 | URL constants |
| `ClaudeAPI/Validate.swift` | 166 | 128 | contract validator |
| `ClaudeUsageOverlay/UsageModel.swift` | 111 | 72 | usage % + projection |
| `ClaudeUsageOverlay/SessionsModel.swift` | 528 | 286 | state.json read/write, dedupe |
| `ClaudeUsageOverlay/GraphModel.swift` | 558 | 368 | jsonl tiers → chart buckets |
| `ClaudeUsageOverlay/PlanFitModel.swift` | 526 | 331 | plan_fit.json → verdict UI text |
| `ClaudeUsageOverlay/CloudSessionsModel.swift` | 234 | 81 | /recents filtering + dedupe |
| `ClaudeUsageOverlay/ConfigStore.swift` | 414 | 256 | config.json sole writer |
| `ClaudeUsageOverlay/ChatsModel.swift` | 67 | 40 | chat rows |
| `ClaudeUsageOverlay/SnapshotLogger.swift` | 129 | 68 | snapshots.jsonl appender |
| `ClaudeUsageOverlay/ScopedLimitLogger.swift` | 94 | 50 | scoped_limits.json relay |

`WebSession.swift` (243 lines) is explicitly out of scope but is **not**
separable the way the brief assumes — see §1.7 and Risk R1.

---

## 1. API inventory

Classification key:

- **AVAILABLE** — swift-corelibs-foundation / stdlib / libdispatch on Windows
  provides it with the same semantics. (Availability claims are cross-checked
  against §2; anything §2 could not confirm is marked **VERIFY**.)
- **NEEDS-SHIM** — the symbol exists but the *semantics* differ, or it exists
  only behind a platform module and needs a per-OS implementation.
- **UNAVAILABLE** — does not exist on Windows at all.

### 1.1 Swift standard library — all AVAILABLE

Nothing in scope uses a Darwin-only stdlib facility. `Identifiable`
(`SessionsModel.swift:36`, `GraphModel.swift:14,61,81`,
`CloudSessionsModel.swift:13`, `ConfigStore.swift:9`, `ChatsModel.swift:7`)
is stdlib, not SwiftUI — it ports free. Same for `Hashable`/`Equatable`/
`CaseIterable`, `Result`, and every generic collection operation
(`sorted`, `filter`, `compactMap`, `reduce`, `max(by:)`).

| Symbol | Sites | Class |
|---|---|---|
| `Identifiable`, `Hashable`, `Equatable`, `CaseIterable` | 7 / 3 / many / 1 (above) | AVAILABLE |
| `Result<Success, Failure>` | `Client.swift:31,62,121,141,232` | AVAILABLE |
| `pow(_:_:)` | `Models.swift:108` | AVAILABLE (libm via Foundation re-export) |
| `ceil(_:)` | `GraphModel.swift:511,512` | AVAILABLE |
| `.rounded()` | `PlanFitModel.swift:47,462,470,498`, `ConfigStore.swift:351` | AVAILABLE |
| `String.trimmingCharacters(in: .whitespaces…)` | `Client.swift:178,352,376,377`, `SessionsModel.swift:118`, `CloudSessionsModel.swift:28,152`, `ChatsModel.swift:19` | AVAILABLE (Foundation, but pure Swift impl) |
| `String.lowercased()` | `Client.swift:178,376,377`, `CloudSessionsModel.swift:152` | AVAILABLE — locale-**in**dependent by definition, so no Turkish-İ hazard |

### 1.2 Foundation — value types, AVAILABLE

| Symbol | Sites (file:line) | Class |
|---|---|---|
| `Date`, `Date()`, `.distantPast` | `SessionsModel.swift:148,273,303`, `GraphModel.swift:128,207`, `CloudSessionsModel.swift:121,188`, `SnapshotLogger.swift:36,59`, `UsageModel.swift:25,31,74` | AVAILABLE |
| `Date(timeIntervalSince1970:)` | `SessionsModel.swift:196,197`, `PlanFitModel.swift:314` | AVAILABLE |
| `TimeInterval`, `timeIntervalSince`, `addingTimeInterval` | ~30 sites | AVAILABLE |
| `Data`, `Data(contentsOf:)` | `SessionsModel.swift:179,477`, `GraphModel.swift:366,381,402`, `PlanFitModel.swift:170`, `ConfigStore.swift:303` | AVAILABLE |
| `Data.write(to:)` | `Validate.swift:59`, `SessionsModel.swift:497`, `ConfigStore.swift:317` | AVAILABLE |
| `Data.write(to:options: .atomic)` | `ScopedLimitLogger.swift:87` | **NEEDS-SHIM** — see §1.6 |
| `String(data:encoding:)`, `String.data(using:)` | `Validate.swift:30`, `GraphModel.swift:366,369,381,384`, `SnapshotLogger.swift:88,105` | AVAILABLE |
| `URL`, `appendingPathComponent`, `appendingPathExtension`, `.path` | ~25 sites | AVAILABLE (but see §1.5 for separator semantics) |
| `URL(string:)` | `DeepLinks.swift:11,16,22` | AVAILABLE |
| `URL(fileURLWithPath:)` | `main.swift:31` (out of scope, noted for the FFI entry point) | AVAILABLE |
| `UUID()` | `GraphModel.swift:62,82` | AVAILABLE |
| `LocalizedError` / `errorDescription` | `Models.swift:14,29` | AVAILABLE |

### 1.3 Foundation — JSON. AVAILABLE, but the **casts are the #1 portability trap**

`JSONSerialization` itself is present on Windows
(`Validate.swift:29,57,58`; `SessionsModel.swift:180,481,491`;
`GraphModel.swift:370,385,403`; `PlanFitModel.swift:171`;
`ConfigStore.swift:304,312`; `SnapshotLogger.swift:86,87`;
`ScopedLimitLogger.swift:75,76` — 16 sites). What is *not* portable is how
this codebase reads values out of the resulting `[String: Any]`.

Verified locally on macOS (Swift 6.2.4, Darwin): `JSONSerialization` returns
`__NSCFBoolean` / `__NSCFNumber`, and Objective-C bridging makes
`as? Bool`, `as? Int`, `as? Double` all succeed. **Objective-C bridging does
not exist on Windows.** On swift-corelibs-foundation these values come back
as `NSNumber` (or, under the newer swift-foundation JSON implementation, as
native Swift values — the two possibilities fail on *opposite* halves of the
codebase, which is exactly why this must be measured, not reasoned about).

The codebase already has a defensive helper for the numeric case —
`doubleValue(_:)` at `GraphModel.swift:432-436` and
`PlanFitModel.swift:318-322` try `as? NSNumber` *then* `as? Double`. But
**23 call sites bypass it**, and each failure mode is a silent wrong default,
not a crash:

| Cast | Sites | Silent failure if bridging differs |
|---|---|---|
| `as? Bool` | `Client.swift:243,252,316,331,361`; `PlanFitModel.swift:274,275,297`; `SessionsModel.swift:162,185,198,199,204,205,211`; `ConfigStore.swift:402,406` | `?? false` / `?? true` — every toggle reads off, `handled` reads false, the API envelope's `ok`/`loggedOut` checks fail ⇒ **every API call returns `.unexpectedShape`** |
| `as? Double` (no NSNumber fallback) | `SessionsModel.swift:188,189` | `resets_at` / `last_activity_at` become nil ⇒ waiting sessions render as active, no countdown |
| `as? Int` | `ConfigStore.swift:372` | `version` silently 1 |
| `as? NSNumber` (no Double fallback) | `Client.swift:268,303,305,315,323,324,328,330,359`; `ConfigStore.swift:381,382,387,405`; `Models.swift:48` | usage percents, spend limits, scoped-limit percents all nil ⇒ blank bars |

`Client.swift:243` and `:252` are the load-bearing ones: `envelope()` gates
*every* API response on `dict["ok"] as? Bool`. If that cast fails, the whole
ClaudeAPI module is dead on Windows with a generic "bad envelope" error.

`NSNull` (`ConfigStore.swift:195,199`, `SnapshotLogger.swift:74,75`,
`ScopedLimitLogger.swift:64-67`) and `JSONSerialization.isValidJSONObject`
(`Validate.swift:57`, `SnapshotLogger.swift:86`, `ScopedLimitLogger.swift:75`)
are AVAILABLE, but `isValidJSONObject`'s acceptance set is defined in terms of
`NSNumber`/`NSString`/`NSNull`, so a core that stops using `NSNumber` must
re-check those three guards.

**Recommendation regardless of the Windows decision:** route every one of the
23 sites through one `JSONValue` accessor set (`json.bool(_:)`,
`json.double(_:)`, `json.int(_:)`, `json.string(_:)`) that tries
`NSNumber`, native Swift, and `NSString`. This is a macOS-safe refactor
(≈1 day) and it is the single highest-leverage portability change in the
audit.

### 1.4 Foundation — dates, calendars, timezones. Mostly AVAILABLE; two live landmines

Plan-fit and snapshot code is timezone-sensitive by design, and the existing
code is already careful — `GraphModel.utcDailyKeyFormatter()`
(`GraphModel.swift:323-332`) pins `en_US_POSIX` + explicit Gregorian + UTC
precisely because a non-Gregorian system calendar made `"yyyy"` era-relative
(the R2-6 fix). That discipline ports.

| Symbol | Sites | Class |
|---|---|---|
| `ISO8601DateFormatter` + `.withInternetDateTime`/`.withFractionalSeconds` | `Client.swift:418-426`, `GraphModel.swift:423-430`, `PlanFitModel.swift:301-306`, `SnapshotLogger.swift:69-70`, `ScopedLimitLogger.swift:55-56` | AVAILABLE — offset-free (`Z`), so tz-database-independent |
| `DateFormatter` + `dateFormat` | `GraphModel.swift:274-276` (`"MMM d"`), `:323-332` (`"yyyy-MM-dd"`) | **NEEDS-SHIM** — §2.2: `corelibs#5202` is an **open Windows crasher** whose reproducer is `en_US_POSIX` + Gregorian calendar + set `timeZone`, i.e. `utcDailyKeyFormatter()` exactly |
| `NumberFormatter` (`.decimal`) | `PlanFitModel.swift:347-353,358` | AVAILABLE — ICU data is embedded in the toolchain (§2.2), but this is CoreFoundation-backed, the fragile half |
| `Locale(identifier: "en_US_POSIX")` | `GraphModel.swift:325` | AVAILABLE |
| `Calendar(identifier: .gregorian)` | `GraphModel.swift:236,247,326,514,542` | AVAILABLE — explicit identifier, so it avoids `Calendar.current` |
| `Calendar.startOfDay(for:)` | `GraphModel.swift:238,549` | AVAILABLE |
| `Calendar.dateComponents([.year,.month,.day,.hour], from:)` + `date(from:)` | `GraphModel.swift:249-250,516-517` | AVAILABLE |
| `Calendar.date(byAdding: .day, ...)` | `GraphModel.swift:554` | AVAILABLE |
| `TimeZone(identifier: "UTC")` | `GraphModel.swift:237,248,327,329,515,543` | AVAILABLE (tzdata is embedded — §2.2) |
| `TimeZone.current` (via `?? .current`) | `GraphModel.swift:237,248,515,543` | **NEEDS-SHIM** — see below |

**Landmine — the `?? .current` fallback, not the `TimeZone(identifier:)`
call.** §2.2 resolved the tz-database question favourably: Windows embeds
tzdata in the binary via `swift-foundation-icu`, so `TimeZone(identifier:
"UTC")` works with no system package and no registry read — *better* than
Linux. So the primary expression is fine.

The **fallback** is not. Four sites fall through to `TimeZone.current`, and
`TimeZone.current` on Windows has two open defects that both land here:

- It returns **GMT on any non-English Windows install** — `findCurrentTimeZone()`
  reads the *localized* `StandardName` and feeds it to an English-keyed ICU
  lookup. Diagnosed on the forums 2026-03-20; **no issue filed, unfixed**.
- Concurrent `Calendar.current` + `TimeZone.current` causes access violations
  and `STATUS_HEAP_CORRUPTION` on Windows 11
  ([swift-foundation#1886](https://github.com/swiftlang/swift-foundation/issues/1886),
  open against 6.3) — and `GraphModel.refresh()` runs its parsing on a global
  queue (`:180`) while the main thread formats.

If either fires, this code does not crash cleanly and does not log — it
silently shifts every daily/hourly bucket key by the local UTC offset. The
daemon writes `plan_fit.json`'s `cost_series.daily` keys in UTC; the widget
would look up `"2026-07-25"` for what the daemon wrote as `"2026-07-26"`, and
the 3mo cost chart would read **$0 or wrong-by-one-day, with no error
anywhere**.

Fix (macOS-safe, do it now): replace all six with
`TimeZone(secondsFromGMT: 0)!`, constructed arithmetically — no ICU, no
`.current`, no tz database. Two lines of diff each, and it deletes the entire
risk class.

**Separately: `DateFormatter` itself is an open Windows crasher for this exact
configuration.** `corelibs#5202` (2025-04-17, open) reports a crash in
`NSTimeZone.default`'s setter reached from a `DateFormatter` built with
`en_US_POSIX` and a Gregorian calendar. That is `utcDailyKeyFormatter()`
verbatim. Mitigation: the daily key is `"yyyy-MM-dd"` on a UTC-anchored
`Date` — trivially computable from `Calendar.dateComponents` and
`String(format:)` without any `DateFormatter` at all. Doing that removes both
the crasher and the ICU dependency from the hottest formatting path in the
core, and is again macOS-safe.

Secondary note: `PlanFitModel.swift:301-306` holds two `ISO8601DateFormatter`
instances as `static let` and uses them from `refresh()`, which runs off the
main thread. `DateFormatter` family thread-safety is documented-safe on Darwin
since macOS 10.9 but is *not* a guarantee corelibs has historically upheld.
Cheap fix: make them computed, or wrap in a lock, when the core moves.

### 1.5 Foundation — filesystem. Mixed; the path encoding is a hard blocker

| Symbol | Sites | Class |
|---|---|---|
| `FileManager.default.homeDirectoryForCurrentUser` | `SessionsModel.swift:164,389`, `GraphModel.swift:152`, `PlanFitModel.swift:158`, `ConfigStore.swift:89`, `SnapshotLogger.swift:39`, `ScopedLimitLogger.swift:35` | AVAILABLE (`%USERPROFILE%`) |
| `createDirectory(at:withIntermediateDirectories:)` | `Validate.swift:55`, `SessionsModel.swift:165`, `ConfigStore.swift:91`, `SnapshotLogger.swift:42`, `ScopedLimitLogger.swift:38` | AVAILABLE |
| `contentsOfDirectory(at:includingPropertiesForKeys:)` | `SessionsModel.swift:396` | AVAILABLE |
| `attributesOfItem(atPath:)[.modificationDate]` | `PlanFitModel.swift:169,190`, `ConfigStore.swift:132` | AVAILABLE — but see §2.2: open Windows bugs (crashes on files > 2 GB, wrong `.systemFileNumber`). Not reachable with these files' sizes; noted only. |
| `URL.path` fed to POSIX/Win32 | `SessionsModel.swift:461`, `ConfigStore.swift:132,331`, `PlanFitModel.swift:169,190`, `SnapshotLogger.swift:111,122` | **NEEDS-SHIM** — [swift-foundation#973](https://github.com/swiftlang/swift-foundation/issues/973) (open): `URL.path` returns **forward slashes** on Windows (`C:/Users/alex`). Win32 tolerates them in many APIs but not all, and the string then differs from what the Python daemon writes. Use `withUnsafeFileSystemRepresentation` at every boundary. |
| `URL.resourceValues(forKeys: [.creationDateKey])` | `SessionsModel.swift:408` | **VERIFY** — NTFS has a creation time, but `.creationDateKey` support in corelibs on Windows is not something §2 could confirm. If unimplemented this returns nil ⇒ the whole cloud-echo dedupe (`SessionsModel.swift:323`, `CloudSessionsModel.swift:147-150`) silently stops working and every local session grows a phantom cloud twin. |
| `FileManager.replaceItemAt(_:withItemAt:)` | `SessionsModel.swift:498`, `ConfigStore.swift:318` | **NEEDS-SHIM** — §1.6 |
| `(String as NSString).lastPathComponent` | `SessionsModel.swift:192` | **NEEDS-SHIM** — splits on `/` only; on a Windows `project_dir` (`C:\Users\sam\git\x`) it returns the whole string. Replace with `URL(fileURLWithPath:).lastPathComponent`. |

**Hard blocker — the transcript-folder encoding.**
`SessionsModel.transcriptCreationDate` (`:388-405`) reconstructs Claude Code's
project-folder name by `projectDir.replacingOccurrences(of: "/", with: "-")`
then `"." → "-"` (`:391-393`). That encoding is a macOS/POSIX artifact. A
Windows `project_dir` is `C:\Users\sam\git\claude-widget`, which contains a
drive-letter colon and backslashes. This is exactly recon question **R2** in
`windows-port-plan.md:39` and it gates this function entirely; the fallback
directory scan at `:396-404` would carry it, but that scan runs under the
state flock on every refresh and is rate-limited by the R2-5 negative cache,
so relying on the fallback permanently is a performance regression, not a fix.

**Case sensitivity:** nothing in scope compares paths case-sensitively.
Session ids are lowercase UUIDs and `"\(id).jsonl"` lookups are exact. The
only case-folding in scope (`CloudSessionsModel.swift:152`,
`Client.swift:376-377`) is on API strings, not paths. **No case-sensitivity
blockers found** — a genuinely clean result.

### 1.6 POSIX / Darwin — UNAVAILABLE, and this is the load-bearing cross-process contract

Three of the nine widget files `import Darwin`
(`SessionsModel.swift:3`, `ConfigStore.swift:3`, `SnapshotLogger.swift:2`).

| Symbol | Sites | Class |
|---|---|---|
| `import Darwin` | `SessionsModel.swift:3`, `ConfigStore.swift:3`, `SnapshotLogger.swift:2` | **UNAVAILABLE** (`import WinSDK` / `ucrt`) |
| `open(path, O_RDWR \| O_CREAT, 0o644)` | `SessionsModel.swift:461`, `ConfigStore.swift:331`, `SnapshotLogger.swift:111` | **NEEDS-SHIM** (`_open`/`CreateFileW`; mode bits meaningless) |
| `open(path, O_WRONLY \| O_CREAT \| O_APPEND, 0o644)` | `SnapshotLogger.swift:122` | **NEEDS-SHIM** — and the atomicity guarantee changes: POSIX `O_APPEND` gives an atomic seek+write; Windows needs `FILE_APPEND_DATA` without `FILE_WRITE_DATA` to get the same |
| `flock(fd, LOCK_EX)` / `LOCK_UN` | `SessionsModel.swift:463,465`, `ConfigStore.swift:333,335`, `SnapshotLogger.swift:113,117` | **UNAVAILABLE** → `LockFileEx`/`UnlockFileEx` on byte 0 |
| `close(fd)` | `SessionsModel.swift:466`, `ConfigStore.swift:336`, `SnapshotLogger.swift:119,124` | **NEEDS-SHIM** (`_close`) |
| `Darwin.write(fd, ptr, count)` | `SnapshotLogger.swift:126` | **NEEDS-SHIM** (`_write`) |

Three things about this that matter more than the mechanical substitution:

1. **The "never `createFile`, flock is per-inode" discipline** (hardening item
   #1, documented at `SessionsModel.swift:449-457`, copied verbatim to
   `ConfigStore.swift:324-327` and `SnapshotLogger.swift:99-103`) is a POSIX
   fact with no Windows analogue. `windows-port-plan.md:63-66` already says
   this. What must be carried across is the *intent*: one stable lock object
   shared with the daemon. Since `LockFileEx` is handle-and-range based, the
   Windows implementation must open the lock file with `FILE_SHARE_READ |
   FILE_SHARE_WRITE` and lock byte 0 — matching whatever `remote_ctl.py`/
   `autoresume.py` do after daemon blocker B1. **The Swift and Python
   implementations must be written against each other, not independently**,
   and proven with a two-process test (§6.3 step 5).
2. **`replaceItemAt` and `.atomic` are the sharing-violation hazard — and
   this is now confirmed upstream, not just predicted.**
   `windows-port-plan.md:67-84` documents it for the daemon; it applies
   identically to `SessionsModel.swift:498`, `ConfigStore.swift:318`, and
   `ScopedLimitLogger.swift:87`. Foundation has two open Windows bugs saying
   the same thing:
   [swift-foundation#1507](https://github.com/swiftlang/swift-foundation/issues/1507)
   (concurrent atomic writes fail with `ERROR_ACCESS_DENIED`) and
   [#2078](https://github.com/swiftlang/swift-foundation/issues/2078)
   (**the atomic write is not actually atomic on Windows**). Every atomic
   write in the core needs a `replaceWithRetry(tmp:dst:)` shim with bounded
   backoff. There is no better Foundation API to pick — this is a defect in
   the one that exists.
3. **`SnapshotLogger` writes a file the Python compactor also rewrites**
   (`SnapshotLogger.swift:14-23`). This is the one place where a lock bug
   loses data rather than just racing. It deserves the dedicated
   two-process test, not a unit test.
4. **⚠️ The Windows shim must open in binary mode.** On Windows the CRT
   defaults to *text* mode, so a naive `_open`/`_write` port of
   `SnapshotLogger.append` (`:122-127`) would translate every `\n` into
   `\r\n` — silently corrupting the jsonl the Python compactor parses, one
   byte at a time, with no error. This is the same class of bug Foundation
   itself has open for `FileHandle`
   ([corelibs#5105](https://github.com/swiftlang/swift-corelibs-foundation/issues/5105)).
   Pass `_O_BINARY` (or use `CreateFileW`/`WriteFile`, which have no text
   mode). Add a byte-for-byte round-trip assertion to the test suite.

### 1.7 Combine — UNAVAILABLE. 48 uses across 7 of the 9 in-scope model files

| Symbol | Sites | Count |
|---|---|---|
| `import Combine` | `UsageModel.swift:2`, `SessionsModel.swift:2`, `GraphModel.swift:2`, `PlanFitModel.swift:2`, `CloudSessionsModel.swift:2`, `ConfigStore.swift:2`, `ChatsModel.swift:2` | 7 |
| `ObservableObject` conformance | `UsageModel.swift:8`, `SessionsModel.swift:135`, `GraphModel.swift:96`, `PlanFitModel.swift:146`, `CloudSessionsModel.swift:42`, `ConfigStore.swift:69`, `ChatsModel.swift:26` | 7 |
| `@Published` | `UsageModel.swift:9,10,12,13,15,16,17,23,25`; `SessionsModel.swift:136,137,142,359`; `GraphModel.swift:100,103,110,111,112,113,114,115,118,125`; `PlanFitModel.swift:147`; `CloudSessionsModel.swift:45,49,56,57,58,59`; `ConfigStore.swift:71`; `ChatsModel.swift:27,29,30,31,33` | 36 |

Plus the **consumer** side, all outside the audited set but tightly coupled:
`AppDelegate.swift:62` (`Set<AnyCancellable>`) and four
`$property.sink(...).store(in:)` chains at `AppDelegate.swift:320-327`
(`$sessionsExpanded`), `:340-346` (`$selectedTab`), `:354-359` (`$data`),
`:367-…` (`$config`); and 13 `@ObservedObject`/`@StateObject` declarations in
`OverlayView.swift`, `GraphView.swift`, `ExpandedGraphView.swift`,
`SettingsWindow.swift`.

`AppDelegate.swift:322` deserves specific mention: the comment there
(`"@Published emits on willSet; hop a beat so the resize runs after the value
has actually changed"`) documents a dependence on `@Published`'s
**will-change, not did-change** semantics. Any replacement primitive must
preserve willSet ordering or that comment's workaround (`.receive(on:
DispatchQueue.main)`) stops being sufficient. This rules out several otherwise
attractive designs — see §3.

Two `@Published` properties are **not model state at all** and should leave
the core regardless of platform: `SessionsModel.sessionsExpanded`
(`:142-144`) and `GraphModel.selectedTab`/`period` (`:100-108`) are view
preferences persisted to `UserDefaults`.

### 1.8 Dispatch — AVAILABLE, with one confirmed blocker

| Symbol | Sites | Class |
|---|---|---|
| `DispatchQueue(label:)` (serial) | `SessionsModel.swift:443`, `ConfigStore.swift:80`, `SnapshotLogger.swift:29`, `ScopedLimitLogger.swift:32` | AVAILABLE |
| `DispatchQueue.global(qos: .utility).async` | `GraphModel.swift:180` | AVAILABLE |
| `DispatchQueue.main.async` | `SessionsModel.swift:342`, `GraphModel.swift:191`, `PlanFitModel.swift:172,176`, `ConfigStore.swift:139` | **NEEDS-SHIM** |
| `DispatchQueue.main.asyncAfter` | `WebSession.swift:128`, `main.swift:36` (out of scope; noted for FFI) | **NEEDS-SHIM** |

libdispatch is part of the Swift Windows toolchain, and serial/global queues
work. `DispatchQueue.main` is the problem, and §2.4 upgrades this from
inference to **a confirmed, open, independently re-reported defect**: on
non-Darwin, main-executor initialisation calls `dispatchMain()`, which
unconditionally calls `_endthreadex`, so a host run loop does not help;
`Thread.isMainThread` returns false and `MainActor` isolation is not
recognised ([libdispatch#846](https://github.com/swiftlang/swift-corelibs-libdispatch/issues/846),
open since 2024-09-20). Someone hit exactly this architecture — SwiftPM
dynamic library, .NET 8, P/Invoke — on **2026-07-23**
([forums 88469](https://forums.swift.org/t/swift-concurrency-mainactor-does-not-execute-when-swift-dll-is-called-from-net-on-windows/88469)),
and Cascable reported the same thing in 2024.

In the macOS app, `NSApplication.run()` drains the main queue. In a `.dll`
loaded by a WPF process, nothing does — the .NET main thread runs a WPF
`Dispatcher` loop that knows nothing about libdispatch. Every
`DispatchQueue.main.async { self.data = … }` in the core would enqueue work
that **never executes**, and the failure is total silence: no data ever
publishes.

The same evidence gives the operational rule: **C-ABI entry points must be
synchronous, `@MainActor`-free, and free of Swift concurrency.** The one piece
of good news in that forum thread is the sentence *"synchronous exported C
functions execute correctly"* — which is precisely the FFI shape §5 proposes.
Do not be tempted to make an entry point `async`.

This is not a Combine problem and it is not solved by §3. The core needs its
own scheduler seam:

```swift
public protocol CoreScheduler: Sendable {
    func onMain(_ work: @escaping () -> Void)
}
```

macOS supplies `DispatchQueue.main`; Windows supplies a shim that either posts
to the host's UI thread through a registered C callback, or (simpler) calls
`work()` inline on the calling thread and makes the *C# side* responsible for
marshalling to the WPF `Dispatcher`. The latter is better: it keeps the FFI
one-directional for this concern and matches how P/Invoke consumers expect to
work. It does mean the core's `@Observed` notifications fire on a background
thread on Windows, which the C# adapter must `Dispatcher.BeginInvoke`.

### 1.9 Foundation — logging, defaults, and the transport

| Symbol | Sites | Class |
|---|---|---|
| `NSLog` | `Models.swift:177` (comment only), `SessionsModel.swift:478,482,486,492,500`, `ConfigStore.swift:313,320`, `ScopedLimitLogger.swift:91` | **NEEDS-SHIM** — 8 real call sites |
| `UserDefaults.standard` | `SessionsModel.swift:143,162`, `GraphModel.swift:101,105,149,150` | **NEEDS-SHIM** — and should leave the core |
| `error.localizedDescription` | `Client.swift:238`, `SessionsModel.swift:500`, `ConfigStore.swift:320`, `ScopedLimitLogger.swift:91` | AVAILABLE (Foundation `Error` extension) |
| `WKWebView` / `WKWebsiteDataStore` / `HTTPCookie` | `WebSession.swift` (out of scope) | **UNAVAILABLE** — §1.10 |

**`NSLog` has no Windows equivalent worth using.** It does exist and does not
crash — CoreFoundation's `CFLog1` takes the `also_do_stderr()` path for
`TARGET_OS_WIN32`, so output goes to **stderr and nowhere else**. Notably it
does **not** call `OutputDebugString`, so nothing appears in a Visual Studio
or WinDbg output pane either. Three things make it wrong for the shared core:

1. The call sites use printf-style `%@` with Swift `String` arguments
   (`SessionsModel.swift:478`: `NSLog("[SessionsModel] mutate(%@): read failed", sessionId)`).
   `%@` is an Objective-C format specifier. On corelibs `String` does conform
   to `CVarArg`, but this is the exact category of thing that silently prints
   garbage rather than failing to compile.
2. In a DLL, stderr is usually nowhere. The whole point of those NSLogs
   (hardening item S8 — "a toggle that silently reverts is at least
   diagnosable from Console.app") is lost.
3. The C# host wants these in *its* log sink.

**Replacement:** a 20-line `CoreLog` with a settable sink.

```swift
public enum CoreLogLevel: Int32 { case debug = 0, info = 1, warn = 2, error = 3 }

public enum CoreLog {
    /// Host-installed sink. macOS installs an NSLog/os_log forwarder;
    /// the FFI installs a C callback into the C# logger.
    public static var sink: ((CoreLogLevel, String) -> Void)?
    public static func error(_ msg: @autoclosure () -> String) {
        sink?(.error, msg())      // no-op when unset — never writes to a
    }                             // stream the host doesn't own
}
```

Rewrite the 8 sites as string interpolation (`CoreLog.error("[SessionsModel]
mutate(\(sessionId)): read failed")`), which also removes the `%@` hazard.
This is a macOS-safe change today.

**`UserDefaults` should not be in the shared core**, and §2.2 makes the case
stronger than "it's untidy". Its Windows implementation persists to a
**hand-assembled** `C:\Users\<CFGetUserName()>\AppData\Local\…` path rather
than calling `SHGetKnownFolderPath`, so on a domain-joined machine or any
profile whose directory name differs from `%USERNAME%`, **every write silently
fails**
([corelibs#4997](https://github.com/swiftlang/swift-corelibs-foundation/issues/4997),
open since 2024-06-28). It is also keyed by bundle identifier — a concept a
DLL loaded into `MyApp.exe` does not have. All six sites are view preferences
(sessions expanded, selected tab, graph period). Move them into a host-owned
`Preferences` protocol with a two-method surface (`bool(forKey:)`,
`set(_:forKey:)`); macOS backs it with `UserDefaults`, Windows with the
registry or a JSON file next to `config.json`.

### 1.10 The `ClaudeAPI` transport — the finding that reshapes the plan

The brief assumes `WebSession.swift` "stays platform-specific" and the other
four `ClaudeAPI` files become shared. That separation does not hold as the
code is written:

- `ClaudeAPIClient` **constructs** `ClaudeWebSession` directly
  (`Client.swift:13` `private let session: ClaudeWebSession`,
  `Client.swift:23` `self.session = ClaudeWebSession()`). There is no
  protocol; the concrete WebKit type is the dependency.
- Every call's payload is a **JavaScript source string**
  (`Client.swift:32-43,63-93,122-158,212-224`), ~120 of Client.swift's 310
  code lines. The transport contract is "run this async JS function body
  inside an authenticated claude.ai page and give me back the returned
  object". That is not an HTTP client; it is a JS execution environment.
- `Client.swift:191-204` (`signOut`, `signIn(sessionKey:)`) reach further into
  cookie-store and navigation-lifecycle behaviors of the webview.
- `Client.swift:235` type-matches `ClaudeWebSessionError.backlogFull` — an
  error case owned by the transport — to map it to `ClaudeAPIError.backlogFull`.

Abstracting this is mechanical (introduce
`protocol ClaudeScriptRunner { func run(script: String, completion: @escaping (Result<Any, Error>) -> Void) }`
and inject it), but the *consequence* is not: on Windows the implementation of
that protocol lives in **C#/WebView2**, above the FFI boundary. So the shared
Swift core does not call out to the world; it must be **called back into** with
results. The FFI stops being a one-way "C# asks Swift for JSON" boundary and
becomes bidirectional. §5 sketches how, but this is the single biggest
structural surprise in the audit and it is Risk R1.

### 1.11 Summary counts

| Class | Distinct symbols | Call sites |
|---|---:|---:|
| AVAILABLE | ~35 | ~250 |
| NEEDS-SHIM | 14 | ~70 |
| UNAVAILABLE | 4 (`Combine`, `flock`, `import Darwin`, `WebKit`) | 48 + 6 + 3 + all of `WebSession` |
| VERIFY (§2 could not settle) | 2 (`.creationDateKey`, `ISO8601DateFormatter` vs the `DateFormatter` crasher) | 6 |

(The ICU/tzdata question §1.4 raised was **settled favourably** by §2.2 — tz
data is embedded in the toolchain. The `.atomic`-on-Windows question was
settled **unfavourably**: it is an open upstream defect, not a maybe.)

---

## 2. Current toolchain status

All facts below were verified against primary sources on **2026-07-26**. Every
claim carries a URL and a date. Where a source could not be found, it says
**unverified** — do not upgrade those to facts.

**Headline: the picture is better than expected in two places and materially
worse in two others.** Better: the toolchain installs cleanly with no MSVC
modulemap surgery, Windows is now a top-tier supported platform with PR
testing and a governing workgroup, and — contrary to a 2021 forum answer that
still circulates — **SwiftPM → DLL → C# P/Invoke demonstrably works today** for
synchronous C-ABI functions. Worse: **there is no working main dispatch queue
when a Swift DLL is hosted in a .NET process** (a confirmed, open, 2-year-old
defect, re-reported three days before this audit), and **Foundation's
C-backed half — the formatters, `UserDefaults`, `Bundle`, atomic writes — has a
live Windows bug queue that lands directly on this codebase**, including a
crasher whose reproducer is character-for-character `GraphModel`'s daily-key
formatter.

### 2.1 Toolchain and installation

- **Latest release: Swift 6.3.3.** 6.3.0 shipped 2026-03-24
  ([swift.org/blog/swift-6.3-released](https://www.swift.org/blog/swift-6.3-released/));
  6.3.4 closed its merge window 2026-07-24
  ([forums 88288](https://forums.swift.org/t/development-open-for-swift-6-3-4-for-non-darwin-platforms/88288)).
  Local reference point: this repo's Mac builds with Apple Swift 6.2.4.
- **Install path is winget, in two commands** — the toolchain alone is not
  enough ([swift.org/install/windows/winget](https://www.swift.org/install/windows/winget/)):
  ```
  winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom ^
    "--add Microsoft.VisualStudio.Component.Windows11SDK.22000 ^
     --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
     --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
  winget install --id Swift.Toolchain -e --source winget
  ```
  Also needs Python 3.10, Git for Windows, and **Developer Mode enabled**
  ([swift.org/install/windows/manual](https://www.swift.org/install/windows/manual/)).
- **The MSVC modulemap-copy step is gone.** Copying `ucrt.modulemap` /
  `visualc.modulemap` into the Windows SDK was required only for Swift < 5.9
  ([swift.org/install/windows/archived](https://www.swift.org/install/windows/archived/)).
  Good news — that step was the historical reason Swift-on-Windows setups rotted.
- **⚠️ `swiftly` does not support Windows.**
  [swiftlang/swiftly#151](https://github.com/swiftlang/swiftly/issues/151) has
  been open since 2024-08-06 with no assignee and no linked PR; latest swiftly
  release 1.1.3 (2026-06-17) is Linux/macOS only. Toolchain *management* on
  Windows is manual. Plan for pinned toolchain versions in CI by installer
  version, not by `swiftly use`.
- **Platform tier: "Deployment and Development"** — the top category on
  [swift.org/platform-support](https://www.swift.org/platform-support/), with
  Apple-provided toolchains and **pull-request testing**. SwiftPM, SourceKit-LSP
  and the debugger are all ✓. ⚠️ The **REPL is not available** on Windows.
  Minimum deployment target Windows 10.0.
- **A Windows Workgroup now exists** (announced 2026-01-26,
  [swift.org/blog/announcing-windows-workgroup](https://www.swift.org/blog/announcing-windows-workgroup/)),
  and its charter explicitly includes *"identify best practices for … shipping
  Swift libraries with Windows applications"* — i.e. the exact gap §2.5
  describes is a known, owned problem, not an oversight.
- **⚠️ 32-bit Windows is broken at the calling-convention level**
  ([swiftlang/swift#85263](https://github.com/swiftlang/swift/issues/85263),
  2025-11-01, open): imported Win32 `stdcall` is treated as `cdecl` → stack
  corruption. Target x64 or ARM64 only. ARM64 toolchains are published for
  6.3.x but are newer and thinner (e.g.
  [#76881](https://github.com/swiftlang/swift/issues/76881), open since
  2024-10-05).

### 2.2 Foundation completeness — the important nuance

`import Foundation` on Windows has been backed by the Swift-native
**swift-foundation** since Swift 6.0
([forums 73530, 2024-07-29](https://forums.swift.org/t/swift-foundation-now-available/73530)),
with swift-corelibs-foundation re-exporting `FoundationEssentials` +
`FoundationInternationalization`.

**⚠️ But "Foundation was rewritten in Swift" is only about half true, and this
codebase uses both halves.**

- **Swift-native (solid):** `URL`, `Data`, `Date`, `Calendar`, `TimeZone`,
  `Locale`, `FileManager`, `JSONSerialization`, `JSONEncoder`/`Decoder`,
  `FormatStyle`.
- **Still C / CoreFoundation-backed (fragile):** `DateFormatter`,
  `ISO8601DateFormatter`, `NumberFormatter`, `Bundle`, `UserDefaults`,
  `RunLoop`, `Timer`, `NSLog`, `Process`, `URLSession` internals.

Every open Windows Foundation bug that touches this codebase is in the second
list. Specifics, with the in-scope call sites they hit:

| Upstream issue | Date / status | Hits |
|---|---|---|
| [corelibs#5202](https://github.com/swiftlang/swift-corelibs-foundation/issues/5202) — crash in `NSTimeZone.default` setter from a `DateFormatter` configured with `en_US_POSIX` + Gregorian calendar | 2025-04-17, **OPEN** | **`GraphModel.utcDailyKeyFormatter()` (`:323-332`) is this reproducer, line for line.** Also `:274-276`. |
| [swift-foundation#1886](https://github.com/swiftlang/swift-foundation/issues/1886) — concurrent `Calendar.current` + `TimeZone.current` → access violation / `STATUS_HEAP_CORRUPTION` on Windows 11, stack through `_timeZoneIdentifier(forWindowsIdentifier:)` | 2026-04-08, **OPEN**, against 6.3 | The `?? .current` fallbacks at `GraphModel.swift:237,248,515,543` — reached from a background queue (`:180`) while the main thread also formats. |
| `TimeZone.current` returns **GMT on any non-English Windows** — `findCurrentTimeZone()` reads the *localized* `StandardName` from `GetTimeZoneInformation` and feeds it to an English-keyed ICU lookup. Diagnosed [2026-03-20](https://forums.swift.org/t/getting-the-current-time-zone-in-non-english-regions-does-not-meet-expectations/85329); **no issue filed, unfixed** | 2026-03-20 | Same four sites. Silently wrong, never an error. |
| [swift-foundation#1507](https://github.com/swiftlang/swift-foundation/issues/1507) — concurrent atomic writes fail with `ERROR_ACCESS_DENIED`; [#2078](https://github.com/swiftlang/swift-foundation/issues/2078) — atomic write **isn't actually atomic** on Windows | 2025-09-11 / 2026-07-02, both **OPEN** | `ScopedLimitLogger.swift:87` (`.atomic`), `SessionsModel.swift:498` and `ConfigStore.swift:318` (`replaceItemAt`). **Upstream confirmation of §1.6's hazard.** |
| [swift-foundation#973](https://github.com/swiftlang/swift-foundation/issues/973) — **`URL.path` returns forward slashes on Windows** (`URL(fileURLWithPath: #"C:\Users\alex"#).path` → `C:/Users/alex`) | 2024-10-10, **OPEN** | Eight sites feed `.path` to POSIX/Win32 APIs: `SessionsModel.swift:461`, `ConfigStore.swift:132,331`, `PlanFitModel.swift:169,190`, `SnapshotLogger.swift:111,122`. Use `withUnsafeFileSystemRepresentation`. |
| [corelibs#5258](https://github.com/swiftlang/swift-corelibs-foundation/issues/5258) / [swift-foundation#2096](https://github.com/swiftlang/swift-foundation/issues/2096) — `attributesOfItem` **crashes on files > 2 GB**; [#2107](https://github.com/swiftlang/swift-foundation/issues/2107) — `.systemFileNumber` wrong (32-bit shift) | 2025-08-14 / 2026-07-10 / 2026-07-14, **OPEN** | `PlanFitModel.swift:169,190`, `ConfigStore.swift:132`. Files involved are small today; `snapshots.jsonl` is compacted by the daemon, so 2 GB is not reachable in practice. Low but non-zero. |
| [corelibs#4997](https://github.com/swiftlang/swift-corelibs-foundation/issues/4997) — `UserDefaults` writes **silently fail** when `%USERNAME%` ≠ the profile directory name (domain-joined / renamed profiles), because `CFKnownLocations.c` hand-assembles the path instead of calling `SHGetKnownFolderPath` | 2024-06-28, **OPEN** | `SessionsModel.swift:143`, `GraphModel.swift:101,105`. Reinforces §1.9: get `UserDefaults` out of the core. |
| [corelibs#5105](https://github.com/swiftlang/swift-corelibs-foundation/issues/5105) — `FileHandle` opens without `_O_BINARY` → **silent CRLF corruption** | 2024-10-13, **OPEN** | Not hit directly (this code uses raw `open`/`write`), **but the same trap applies to the shim**: on Windows the CRT defaults to text mode, so a naive `_open` + `_write` in `SnapshotLogger.append` (`:122-127`) would translate `\n` → `\r\n` and corrupt the jsonl the Python compactor parses. The Windows shim **must** pass `_O_BINARY`. |
| [swift-foundation#2102](https://github.com/swiftlang/swift-foundation/issues/2102) — `Foundation.dll` `STATUS_ILLEGAL_INSTRUCTION` at a fixed offset on Windows Server 2025 / Ryzen, on 6.3.3, undiagnosed, zero comments | 2026-07-11, **OPEN** | Nothing specific — noted as a maturity signal. |

**Good news on timezones, with a catch.** `TimeZone(identifier: "UTC")` *does*
work on Windows: the tz database is **embedded in the binary** via
[swift-foundation-icu](https://github.com/swiftlang/swift-foundation-icu),
so unlike Linux there is no system `tzdata` package to install and no registry
read. **⚠️ The catch:** `_timeZoneICUClass()` is a nil-returning stub in
`FoundationEssentials`, dynamically replaced only by
`FoundationInternationalization`. A core that trims to
`import FoundationEssentials` for size gets `TimeZone(identifier:)` → **nil**
for every named zone, with only GMT-offset forms surviving. `import Foundation`
pulls both, so the current code is fine — but this is a landmine for anyone
who later "optimizes" the import.

`JSONSerialization`, `JSONEncoder`/`Decoder` and `Codable` are pure-Swift
`FoundationEssentials` with **no open Windows issues** — encouraging for §1.3,
though it does *not* answer the bridging-cast question, which is about
`as?` dynamic casts, not the parser. §6.3 step 2 still has to measure it.

`NotificationCenter`, `Timer`, `RunLoop`, `Process`, `NSHomeDirectory()`,
`contentsOfDirectory`, `fileExists` are all available with no in-scope
blockers. `URLSession` requires a separate `import FoundationNetworking` and
has open issues, but nothing in scope uses it.

### 2.3 Combine — **confirmed unavailable**; Observation *is* available

**Confirmed.** Apple's Combine is closed-source and ships only in Apple SDKs.
It does not exist on Windows, Linux or Wasm, and there is no plan for it to.

**⚠️ OpenCombine is dormant — do not plan on it.** Verified against the GitHub
API: latest release **0.14.0, published 2023-04-23**, still flagged
*prerelease*; `GET /releases/latest` returns 404 (there has never been a
non-prerelease release); **last commit to `main` was 2023-10-20** — about
2¾ years ago. Windows support did land (0.13.0, 2022-02-01), but nothing has
been adapted for Swift 6, strict concurrency or `Sendable`.

**Swift `Observation` (`@Observable`) DOES ship on Windows and Linux** — this
corrects a prior assumption. The compiler repo's
[`stdlib/public/Observation/CMakeLists.txt`](https://github.com/swiftlang/swift/tree/main/stdlib/public/Observation)
declares `SWIFT_MODULE_DEPENDS_WINDOWS WinSDK`, and the
`macOS 14+/iOS 17+` availability gate is an Apple-SDK restriction that does not
apply off-Darwin
([swift-perception discussion #71, 2024-05-06](https://github.com/pointfreeco/swift-perception/discussions/71)).
That removes one of the three reasons §3 rejected it — see §3.1 for why the
recommendation nonetheless stands.

### 2.4 Dispatch on Windows — and the finding that matters most

**Available:** `DispatchQueue`, `DispatchSemaphore`, `DispatchWorkItem`,
`DispatchGroup`, `DispatchSourceTimer` (no platform conditional), signal and
user-data sources, and Windows-specific read/write sources.

**⚠️ Not available** (verified verbatim in
[`src/swift/Source.swift`](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/swift/Source.swift)):

- `makeFileSystemObjectSource` — excluded on Windows. **No `DispatchSource`
  file-system monitoring.** Out of the audited scope, but it is exactly what
  `AppDelegate.swift:417` uses to watch the state directory; the Windows host
  needs `ReadDirectoryChangesW` / `FileSystemWatcher`, as
  `windows-port-plan.md:293` already anticipated.
- `makeProcessSource`, `makeMemoryPressureSource` — also excluded.

**⚠️⚠️ `DispatchQueue.main` does not work when a Swift DLL is hosted in a .NET
process. This is confirmed, open, and re-reported three days before this
audit.**

- [libdispatch#846](https://github.com/swiftlang/swift-corelibs-libdispatch/issues/846),
  opened **2024-09-20, still open**: work dispatched to `DispatchQueue.main`
  runs on the right thread *ID*, but `Thread.isMainThread` returns **false**
  and `MainActor.preconditionIsolated()` fails to recognise the context.
- [forums 88469](https://forums.swift.org/t/swift-concurrency-mainactor-does-not-execute-when-swift-dll-is-called-from-net-on-windows/88469),
  opened **2026-07-23** — Swift 6.3.2, Windows ARM64, .NET 8, SwiftPM-built
  dynamic library, C-ABI P/Invoke. Almost exactly the architecture in §4/§5.
  The reporter's key line is *both* the good news and the bad news:
  **"The DLL loads successfully and synchronous exported C functions execute
  correctly."** What fails is `Task { @MainActor in … }` / `await
  MainActor.run { }` — they silently never execute. Root cause per David Smith
  (2026-07-24): on non-Darwin, main-executor init calls `dispatchMain()`,
  which *"will unconditionally call `pthread_exit`/`_endthreadex`"*, so a host
  run loop doesn't help; you need a custom executor bridged to the host loop.
  **Thread unresolved.**
- Independently observed two years earlier by Daniel Kennett
  ([SwiftToCLR, 2024-02-12](https://ikennd.ac/blog/2024/02/swift-on-windows-with-swifttoclr/)):
  *"Swift lacks a working main dispatch queue when embedded in C#
  applications."*

This is §1.8's `CoreScheduler` finding, confirmed by three independent primary
sources rather than inferred. **The operational rule it implies:** every C-ABI
entry point must be **synchronous, `@MainActor`-free, and free of
`DispatchQueue.main`**. That is a design constraint on §5, not a bug to work
around later.

### 2.5 Shipping: runtime redistributable and static linking

**⚠️ Swift on Windows does not produce self-contained binaries.** Verbatim,
[forums 87411](https://forums.swift.org/t/what-is-needed-for-consumers-to-use-my-swift-written-dll-i-put-on-nuget/87411)
(2026-06): *"Swift on Windows does not create self-contained .dll and .exe
files, unlike some other compilers do."*

**What must ship alongside the app:** `swiftCore.dll`, `swiftCRT.dll`,
`swiftDispatch.dll`, `swiftWinSDK.dll`, `swift_Concurrency.dll`,
`BlocksRuntime.dll`, `dispatch.dll`, `Foundation.dll`,
`FoundationEssentials.dll`, plus — because this codebase formats dates and
numbers — `FoundationInternationalization.dll`, `_FoundationICU.dll` and the
ICU data DLLs, plus the MSVC redist (`vcruntime140.dll`, `msvcp140.dll`).
Call it **~12 DLLs**. They go in the .NET host's output directory: Windows
resolves a `DllImport`ed DLL's dependencies from the *process* search path.

- **⚠️ Do NOT add the runtime directory to the system `%PATH%`.**
  [swiftlang/swift#85321](https://github.com/swiftlang/swift/issues/85321):
  SwiftFormat's installer did exactly that and **broke the installed Swift
  toolchain** on affected machines. Fixed on the toolchain side 2026-05-30 by
  SxS-binding, which does not solve an app's own layout problem.
- **⚠️ The Windows Swift DLLs are still unversioned.** Three tracking issues
  filed by the Windows platform champion on **2026-07-21**
  ([swift-foundation#2124](https://github.com/swiftlang/swift-foundation/issues/2124),
  [corelibs#5520](https://github.com/swiftlang/swift-corelibs-foundation/issues/5520),
  [libdispatch#950](https://github.com/swiftlang/swift-corelibs-libdispatch/issues/950)).
  Until they land, two Swift-based apps coexisting on one machine is fragile.
- **Redistributable:** the toolchain installer contains MSIs that can be
  extracted and re-packaged. Merge modules (MSMs) were under investigation as
  of Dec 2024 ([forums 65358](https://forums.swift.org/t/improving-the-distribution-of-swift-on-windows/65358));
  **no evidence an official MSM shipped — unverified.** In 2026 the practical
  answer is "copy the DLLs next to your exe".
- **Licensing is fine:** Apache 2.0 **with the Runtime Library Exception**
  ([swift.org/LICENSE.txt](https://www.swift.org/LICENSE.txt)). Redistributing
  the runtime DLLs is ordinary Apache-2.0 redistribution (retain
  license/NOTICE).

**⚠️ Static linking is not an option on Windows today.**
[forums 77728, "Towards `-static-stdlib` support on Windows"](https://forums.swift.org/t/towards-static-stdlib-support-on-windows/77728)
(2025-02): IRGen and dependency scanning are done, but ~11 items remain —
including *building a static Foundation*, static libdispatch, and concurrency
runtime work. No primary source says it completed; `swift.org`'s
`static-linking-on-windows.html` is a **404**. Contrast Linux, which has a
fully supported Static Linux SDK. SwiftPM gained `--[no-]static-swift-stdlib`
parity plumbing ([PR #9417](https://github.com/swiftlang/swift-package-manager/pull/9417),
2025-12-16), but that is plumbing, not a working static Windows runtime.

**So §6.3 step 6's `-static-stdlib` attempt is expected to fail.** Run it
anyway to record the exact error, but budget for dynamic redistribution.

### 2.6 SwiftPM → C-ABI DLL → C# P/Invoke: **works, with one trap that will cost days**

**Yes, `.library(type: .dynamic)` produces a real `MyLib.dll`** on Swift 6.3 —
SwiftPM's `dynamicLibraryPrefix` is `""` for `.win32` with extension `.dll`.
Output at `.build/release/MyLib.dll` (`--build-system native`).

**⚠️ This is recent.**
[SwiftPM#9574 "dynamic library products are not produced in build output on
windows"](https://github.com/swiftlang/swift-package-manager/issues/9574) was
opened **2026-01-08** and closed **2026-01-29**. Before that, `.dynamic` often
produced no DLL at all — in 2023 the platform champion was telling people to
use CMake instead because SwiftPM *"lacks target-level linkage concepts
necessary for proper Windows DLL construction"*
([forums 69023](https://forums.swift.org/t/swiftpm-does-not-create-a-dll-file/69023)).
[SwiftPM#5597 "Support static and dynamic linking on Windows"](https://github.com/swiftlang/swift-package-manager/issues/5597)
(filed 2022-06-17) is **still open**. Translation: this capability is roughly
six months old. Pin the toolchain.

**⚠️⚠️ THE TRAP: SwiftPM passes `-static` to every Swift module on Windows by
default, which strips `dllexport`.** Verified in SwiftPM `main`:
`SwiftModuleBuildDescription.swift` sets
`isWindowsStatic = triple.isWindows()` and adds `-static` with the comment
*"Add -static to reduce symbol export count"* (the DLL export table has a ~64K
limit — [PR #8049](https://github.com/swiftlang/swift-package-manager/pull/8049)).
`BuildPlan.swift` re-enables export **only for targets literally listed in the
`.dynamic` product's `targets:` array**. Compiler-side, `-static` ⇒
`Internalize` ⇒ `dllexport` stripped from `public`.

**Consequence: a `@_cdecl` function in a transitive dependency target
compiles, links, and is simply absent from the export table — with no
warning.** Confirmed by swift-testing hitting it
([SwiftPM#8111](https://github.com/swiftlang/swift-package-manager/issues/8111),
open since 2024-11-11) and acknowledged upstream
([swiftlang/swift#87701](https://github.com/swiftlang/swift/issues/87701),
2026-03-05: *"we strip the `dllexport` on `public` interfaces in static
libraries … and we cannot do this today"*).

**This directly constrains §4.2's layout, and the proposed layout happens to
satisfy it:** all `@_cdecl` entry points live in `ClaudeCoreFFI`, which is the
single target listed in the `ClaudeCoreFFI` product. **Never move an entry
point into `ClaudeCore`.** A comment saying so belongs in `Package.swift`.

Two more rules:
- **`public` is load-bearing.** `@_cdecl`/`@c` inherits the function's Swift
  access level (`SILDeclRef.cpp`'s `getLinkageLimit()`), so a default-`internal`
  `@_cdecl` is not exported. There is no `@_dllexport` attribute in Swift.
- **`-Xlinker /EXPORT:` and `.def` files** are valid MSVC escape hatches in
  principle, but no Swift thread documents their use — **unverified**.

**The 2021 "you can't P/Invoke Swift" quote, in context.**
[forums 50667](https://forums.swift.org/t/p-invoke-swift-code-from-c/50667)
(2021-07-27): *"no, it is not possible to call Swift code from C# via P/Invoke.
The calling convention would not be supported by the CLR"* — immediately
followed by *"The lingua franca for FFI is C, which you should be able to use
to bridge between C# and Swift."* The thread never mentions `@_cdecl`, which
emits a **C-calling-convention** entry point
([UnderscoredAttributes.md](https://github.com/swiftlang/swift/blob/main/docs/ReferenceGuides/UnderscoredAttributes.md)).
So the statement scopes to native Swift-convention symbols, and the C bridge he
recommends *is* the `@_cdecl` path. Also note .NET 9's `CallConvSwift` (native
Swift ABI) is **Apple-platforms only**
([dotnet/runtime#95638](https://github.com/dotnet/runtime/issues/95638)) — not
a Windows option.

**Use `@c`, not `@_cdecl`, on 6.3+.**
[SE-0495 "C Compatible Functions and Enums"](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0495-cdecl.md)
is **Implemented (Swift 6.3)**: it formalises `@_cdecl`, adds stricter
C-representability checking and emits into the generated compatibility header.
⚠️ Migration is **ABI-breaking** (`@_cdecl` emitted dual symbols; `@c` emits
one), and SE-0495 says nothing about Windows/dllexport — the `-static` rule
above is unchanged.

**Real-world evidence, and how thin it is.** The best confirmation is
[forums 88469](https://forums.swift.org/t/swift-concurrency-mainactor-does-not-execute-when-swift-dll-is-called-from-net-on-windows/88469)
(2026-07-23): Swift 6.3.2, SwiftPM dynamic library, .NET 8, P/Invoke —
*"The DLL loads successfully and synchronous exported C functions execute
correctly."* The other precedent is Cascable's
[SwiftToCLR](https://github.com/Cascable/swift-on-windows-poc) (2024-02),
which took the heavier C++-interop → C++/CLI route and reported both the main-
dispatch-queue defect and *"cryptic crashes unless targets were explicitly
`.dynamic`"*. **⚠️ There is no official documentation for exporting a Swift
DLL** — swift.org's Windows interop article covers Swift *consuming* C/C++/COM
only. You would be relying on working practice, not a supported, documented
path.

### 2.7 What changed recently

**Good (last 12 months):** Windows Workgroup founded (2026-01-26); Windows
confirmed top-tier with PR testing; SwiftPM Windows DLL output fixed
(2026-01); import-`.lib` copying (2026-02); ARM64 installers published;
Swift 6.3 shipped `@c`/SE-0495; toolchain↔runtime SxS binding closed the
`%PATH%`-poisoning hazard (2026-05-30); active COM-interop and Win32/WinRT
projection efforts on the forums (2026-04, 2026-07).

**Bad (still true):** static linking incomplete; DLLs unversioned; no
`swiftly`; no REPL; **five new Windows Foundation issues filed in July 2026
alone**, including a 6.3.3 crasher; the `DispatchQueue.main`/`MainActor` defect
open since 2024 and freshly re-reported; and the release announcements for both
6.2 and 6.3 contain essentially no Windows Foundation content — a fair proxy
for how much attention that surface gets.

---

## 3. Combine replacement — recommendation

**Recommendation: a hand-rolled `Observable` base class plus an `@Observed`
property wrapper using Swift's `static subscript(_enclosingInstance:)`. ~70
lines, zero dependencies, zero view-code changes, and it preserves the
willSet ordering `AppDelegate.swift:322` depends on.**

### 3.1 Why not the alternatives

| Option | Verdict |
|---|---|
| **`AsyncStream` per property** | Rejected. It is did-change, not will-change: SwiftUI needs `objectWillChange` to fire *before* the value updates, and `AppDelegate.swift:320-327` explicitly relies on that ordering. Adapting back to `ObservableObject` needs a `Task` per property and an actor hop, which reorders notifications relative to the mutation. Also changes 36 property declarations into 36 continuations. |
| **`swift-async-algorithms`** | Rejected. Adds a package dependency (brief asks to avoid), and does not solve the will-change problem — it is the same AsyncSequence model with better operators. |
| **Swift `Observation` (`@Observable`)** | Rejected — but **for two reasons, not three**. §2.3 confirmed my third objection was wrong: Observation *does* ship on Windows and Linux in the open-source toolchain (the compiler builds it with `SWIFT_MODULE_DEPENDS_WINDOWS WinSDK`), and the `macOS 14+` gate is an Apple-SDK restriction that does not apply off-Darwin. The two surviving objections are decisive anyway: **(a)** SwiftUI's observation support *does* require macOS 14+ on Darwin, and this package targets `.macOS(.v13)` (`Package.swift:7`) — adopting it means dropping Ventura; **(b)** it changes view code (`@ObservedObject var model:` → plain `var model:`, plus `@Bindable` wherever bindings are taken), which is precisely the constraint the brief set. It is the right answer for a greenfield core; it is not the right answer for one that has to keep an existing SwiftUI app compiling unchanged. |
| **Plain closure/callback registration only** | Insufficient alone — it gives the Windows side what it needs, but nothing makes SwiftUI re-render without a per-property will-change hook. It is however the *right primitive underneath*, which is what the recommendation builds on. |
| **OpenCombine** | Rejected. It is a third-party dependency for a 70-line problem, and its API-surface fidelity to `@Published`'s enclosing-instance behavior is exactly the kind of thing that would need verifying on Windows anyway. |

### 3.2 The type

**Empirically validated.** The code below was compiled and run under Swift
6.2.4 on macOS before being written down. Output:

```
["willChange(sees=nil)", "didChange(sees=Optional(42))"]
read back: Optional(42)
UsageModel conforms to ObservableObject
```

That first line is the whole point: `objectWillChange` fires **while the old
value is still readable**, exactly as `@Published` does, so
`AppDelegate.swift:322`'s documented assumption still holds and SwiftUI
invalidation is correct. And `UsageModel` — declared only as
`final class UsageModel: Observable`, with no Combine import of its own —
satisfies a generic `<O: ObservableObject>` constraint, which is what makes
`@ObservedObject var model: UsageModel` in `OverlayView.swift:47` keep
compiling untouched.

Put this in `ClaudeCore/Observation.swift`:

```swift
#if canImport(Combine)
import Combine
#endif
import Foundation

/// Opaque handle; deregisters on deinit so callers can't leak observers.
public final class ObservationToken {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
    public func keepAlive() {}   // silences "unused result" at call sites
}

/// Base class for every shared-core model. On Apple platforms it IS an
/// ObservableObject, so SwiftUI views keep working verbatim; everywhere else
/// it exposes plain callback registration.
open class Observable {
    private var observers: [ObjectIdentifier: () -> Void] = [:]
    private let lock = NSLock()          // Foundation, available everywhere

    public init() {}

    /// Register a change callback. Fires AFTER the property has changed.
    @discardableResult
    public func onChange(_ body: @escaping () -> Void) -> ObservationToken {
        let box = Box(); let key = ObjectIdentifier(box)
        lock.lock(); observers[key] = body; lock.unlock()
        return ObservationToken { [weak self] in
            self?.lock.lock(); self?.observers[key] = nil; self?.lock.unlock()
            _ = box
        }
    }
    private final class Box {}

    /// Called by @Observed BEFORE the stored value changes.
    public func coreWillChange() {
        #if canImport(Combine)
        objectWillChange.send()
        #endif
    }

    /// Called by @Observed AFTER the stored value changes.
    public func coreDidChange() {
        lock.lock(); let fns = Array(observers.values); lock.unlock()
        fns.forEach { $0() }
    }

    #if canImport(Combine)
    /// Explicit (not synthesized) — the class has no @Published properties
    /// anymore, so nothing would synthesize it.
    public let objectWillChange = ObservableObjectPublisher()
    #endif
}

#if canImport(Combine)
extension Observable: ObservableObject {}
#endif

/// Drop-in replacement for @Published on an `Observable` subclass.
@propertyWrapper
public struct Observed<Value> {
    private var stored: Value
    public init(wrappedValue: Value) { self.stored = wrappedValue }

    // The enclosing-instance subscript is what lets a value-type wrapper
    // reach its owning object — the same mechanism @Published uses.
    public static subscript<T: Observable>(
        _enclosingInstance instance: T,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
    ) -> Value {
        get { instance[keyPath: storageKeyPath].stored }
        set {
            instance.coreWillChange()                       // will-change, like @Published
            instance[keyPath: storageKeyPath].stored = newValue
            instance.coreDidChange()
        }
    }

    @available(*, unavailable, message: "@Observed is only usable on an Observable subclass")
    public var wrappedValue: Value {
        get { fatalError() } set { fatalError() }
    }
}
```

### 3.3 What changes at each call site

**Model files (the shared core) — mechanical, 43 lines touched:**

```diff
-import Combine
-final class UsageModel: ObservableObject {
-    @Published var sessionPercent: Int?
+final class UsageModel: Observable {
+    @Observed var sessionPercent: Int?
```

36 `@Published` → `@Observed`, 7 `: ObservableObject` → `: Observable`,
7 `import Combine` deleted.

`didSet` composes with the enclosing-instance wrapper — **verified**, not
assumed: I compiled `@Observed var expanded: Bool = false { didSet { … } }`
under Swift 6.2 and both the `didSet` body and the change notification fire.
So `SessionsModel.swift:142-144` and `GraphModel.swift:100-108` keep their
`didSet` blocks as written; only the `UserDefaults` call inside them moves to
the `Preferences` seam from §1.9.

**View files — ZERO changes.** `OverlayView.swift:47-65`'s
`@ObservedObject var model: UsageModel` still compiles, because `UsageModel`
still conforms to `ObservableObject` on Apple platforms and still publishes
`objectWillChange` before each mutation.

**`AppDelegate.swift` — 4 sites, ~12 lines.** The `$property` projected
publisher is gone. Two options:

- *Simple (recommended):* convert to `onChange`. `AppDelegate` is not view
  code, so the zero-change constraint does not apply.
  ```swift
  tokens.append(graphModel.onChange { [weak self] in
      DispatchQueue.main.async { self?.updatePanelSize() }
  })
  ```
  Note `onChange` is coarser than `$selectedTab` (it fires for any property on
  the model). `updatePanelSize()` is documented idempotent
  (`AppDelegate.swift:352-353`), and `$data`/`$config` already run without
  `removeDuplicates()`, so only `$sessionsExpanded` (`:321`) genuinely wanted
  deduping — and it is `Bool`, so a `guard newValue != last` in the closure is
  one line.
- *Full fidelity:* add a `projectedValue` to `@Observed` via
  `static subscript(_enclosingInstance:projected:storage:)`, returning an
  `AnyPublisher<Value, Never>` under `#if canImport(Combine)`. This makes
  `$sessionsExpanded.removeDuplicates().sink { … }` compile unchanged. It
  costs ~25 more lines in `Observation.swift` and is only worth it if you want
  literally-zero diff outside the core. **I would not do this** — the
  per-property publisher is a Combine-shaped API in a core that is trying to
  stop depending on Combine's shape.

**Windows/C# side:** `core.onChange { ffiInvokeCallback() }`, wired to the
`claude_core_set_change_callback` entry point in §5.

### 3.4 Honest caveats

- `ObservableObjectPublisher` as an explicit stored property (rather than the
  synthesized one) is fine, but it means every `Observable` subclass carries
  the publisher even when nothing observes it. Irrelevant at 7 instances.
- `coreDidChange()` fires observers on the mutating thread. Combined with
  §1.8's finding that `DispatchQueue.main` does not drain in a DLL, the
  Windows adapter must not assume any particular thread. Document it at the
  FFI boundary.
- Property-level granularity is lost on the `onChange` path. For a widget that
  redraws a 280pt panel, this does not matter; for the FFI it is actively
  *better* (one "something changed, re-pull the JSON" signal instead of 36).

---

## 4. Proposed package layout

### 4.1 Structure

```
ClaudeUsageOverlay/
  Package.swift
  Sources/
    ClaudeCore/                    # shared, platform-conditional
      Observation.swift            # §3
      Logging.swift                # CoreLog (§1.9)
      Preferences.swift            # protocol; no UserDefaults (§1.9)
      Scheduler.swift              # CoreScheduler (§1.8)
      JSONValue.swift              # the 23 casts, one accessor set (§1.3)
      Platform/
        FileLock.swift             # protocol + factory
        FileLock+POSIX.swift       # #if canImport(Darwin) || canImport(Glibc)
        FileLock+Windows.swift     # #if os(Windows)  — LockFileEx
        AtomicWrite.swift          # replaceWithRetry (§1.6)
        Paths.swift                # home/state/usage dirs; separator-safe
      API/
        Models.swift               # unchanged
        DeepLinks.swift            # unchanged
        Client.swift               # ClaudeScriptRunner injected (§1.10)
        Validate.swift             # unchanged
        ScriptRunner.swift         # protocol + FFI-backed impl
      Models/
        UsageModel.swift SessionsModel.swift GraphModel.swift
        PlanFitModel.swift CloudSessionsModel.swift ConfigStore.swift
        ChatsModel.swift SnapshotLogger.swift ScopedLimitLogger.swift
        DurationFormatting.swift
    ClaudeCoreDarwin/              # macOS-only impls; compiles empty elsewhere
      WebSession.swift             # entire file inside #if canImport(WebKit)
      DarwinPreferences.swift      # UserDefaults-backed
    ClaudeCoreFFI/                 # C ABI facade — Windows-consumed
      FFI.swift                    # @_cdecl entry points (§5)
      include/claude_core.h        # hand-written C header for P/Invoke docs
    ClaudeUsageOverlay/            # existing macOS app, unchanged views
      AppDelegate.swift OverlayView.swift GraphView.swift ...
  Tests/
    ClaudeCoreTests/               # runs on macOS AND Windows
```

### 4.2 `Package.swift`

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageOverlay",
    // Applies to Apple platforms only; Windows ignores it. Keep .v13 — do
    // NOT raise to .v14 for Observation (see §3.1).
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeCore", targets: ["ClaudeCore"]),
        // The Windows consumable. `.dynamic` asks SwiftPM for a .dll.
        //
        // ⚠️ LOAD-BEARING: SwiftPM passes `-static` to every Swift module on
        // Windows by default ("reduce symbol export count" — the DLL export
        // table has a ~64K limit), and `-static` strips `dllexport` from
        // `public`. Export is re-enabled ONLY for targets listed literally in
        // this product's `targets:` array. So EVERY @c/@_cdecl entry point
        // must live in ClaudeCoreFFI itself and be `public`. Move one into
        // ClaudeCore and it compiles, links, and is simply absent from the
        // export table with no warning (swiftlang/swift#87701,
        // swift-package-manager#8111). Verify with `dumpbin /exports`.
        .library(name: "ClaudeCoreFFI", type: .dynamic, targets: ["ClaudeCoreFFI"]),
    ],
    targets: [
        .target(
            name: "ClaudeCore",
            path: "Sources/ClaudeCore",
            exclude: ["API/CONTRACT.md"]
        ),
        .target(
            name: "ClaudeCoreDarwin",
            dependencies: ["ClaudeCore"],
            path: "Sources/ClaudeCoreDarwin"
        ),
        .target(
            name: "ClaudeCoreFFI",
            dependencies: ["ClaudeCore"],
            path: "Sources/ClaudeCoreFFI"
        ),
        .executableTarget(
            name: "ClaudeUsageOverlay",
            dependencies: ["ClaudeCore", "ClaudeCoreDarwin"],
            path: "Sources/ClaudeUsageOverlay"
        ),
        .testTarget(
            name: "ClaudeCoreTests",
            dependencies: ["ClaudeCore"],
            path: "Tests/ClaudeCoreTests"
        ),
    ]
)
```

**Known SwiftPM limitation, stated plainly:** there is no way to declare a
target that only exists on some platforms. `swift build` on Windows will try
to compile `ClaudeCoreDarwin` and `ClaudeUsageOverlay` too. The workable
pattern — and the one every cross-platform Swift package uses — is to wrap the
*entire contents* of each Apple-only file in `#if canImport(AppKit)` /
`#if canImport(WebKit)`, so those targets compile to empty modules on Windows.
Uglier than conditional targets, but it is what works. (`swift build --target
ClaudeCoreFFI` also limits the blast radius during development; CI should
still build everything.)

### 4.3 The conditional strategy, concretely

**Preferred discriminator: capability, not OS.** `#if canImport(Darwin)` is
the right test for POSIX facilities, `#if os(Windows)` for Win32 ones, and
`#if canImport(WebKit)` for the transport. Reserve `#if os(macOS)` for things
that are genuinely macOS-product decisions.

```swift
// Sources/ClaudeCore/Platform/FileLock.swift
public protocol FileLock {
    /// Blocks until the exclusive lock is held. Must be the SAME lock the
    /// Python daemon takes (flock byte-less on POSIX, LockFileEx byte 0 on
    /// Windows) — see autoresume.py StateLock.
    func withExclusiveLock<T>(_ body: () throws -> T) rethrows -> T
}

public enum FileLocks {
    public static func make(at url: URL) -> FileLock {
        #if os(Windows)
        return WindowsFileLock(url: url)
        #else
        return POSIXFileLock(url: url)
        #endif
    }
}
```

```swift
// Sources/ClaudeCore/Platform/FileLock+POSIX.swift
#if canImport(Darwin) || canImport(Glibc)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// S1 — DO NOT reintroduce FileManager.createFile here. createFile replaces
/// the lock file's inode on every call and flock is per-inode, so the widget
/// and daemon would lock different inodes and exclude nothing.
/// (Comment carried verbatim from SessionsModel.swift:449-457 — it documents
/// a bug that WILL recur if this file is ever "simplified".)
struct POSIXFileLock: FileLock {
    let url: URL
    func withExclusiveLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return try body() }   // degrade, never drop the write
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }
}
#endif
```

```swift
// Sources/ClaudeCore/Platform/FileLock+Windows.swift
#if os(Windows)
import WinSDK

/// Windows analogue of the POSIX flock above. Locks BYTE 0 of the lock file,
/// which is the protocol the Python daemon's LockFileEx implementation must
/// also use (daemon blocker B1 in docs/windows-port-plan.md). The two are a
/// single cross-language contract — change one, change the other, and prove
/// it with the two-process test.
///
/// FILE_SHARE_READ|WRITE|DELETE on the open is REQUIRED: without
/// FILE_SHARE_DELETE, holding this handle makes an unrelated atomic rename of
/// a neighbouring file fail with a sharing violation.
struct WindowsFileLock: FileLock {
    let url: URL
    func withExclusiveLock<T>(_ body: () throws -> T) rethrows -> T {
        // NOT url.path — swift-foundation#973: URL.path returns FORWARD
        // slashes on Windows ("C:/Users/…"). Go through the file-system
        // representation so Win32 and the Python daemon see the same string.
        let handle = url.withUnsafeFileSystemRepresentation { rep -> HANDLE? in
            guard let rep else { return nil }
            return String(cString: rep).withCString(encodedAs: UTF16.self) { p in
            CreateFileW(p, DWORD(GENERIC_READ | GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_ALWAYS),
                        DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return try body() }
        defer { CloseHandle(handle) }
        var ov = OVERLAPPED()
        // No LOCKFILE_FAIL_IMMEDIATELY ⇒ blocks indefinitely, matching
        // flock(LOCK_EX). This is the exact analogue; msvcrt.locking() is NOT
        // (it gives up after ~10s).
        LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &ov)
        defer { var u = OVERLAPPED(); UnlockFileEx(handle, 0, 1, 0, &u) }
        return try body()
    }
}
#endif
```

```swift
// Sources/ClaudeCoreDarwin/WebSession.swift
#if canImport(WebKit)
import WebKit
import ClaudeCore
final class ClaudeWebSession: NSObject, WKNavigationDelegate, ClaudeScriptRunner {
    ... // existing 243 lines, unchanged except the protocol conformance
}
#endif
// On Windows this file compiles to nothing, and the target is an empty module.
```

---

## 5. C ABI facade

### 5.1 The JSON-string prior: **validated, with four amendments**

The prior is right, and the strongest argument for it is not the one stated in
the brief. It is this: **the FFI is not a performance path.** The widget polls
`state.json` every 5s, `/recents` every 30s, usage every 120s, plan-fit every
120s. A 40 KB JSON round-trip 12 times a minute is free. Hand-modelled structs
buy nothing measurable and cost:

- ABI fragility across Swift versions (Swift has no stable C-struct layout
  guarantee for anything but `@frozen` C-compatible types; every optional,
  every `String`, every array needs manual flattening);
- 32/64-bit and packing hazards in the C# `[StructLayout]` mirror;
- N marshalling rules instead of one, all of which drift silently;
- a second contract to keep in sync alongside `docs/contracts/*.schema.json`.

And the reuse argument compounds — more than it did when this audit started.
`docs/contracts/` now exists in the working tree (untracked as of this
writing): `state.schema.json`, `config.schema.json`, `plan_fit.schema.json`,
`snapshots.schema.json`, `scoped_limits.schema.json` plus a README, i.e. the
port plan's §A.2 item. **Those five schemas are already a usable FFI
contract.** The same artifacts validate the on-disk files, validate the FFI
payloads, generate the C# DTOs (`System.Text.Json` source generators), and
drive round-trip tests. One contract artifact, four consumers — which is
exactly the argument for JSON strings over hand-modelled structs, and it is
now concrete rather than prospective.

Four amendments to the prior:

**(a) Not everything can be pull-JSON.** §1.10's finding forces a callback in
the other direction: the Swift core needs claude.ai fetches executed by
WebView2 in the C# host. Two entry-point pairs handle it (§5.3, #6/#7). Keep
those JSON too — the payload is `{"id": 7, "script": "…"}` in and
`{"id": 7, "ok": true, "value": {…}}` out — but accept that the boundary is
bidirectional. Anyone who tells you the FFI is "just C# calls Swift" has not
read `Client.swift:32-43`.

**(b) UTF-8 bytes + explicit length, not `char*`.** Return
`UnsafeMutablePointer<CChar>` with a companion out-parameter length, or a
2-word struct. Reason: .NET's default `string` marshalling for `char*` is
ANSI-code-page on some paths, and even with `UnmanagedType.LPUTF8Str` you pay
an O(n) `strlen`. Passing the length makes the C# side a single
`Encoding.UTF8.GetString(byte*, len)`. JSON has no embedded NULs so
NUL-termination is safe *as well*; provide both.

**(c) Never throw, never trap, across the boundary.** Every entry-point body is
wrapped so that a Swift error becomes `{"ok":false,"error":"…"}`. A Swift
runtime trap (force-unwrap, array bounds) cannot be caught and will take down
the WPF process with no .NET stack trace — so the core's remaining
force-unwraps must be audited before this ships. There are a few:
`DeepLinks.swift:11,16` (`URL(string:)!`, constant, safe),
`Validate.swift:105,158` (`report.session.percent!`, `states["running"]!` —
both guarded by the surrounding logic, but they are exactly the shape that
turns a contract surprise into a process kill).

**(d) Two hard rules from §2, added after the research:**

- **Every entry point is synchronous, `@MainActor`-free, and touches no Swift
  concurrency and no `DispatchQueue.main`.** §2.4: `Task { @MainActor in … }`
  in a .NET-hosted Swift DLL silently never runs, and the only thing confirmed
  working in that configuration is *"synchronous exported C functions"*. The
  core's internal serial queues (`SessionsModel.swift:443` etc.) are fine —
  the *boundary* must be synchronous.
- **Use `@c` (SE-0495, Swift 6.3) rather than `@_cdecl`** for new code:
  `@_cdecl` is an underscored, explicitly-not-for-production attribute, while
  `@c` is a shipped language feature with real C-representability checking and
  generated-header emission. Migration between them is ABI-breaking (`@_cdecl`
  emits dual symbols, `@c` emits one), so pick one and stay. Export behaviour
  is identical — `public` and the directly-listed-target rule (§4.2) still
  apply. The sketches below use `@_cdecl` only because it is the form the
  existing forum evidence is written against; prefer `@c` in real code.

### 5.2 Memory-ownership rules

Write these into `claude_core.h` as the normative statement:

1. Every `char*` returned by a `claude_core_*` function is **owned by the
   core** and allocated with the core's allocator. The caller must return it
   with `claude_core_string_free`. It must **not** be freed with
   `Marshal.FreeHGlobal`, `free()`, or anything else — the CRT the Swift DLL
   links may not be the CRT the CLR uses, and on Windows a cross-CRT free is
   an immediate heap corruption, not an error.
2. Every `const char*` **passed in** is owned by the caller and is only valid
   for the duration of the call. The core copies anything it retains. C# may
   therefore use a stack/pinned buffer.
3. Handles (`ClaudeCoreHandle`) are opaque `void*`. One `create`, one
   `destroy`. Calling any function with a destroyed handle is undefined —
   the C# wrapper must be a `SafeHandle`.
4. Callbacks registered with `claude_core_set_*_callback` must remain valid
   until replaced or until `destroy`. On the C# side that means a
   `[UnmanagedCallersOnly]` static method plus a rooted `GCHandle` for the
   context — a lambda captured in a local **will** be collected and crash.
5. Callbacks may fire on **any** thread (§1.8). The C# adapter marshals to the
   WPF `Dispatcher`; the core makes no thread promises.
6. Callbacks must not re-enter the core synchronously. Post the work; return
   promptly.

### 5.3 Representative entry points

```swift
// Sources/ClaudeCoreFFI/FFI.swift
import Foundation
import ClaudeCore

private final class CoreBox {                       // what the handle points at
    let models: CoreModels
    var changeCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    var changeContext: UnsafeMutableRawPointer?
    init(models: CoreModels) { self.models = models }
}

/// Wraps a body so nothing ever throws or returns nil across the boundary.
private func envelope(_ body: () throws -> [String: Any]) -> UnsafeMutablePointer<CChar> {
    let obj: [String: Any]
    do { obj = ["ok": true, "value": try body()] }
    catch { obj = ["ok": false, "error": "\(error)"] }
    let data = (try? JSONSerialization.data(withJSONObject: obj))
        ?? Data(#"{"ok":false,"error":"serialize_failed"}"#.utf8)
    return strdupUTF8(data)     // core-allocated; freed by claude_core_string_free
}

// ── 1. Lifecycle ────────────────────────────────────────────────────────────
/// `config_json`: {"state_dir": "C:\\Users\\sam\\.claude-autoresume"}.
/// Returns NULL on failure. Never blocks on I/O.
@_cdecl("claude_core_create")
public func claude_core_create(_ config_json: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let cfg = decodeJSON(config_json) else { return nil }
    let box = CoreBox(models: CoreModels(stateDir: cfg["state_dir"] as? String ?? ""))
    return Unmanaged.passRetained(box).toOpaque()
}

@_cdecl("claude_core_destroy")
public func claude_core_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let h = handle else { return }
    Unmanaged<CoreBox>.fromOpaque(h).release()
}

/// Rule 1. The ONLY legal way to release a string the core returned.
@_cdecl("claude_core_string_free")
public func claude_core_string_free(_ p: UnsafeMutablePointer<CChar>?) { free(p) }

// ── 2. Pull: the whole UI state as one document ─────────────────────────────
/// Re-reads state.json under the shared lock, applies the dedupe rules
/// (SessionsModel.refresh), merges cloud rows, and returns
/// {"ok":true,"value":{"sessions":[…],"usage":{…},"planFit":{…},"config":{…}}}.
/// `out_len` receives the UTF-8 byte count (rule (b)); may be NULL.
@_cdecl("claude_core_snapshot")
public func claude_core_snapshot(_ handle: UnsafeMutableRawPointer?,
                                 _ out_len: UnsafeMutablePointer<Int32>?)
    -> UnsafeMutablePointer<CChar>? { … }

// ── 3. Push: a user action ──────────────────────────────────────────────────
/// `command_json`: {"op":"set_enabled","session_id":"…","value":true}
///                 {"op":"resume_now","session_id":"…"}
///                 {"op":"set_resume_armed","session_id":"…","value":false}
///                 {"op":"config_set_idle_retention","minutes":30}
/// One op vocabulary rather than one entry point per setter: the setters are
/// all the same locked read-modify-write and the vocabulary is versionable.
/// Returns the standard envelope; blocking (takes the state flock).
@_cdecl("claude_core_command")
public func claude_core_command(_ handle: UnsafeMutableRawPointer?,
                                _ command_json: UnsafePointer<CChar>?)
    -> UnsafeMutablePointer<CChar>? { … }

// ── 4. Observation bridge (§3) ──────────────────────────────────────────────
/// `cb` fires (on an arbitrary thread — rule 5) whenever any core model
/// changes; the host responds by calling claude_core_snapshot. Deliberately
/// coarse: one signal, not 36. Pass NULL to unregister.
@_cdecl("claude_core_set_change_callback")
public func claude_core_set_change_callback(
    _ handle: UnsafeMutableRawPointer?,
    _ cb: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
    _ context: UnsafeMutableRawPointer?) { … }

// ── 5. Transport inversion, out (§1.10) ─────────────────────────────────────
/// Returns the next pending claude.ai request as
/// {"ok":true,"value":{"id":7,"script":"…async JS body…"}} or
/// {"ok":true,"value":null} when idle. The host runs `script` in its
/// authenticated WebView2 via ExecuteScriptAsync and returns the result via
/// claude_core_deliver_response. Poll it from the change callback.
@_cdecl("claude_core_next_request")
public func claude_core_next_request(_ handle: UnsafeMutableRawPointer?)
    -> UnsafeMutablePointer<CChar>? { … }

// ── 6. Transport inversion, in ──────────────────────────────────────────────
/// `response_json`: {"id":7,"ok":true,"value":{…}}
///                  {"id":7,"ok":false,"error":"transport: navigation failed"}
/// An id the core doesn't know is ignored (not an error) — a late response
/// after a timeout must not crash anything.
@_cdecl("claude_core_deliver_response")
public func claude_core_deliver_response(_ handle: UnsafeMutableRawPointer?,
                                         _ response_json: UnsafePointer<CChar>?)
    -> UnsafeMutablePointer<CChar>? { … }

// ── 7. Logging sink (§1.9) ──────────────────────────────────────────────────
@_cdecl("claude_core_set_log_callback")
public func claude_core_set_log_callback(
    _ handle: UnsafeMutableRawPointer?,
    _ cb: (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
    _ context: UnsafeMutableRawPointer?) { … }
```

C# side, for concreteness:

```csharp
internal static partial class Native {
    private const string Dll = "ClaudeCoreFFI";

    [LibraryImport(Dll)]
    internal static partial IntPtr claude_core_create(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configJson);

    [LibraryImport(Dll)]
    internal static partial IntPtr claude_core_snapshot(IntPtr h, out int len);

    [LibraryImport(Dll)]
    internal static partial void claude_core_string_free(IntPtr p);
}

internal static string TakeString(IntPtr p, int len) {
    if (p == IntPtr.Zero) return null;
    try   { unsafe { return Encoding.UTF8.GetString((byte*)p, len); } }
    finally { Native.claude_core_string_free(p); }   // rule 1, always
}
```

### 5.4 The argument this design makes against itself

Worth stating because it is load-bearing for §6: if the boundary is JSON in /
JSON out, and the on-disk formats are already JSON, then for
`PlanFitModel` (526 lines, a pure `plan_fit.json` reader + string formatter),
`GraphModel` (558 lines, a pure jsonl reader + bucketer) and `ChatsModel`
(67 lines), the Swift core's marginal value over "the C# app reads the same
files itself" is *only* the reimplementation cost — the same JSON is being
parsed either way, just on a different side of a DLL boundary you had to build
and maintain. See §6.1.

---

## 6. Verdict + risk register

### 6.1 Verdict: **go-with-caveats on a much smaller core than proposed — and the economics are marginal**

Nothing in §1 or §2 is a *technical* no-go, and §2 removed more doubt than it
added on the mechanics. Swift is a top-tier supported Windows platform with a
governing workgroup and PR testing; the toolchain installs in two winget
commands with no modulemap surgery; SwiftPM produces a real DLL and someone
was successfully P/Invoking `@_cdecl` functions from .NET 8 three days before
this audit; tzdata is embedded rather than a system dependency; and §3's
Combine replacement is verified working in 70 lines with zero view-code
changes. If the question were only "can a Swift `ClaudeCore` compile and run
on Windows behind a C ABI", the answer is **yes** — with a fortnight of shim
work and a hard rule that the boundary stays synchronous.

But that is not the decision. The decision is whether this is the cheapest way
to get a Windows widget, and three findings say the proposed scope is wrong:

**1. The one module with a real sharing argument is the one that can't be
shared cleanly.** `ClaudeAPI` tracks a volatile external contract that changes
without notice — duplicating it means diagnosing every break twice. That is
the whole case for a shared core, and `windows-port-plan.md:457-469` already
identifies it. But §1.10 shows `Client.swift` is not an HTTP client; it is
~120 lines of JavaScript executed inside an authenticated WebView, and on
Windows that WebView lives in C#. Sharing it forces a **bidirectional** FFI
(§5.3 entry points 5 and 6) where the Swift core hands JS source *up* to the
host and waits for results *down*. That is buildable, and it is also the
single most fragile thing in the design — an async, cross-language,
cross-thread request/response correlation layer built to carry a payload that
is itself a string of JavaScript.

**2. Everything that shares easily is worth the least.** `PlanFitModel` (526),
`GraphModel` (558), `ChatsModel` (67), `CloudSessionsModel` (234) are pure
functions of JSON files and API DTOs. They port almost free — and by §5.4's
own argument, they are also the pieces where "let the C# app read the same
JSON" is nearly as cheap, because with a JSON FFI boundary the C# side is
deserializing JSON either way. The genuinely subtle, empirically-derived logic
worth *not* reimplementing is smaller than the file list suggests: the
crash-continuation dedupe (`SessionsModel.swift:214-278`), the cloud-echo
`created_at` join (`CloudSessionsModel.swift:119-183` + the retention/eviction
cache at `SessionsModel.swift:303-340`), the tiered bucket merge
(`GraphModel.swift:445-497`), the UTC key discipline (`:236-254, 323-332`),
and `ConfigStore`'s unknown-key-preserving locked RMW (`:271-298`). Call it
**800–1,000 lines that are expensive to get right twice** out of 2,076.

**2b. The Foundation surface this code leans on is the *fragile* half.** §2.2's
split matters more than it first appears. The Swift-native rewrite covers
`URL`, `Data`, `Date`, `Calendar`, `JSONSerialization` — solid, no open Windows
issues. Everything still C/CoreFoundation-backed is where the live bug queue
is, and this codebase sits in it: `DateFormatter` (an open crasher whose
reproducer *is* `GraphModel.utcDailyKeyFormatter()`), `NumberFormatter`,
`UserDefaults` (silent write failure on domain-joined profiles), `TimeZone.current`
(GMT on non-English Windows; heap corruption under concurrency), atomic writes
(not actually atomic), `URL.path` (forward slashes). Five new Windows
Foundation issues were filed in July 2026 alone. None of these is
unfixable-by-us — most have a one-line workaround, and several of those
workarounds improve the Mac build too — but collectively they say the shared
core will spend real time on platform bugs that have nothing to do with the
product.

**3. It contradicts the repo's own churn evidence.** `windows-port-plan.md`
§A.1 measured that features cross layers routinely (`d3e8511` touched 16 files
across ClaudeAPI, six widget files and two daemon files) and that the existing
Python-computes/Swift-renders seam is *already* the expensive part
(`plan_fit.py` 11 commits vs `PlanFitModel.swift` 9, churning in lockstep with
nothing checking they agree). A Swift↔C# FFI adds a **second** untyped seam of
exactly that kind, cutting through the middle of where features land.

**What I would actually do, in order:**

1. **Finish §A.2 (versioned JSON Schemas + validators on both sides),
   unconditionally.** Everything below depends on it, and it is useful on a
   Mac-only future. **This is already underway** — `docs/contracts/` holds the
   five schemas plus a README in the working tree, though untracked and with
   no validator wired into either side yet. Completing it (validators in the
   daemon's tests and behind a `--validate-*` entry point in the widget) is
   what makes decision 3 reversible.
2. **Do the macOS-safe portability refactors now** (§1.3's `JSONValue`
   accessors, §1.4's `TimeZone(secondsFromGMT: 0)`, §1.9's `CoreLog`, §3's
   `Observed`, extracting `FileLock`/`AtomicWrite`/`Preferences` seams). All
   of it improves the Mac app on its own terms — the `TimeZone` fallback and
   the 23 unguarded casts are latent bugs *today*, not just on Windows — and
   none of it commits to Windows.
3. **Run the spike (§6.3) before writing any FFI code.** One hour settles the
   three risks that could turn this into a no-go.
4. **Then scope the core to what earns its keep:** `SessionsModel`,
   `ConfigStore`, `GraphModel`'s bucketing, and the ClaudeAPI **DTOs +
   decoders** (`Models.swift`, the `decodeUsage`/`decodeScopedLimits`/
   `mapWorkState` half of `Client.swift`) — with the *transport* left
   platform-native on both sides and the JS scripts moved to a shared,
   language-neutral resource file. That keeps the volatile part shared without
   building the bidirectional FFI: C# owns WebView2 and the fetch loop, Swift
   owns "here is what the response means".

That last point is the non-obvious result of this audit and it is worth
restating: **split `ClaudeAPI` at the transport/decode line, not at the
WebSession file boundary.** Decoding is the part that breaks when claude.ai
changes; transport is the part that is irreducibly per-platform.

If after the spike the answer is "the DLL/interop tax is real and the shared
piece is ~900 lines", then Path 2 (one cross-platform UI, retire the Swift
app) from `windows-port-plan.md:418-437` becomes the better trade, and this
audit's §1 findings still apply — they are the same portability bugs any port
must fix.

### 6.2 Top 5 risks, ranked

| # | Risk | Impact | Mitigation / cheap experiment |
|---|---|---|---|
| **R1** | **The ClaudeAPI transport cannot be shared as designed** (§1.10). `Client.swift` is built around executing JS in an authenticated WebView owned by the UI layer. Sharing it forces a bidirectional, async, correlated FFI. | Highest. It is the only module with a real sharing argument, so if it can't come across, the core's value drops to ~900 lines of file-reader logic and the whole approach is marginal. | **Do not build the bidirectional FFI.** Split at the transport/decode line (§6.1 step 4): share the DTOs + decoders, keep the fetch loop native, and move the JS from Swift string literals into a shared `scripts/*.js` resource both hosts load. Cheap experiment: extract `ClaudeScriptRunner` behind a protocol on macOS *first* (half a day, macOS-only, no Windows needed) and see whether `Client.swift` survives it without the transport leaking back in through `signOut`/`signIn`/`backlogFull` (`Client.swift:191-204,235`). If it doesn't, R1 is confirmed before a line of C# exists. |
| **R2** | **`JSONSerialization` bridging casts** (§1.3). 23 sites do `as? Bool` / `as? Double` / `as? NSNumber` against `Any` from JSON. Objective-C bridging is Darwin-only; the failure is a wrong default, silently. `Client.swift:243,252` gates *every* API response on `as? Bool`. | High but bounded — it is a mechanical fix, the danger is shipping without knowing. | Spike step 2 measures it in 5 minutes. Then route all 23 sites through one `JSONValue` accessor set that tries `NSNumber`, native Swift, and `NSString`. This is a macOS-safe refactor worth doing regardless. |
| **R3** | **The `-static` export trap and the shipping story** (§2.6, §2.5). The DLL itself is no longer in doubt — SwiftPM produces one and P/Invoke works. What bites is that SwiftPM passes `-static` to every Swift module on Windows, stripping `dllexport`, so an entry point in the wrong target vanishes from the export table **with no warning**; that the capability is only ~6 months old (SwiftPM#9574 fixed 2026-01-29; SwiftPM#5597 still open); that `-static-stdlib` does not work on Windows, so ~12 unversioned runtime DLLs must ship next to the host exe; and that there is **no official documentation** for exporting a Swift DLL at all. | Medium-high. Not a blocker, but a source of days-long mystery debugging and an ongoing packaging tax. | Keep every entry point `public` and in the target listed in the `.dynamic` product (§4.2's comment). **Verify with `dumpbin /exports` before debugging anything else** — an empty table means `-static` internalised you. Pin the toolchain version; this is new code upstream. Spike steps 3, 4 and 6 walk it end to end. Budget for dynamic redistribution; expect step 6's `-static-stdlib` to fail. |
| **R4** | **`DispatchQueue.main` and all Swift concurrency are broken in a .NET-hosted Swift DLL** (§1.8, §2.4). Five in-scope sites publish via `DispatchQueue.main.async`. **This is no longer a hypothesis:** libdispatch#846 has been open since 2024-09-20, someone hit this exact architecture on 2026-07-23 (forums 88469, unresolved), and Cascable reported it in 2024. Root cause is main-executor init calling `dispatchMain()` → `_endthreadex`, which a host run loop cannot fix. | High, and *silent* — on macOS it works perfectly and every unit test passes. | Two parts. **(1)** Introduce the `CoreScheduler` seam (§1.8) before any Windows work; on Windows implement it as "call inline, let C# marshal to the WPF `Dispatcher`". **(2)** Make it a standing design rule that C-ABI entry points are synchronous and `@MainActor`-free (§5.1d) — the one thing confirmed working is *"synchronous exported C functions"*. Spike step 7 demonstrates the failure so it is seen once, early, rather than discovered at integration. A proper fix (a custom executor bridged to the WPF dispatcher) exists in precedent — swift-android-native's `AndroidLooper`, swift-cross-ui's `Gtk3Backend` — but is a project of its own; do not plan on needing it. |
| **R5** | **The cross-language file lock, the atomic-rename sharing violation, and text-mode line endings** (§1.6). The widget and the Python daemon must take the *same* Windows lock. Every tmp+rename (`SessionsModel.swift:498`, `ConfigStore.swift:318`, `ScopedLimitLogger.swift:87`) can fail intermittently — **confirmed upstream**, not just predicted: swift-foundation#1507 (concurrent atomic writes → `ERROR_ACCESS_DENIED`) and #2078 (*the atomic write is not actually atomic on Windows*), both open. And a naive `_open`/`_write` port of `SnapshotLogger.append` inherits Windows text mode, turning every `\n` into `\r\n` and corrupting the jsonl the Python compactor reads. | High and *intermittent* — the worst failure mode. It will pass every test and fail on the owner's machine at 3am. `SnapshotLogger` is the one where a bug **loses data** rather than racing. | Write the Swift `LockFileEx` implementation and the daemon's B1 implementation **against each other**, and prove it with a real two-process test (spike step 5), the way hardening item #1 was proven on macOS — not a mocked unit test. Add `replaceWithRetry` uniformly with bounded backoff. Pass `_O_BINARY` (or use `CreateFileW`/`WriteFile`) and add a byte-for-byte jsonl round-trip assertion. Route paths through `withUnsafeFileSystemRepresentation`, never `URL.path` (swift-foundation#973). |

Also-rans worth tracking but not top-5: `.creationDateKey` on Windows
(silently disables the cloud-echo dedupe — §1.5); `DateFormatter`'s open
Windows crasher matching `utcDailyKeyFormatter()` (§1.4 — mitigated by
dropping `DateFormatter` from the daily-key path entirely, which is worth
doing anyway); `UserDefaults` silently failing to write on domain-joined
profiles (§1.9); the absence of any CI today
(`windows-port-plan.md:223-227` — this is the first point in the project's
life where CI actually pays for itself, and the Windows Foundation bug queue
makes a `windows-latest` job genuinely load-bearing rather than hygiene); the
~12 unversioned runtime DLLs and the "never put them on `%PATH%`" rule (§2.5);
and the force-unwraps at `Validate.swift:105,158` becoming process kills once
they sit behind a C ABI (§5.1c).

### 6.3 Spike script — settle it in under an hour on a Windows box

Run these in order on a Windows 11 machine. **Stop at the first FAIL** —
each step gates the ones after it. Total wall time ≈ 45 min, most of it
toolchain install.

#### Step 0 — install (≈15 min, mostly download)

Both commands. The toolchain alone will not build anything — it needs MSVC and
the Windows SDK. Enable **Developer Mode** first (Settings → System → For
developers).

```powershell
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom ^
  "--add Microsoft.VisualStudio.Component.Windows11SDK.22000 ^
   --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
   --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
winget install --id Swift.Toolchain -e --source winget
# new shell, then:
swift --version
```

**Expected:** Swift **6.3.3** (or later), `Target: x86_64-unknown-windows-msvc`
(or `aarch64-…` on ARM64).
**FAIL if:** `swift` is not on PATH after a new shell, or the compiler errors
about a missing Windows SDK component.
**Do not** go looking for the old `ucrt.modulemap` / `visualc.modulemap` copy
step — it was removed in Swift 5.9 and following a stale blog post that
describes it will break the install. There is **no** `swiftly` on Windows
(§2.1), so record the exact installer version; that is your only pin.
`dumpbin` comes from the VS install — run these from a **Developer PowerShell
for VS 2022** so it is on PATH.

#### Step 1 — does a plain SwiftPM library build at all? (2 min)

```powershell
mkdir C:\spike; cd C:\spike
swift package init --type library --name Probe
swift build
```

**Expected:** `Build complete!`
**FAIL if:** any error. Everything below is moot.

#### Step 2 — the JSON bridging question (R2). **The highest-information 5 minutes in this spike.**

Replace `Sources/Probe/Probe.swift` with:

```swift
import Foundation

@main struct Probe {
  static func main() {
    let s = #"{"b": true, "d": 1.5, "i": 7, "n": null, "big": 1753000000.0}"#
    let o = try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    print("b type       :", type(of: o["b"]!))
    print("b as? Bool   :", o["b"] as? Bool as Any)
    print("b as? NSNum  :", (o["b"] as? NSNumber)?.boolValue as Any)
    print("d as? Double :", o["d"] as? Double as Any)
    print("d as? NSNum  :", (o["d"] as? NSNumber)?.doubleValue as Any)
    print("i as? Int    :", o["i"] as? Int as Any)
    print("big as? Doubl:", o["big"] as? Double as Any)
    print("null isNSNull:", o["n"] is NSNull)
    print("validJSONObj :", JSONSerialization.isValidJSONObject(["a": NSNull()]))
    // tz + calendar (§1.4)
    print("TZ UTC       :", TimeZone(identifier: "UTC") as Any)
    print("TZ gmt0      :", TimeZone(secondsFromGMT: 0) as Any)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = cal
    f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"
    print("daily key    :", f.string(from: Date(timeIntervalSince1970: 1_753_000_000)))
    let nf = NumberFormatter(); nf.numberStyle = .decimal
    nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 2
    print("grouped      :", nf.string(from: NSNumber(value: 2786.17)) as Any)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    print("iso frac     :", iso.date(from: "2026-07-26T10:00:00.123Z") as Any)
    // filesystem (§1.5)
    let home = FileManager.default.homeDirectoryForCurrentUser
    print("home         :", home.path)
    let probe = home.appendingPathComponent("spike-probe.txt")
    try? Data("x".utf8).write(to: probe)
    let created = (try? probe.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    print("creationDate :", created as Any)
  }
}
```

```powershell
swift run
```

**Expected on macOS today (the baseline).** CORRECTION 2026-07-26: `daily key` below said `2026-07-20`; the true value is `2025-07-20` (epoch 1753000000 is July 2025). Use the verified baseline in `docs/windows-spike/README.md` instead of this block.

```
b as? Bool   : Optional(true)
d as? Double : Optional(1.5)
i as? Int    : Optional(7)
null isNSNull: true
TZ UTC       : Optional(GMT)
daily key    : 2026-07-20
grouped      : Optional(2,786.17)
iso frac     : Optional(2026-07-26 10:00:00 +0000)
creationDate : Optional(…)
```

**What each line decides:**
- `b as? Bool` / `d as? Double` / `i as? Int` **nil** ⇒ R2 confirmed; the
  `JSONValue` refactor is mandatory, not optional. Whether `as? NSNumber`
  works tells you which direction the accessors must fall back in.
- `TZ UTC` **nil** ⇒ §1.4's landmine is live; the `?? .current` fallbacks
  must be replaced *before* any Windows build ships.
- `daily key` ≠ `2026-07-20` ⇒ tz/calendar handling diverges from the daemon;
  the plan-fit and cost charts will be wrong by a day.
- `grouped` nil or unformatted ⇒ no ICU locale data; `apiEquivalentText`
  (`PlanFitModel.swift:356-364`) needs a hand-rolled grouping.
- `creationDate` **nil** ⇒ the cloud-echo dedupe silently dies (§1.5).

#### Step 3 — does SwiftPM emit a real DLL with `@_cdecl` exports? (R3, 5 min)

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Probe",
    products: [.library(name: "ProbeFFI", type: .dynamic, targets: ["ProbeFFI"])],
    targets: [.target(name: "ProbeFFI", path: "Sources/ProbeFFI")]
)
```

`Sources/ProbeFFI/FFI.swift`:

```swift
import Foundation

@_cdecl("probe_hello")
public func probe_hello(_ name: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let who = name.map { String(cString: $0) } ?? "world"
    let obj: [String: Any] = ["ok": true, "greeting": "hello \(who)"]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    let s = String(decoding: data, as: UTF8.self)
    return strdup(s)          // core-allocated; freed by probe_free
}

@_cdecl("probe_free")
public func probe_free(_ p: UnsafeMutablePointer<CChar>?) { free(p) }
```

```powershell
swift build -c release
dir .build\release\*.dll
dumpbin /exports .build\release\ProbeFFI.dll | findstr probe_
```

**Expected:** `ProbeFFI.dll` exists, and `dumpbin /exports` lists
`probe_hello` and `probe_free` **undecorated** — no leading underscore, no
`$s…` mangling. Mangled Swift symbols will also be present; that is normal and
harmless. (Verified on macOS: `swiftc -emit-library` on the identical source
exports `_probe_hello` / `_probe_free` alongside
`_$s8probeffi11probe_helloySpys4Int8VGSgSPyADGSgF`. The Windows question is
purely whether the PE export table gets the same treatment.)
**FAIL if:** no `.dll` is produced, or `dumpbin` lists mangled names only, or
`probe_hello` is absent. **The most likely cause is the `-static` trap**
(§2.6): the function must be `public` *and* live in a target named directly in
the `.dynamic` product's `targets:` array. If it is and the table is still
empty, record exactly what *is* exported — the fallback is a `.def` file or
`-Xlinker /EXPORT:probe_hello`, neither of which is documented for Swift, and
knowing which you need changes the build's maintenance cost substantially.

**Deliberate second measurement (2 min, high value):** move `probe_hello` into
a second target that `ProbeFFI` merely depends on, rebuild, and re-run
`dumpbin`. Expect it to **disappear**. Seeing that failure once, on purpose,
is worth more than any amount of reading — it is the failure mode that
otherwise costs a day.

Also note whether a `ProbeFFI.lib` import library appears next to the DLL;
`LibraryImport` does not need one, but a C consumer would.

#### Step 4 — call it from C# (R3, 10 min)

```powershell
cd C:\spike
dotnet new console -n Caller; cd Caller
```

`Program.cs`:

```csharp
using System.Runtime.InteropServices;
using System.Text;

internal static partial class N {
    [LibraryImport("ProbeFFI")]
    internal static partial IntPtr probe_hello(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [LibraryImport("ProbeFFI")]
    internal static partial void probe_free(IntPtr p);
}

var p = N.probe_hello("windows");
Console.WriteLine(Marshal.PtrToStringUTF8(p));
N.probe_free(p);
Console.WriteLine("freed cleanly");
```

Add `<AllowUnsafeBlocks>true</AllowUnsafeBlocks>` to the csproj, copy every
DLL from `..\.build\release\` next to the built exe, then:

```powershell
dotnet build -c Release
Copy-Item ..\.build\release\*.dll .\bin\Release\net8.0\
.\bin\Release\net8.0\Caller.exe
```

**Expected:**

```
{"ok":true,"greeting":"hello windows"}
freed cleanly
```

**FAIL if:** `DllNotFoundException` (a Swift runtime DLL is missing — go to
step 6), `EntryPointNotFoundException` (step 3's export table lied), or the
process dies on `probe_free` (cross-CRT free — the ownership rule in §5.2
rule 1 needs a different allocator, e.g. export a Swift-side `malloc` too).

#### Step 5 — cross-process lock, for real (R5, 10 min)

Two processes, not two threads, and not a mock. In one PowerShell window run a
Python holder that takes the lock the daemon will take:

```python
# holder.py — the daemon's side of blocker B1
import ctypes, ctypes.wintypes as w, msvcrt, time, sys
LOCKFILE_EXCLUSIVE_LOCK = 0x2
path = sys.argv[1]
f = open(path, "a+b")
h = msvcrt.get_osfhandle(f.fileno())
ov = (ctypes.c_byte * 32)()
ok = ctypes.windll.kernel32.LockFileEx(
        w.HANDLE(h), LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, ctypes.byref(ov))
print("python holds lock:", bool(ok), flush=True)
time.sleep(20)
print("python releasing", flush=True)
```

```powershell
python holder.py C:\spike\state.json.lock
```

In a second window, immediately run a Swift program using the
`WindowsFileLock` from §4.3 against the same path, printing a timestamp before
and after acquisition.

**Expected:** the Swift program **blocks for ~20 s** and prints its "acquired"
timestamp only after `python releasing`.
**FAIL if:** the Swift side acquires immediately — the two implementations are
locking different things and the cross-language contract does not exist.
That is the Windows twin of hardening bug #1 and it must be caught here.

Then, still in step 5, the sharing-violation check (R5, second half):

```powershell
# window A: hold state.json open for reading, in a loop
while ($true) { $s = [IO.File]::OpenRead("C:\spike\state.json"); Start-Sleep -Milliseconds 50; $s.Close() }
# window B: hammer the atomic write 200 times and count failures
```

**Expected:** *some* nonzero failure count from a naive tmp+`replaceItemAt`,
proving `replaceWithRetry` is needed. A zero count is a *weaker* result, not a
pass — it means the race is rarer than the loop, not absent.

#### Step 6 — what has to ship (R3, 5 min)

```powershell
dumpbin /dependents .build\release\ProbeFFI.dll
swift build -c release -Xswiftc -static-stdlib
dir .build\release\*.dll
```

**Expected:** the first command lists the runtime DLLs the redistributed app
must carry. §2.5 predicts roughly: `swiftCore.dll`, `swiftCRT.dll`,
`swiftDispatch.dll`, `swiftWinSDK.dll`, `swift_Concurrency.dll`,
`BlocksRuntime.dll`, `dispatch.dll`, `Foundation.dll`,
`FoundationEssentials.dll`, plus `FoundationInternationalization.dll` +
`_FoundationICU.dll` once anything formats a date, plus `vcruntime140.dll` /
`msvcp140.dll`. Record the exact list and total size — that is the install
footprint, and those DLLs are currently **unversioned**, so note that two
Swift-based apps on one machine is a known-fragile situation.

**`-static-stdlib` is expected to FAIL** (§2.5: static Foundation and static
libdispatch are unfinished; `swift.org`'s static-linking-on-Windows article is
a 404). Run it anyway and record the exact error — a surprise success would be
genuinely good news worth acting on. Either way, plan on **dynamic
redistribution: copy the DLLs into the .NET host's output directory**, and
**never** add that directory to the system `%PATH%` (swiftlang/swift#85321 —
doing so has broken installed Swift toolchains).

#### Step 6b — binary vs text mode (R5, 3 min)

The jsonl contract with the Python compactor is byte-exact. Add to
`FFI.swift` a function that opens a file the way a naive `SnapshotLogger`
port would (`_open` + `_write`, no `_O_BINARY`), writes `{"a":1}\n`, and have
the C# caller read the file back as bytes.

**Expected FAILURE (the finding):** the file contains `0D 0A`, not `0A` —
Windows text mode silently inserted a carriage return. Confirm that passing
`_O_BINARY` (or switching to `CreateFileW`/`WriteFile`) produces `0A` alone.
This is 3 minutes that prevents a data-corruption bug the Python side would
report as unparseable lines.

#### Step 7 — confirm the `DispatchQueue.main` trap (R4, 3 min)

§2.4 already establishes this from three primary sources, so this step is
about *seeing the exact behaviour in your configuration*, not about
discovering it.

Add to `FFI.swift`:

```swift
@_cdecl("probe_main_queue")
public func probe_main_queue() {
    DispatchQueue.main.async { print("MAIN QUEUE RAN") }
    Thread.sleep(forTimeInterval: 1.0)
    print("returning from probe_main_queue")
}
```

Call it from the C# program.

**Expected (the finding):** `returning from probe_main_queue` prints and
`MAIN QUEUE RAN` **never does**. That confirms R4 and means every
`DispatchQueue.main.async` in the core must go through `CoreScheduler` before
any Windows build is attempted.
If `MAIN QUEUE RAN` *does* print, note it — something is draining the queue
and R4 downgrades. Either way, **do not** try to work around it by making an
entry point `async` or `@MainActor`; §2.4's evidence is that those silently
never run, while synchronous C functions work correctly.

#### Recording the result

Write the answers into `docs/windows-recon.md` next to the R1–R8 daemon
answers, in the same empirical style. The decisive lines are: step 3's
`dumpbin /exports` output, step 4's stdout, step 2's five cast results, and
step 5's blocking timestamps. Everything else in this document is inference;
those four are measurements.
