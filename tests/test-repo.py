#!/usr/bin/env python3
"""
test-repo.py - invariants that can be checked from the repo alone.

Runs anywhere with a Python 3 and a checkout: no Mac, no build, no hardware.
That is the point. Every check here corresponds to something that actually
shipped wrong at least once.

    python3 tests/test-repo.py            # all checks
    python3 tests/test-repo.py -v         # list every check as it runs

Exit status is the number of failed checks, so CI can use it directly.
"""
import io
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FAILED = []
PASSED = []
VERBOSE = "-v" in sys.argv


def check(name, ok, detail=""):
    if ok:
        PASSED.append(name)
        if VERBOSE:
            print("  ok    %s" % name)
    else:
        FAILED.append((name, detail))
        print("  FAIL  %s" % name)
        for line in str(detail).rstrip().splitlines():
            print("          %s" % line)


def read(rel):
    with io.open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


def tracked_text_files():
    """Text files we control, excluding vendored and generated trees."""
    skip_dirs = {".git", "vendor", "dist", "node_modules", ".venv", "build"}
    exts = {".md", ".sh", ".py", ".m", ".h", ".c", ".txt", ".yml", ".yaml",
            ".plist", ".svg", ".cfg", ".map", ".diff", ".patch"}
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in skip_dirs and not d.startswith(".venv")]
        for fn in files:
            if os.path.splitext(fn)[1] in exts:
                yield os.path.relpath(os.path.join(root, fn), REPO)


# --------------------------------------------------------------- mod tables --

def gamedirs_from_map():
    out = []
    for line in read("installer/mods.map").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line.split()[0])
    return out


def sourced_gamedirs():
    """Mods with an automatable download, from installer/mod-sources.txt."""
    out = []
    for line in read("installer/mod-sources.txt").splitlines():
        line = line.strip()
        if line.startswith("mod ") and not line.startswith("#"):
            out.append(line.split()[1])
    return out


def test_mod_tables_agree():
    """Every mod needs a build, artwork and a description; every mod we FETCH
    also needs a manifest row.

    Xen Warrior shipped in v1.4.0 with the dylibs but with none of the other
    three, so it installed unverified and appeared in Custom Game with no
    preview. Nothing caught that.

    Manifests are the one table that is deliberately incomplete. A manifest row
    is the expected result of unpacking a known archive, so it can only exist for
    a mod we have an archive for. Seven have none: three are Valve retail
    products we will not fetch, and four have no public download in a format any
    Mac tool can open. Those install via Choose... from content the player
    supplies, where there is nothing to compare against. See the bottom of
    installer/mod-sources.txt.
    """
    gd = set(gamedirs_from_map())
    man = set()
    for line in read("installer/manifests.txt").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            man.add(line.split()[0])
    art = {f[:-4] for f in os.listdir(os.path.join(REPO, "installer/artwork"))
           if f.endswith(".tga")}
    des = {f[:-4] for f in os.listdir(os.path.join(REPO, "installer/descriptions"))
           if f.endswith(".txt")}

    for label, have in (("artwork/", art), ("descriptions/", des)):
        missing = sorted(gd - have)
        extra = sorted(have - gd)
        check("every mod in mods.map has %s" % label,
              not missing and not extra,
              "missing: %s\nextra:   %s" % (missing or "none", extra or "none"))

    # Every source must name a real mod, and every fetched mod must have a row.
    src = set(sourced_gamedirs())
    check("every mod-sources.txt entry is a gamedir in mods.map",
          not (src - gd), "not in mods.map: %s" % sorted(src - gd))
    check("every mod with a source has a manifests.txt row",
          not (src - man), "missing: %s" % sorted(src - man))
    check("manifests.txt has no row for a mod with no source",
          not (man - src), "extra: %s" % sorted(man - src))


