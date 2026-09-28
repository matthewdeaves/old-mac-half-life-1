# Tiger QEMU capture

Summary: `scripts/vm-frame-check.sh` claims `qemu-tiger3d`, starts `c0a0` in the Tiger VM,
captures the host framebuffer at the engine's capture marker, and asks the engine to quit
normally. It proves a visible frame and a clean exit, not audio or Mac focus behaviour.
VM builds and shared tooling belong to `old-mac-build-host`.

## Capture

With the installed Tiger VM running:

```sh
scripts/vm-frame-check.sh 150 /tmp/halflife-gameplay.png
```

The helper claims `qemu-tiger3d`, refuses overlapping games, starts `c0a0`,
and captures the host framebuffer after the engine reaches its capture marker.
It keeps the SSH session alive and asks the engine to quit normally. Avoid
killing a fullscreen process on the emulated Radeon.

## What it verifies

The capture run disables sound. It verifies the visible frame and normal exit,
not audio playback or physical Mac focus behaviour. Guest `glReadPixels` remains
tracked in matthewdeaves/qemu#7; host capture avoids that unresolved path.

## Validation

Validated on 2026-09-27 at 1024x768: the capture shows the train approaching the
security guard, followed by command-driven `CL_Shutdown` in the guest log.

## Iterating on the VM

`scripts/pick-bench-host.sh --run qemu-tiger3d <label> -- <script>` wraps
`scripts/deploy-dmg.sh` and `scripts/smoke-dmg.sh` as on any Mac. For
`scripts/shared.sh bench-evidence.sh` the adapter never sets `BENCH_ARTEFACT`
(`make-dmg.sh`'s stage is a trap-removed mktemp dir): mount the current
`dist/*.dmg`, copy out `Half-Life.app/Contents/MacOS/xash3d.bin`, and export
`BENCH_ARTEFACT=<extracted path>` yourself. `scripts/vm-frame-check.sh`
self-claims for the frame capture.
