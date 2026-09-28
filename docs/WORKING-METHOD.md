# Working method: the refutation pass

Work solo by default. A refutation pass hands a fresh agent the diff plus the
unpatched upstream file and asks it to refute the fix, not approve it. This
page says when that earns its cost. One-line hard rules live in `CLAUDE.md`.

## When to run one

Worth it for a load-bearing, hard-to-test claim: endianness, the frame loop,
save/restore, `dlopen`, any "this is why it broke" about to be written down as
fact. Not worth it for a build-script change or a mechanical port that the
compiler and hardware already check: the build and bench boxes are the stronger
evidence there.

## How

- Judge whether it earns its cost, say so, and ask before running one.
- Brief every agent read-only unless told otherwise, and label each claim
  measured or inferred.
- A partial result from a killed agent is a lead, never a finding.
- A symbolized crash frame is cheaper than a pass and comes first
  (`docs/adr/0018`).
- Refuted porting mechanisms: `docs/port/POWERPC-FINDINGS.md`.