def test_every_branch_is_pinned():
    """vendor/MANIFEST.md is the reproduction contract.

    sohl1.2 shipped with no recorded pin, so v1.4.0 could not be rebuilt from
    the manifest alone.
    """
    manifest = read("vendor/MANIFEST.md")
    branches = set()
    for line in read("installer/mods.map").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and len(line.split()) >= 2:
            branches.add(line.split()[1])
    unpinned = sorted(b for b in branches
                      if not re.search(r"^%s\s+[0-9a-f]{40}\s*$" % re.escape(b),
                                       manifest, re.M))
    check("every mods.map branch has a 40-char pin in vendor/MANIFEST.md",
          not unpinned, "unpinned: %s" % unpinned)


def test_mod_count_is_consistent():
    """One number, everywhere. v1.4.0 said 24 in the shipped README and help
    text while installing 25."""
    n = len(gamedirs_from_map())
    # The catalogue is 25, but not all of them can be fetched: 18 have a public
    # download this app can unpack, and that number is quoted legitimately in the
    # help text and in code comments. Derived rather than hard-coded so it moves
    # if a source is ever found for one of the other seven.
    sourced = len(sourced_gamedirs())
    stale = []
    pat = re.compile(r"\b(?:all |any of |installs |our )?(\d{2}) (?:Half-Life )?mods?\b")
    for rel in tracked_text_files():
        if rel.startswith("tests/"):
            continue
        try:
            body = read(rel)
        except (IOError, UnicodeDecodeError):
            continue
        for m in pat.finditer(body):
            # 26 is the upstream collection's own count, a different number again.
            if m.group(1) not in (str(n), str(sourced), "26"):
                line = body[:m.start()].count("\n") + 1
                stale.append("%s:%d  %s" % (rel, line, m.group(0)))
    check("no doc or comment claims a mod count other than %d or %d (or upstream's 26)"
          % (n, sourced),
          not stale, "\n".join(stale))


# ------------------------------------------------------------------ slices --

def test_no_ppc970_in_shipped_strings():
    """ppc970 left the build in v1.4.0.

    It survived in the System Report app, which told a G5 owner the app needed
    Leopard only, and in BUILD-INFO.txt's slice line. Both shipped.
    """
    offenders = []
    # Source of user-visible strings, plus the BUILD-INFO generator.
    for rel in ("sysreport/SRController.m", "scripts/build-pins.sh",
                "installer/OMController.m", "installer/OMInstaller.m"):
        body = read(rel)
        for i, line in enumerate(body.splitlines(), 1):
            # A cpusubtype case label is a fact about the CPU, not a claim
            # about a slice we ship, so CPU_SUBTYPE_POWERPC_970 is allowed.
            if "ppc970" in line and "CPU_SUBTYPE" not in line:
                offenders.append("%s:%d  %s" % (rel, i, line.strip()))
    check("no shipped string mentions a ppc970 slice", not offenders,
          "\n".join(offenders))


def test_build_info_slice_line_is_measured():
    """BUILD-INFO.txt must name the slices the binary actually has.

    This used to assert the literal list in build-pins.sh, and that is precisely
    how the line went wrong: it was a hardcoded "ppc750 . ppc7400 . i386 .
    x86_64" that stayed put when arm64 landed, so the one document telling a user
    what the download supports under-reported it, and this test agreed because
    both sides were the same stale literal.

    A declared list of what a binary contains is a second source of truth for
    something the binary already knows. So the template takes the list as a
    parameter now, and what is worth checking is the WIRING: that build-pins.sh
    interpolates it rather than spelling it out, and that make-dmg.sh derives
    what it passes from lipo.
    """
    body = read("scripts/build-pins.sh")
    m = re.search(r"^Fat slices\s*:\s*(.+)$", body, re.M)
    check("build-pins.sh has a Fat slices line", m is not None)
    if m:
        check("the Fat slices line is a parameter, not a hardcoded list",
              "${slices}" in m.group(1),
              "found: %s" % m.group(1).strip())

    dmg = read("scripts/make-dmg.sh")
    check("make-dmg.sh passes a slice list to provenance_table",
          re.search(r"provenance_table[^\n]*\$SLICE_LINE", dmg) is not None)
    # The value must come from the binary, not from a constant somewhere else.
    m2 = re.search(r"^SLICE_LINE=(.+)$", dmg, re.M)
    check("SLICE_LINE is derived from the measured ARCHS", 
          m2 is not None and "$ARCHS" in m2.group(1),
          "found: %s" % (m2.group(1).strip() if m2 else "no SLICE_LINE"))


