# Windows spike — settle the Path 3 gating questions

Self-contained. Copy this whole folder to a Windows 11 box; you do not need
the repo or `swift-windows-audit.md` on that machine. ~45 min, most of it
toolchain download.

**Run in order. Stop at the first FAIL** — each step gates the ones after it.
Paste output into `RESULTS.md` as you go.

Four lines in this spike are *measurements*; everything in the audit is
inference. Those four are: step 2's cast results, step 3's `dumpbin /exports`,
step 4's stdout, step 5's blocking timestamps. If you run out of time, run 2,
3, 5 and skip the rest.

---

## Step 0 — install (~15 min)

Enable **Developer Mode** first (Settings → System → For developers). Both
commands — the Swift toolchain alone builds nothing without MSVC + the
Windows SDK.

```powershell
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22000 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
```

```powershell
winget install --id Swift.Toolchain -e --source winget
```

Open a **new** shell — specifically a *Developer PowerShell for VS 2022*, so
`dumpbin` is on PATH — then:

```powershell
swift --version
```

**PASS:** Swift 6.3.3 or later, target `x86_64-unknown-windows-msvc` (or
`aarch64-…`).
**FAIL:** `swift` not on PATH after a new shell, or errors about a missing
Windows SDK component.

> Ignore any blog post telling you to copy `ucrt.modulemap` /
> `visualc.modulemap`. That step was removed in Swift 5.9 and following it
> **breaks** a modern install. There is no `swiftly` on Windows, so record the
> exact installer version — it's your only pin.

---

## Step 1+2 — Foundation behavior (~7 min). **Highest information density in the spike.**

```powershell
mkdir C:\spike; cd C:\spike
swift package init --type executable --name Probe
```

