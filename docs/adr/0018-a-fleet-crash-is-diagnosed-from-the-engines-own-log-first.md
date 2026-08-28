# 18. A fleet crash is diagnosed from the engine's own log, symbolized, before any mechanism is proposed

Date: 2026-08-28
Status: accepted

## Context

Issue #18 took most of a day and produced three published mechanisms before the
right one. The bug was a menu text box killing the game on PowerPC. The
sequence:

1. `SDLash_TextInputDelivers()` was re-gated from Darwin version to CPU
   architecture. A real bug, fixed, not this crash.
2. The key-derived text path was made to return after delivering a character,
   so a typed letter could no longer also fire a menu hotkey. A real bug,
   fixed, confirmed by hand on two machines, not this crash.
3. An SDL_DYNAPI jump-table race was proposed on the strength of register
   values in Apple's CrashReporter log. Entirely wrong, and retracted.

None of these were guesses in the sense of being careless. Each was argued from
evidence. The problem is that the evidence was the wrong evidence, and better
evidence was sitting unread on the machine the whole time.

The engine's POSIX crash handler writes to `Sys_LogFileNo()`, which on a fleet
install is `~/Desktop/Half-Life/last-run.log`. That file held:

```
Ver: Xash3D FWGS 0.21 (build 4167-1bad7f77-HEAD, apple-ppc)
Crash: signal 10 errno 0 with code 1 at 0xffff9228
 0: 0xffff9228
 1: libmenu.dylib+0x1baec [0x193f6aec]
 2: libmenu.dylib+0x1faac [0x193faaac]
 3: libxash.dylib+0x99728
```

Two `nm` lookups against the deployed `libmenu.dylib` turn that into
`CMenuField::KeyDown+0x1dc` under `CMenuItemsHolder::Key+0x164`, calling the
PowerPC commpage `bcopy`. From there the cause is a short read of one function:
`CMenuField::UpdateEditable()` replaces the field's buffer without bringing
`iCursor` back into range, so both of the field's memmoves take a negative
length that converts to a roughly 4 GB `size_t`. That is a ten minute diagnosis
from a file that already existed.

What was read instead was `~/Library/Logs/CrashReporter/xash3d.bin.crash.log`.
Apple's report named CoreAudio's IO thread as the faulting thread, because the
main thread had already taken its signal and was inside the crash handler. The
whole SDL_DYNAPI theory was built on that thread's registers. It was a thread
that had nothing to do with the bug.

Two supporting failures made this last longer than it should have:

**The regression test could not reach its own assertion.**
`scripts/test-text-input.sh` exists specifically to type into a text box,
because no earlier smoke test did. Its "reached the menu" gate grepped for the
literal string `execing mainui.cfg`, and the engine writes that filename with
colour escapes inside it, so the gate never matched on any machine, ever. Every
run printed `FAIL - never reached the menu` and exited before typing a single
character. That reads like a machine or display problem, so it was treated as
one. The one check that would have caught this bug had never executed.

**A fat binary symbolizes differently per slice.** `libmenu.dylib` ships `ppc`
and `ppc7400` among others. Symbolizing those two offsets against the generic
`ppc` slice yields a destructor and `CMenuPicButton::Draw`, which do not call
each other and would have sent the diagnosis somewhere else again. The
`ppc7400` slice yields `Key` calling `KeyDown`, which is coherent. Picking the
wrong slice does not fail loudly; it returns confident nonsense.

## Decision

**Before proposing any mechanism for a crash on a fleet machine, pull that
machine's `last-run.log` and symbolize every frame it names.** The engine's own
handler runs in-process and reports the thread that actually faulted. Apple's
CrashReporter report is a secondary source for a crash in our own code: it is
worth reading, but it is not the starting point and its "Thread N Crashed" is
not authoritative when our handler is on the stack.

Concretely, for any fleet crash:

1. `last-run.log` first, whole file. The `Crash:` line gives the signal and the
   faulting address; the numbered frames give module plus offset.
2. Symbolize with `nm -n` against **the exact deployed binary**, checked by md5,
   and against **the slice that machine actually loaded**. If the symbolized
   frames do not form a call chain that could exist, the slice is wrong.
3. Only then read the source, and only then say what the mechanism is.

**A claim about a crash mechanism cites a symbolized frame or is labelled
inferred.** This is `.claude/skills/claim-hygiene` applied to crashes
specifically. "The register shape suggests a dispatch table" is not a frame.

**A test that cannot reach its assertion is a broken test, not a failing
environment.** When a harness reports an early-stage failure such as "never
reached the menu" on a machine that is demonstrably fine, the harness is the
first suspect. Do not re-run it hoping for a different machine state.

## Consequences

**The engine's crash log is a first-class artifact and must keep working.**
`Sys_Crash` writes the log before it does anything else, which is why the text
survived a handler that went on to deadlock in `SDL_ShowSimpleMessageBox`. That
ordering is load bearing. Anything that moves, buffers or conditionalises the
log write costs the fleet its best diagnostic, and `-nomsgbox` must keep
suppressing only the dialog.

**`deploy-dmg.sh` should not delete `last-run.log` on install.** Not yet
checked. If it does, a crash from the previous build is gone before anyone asks
about it.

**Nothing here says stop using hardware.** The user reproducing this by hand,
and correcting "it crashes on Backspace" to "it crashes on any key", is what
made the mechanism findable at all: Backspace alone points at one memmove, any
key points at both, and both is what the code does. Hands-on evidence steered
this correctly every time it was consulted. What failed was the desk work
between those reports.

**This does not add a review gate.** It changes the order of two steps that were
already being done, and costs a file read.

## Related

- Issue #18, and the three retractions on it.
- `.claude/skills/claim-hygiene`: measured versus inferred, and retracting the
  claim only.
- `.claude/rules/working-method-and-hard-rules.md`: the refutation pass, for
  when a mechanism is load bearing and hard to test directly. A symbolized
  frame is cheaper than a refutation pass and should come first.
- `.claude/rules/build-verification.md`: never trust a build's exit code. Same
  shape of failure, one stage earlier.
- `scripts/test-text-input.sh`, and `BUGFIXES.md` for the fix itself.