def test_menu_dictionary_is_shipped_and_sane():
    """The GameUI_* dictionary, and the copy step that ships it.

    mainui's L() returns the key itself when the dictionary has no entry, so a
    missing dictionary does not degrade gracefully: coded tokens are drawn as
    their own names. Retail Half-Life carries no resource/*_english.txt and
    mainui bundles none, so nothing supplies these but us. Shipping the file and
    forgetting the copy step would look identical to never having written it.
    """
    rel = "configs/gameui_english.txt"
    body = read(rel)
    check("%s exists" % rel, bool(body))
    if not body:
        return

    check("dictionary ships via make-universal.sh",
          "gameui_english.txt" in read("scripts/make-universal.sh"),
          "the file exists but nothing copies it into the payload")

    keys = re.findall(r'^"(GameUI_[A-Za-z0-9_]+)"', body, re.M)
    check("dictionary defines tokens", len(keys) > 50,
          "found only %d" % len(keys))

    dupes = sorted(set(k for k in keys if keys.count(k) > 1))
    check("no duplicate token definitions", not dupes, ", ".join(dupes))

    # A stray brace silently truncates the token list at parse time, and the
    # menu then falls back to raw names for everything after it.
    check("braces balance", body.count("{") == body.count("}"),
          "%d open, %d close" % (body.count("{"), body.count("}")))

    # Every value must be non-empty: an empty string renders as nothing at all,
    # which is worse than the raw token it replaced.
    empty = re.findall(r'^"([A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+)"\s+""\s*$', body, re.M)
    check("no token maps to an empty string", not empty, ", ".join(empty))

    # The check that matters, when the trees are here to check against. The
    # first version of this test only counted entries, and shipped a dictionary
    # missing all nine Valve_* tokens: those are used by the PowerPC menu fork
    # alone, and are written "#Valve_Orange" at the call site, so a search for
    # GameUI_ found nothing and a count of 81 looked complete.
    have = set(re.findall(r'^"([A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+)"', body, re.M))
    # One tree now: every slice builds the menu from the same branch of our fork.
    trees = [d for d in ("vendor/xash3d-fwgs/3rdparty/mainui",)
             if os.path.isdir(os.path.join(REPO, d))]
    if not trees:
        if VERBOSE:
            print("          (vendor trees absent, skipping token cross-check)")
        return

    used = set()
    for tree in trees:
        for root, _dirs, files in os.walk(os.path.join(REPO, tree)):
            for fn in files:
                if not fn.endswith((".cpp", ".h")):
                    continue
                src = open(os.path.join(root, fn)).read()
                # L() strips a leading #, so "#Valve_Orange" looks up Valve_Orange.
                for tok in re.findall(r'"#?((?:GameUI|Valve|Cstrike)_[A-Za-z0-9_]+)"', src):
                    used.add(tok)

    missing = sorted(used - have)
    check("dictionary covers every token the menus ask for", not missing,
          "missing %d: %s" % (len(missing), ", ".join(missing[:12])))
    dead = sorted(have - used)
    check("dictionary has no unused tokens", not dead,
          "unused: %s" % ", ".join(dead[:12]))


# ----------------------------------------------------------- shell parsing --
#
# The wiring tests below used to ask whether a script's name appeared anywhere
# in a driver's text. That is not the question. patch-mainui-miniutl-endian.py
# passed for a while on the strength of a COMMENT in a driver that said, in
# so many words, that the driver does not run it. A mention is not a call, and
# the whole point of these tests is that an unrun patch ships as a missing fix
# on one machine, with no build error anywhere.
#
# Dropping the comment is the whole of the fix. This was a quote-aware shell
# tokenizer for a while: heredoc tracking, word splitting, an interpreter in
# command position. An adversarial review measured it against the two-line
# version below across all 48 patch scripts times all 26 shell scripts, on HEAD
# and on the tree before the tokenizer landed, and found ZERO disagreements. The
# shapes it existed to reject, a name in a heredoc body or inside an echo
# string, do not occur in scripts/ at all. The shape it would catch that this
# misses, a patch name in a TRAILING comment on a line that is not itself the
# real invocation, also does not occur: all 28 lines in scripts/*.sh that put a
# patch name near a `#` are either whole-line comments or trailing comments on
# the real invocation.
#
# So this is deliberately naive. If a driver ever grows a heredoc that mentions
# a patch script, this will report it as wired when it is not, and the fix is to
# not write that rather than to bring the tokenizer back.