Now **overwrite** `C:\spike\Sources\Probe\Probe.swift` with the `Probe.swift`
from this folder (delete `main.swift` if the toolchain made one instead —
you can't have both).

```powershell
swift build
swift run
```

**PASS:** it builds and runs. The *values* are the finding — record all of
them, there is no single pass/fail line.

macOS baseline — **actually measured** on the dev Mac (Swift 6.2, 2026-07-26)
by compiling and running this exact file, not transcribed from the audit:

```
b type       : __NSCFBoolean
b as? Bool   : Optional(true)
b as? NSNum  : Optional(true)
d as? Double : Optional(1.5)
d as? NSNum  : Optional(1.5)
i as? Int    : Optional(7)
big as? Doubl: Optional(1753000000.0)
null isNSNull: true
validJSONObj : true
TZ UTC       : Optional(GMT)
TZ gmt0      : Optional(GMT (0))
daily key    : 2025-07-20
grouped      : Optional("2,786.17")
iso frac     : Optional(2026-07-26 10:00:00 +0000)
home         : /Users/sam
creationDate : Optional(2026-07-26 20:41:58 +0000)
```

> `daily key` is **2025**-07-20, not 2026 — epoch 1753000000 is July 2025.
> The audit's §6.3 wrote 2026 here; that was wrong and would have read as a
> timezone divergence on Windows when nothing was actually wrong. Compare
> against the block above, not against the audit.

What each divergence decides:

| Line | If it differs from baseline |
|---|---|
| `b as? Bool` / `d as? Double` / `i as? Int` → **nil** | The `JSONValue` refactor already landed is *mandatory*, not defensive. Whether `as? NSNum` still works tells us which way the accessors must fall back. |
| `TZ UTC` → **nil** | The `?? .current` landmine is live. (Already fixed in `GraphModel`, but it means the pattern must never come back.) |
| `daily key` ≠ `2026-07-20` | Timezone/calendar handling diverges from the Python daemon — plan-fit and cost charts would be wrong by a day. |
| `grouped` nil or ungrouped | No ICU locale data; `PlanFitModel.apiEquivalentText` needs hand-rolled grouping. |
| `creationDate` → **nil** | The cloud-echo dedupe silently dies. |

---

## Step 3 — does SwiftPM emit a real DLL with `@_cdecl` exports? (~5 min)

Separate package, so step 2's executable stays intact:

```powershell
cd C:\spike
mkdir ProbeFFI; cd ProbeFFI
mkdir Sources\ProbeFFI
```

Copy `Package.swift` and `FFI.swift` from this folder into
`C:\spike\ProbeFFI\` and `C:\spike\ProbeFFI\Sources\ProbeFFI\` respectively.

```powershell
swift build -c release
dir .build\release\*.dll
dumpbin /exports .build\release\ProbeFFI.dll | findstr probe_
```

**PASS:** `ProbeFFI.dll` exists and `dumpbin` lists `probe_hello`,
`probe_free`, `probe_main_queue` **undecorated** — no leading underscore, no
`$s…` mangling. Mangled Swift symbols alongside them are normal.
**FAIL:** no DLL, or mangled names only, or `probe_hello` absent.

> Most likely cause of a FAIL is the **`-static` trap**: SwiftPM passes
> `-static` to every Swift module on Windows, stripping `dllexport`. The
> function must be `public` *and* live in a target named directly in the
> `.dynamic` product's `targets:` array. If it is, and the table is still
> empty, record exactly what *is* exported — the fallback is a `.def` file or
> `-Xlinker /EXPORT:`, neither documented for Swift, and which one we need
> changes the build's maintenance cost a lot.

**Worth 2 extra minutes:** move `probe_hello` into a second target that
`ProbeFFI` merely *depends on*, rebuild, re-run `dumpbin`. Expect it to
**vanish**. Seeing that failure once on purpose is worth more than reading
about it — it's the one that otherwise costs a day.

Also note whether a `ProbeFFI.lib` appears next to the DLL.

---

## Step 4 + 7 — call it from C#, and the `DispatchQueue.main` trap (~12 min)

```powershell
cd C:\spike
dotnet new console -n Caller
cd Caller
```

Overwrite `Program.cs` with the one from this folder. Add
`<AllowUnsafeBlocks>true</AllowUnsafeBlocks>` to `Caller.csproj`, then:

```powershell
dotnet build -c Release
Copy-Item ..\ProbeFFI\.build\release\*.dll .\bin\Release\net8.0\
.\bin\Release\net8.0\Caller.exe
```

**PASS (step 4):**

```
{"ok":true,"greeting":"hello windows"}
freed cleanly
```

**FAIL:** `DllNotFoundException` (missing Swift runtime DLL → step 6),
`EntryPointNotFoundException` (step 3's export table lied), or a crash on
`probe_free` (cross-CRT free — we'd need to export a Swift-side allocator).

**Step 7, the expected finding:** `returning from probe_main_queue` prints and
**`MAIN QUEUE RAN` never does.** That confirms libdispatch's main queue is
dead in a .NET-hosted Swift DLL, which means every `DispatchQueue.main.async`
in the shared core needs a scheduler seam, and **entry points must stay
synchronous** — not `async`, not `@MainActor`. If `MAIN QUEUE RAN` *does*
print, note it; something is draining the queue and this risk downgrades.

Either way: do **not** try to fix it by making an entry point `async` or
`@MainActor`. The evidence is that those silently never run, while synchronous
C functions work correctly.

---

## Step 5 — cross-process lock, for real (~10 min)

Two processes, not two threads, not a mock. This is the Windows twin of the
`flock`-per-inode bug that once made the Mac's locking *illusory* while
looking correct.

Window A:

```powershell
python holder.py C:\spike\state.json.lock
```

It prints `python holds lock: True`, holds for 20 s, then prints
`python releasing`.

Window B, immediately: a Swift (or second Python) process taking
`LockFileEx(LOCKFILE_EXCLUSIVE_LOCK)` on the **same path**, printing a
timestamp before and after acquisition. Easiest version — run `holder.py`
again in a second window and watch its `holds lock` timestamp.

**PASS:** the second process **blocks ~20 s** and acquires only after
`python releasing`.
**FAIL:** it acquires immediately ⇒ the two sides are locking different
things and the cross-language contract does not exist. Must be caught here.

### Step 5b — the sharing-violation check

Window A:

```powershell
while ($true) { $s = [IO.File]::OpenRead("C:\spike\state.json"); Start-Sleep -Milliseconds 50; $s.Close() }
```

Window B: hammer a tmp-write + replace 200 times against
`C:\spike\state.json` and count failures.

**Expected:** a *nonzero* failure count, proving `replace_with_retry` (already
implemented in `platform_compat.py`) is genuinely required. A zero count is a
**weaker** result, not a pass — it means the race is rarer than the loop, not
that it's absent.

---

## Step 6 — what has to ship (~5 min)

```powershell
cd C:\spike\ProbeFFI
dumpbin /dependents .build\release\ProbeFFI.dll
swift build -c release -Xswiftc -static-stdlib
dir .build\release\*.dll
```

Record the dependents list — that's what a redistributed app must carry.
Expect roughly `swiftCore.dll`, `swiftCRT.dll`, `swiftDispatch.dll`,
`swiftWinSDK.dll`, `swift_Concurrency.dll`, `BlocksRuntime.dll`,
`dispatch.dll`, `Foundation.dll`, `FoundationEssentials.dll`, plus
`FoundationInternationalization.dll` + `_FoundationICU.dll` once anything
formats a date, plus `vcruntime140.dll`. Note whether `-static-stdlib`
meaningfully shrinks that list.

---

## Recording the result

Fill in `RESULTS.md` and bring it back to the repo. The decisive items:

- [ ] Step 2 — all printed values
- [ ] Step 3 — `dumpbin /exports` output, and whether the second-target move made it vanish
- [ ] Step 4 — stdout
- [ ] Step 7 — did `MAIN QUEUE RAN` print?
- [ ] Step 5 — blocking timestamps
- [ ] Step 5b — failure count out of 200
- [ ] Step 6 — dependents list
- [ ] Toolchain version from step 0
