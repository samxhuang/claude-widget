# Windows spike results

Machine: <!-- Windows 11 build, x64 or ARM64 -->
Date run:
Swift toolchain version (step 0):
Visual Studio / Windows SDK version:

---

## Step 2 — Foundation behavior

Paste `swift run` output verbatim:

```
```

macOS baseline for diffing:

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

- [ ] Did `DateFormatter` crash rather than print? (open corelibs Windows
      crasher whose reproducer matches `GraphModel.utcDailyKeyFormatter()`)

---

## Step 3 — DLL + export table

`dumpbin /exports .build\release\ProbeFFI.dll | findstr probe_`:

```
```

- [ ] `probe_hello` present and **undecorated**?
- [ ] `ProbeFFI.lib` produced alongside the DLL?
- [ ] Second-target experiment: after moving `probe_hello` into a
      merely-depended-on target, did it **vanish** from the export table?
      (expected yes — confirms the `-static` trap)

---

## Step 4 — C# P/Invoke

`Caller.exe` stdout:

```
```

- [ ] `{"ok":true,"greeting":"hello windows"}` printed?
- [ ] `freed cleanly` printed, no crash on `probe_free`?

---

## Step 7 — `DispatchQueue.main` in a .NET-hosted DLL

- [ ] Did `returning from probe_main_queue` print?
- [ ] Did **`MAIN QUEUE RAN`** print?

> Expected finding: the first yes, the second **no**. That confirms R4 —
> entry points must stay synchronous, and every `DispatchQueue.main.async` in
> the shared core needs a scheduler seam. If `MAIN QUEUE RAN` *did* print,
> say so; the risk downgrades materially.

---

## Step 5 — cross-process lock

Window A timestamps:

```
```

Window B timestamps:

```
```

- [ ] Did window B **block ~20s**, acquiring only after A released?
- [ ] Was `platform_compat.py` copied in (testing the real `FileLock`), or did
      it fall back to the inline version?

## Step 5b — sharing violations

```
naive os.replace failures:      /200
replace_with_retry failures:    /200
```

---

## Step 6 — redistributable footprint

`dumpbin /dependents`:

```
```

- [ ] Did `-static-stdlib` meaningfully shrink the DLL list?

---

## Anything surprising

<!-- Free text. Errors, weird behavior, things that took much longer than the
     estimate, anything that contradicts docs/swift-windows-audit.md. A
     surprise here is worth more than a clean pass. -->