def shell_commands(body):
    """The lines of a shell script that are not whole-line comments."""
    return [ln for ln in body.split("\n") if not ln.lstrip().startswith("#")]


def invocation_line(commands, name):
    """Index of the first non-comment line naming `name`, or -1."""
    for i, line in enumerate(commands):
        if name in line:
            return i
    return -1


def patch_scripts(prefix="patch-"):
    return sorted(f for f in os.listdir(os.path.join(REPO, "scripts"))
                  if f.startswith(prefix) and f.endswith(".py"))


def shell_scripts():
    return sorted(f for f in os.listdir(os.path.join(REPO, "scripts"))
                  if f.endswith(".sh"))


# --------------------------------------------------------------- the pins --
#
# These used to be wiring tests: every scripts/patch-*.py had to be invoked by
# every driver that built a tree it touched. That mechanism is gone. The port is
# carried as commits on our own branch of each upstream, and the build checks out
# a pin and compiles it, so there is no per-driver list left to drift.
#
# The failure they guarded against has not gone away, it has moved. It used to be
# "a fix is wired into three drivers out of four, so one machine silently ships
# without it". It is now "a driver builds a tree that is not at its pin", which is
# the same fault with a different shape: a build that looks fine and contains
# something other than what the pins say. So the tests follow it.

def test_invocation_matcher_rejects_a_mention():
    """The wiring tests are only worth their runtime if a mention fails them.

    This is the exact shape that got through before: the name is there, the
    interpreter is there, and the line is a comment saying the driver does not
    run it. The matcher is a substring test on non-comment lines, so a comment
    is the only shape it rejects, and it is the only shape that has ever
    occurred in scripts/. See the note above shell_commands.
    """
    fake = "\n".join([
        "#!/bin/bash",
        '#   -> scripts/patch-x.py, run by the other two drivers; not here.',
        'python "$ROOT/scripts/patch-real.py" \\',
        '\t"$ENGINE/3rdparty/mainui"',
    ])
    cmds = shell_commands(fake)
    for name, want in (("patch-x.py", False), ("patch-real.py", True)):
        got = invocation_line(cmds, name) >= 0
        check("invocation matcher: %s is %s" % (name, "a call" if want else "not a call"),
              got == want, "matcher said %s" % got)


PIN_FILE = "scripts/build-pins.sh"

# The drivers that compile something we ship.
BUILD_DRIVERS = ("scripts/build-lion.sh", "scripts/build-ppc-panther.sh",
                 "scripts/build-ppc-tiger.sh")


def test_every_pin_is_a_full_commit():
    """A pin has to be a full 40-character commit, not a branch or a tag.

    A branch name would make the build a function of when it ran rather than of
    what it was told to build, which is the whole property the pins exist for.
    An abbreviated sha would be worse than useless in a shipped BUILD-INFO: it
    is what a person reads to find out what a release was made from.
    """
    body = read(PIN_FILE)
    pins = re.findall(r'^(PIN_[A-Z0-9_]*_COMMIT)="([^"]*)"', body, re.M)
    check("build-pins.sh declares pins", bool(pins))

    bad = ["%s=%s" % (k, v) for k, v in pins
           if not re.match(r'^[0-9a-f]{40}$', v)]
    check("every pin is a 40-character commit", not bad, "\n".join(bad))


