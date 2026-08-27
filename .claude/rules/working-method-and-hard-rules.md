# Working Method and Hard Rules

## Working method: measure, and refute when it earns it

Work solo by default. Agents are a tool for when they pay, not a ritual.

A **refutation pass** is handing a fresh agent the diff plus the unpatched
upstream file and telling it to **refute** the fix, not approve it. It is worth
doing when a claim is load-bearing and hard to test directly: a mechanism about
endianness, the frame loop, save/restore or `dlopen`, or any "this is why it
broke" that is about to be written down as fact. Three mechanisms were published
as fact and retracted in one session; that is the failure it exists for.

**Do not run one automatically.** Judge whether it earns its cost, and when it
does, say so and ask before running it. A build-script change or a mechanical
port that the compiler and the hardware already check is not a candidate: the
build and the bench boxes are the stronger evidence.

Brief every agent: read-only unless told otherwise, label each claim measured or
inferred. A partial result from a killed agent is a lead, never a finding.

## Hard rules

- **NEVER trust a build's "done" or exit 0.** waf exits 0 on a failed task and
  then installs stale objects. Procedure, cpusubtype stamping and the launcher's
  display profiles: `.claude/rules/build-verification.md`.
- **Payload sits at the `valve/` level**, not the rodir root, or the engine's
  pre-flight check misses it. `.claude/rules/shipped-layout.md`, `docs/adr/0006`
- **We ship code, not content.** No Valve assets, no mod author's content, ever.
- **Never PR or push to upstream repos.** Changes are commits on the `oldmac`
  branch of **our own fork** of each, pinned in `scripts/build-pins.sh`. The only
  patch scripts left are the five applied to each mod's own source tree, which is
  not ours to fork. `docs/adr/0012`
- **Build the release DMG only on a Tiger G4**, never the G3 or Lion, `-format
  UDZO`; md5 every binary, `hdiutil verify` is not enough. `docs/adr/0005`
- Before a release run `python3 tests/test-repo.py` and `tests/test-artifact.sh`.
- **No em dashes anywhere**, prose or shipped strings.
- **Never rate or praise work**, ours or upstream's; attribution is a fact.
- **No Claude co-author** on commits.
