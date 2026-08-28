# Ticketing and Multi-Repo Workflow

## Working alongside the other repos

Seven repos share one board, project 8: the four game ports,
`retro-server-infra`, `old-mac-build-host` and `retro-agents`. The process behind
it, the columns, the labels, the approval gate and the GraphQL budget, lives in
`retro-agents/CLAUDE.md` and in the brief every session is launched with. What follows is only what
is specific to this repo.

**A human at the keyboard is a state only you can put in the lock.** When the
user says they are testing on a machine by hand, `--acquire` it for them with a
label saying so, and release it when they are done. No process check can see
someone sitting at a console: the lock and the proc-regex both read free, which
is exactly what they are supposed to read.

Measured 2026-08-28. The user said they were going to play on the dual G5.
Three minutes later `old-mac-build-host` rebooted that box into Tiger for a
boot-sequencing round, having checked `--status g5-panther` immediately before
and correctly read free/0 procs. Their check was working on every signal
available to it; the information it lacked was sitting in this session's chat.
Remember the three G5 partitions are one physical machine, so "reboot into
another partition" ends whatever is running on the current one.

**Hardware is claimed, never assumed free.** Every script that deploys to,
benches on, or otherwise drives a fleet machine re-execs itself under
`scripts/pick-bench-host.sh --run`, so the machine is claimed for the run and
released however it ends. The lock is a directory on the target, so it is shared
with the build lock and visible to every repo, agent and workstation. Check
`scripts/pick-bench-host.sh --status` before assuming a box is idle, and never
work around a busy one. `BENCH_NO_LOCK=1` exists only for debugging the picker.

**Filing puts nothing in a column.** A new board item lands with `Status: null`,
in no column at all, which reads as work nobody raised. Measured 2026-08-22,
issue #6: nothing on the board sets a status on add. So file the issue, then run

```sh
../retro-agents/bin/board-add.sh old-mac-half-life-1#<n>
```

which adds it and sets `Triage` in one step, over REST.

**Your work stops at `Review`.** That column sits between `Blocked` and `Done`.
Moving anything to `Done`, and closing the issue, is the user's. So never write
`Closes #12` or `Fixes #12` in a commit message: GitHub acts on those and the
issue reads as finished while the column says otherwise. Write `Refs #12`.

**This repo is PUBLIC. `retro-server-infra` is PRIVATE.** It describes the
topology, firewall rules and admin surface of a live host. Never copy addresses,
key material, tunnel tokens or `.env` content out of it into this repo, in code,
docs or a commit message. Referring to a server release tag is fine; describing
where it runs is not.