def test_every_pin_has_a_url_and_a_branch():
    """Each pinned component names where it came from, so provenance is complete.

    BUILD-INFO in a shipped app prints this table. A pin with no URL beside it
    reduces that to a bare sha, which nobody can resolve to anything.
    """
    body = read(PIN_FILE)
    missing = []
    for key in re.findall(r'^PIN_([A-Z0-9_]*)_COMMIT="', body, re.M):
        for suffix in ("URL", "BRANCH"):
            if not re.search(r'^PIN_%s_%s="[^"]+"' % (key, suffix), body, re.M):
                missing.append("PIN_%s_%s" % (key, suffix))
    check("every pin has a URL and a branch", not missing, ", ".join(missing))


def test_drivers_refuse_a_tree_that_is_not_at_its_pin():
    """The pre-flight is the only thing standing between us and a stale build.

    This is not hypothetical. A driver did once compile a tree that had been left
    at the wrong commit, the link succeeded, the timestamps looked fresh, and the
    slices shipped code that was not in the source tree. Every check in place at
    the time passed, because they all looked at the output.

    Each driver must therefore read the pins and compare them against what is
    actually checked out. Asserted on the pin variables being read at all: a
    driver that never sources build-pins.sh cannot be checking anything.
    """
    # On NON-COMMENT lines only. A plain `"build-pins.sh" in body` passed off the
    # header comment alone: every driver names the file in its own preamble and in
    # the echo strings inside check_pin, so the entire pre-flight could be deleted
    # and this stayed green. That is the exact failure the note above
    # shell_commands exists to record, reintroduced in the test written to replace
    # the tests that had it.
    missing = []
    for driver in BUILD_DRIVERS:
        cmds = shell_commands(read(driver))
        text = "\n".join(cmds)
        if not re.search(r'^\s*(?:\.|source)\s+\S*build-pins\.sh', text, re.M):
            missing.append("%s never sources %s" % (driver, PIN_FILE))
            continue
        if "PIN_ENGINE_COMMIT" not in text:
            missing.append("%s sources the pins but never compares PIN_ENGINE_COMMIT" % driver)
        if "exit 1" not in text:
            missing.append("%s checks a pin but never exits non-zero" % driver)
    check("every build driver reads the pins and refuses a mismatch",
          not missing, "\n".join(missing))


def test_no_script_calls_a_helper_that_is_gone():
    """Deleting a retired script must not leave a driver calling it.

    Forty-five went when the port moved onto our own branches. This is not a
    style check: build-mod.sh was left invoking scripts/graft-ppc-endian.sh after
    it was deleted, which would have failed every mod build at the first branch.
    The earlier version of this test looked only for patch-*.py and so did not
    see it, which is why it now covers every script in scripts/ regardless of
    extension.

    Only real invocations count, not mentions: a comment explaining why something
    was removed is exactly the thing worth writing.
    """
    present = set(os.listdir(os.path.join(REPO, "scripts")))
    dangling = []
    for sh in shell_scripts():
        body = read(os.path.join("scripts", sh))
        cmds = shell_commands(body)
        # Anchored on "scripts/NAME", with no further path component allowed
        # between them. Without that anchor this matched
        # "$tree_p/scripts/waifulib/xcompile.py", which is a path INTO a mod's
        # own source tree passed as an argument, not a script of ours.
        for name in set(re.findall(r'scripts/([a-z0-9][a-z0-9._-]*\.(?:py|sh))\b', body)):
            if name in present or name == sh:
                continue
            if invocation_line(cmds, name) >= 0:
                dangling.append("scripts/%s invokes %s, which does not exist" % (sh, name))
    check("no script invokes a helper that has been deleted", not dangling,
          "\n".join(dangling))


def test_surviving_patch_scripts_are_still_wired():
    """The few patch scripts left over patch trees that are not ours to fork.

    Every survivor is applied to the separate source tree of each mod we build.
    There is no single repository for those to be commits in, so they stay
    scripts, and the original rule still applies to them: a patch script nobody
    runs is a fix that never shipped.
    """
    names = patch_scripts()
    check("there are surviving patch scripts to check", bool(names))

    invokers = {}
    for sh in shell_scripts():
        invokers[sh] = shell_commands(read(os.path.join("scripts", sh)))

    orphans = [n for n in names
               if not any(invocation_line(c, n) >= 0 for c in invokers.values())]
    check("every surviving scripts/patch-*.py is invoked by some scripts/*.sh",
          not orphans, "invoked by nothing: %s" % ", ".join(orphans))


