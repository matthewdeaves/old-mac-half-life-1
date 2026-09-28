# Ticketing and Multi-Repo Workflow

Board and ticketing mechanics are POLICY's. This file is only what's specific
to this repo; incident detail behind each rule is `docs/INCIDENTS.md`.

- **A human at the keyboard is a state only you can put in the lock.** When the
  user says they're testing on a machine by hand, `--acquire` it with a label
  saying so, and release it when they're done: no process check can see
  someone sitting at a console. The three G5 partitions
  (`g5-panther`/`g5-tiger`/`g5-desktop`, `quad-tiger`/`quad-leopard`) are each
  one physical machine, so rebooting into another partition ends whatever is
  running on the current one.
- **Filing puts nothing in a column** until
  `../retro-agents/bin/board-add.sh old-mac-half-life-1#<n>` runs right after.
- **This repo and `retro-server-infra` are both PUBLIC.** Never copy
  addresses, key material, tunnel tokens or `.env` content from
  `retro-server-infra` into this repo, in code, docs or a commit message.
  Referring to a server release tag is fine; describing where it runs is not.
