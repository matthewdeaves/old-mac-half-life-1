# Tiger QEMU capture

Builds and shared VM tooling are owned by `old-mac-build-host`.
With the installed Tiger VM running, use:

```sh
scripts/vm-frame-check.sh 150 /tmp/halflife-gameplay.png
```

The helper claims `qemu-tiger3d`, refuses overlapping games, starts `c0a0`,
and captures the host framebuffer after the engine reaches its capture marker.
It keeps the SSH session alive and asks the engine to quit normally. Avoid
killing a fullscreen process on the emulated Radeon.

The capture run disables sound. It verifies the visible frame and normal exit,
not audio playback or physical Mac focus behaviour. Guest `glReadPixels` remains
tracked in matthewdeaves/qemu#7; host capture avoids that unresolved path.

Validated on 2026-09-27 at 1024x768: the capture shows the train approaching the
security guard, followed by command-driven `CL_Shutdown` in the guest log.
