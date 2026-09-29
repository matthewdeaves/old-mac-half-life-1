# Incidents

Search by ticket or date; entries are newest first.
Archive: `docs/archive/`.

## 2026-08-28 A release claim lives in two places
`v1.9.9` went out with a body that correctly listed the microphone fix as withdrawn, and a TITLE that still said "permissions asked up front", because the title was baked into the publish script before the revert. It was public and wrong for about a minute. Correcting one place does not correct the other: when what shipped changes, re-read the title, the notes AND the `--title` argument in whatever script publishes them. The same applies to a release re-cut under an existing version number: the artifacts change, the prose usually does not, and nothing checks that they still agree. See also: a v1.9.22 release note published a literal, unexecuted `$(shasum ...)` command instead of a hash (2026-09-28), caught and fixed post-publish - the drift isn't always title-vs-body, it can be a script whose substitution silently never ran.

## 2026-08-28 A human at the keyboard is a state only a claim label can capture
The user said they were going to play on the dual G5. Three minutes later `old-mac-build-host` rebooted that box into Tiger for a boot-sequencing round, having checked `--status g5-panther` immediately before and correctly read free/0 procs. Their check was working on every signal available to it; the information it lacked was sitting in a different session's chat. No process check can see someone sitting at a console: the lock and the proc-regex both read free, which is exactly what they are supposed to read. Remember the three G5 partitions are one physical machine, so "reboot into another partition" ends whatever is running on the current one. When the user says they are testing on a machine by hand, `--acquire` it for them with a label saying so, and release it when they are done.

## 2026-08-22 Filing puts nothing in a column (2026-08-22, issue #6)
A new board item lands with `Status: null`, in no column at all, which reads as
work nobody raised: nothing on the board sets a status on add. File the issue,
then run `../retro-agents/bin/board-add.sh old-mac-half-life-1#<n>`, which adds
it and sets `Triage` in one step, over REST.