# ------------------------------------------------------------------- style --

def test_no_em_dashes():
    """Em dashes are not used in this project, in prose or in shipped strings.

    Shipped strings additionally need to stay greppable with `strings`.
    """
    hits = []
    for rel in tracked_text_files():
        if rel.startswith("tests/"):
            continue
        try:
            body = read(rel)
        except (IOError, UnicodeDecodeError):
            continue
        for i, line in enumerate(body.splitlines(), 1):
            if "—" in line or "–" in line:
                hits.append("%s:%d  %s" % (rel, i, line.strip()[:90]))
    check("no em dash or en dash in tracked text", not hits, "\n".join(hits))


def test_no_stray_tool_markup():
    """A tool-call fragment once got written into CLAUDE.md and committed."""
    hits = []
    # Anchored to whole lines: these fragments only ever appear alone, and a
    # loose substring match would flag every C generic and every SVG tag.
    frag = re.compile(r"^\s*</?(?:content|invoke|function_calls|parameter)\b[^\n]*>\s*$")
    for rel in tracked_text_files():
        if rel.startswith("tests/"):
            continue
        try:
            body = read(rel)
        except (IOError, UnicodeDecodeError):
            continue
        for i, line in enumerate(body.splitlines(), 1):
            if frag.match(line):
                hits.append("%s:%d  %s" % (rel, i, line.strip()[:90]))
    check("no stray tool markup in tracked files", not hits, "\n".join(hits))


def test_issue_templates_reference_real_labels():
    """An issue form naming a label that does not exist silently drops it."""
    tdir = os.path.join(REPO, ".github/ISSUE_TEMPLATE")
    if not os.path.isdir(tdir):
        return
    declared = set()
    for fn in os.listdir(tdir):
        if not fn.endswith(".yml") or fn == "config.yml":
            continue
        for m in re.finditer(r'^labels:\s*\[(.+)\]\s*$',
                             read(".github/ISSUE_TEMPLATE/" + fn), re.M):
            for part in m.group(1).split(","):
                declared.add(part.strip().strip('"').strip("'"))
    # `bool(declared) or True` was the previous assertion, which cannot fail under
    # any input. If a template declares a label, say which; if the directory has
    # templates but none declares one, that is worth knowing, because a label named
    # in a form that does not exist is silently dropped by GitHub.
    forms = [f for f in os.listdir(tdir) if f.endswith(".yml") and f != "config.yml"]
    check("there are issue forms to check", bool(forms))
    check("issue forms declare labels", bool(declared),
          "no labels declared by any of: %s" % ", ".join(sorted(forms)))
    if VERBOSE and declared:
        print("          labels used: %s" % ", ".join(sorted(declared)))


# -------------------------------------------------------------------- main --


