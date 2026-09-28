# Bug-fix log

One `## <ticket> <summary>` entry per real bug fixed, newest first, body 5 lines or fewer: cause, fix, evidence.
Read it with `grep -n '<ticket>' BUGFIXES.md` and a `sed -n` range, never whole. `F<n>` is a finding in
`docs/port/POWERPC-FINDINGS.md`; an entry with no ticket is headed by its commit hash or finding id.
Entries older than 60 days move to `docs/archive/BUGFIXES.md`. Not a changelog: add one only for a real bug.

## #54 G5 provisioned before the MSAA/ripple seed pins kept both off, with no error
Cause: `gl_msaa_samples` and `r_ripple` are `FCVAR_GLCONFIG`, so the launcher's "seed if absent" write never reaches an install that already archived the pre-pin value into `opengl.cfg`. Read live on two G5s: `imac-g5` correct, `g5-panther` had both archived at `0`.
Fix: `gl_msaa_samples` has no player control (mainui's note says so), so it is FORCED every launch, as for the G3 and the Radeon 9200 mini G4. `r_ripple` has one ("Water ripples", `menus/VideoOptions.cpp:211`), so it gets a ONE-TIME catch-up gated on marker `valve/.hl-g5-ripple-catchup` (written at seed on a fresh install, at first catch-up on an existing one).
Evidence: `make-app.sh`; d963b4c (v1.9.23). 2026-09-28.

## 4175fcf deploy-dmg.sh upgrade left the loose files beside the apps stale
Cause: an upgrade replaced only the three app bundles, so `BUILD-INFO.txt`, `README.txt` and `Fix Launch Problems.command` kept the first install's copies; a v1.9.19 deploy on the workstation left `BUILD-INFO.txt` reading 1.9.16-rc1.
Fix: install each of the three by name when the image carries it.
Evidence: control, the same redeploy reads 1.9.19 in all three places, and `valve/config.cfg` and the retail data are untouched. 4175fcf. 2026-09-23.

## #37 make-dmg.sh refused a correct five-slice fuse as "missing ppc7400" on Xcode 27
Cause: Xcode 27's `lipo -archs` drops both PowerPC slices and `-detailed_info` calls them "unknown cputype". The mod-dylib checks would have refused every mod next, and `test-artifact.sh`'s guard against a generic `ppc (ALL)` executable slice could no longer fail.
Fix: both read slice names from the Mach-O header with `scripts/macho-archs.py`.
Evidence: control, `test-artifact.sh` on the published v1.9.18 image, 53 passed; a copy of `xash3d.bin` re-stamped to generic ppc trips the guard. 85f2eff, 53071e6. 2026-09-22.

## retro-server-infra#27 join-test.sh counted "Server info" as a join and killed the game at once
Cause: every Half-Life row on retro-server-infra#27 was "info only". The client log has no spawn line (a client the user played in on imac-g5 logged nothing after connect).
Fix: require the client to parse the server's serverdata, then stay alive `HOLD` seconds (default 60) with no drop; print the UTC window, host and binary md5; exit 3 for "confirm the spawn from the server journal". `VOICE=0` (default) keeps a headless 10.14+ host off the microphone prompt that blocked imac-2019 mid-connect.
Evidence: a72b5cc, 53071e6. 2026-09-22.

## #34 Flashlight hard edges at wall folds
Cause: the earlier spherical candidate mixed texture-space offsets with world-space plane distance, so adjoining faces still disagreed.
Fix: engine `7d3a331b`: plane-correct inverse texture mapping, conservative world-space marking, one flashlight radius chosen from its hit face.
Evidence: shared-point regression passes on Apple Silicon and the G4; user confirmed in `v1.9.18-rc3` on Apple Silicon, the G4 mini, the iMac G5 and imac-2019. `docs/adr/0020`, aff0d69, 63bf4ec, 2ca6db2 (v1.9.18). 2026-09-08.

## d3c10eeb Flashlight drew a dark rectangle around its beam on PowerPC
Cause: with `gl_overbright` on, the single-pass world stage draws base x lightmap x2 with no colour, but `R_BlendLightmaps`, which still draws every surface single-pass defers (dynamically lit ones first), kept the classic `GL_DST_COLOR`/`GL_SRC_COLOR` blend with its 128/192 colour, so those surfaces came out at 1.333x (one wall at two thirds the brightness of its neighbours).
Fix: shared `R_SinglePassLighting()` predicate; `R_BlendLightmaps` skips the colour when it holds. Intel and arm64, where `gl_singlepass` is off, are unchanged.
Evidence: measured on the mini G4 (Radeon 9200), map `c0a0`: present at defaults, absent with `gl_overbright 0` (both routes x1) and `gl_singlepass 0` (both routes classic). Engine `d3c10eeb`, pin 08e77c1. 2026-09-07.

## #31 Bans from banid/addip did not survive a server restart
Cause: neither writes to disk on its own and `server.cfg` never executed the files that restore them; confirmed in the engine source (`sv_filter.c` says `banned.cfg` "is not executed by engine").
Fix: `server.cfg` execs `banned.cfg` and `listip.cfg` at startup (no-op before either exists); operators still run `writeid`/`writeip` after a ban. `server/README.md` also documents the dead-code trap where `banid`'s `#<userid>` short form silently does nothing.
Evidence: from infra's admin-panel survey. a8c0710. 2026-09-03.

## #25 Voice-init mouse release bypassed the engine's own mouse-state flags
Cause: the fix for #25 (release the mouse before macOS's microphone prompt) called `SDL_SetRelativeMouseMode` and `Platform_SetMouseGrab` directly, skipping `IN_SetRelativeMouseMode`'s and `IN_SetMouseGrab`'s static flags; out of sync, a later re-enable could silently no-op and leave mouse-look broken for the session.
Fix: route through those wrappers (also removes the manual state restore); adds diagnostic logging. This does NOT fix #25's actual complaint: the permission dialog still cannot be reached mid-connect on real hardware.
Evidence: engine `f9043e87`, pin 13676c7. 2026-09-03.

## #26 deploy-dmg.sh left its copy of the release .dmg on the target's Desktop
Cause: it copied the source `.dmg` to the target's Desktop, installed from it and never removed it; found by old-mac-build-host's fleet Desktop-cruft sweep, a leftover DMG on 8 of 9 reachable hosts, mtimes matching known bench-testing rounds.
Fix: removed once the install it was copied for has fully succeeded. The script is now a shim over the shared copy (`shared-scripts.pin`).
Evidence: logged in 5553ca2. 2026-09-02.

## 7084c3d "macOS is blocking Half-Life" dialog with the game already outside Desktop/Documents/Downloads
Cause: reproduced on imac-2019/Sequoia, folder at `~/Half-Life` reached via a `~/Desktop/Half-Life` symlink. The launcher's `cd ... && pwd` is bash's LOGICAL pwd, so it kept the Desktop-prefixed path and the write probe hit the modern-macOS block for an unsigned app.
Fix: `cd -P` / `pwd -P` in `make-app.sh`'s launcher heredoc. Also `Fix Launch Problems.command` in the DMG (every slice): copies the game out of a mounted image, or relocates an install stuck in those folders, to `~/Half-Life` and clears quarantine.
It does nothing on Panther/Tiger (checks the Darwin major, says so). Leopard and Snow Leopard carry the quarantine flag and its one-click warning without Gatekeeper's hard block, so it clears it there; this file once said "no-op on Panther/Tiger/Leopard", wrong for Leopard.
Evidence: 7084c3d, 92fe2df, e8fd375 (Panther skip). 2026-09-02.

## #28 Flashlight and dynamic light rendered as a grid of grey squares on imac-2019
Cause: this fork's single-pass world multitexture (`gl_singlepass`), built for fillrate-bound PowerPC GPUs, misbehaves on at least one modern GPU/driver (imac-2019, AMD Radeon Pro 580X; absent on imac-g5, Radeon 9600) on the path deferring dynamic-lit surfaces to the classic renderer. User isolated it live: `gl_singlepass 0` fixed it, `gl_overbright` made no difference.
Fix: `gl_singlepass` defaults on for PowerPC only (launcher profile in `make-app.sh`), plus a direct `opengl.cfg` patch because the cvar is `FCVAR_GLCONFIG` and was archived "1" fleet-wide. Root cause in the single-pass code NOT found: a workaround, not a source fix.
Evidence: 26d92b2. 2026-08-31.

## 9208385 Crouch (Ctrl) triggered macOS's "press Control twice" Dictation/Voice Control shortcut mid-game
Cause: crouching in a firefight means tapping Control repeatedly, a system shortcut the game cannot suppress.
Fix: bind `C` to `+duck` too in `userconfig.cfg`, beside the Ctrl bind.
Evidence: 9208385. 2026-08-31.

## #18 Typing or backspacing in a menu text box ran a memmove off the heap block
Cause: `CMenuField` keeps `iCursor`/`iScroll` as byte indices into `szBuffer`; `SetBuffer()`, `Clear()` and `VidInit()` bring them into range but `UpdateEditable()` (run on every `Show()`) did not, and resyncs the cursor BEFORE replacing the buffer with a shorter cvar value (the engine truncates `name` behind the menu), leaving it past the terminator. `len - iCursor + 1` goes negative, becomes a ~4 GB `size_t` and runs to an unmapped page.
Fix: all three call sites clamp. Also fixed from reading against upstream (all present in upstream mainui): `VidInit()` computed `iScroll` from `iRealWidth` before assigning it, and `m_bOverrideOverstrike` was never initialised.
Evidence: measured on `g5-panther` (10.3.9), engine build 1bad7f77: SIGBUS at `0xffff9228` (PowerPC commpage bcopy) from `CMenuField::KeyDown+0x1dc` under `CMenuItemsHolder::Key+0x164`, symbolized against the deployed `libmenu.dylib`. `KeyDown` backspace and `Char` insert are the two memmoves, so never about Backspace. 9c7d838 (menu fork), 2a57fae. 2026-08-28.

## #18 A typed character also fired other menu items' hotkeys on PowerPC
Cause: the key-derived text-input path delivered the character, then fell through to key dispatch for the same keydown, matching every OTHER item's hotkey ('g' in a name left Customize for Game Options). Intel never hit it: with SDL text input active it returns before that dispatch.
Fix: return after delivering a character, matching Intel; non-printable keys (Backspace, arrows, Enter) still fall through since `CMenuField::KeyDown`, not `Char`, handles those.
Evidence: engine 1bad7f77, pin 4aa45ea. 2026-08-28.

## #18 SDLash_TextInputDelivers() was gated on Darwin major and beachballed a second G5
Cause: only 10.3/10.4 skipped SDL text input, on one dated finding that a G5 on 10.5.8 typed fine. Measured hands-on on a SECOND G5 (dual PowerMac, g5-desktop): it did not generalise; the same build gave a system-wide, unrecoverable beachball opening a text box.
Fix: re-gate on CPU architecture (`__ppc__`/`__ppc64__`), so every PowerPC OS version takes the key-derived path.
Evidence: engine ff64ebd3, pin d62ecce. 2026-08-28.

## #18 Sys_Crash's dialog deadlocked inside a signal handler
Cause: `SDL_ShowSimpleMessageBox` allocates and is unsafe in a signal handler; a thread already inside `malloc` deadlocked on its own lock forever. Measured live: two concurrent crashes stuck in the identical deadlock. A crash could cost a hard reboot.
Fix: re-entrancy guard plus a 5-second watchdog that force-exits if the dialog hangs; the crash text is already on disk by then. Apple-only.
Evidence: engine 66d5bd78. 2026-08-28 (first logged; commit date not recoverable, hash not in local fork).

## #19 smoke-dmg.sh could not catch a Gatekeeper/quarantine rejection and misreported working launches as crashes
Cause: it ran the launcher binary directly over ssh, bypassing LaunchServices; its `ps ax` liveness poll truncated the COMMAND column over a non-tty ssh pipe, so `xash3d.bin` never appeared and every working launch read as a crash after the full timeout. The quad G5 aliases (`quad-tiger`/`quad-leopard`) were missing from the machine table.
Fix: launch via `open` (a LaunchServices refusal is a FAIL); `ps -axww` disables the truncation; aliases added.
Evidence: d462f2c, e48e6aa, 154a109. 2026-08-28.

## #19 deploy-dmg.sh installed a bundle without verifying the signature survived
Cause: no signature check and no `com.apple.quarantine` clear if the image arrived by a route that sets it. Found via a corrupted install on `imac-2019`: `codesign -v` failed there, a fresh `ditto` from the same image on the same machine was clean.
Fix: both handled on every install, fatally on a bad signature.
Evidence: d462f2c. 2026-08-28.

## #17 Launcher forced Radeon-measured MSAA/shadows/ripple defaults on every G4/G5
Cause: applied whatever GPU the machine actually had.
Fix: gated on an ioreg check for a Radeon-generation chip; anything else gets conservative defaults.
Evidence: 46a6dd8. 2026-08-23.

## 46a6dd8 Unescaped backticks in the launcher-generation heredoc ran `machine` at generation time
Cause: unescaped backticks are command substitution, so generating the launcher ran `machine` and corrupted the output with it.
Fix: escaped; the general trap is in CLAUDE.md.
Evidence: 46a6dd8. 2026-08-23.

## #8 The G3 profile expressed "no MSAA" by omitting the cvar, inheriting the archived value
Fix: sets `gl_msaa_samples 0` explicitly (now also forced every launch, see #54).
Evidence: 90fafa2. 2026-08-23.

## #16 Game icon crop cut off the top of Gordon's head at every size
Cause: the crop started 100px below his hairline.
Fix: crop from the hairline.
Evidence: 42a3243. 2026-08-23.

## #15 benchmarks/results.csv had 19 host labels for 8 machines
Cause: some came from a `hostname -s` fallback naming no real machine.
Fix: `-l` is now required and labels are registered (enforced by `tests/test-repo.py`).
Evidence: bc1d0cd. 2026-08-23.

## 73b6e39 test-frame.sh expanded a tilde on the caller instead of the remote shell
Cause: the tilde sat inside quotes meant for the remote shell.
Evidence: 73b6e39. 2026-08-23.

## #4 Stale arm64 slices fused silently
Fix: the engine compares the slice BUILD-STAMP to the pinned commit, the Mods/System Report apps carry a source content hash, and mod dylibs carry the hlsdk commit; a mismatch refuses the fuse.
Evidence: 61c52f2, e8c8125, d3fda6e; ADR 0015/0016. 2026-08-22.

## #13 Two re-exec guards compared RETRO_BENCH_LOCK to an empty expansion
Cause: the guard was always true.
Fix: compare against the target host.
Evidence: 60e7e5c. 2026-08-22.

## #12 The bench lock carried no nonce, so a sibling session's --release could drop it
Fix: nonce added.
Evidence: ea2cb0b. 2026-08-22.

## #11 make-dmg.sh pulled from a build mini without claiming it
Fix: claims the Tiger box and checks the mini's lock first.
Evidence: cf00d1f. 2026-08-22.

## 481632b The stale-arm64 error message suggested rebuilding on a host alias that does not resolve
Evidence: 481632b, 5c6492f. 2026-08-22.

## F19 Stale video-mode menu; "syncs on every mode set" mechanism REFUTED, do not republish
Symptom (real): the video menu highlighted a higher resolution than the one on screen; the launcher's `-width`/`-height` path never updated the `vid_mode` storage cvar. Menu-side fix (depth changes by explicit width and height) stands.
The stated mechanism was wrong: at launch `R_SaveVideoMode` runs before the mode list is populated, so the loop iterates zero times; the later `SDL_WINDOWEVENT_RESIZED` carries the fix.
Evidence: engine `def536d3`, `docs/port/POWERPC-FINDINGS.md` F19. 2026-08-18.

## F15 The welder went dark on the G3 because of an archived cvar, not the code
Cause: `r_dynamic` is `FCVAR_ARCHIVE` and the G3's carried-over `config.cfg` held it at `"0"` (old benchmark probe), preserved across every deploy; the single-pass code was line-for-line the pre-fork one.
Fix: `r_dynamic "1"` pin in the shipped `userconfig.cfg`; light confirmed on the G3. Moral: "worked before X" dates the config, not the code.
Evidence: 10c4b06, F15. 2026-08 (v1.7.0 hands-on).

## F14 Blue screenshots were not a rendering fault
Cause: the capture path, not the renderer: `ref_soft` wrote pixels as a native-order word instead of bytes. What was on screen was always correct.
Evidence: `a7bb7bd3`, F14. 2026-07-31.

## F13 Single-pass world draw flicker and dead branch; fog-support attempt withdrawn
Cause: `R_CheckLightMap` ran before the base draw, and a dynamic-lightmap branch rebound the base texture in a case that could never fire (found only by reading code back).
Fix: `a95988c8`, `327336b5`. The third attempt (single-pass under fog) was dropped: a person judged classic two-pass better, and the gain was narrow.
Evidence: F13. 2026-08 (date approximate, engine commit dates not recoverable).

## F9 Menu hint text stopped scaling at 1280 wide
Evidence: F9, `docs/port/POWERPC-FINDINGS.md`; findings published f8e6659 (2026-08-09).

## F8 Menu drew token names on a missing dictionary key
Cause: `L()` returns its key on a miss.
Evidence: F8; findings published dcae10b (2026-08-09).

## F7 Release builds got empty backtraces from backtrace_full
Evidence: F7; engine `5f04e0e4`, `df97adf5` (unwind from the signal context). 2026-07-31 to 2026-08-04.

## F5 Leopard advertises non-power-of-two textures its driver samples in software
Evidence: F5; engine `971bfd77`, `b686a174`. 2026-08-04.

## F4 A blocking getaddrinfo on the frame loop read as broken input
Evidence: F4; engine `b187b4db`, `f75afcb9`. 2026-07-31.

## F3 Finder launch failed: dlopen of a bare leaf name has no directory to resolve against
Evidence: F3; engine `6ceb56b5`. 2026-07-31.

## F2 Mod switching dead on Darwin: execve refused from a multi-threaded process
Evidence: F2; engine `09afd735` (fork before exec). 2026-07-31.

## F1 Guard-door freeze: Panther's dladdr keeps the Mach-O leading underscore
Cause: breaks save/restore's function-pointer name round-trip. Fix: normalize in `COM_NameForFunction`. The gcc-miscompile diagnosis was wrong (F10).
Evidence: F1, F10. 2026-07-31 (engine history rebased; earlier date not recoverable).
