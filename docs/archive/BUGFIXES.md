# Bug-fix log, archive

Entries moved out of `BUGFIXES.md` once older than 60 days, or superseded. Same format: `## <ticket> <summary>`,
body 5 lines or fewer, newest first. Move entries here, never delete them. Read with `grep -n '<ticket>'`.
Nothing has aged out yet: the oldest entries in `BUGFIXES.md` date from 2026-07-31.

## F19 Stale video-mode menu; "syncs on every mode set" mechanism REFUTED, do not republish
Symptom (real): the video menu highlighted a higher resolution than the one on screen; the launcher's `-width`/`-height` path never updated the `vid_mode` storage cvar. Menu-side fix (depth changes by explicit width and height) stands.
The stated mechanism was wrong: at launch `R_SaveVideoMode` runs before the mode list is populated, so the loop iterates zero times; the later `SDL_WINDOWEVENT_RESIZED` carries the fix.
Evidence: engine `def536d3`, `docs/port/POWERPC-FINDINGS.md` F19. 2026-08-18.

## F13 Single-pass world draw flicker and dead branch; fog-support attempt withdrawn
Cause: `R_CheckLightMap` ran before the base draw, and a dynamic-lightmap branch rebound the base texture in a case that could never fire (found only by reading code back).
Fix: `a95988c8`, `327336b5`. The third attempt (single-pass under fog) was dropped: a person judged classic two-pass better, and the gain was narrow.
Evidence: F13. 2026-08 (date approximate, engine commit dates not recoverable).