def test_driver_manifest_is_current():
    """scripts/driver-manifest.md5 must match the drivers it lists.

    build-all.sh refuses to run on a build host whose drivers do not match this
    manifest, which is how a mini that has silently drifted from the repo is
    caught. That protection is only worth anything if the manifest itself is
    current, so editing a driver without running

        scripts/build-all.sh --update-manifest

    has to fail here rather than on a build box at midnight.
    """
    import hashlib
    man = os.path.join(REPO, "scripts", "driver-manifest.md5")
    if not os.path.exists(man):
        check("driver manifest exists", False,
              "scripts/driver-manifest.md5 is missing")
        return
    bad = []
    listed = []
    with io.open(man, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            sum_, name = line.split(None, 1)
            listed.append(name)
            path = os.path.join(REPO, "scripts", name)
            if not os.path.exists(path):
                bad.append("%s: listed but missing" % name)
                continue
            with open(path, "rb") as fh:
                have = hashlib.md5(fh.read()).hexdigest()
            if have != sum_:
                bad.append("%s: manifest %s, file %s" % (name, sum_[:8], have[:8]))
    check("driver manifest matches the drivers it lists",
          not bad,
          "; ".join(bad) + "  (run scripts/build-all.sh --update-manifest)")


def test_every_repo_path_a_driver_reads_is_synced():
    """Anything a build driver reads out of the repo must be in the sync list.

    The drivers run ON a build mini, against a hand-managed ~/oldmac that nothing
    pulls. scripts/sync-build-host.sh is the only thing that puts this repo's
    files there, so a path a driver reads that is NOT in its FILES or DIRS list
    is read from whatever happens to be on that host, silently, and the build
    still says ok.

    That is not theoretical. compat-include/ was added to build-lion.sh and the
    build would have used a stale copy; configs/userconfig.cfg and
    configs/gameui_english.txt are copied into the shipped app by
    make-universal.sh and were never in the list at all; and the header of
    sync-build-host.sh already records a deployed Mods.app that carried an About
    picture weeks older than the repo's for exactly this reason.

    dist/, vendor/ and sdl2-* are excluded: those are build OUTPUT or vendored
    source, and are deliberately not synced.
    """
    sync = os.path.join(REPO, "scripts", "sync-build-host.sh")
    if not os.path.exists(sync):
        check("sync-build-host.sh exists", False, "missing")
        return
    with io.open(sync, encoding="utf-8") as f:
        sync_src = f.read()

    # The two here-doc style lists: FILES="..." and DIRS="..."
    covered = []
    for var in ("FILES", "DIRS"):
        m = re.search(r'^%s="(.*?)"' % var, sync_src, re.S | re.M)
        if m:
            covered += [ln.strip() for ln in m.group(1).splitlines() if ln.strip()]

    # build-installer.sh and build-sysreport.sh count too. build-all.sh runs
    # them now, but for a while nothing did, which is exactly why their sources
    # went unsynced for so long without anything showing: the Mods app and the
    # System Report app were being compiled on the build host from whatever was
    # there.
    drivers = ["build-lion.sh", "build-ppc-tiger.sh", "build-ppc-panther.sh",
               "make-universal.sh", "make-app.sh",
               "build-installer.sh", "build-sysreport.sh", "build-mod.sh"]
    skip = ("dist/", "dist-ppc", "vendor/", "sdl2-")
    wanted = set()
    for d in drivers:
        p = os.path.join(REPO, "scripts", d)
        if not os.path.exists(p):
            continue
        with io.open(p, encoding="utf-8") as f:
            for ref in re.findall(r'\$ROOT/([A-Za-z0-9_./-]+)', f.read()):
                ref = ref.rstrip('./')
                if not ref or ref.startswith(skip):
                    continue
                # Only care about paths that really exist in the repo.
                if os.path.exists(os.path.join(REPO, ref)):
                    wanted.add(ref)

    missing = []
    for ref in sorted(wanted):
        ok = any(c == ref or c.startswith(ref + "/") or ref.startswith(c + "/")
                 for c in covered)
        if not ok:
            missing.append(ref)

    check("every repo path a driver reads is in the sync list",
          not missing,
          "not synced to build hosts: %s  (add to FILES or DIRS in "
          "scripts/sync-build-host.sh)" % ", ".join(missing))


def main():
    print("repo invariants (%s)" % REPO)
    for fn in (test_mod_tables_agree,
               test_every_branch_is_pinned,
               test_mod_count_is_consistent,
               test_no_ppc970_in_shipped_strings,
               test_build_info_slice_line_is_measured,
               test_menu_dictionary_is_shipped_and_sane,
               test_invocation_matcher_rejects_a_mention,
               test_every_pin_is_a_full_commit,
               test_every_pin_has_a_url_and_a_branch,
               test_drivers_refuse_a_tree_that_is_not_at_its_pin,
               test_no_script_calls_a_helper_that_is_gone,
               test_surviving_patch_scripts_are_still_wired,
               test_driver_manifest_is_current,
               test_every_repo_path_a_driver_reads_is_synced,
               test_no_em_dashes,
               test_no_stray_tool_markup,
               test_issue_templates_reference_real_labels):
        fn()
    print("\n%d passed, %d failed" % (len(PASSED), len(FAILED)))
    return len(FAILED)


if __name__ == "__main__":
    sys.exit(main())
