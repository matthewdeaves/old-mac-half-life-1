#!/usr/bin/env python3
"""
make-icon.py - end-to-end Mac OS icon pipeline for the Half-Life old-Mac port.

Takes a source PNG (any background - solid white, solid black, or already
transparent) and produces a Mac OS .icns file that renders correctly on
**every** target in our bench fleet:

  yosemite     10.3.9 Panther     PPC G3 (Rage 128)
  quicksilver  10.4.11 Tiger      PPC G4 (Radeon 9000)
  mini-g4      10.4.11 Tiger      PPC G4 (Radeon 9200)
  imac-g5      10.5.8 Leopard     PPC G5 (Radeon 9600)
  mini-intel   10.7.5 Lion        x86_64 (GMA 950)
  imac-2019    15.7   Sequoia     x86_64 (Radeon Pro 580X)

Pipeline:

  1. Background removal (optional, default auto-detected from corner pixels).
     Edge-flood-fill so interior pixels matching the bg colour are not
     punched transparent. Soft alpha ramp at the edge for AA.

  2. ICNS assembly. Legacy chunks always, plus `ic08` when --modern is passed.
     No `TOC` ever.

     Panther 10.3 is the constraint. Measured on the G3 on 2026-07-26, five
     otherwise-identical test bundles differing only in their .icns:

       legacy only                  -> icon renders
       legacy + ic08 (256)          -> icon renders
       legacy + ic08 + ic09         -> GENERIC icon
       legacy + ic09 (512) alone    -> GENERIC icon
       legacy + ic08 + ic09 + ic10  -> GENERIC icon

     So 256 is free and anything above it is not. Whether Panther is rejecting
     the ic09 FourCC specifically or refusing a file over some size was not
     separated: the ic09-only file was 431 KB against 160 KB for the ic08 one,
     so both explanations fit. It does not matter in practice, because no
     512px PNG of this artwork compresses anywhere near 160 KB.

     Result: 10.5+ gets a native 256×256 instead of upscaling the 128×128
     it32, and Panther keeps its icon. Above 256, Lion and later still upscale.

     Why not `iconutil`? It unconditionally emits TOC + modern chunks, and
     doesn't produce 1-bit ICN#/ics# (Panther) chunks at all.

  3. README hero-strip thumbnail refresh (--readme-refresh, default ON):
     write 256×256 and 1024×1024 Lanczos resamples of the source into
     docs/images/halflife-icon-256.png and halflife-icon.png. The README
     references these directly if they exist. Disable with
     --no-readme-refresh if you only want the .icns regenerated.

Usage:
  scripts/make-icon.py [SOURCE] [-o OUTPUT] [--bg COLOUR] [--preview PATH]
                              [--keep-bg] [--hard N] [--soft N]
                              [--no-readme-refresh]

Examples:
  # Already-transparent PNG (e.g. hand-cleaned in Photoshop), just build the ICNS.
  scripts/make-icon.py MacOSX/icon-source-lrz.png --keep-bg -o MacOSX/Half-Life.icns

  # Custom thresholds (white bg with weaker AA fringe).
  scripts/make-icon.py source.png --bg white --hard 245 --soft 220

Pre-reqs: Pillow, numpy, scipy. The repo's .venv has them.
"""

import argparse
import io
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


# -----------------------------------------------------------------------------
# Stage 1 - background removal (edge-flood-fill + soft AA ramp)
# -----------------------------------------------------------------------------

def autodetect_bg(rgba: np.ndarray) -> str:
    """Look at the four corners. If they're all near-white return 'white',
    near-black 'black', otherwise raise - we can't guess."""
    h, w = rgba.shape[:2]
    corners = rgba[[0, 0, -1, -1], [0, -1, 0, -1], :3]
    brightness = corners.mean(axis=1)
    if (brightness >= 240).all():
        return "white"
    if (brightness <= 16).all():
        return "black"
    raise SystemExit(
        f"make-icon: cannot auto-detect background. Corner brightness = {brightness}. "
        "Pass --bg white|black|transparent explicitly."
    )


def remove_background(rgba: np.ndarray, bg: str, hard: int, soft: int,
                      scrub_interior: int = 0, fill_holes: bool = False,
                      top_seed: bool = False) -> np.ndarray:
    """Return a new RGBA array with bg pixels' alpha set to 0 (or feathered)
    and (mostly) interior pixels preserved.

    Algorithm:
      score = whiteness or darkness (0..255, high = more bg-like)
      hard_mask  = score >= hard
      soft_mask  = score >= soft  (includes AA edge band)
      labelled   = connected components of soft_mask
      bg_region  = labels that touch the image edge
      alpha      = 255 by default
                 = linear ramp in [soft, hard] for pixels in bg_region

    The "edge-touching only" filter usually protects legit interior near-bg
    pixels (specular highlights, internal logo whitespace). The `scrub_interior`
    knob defaults OFF - the canonical workflow is "rough auto + Photoshop
    touch-up", not algorithmic perfection (see `docs/ICONS.md`)."""
    rgb = rgba[:, :, :3]
    if bg == "white":
        score = rgb.min(axis=2)
    else:  # black
        score = 255 - rgb.max(axis=2)

    hard_mask = score >= hard
    soft_mask = score >= soft
    labelled, n_labels = ndimage.label(soft_mask)

    h_, w_ = labelled.shape
    edge_labels = set()
    edge_labels.update(np.unique(labelled[0, :]))            # top edge always
    if top_seed:
        # Portrait/bust: the subject fills the bottom and sides of the frame, so
        # seed background ONLY from the top and the UPPER part of the side edges.
        # Never the bottom, or a dark subject (e.g. black shoulders) that touches
        # the frame gets flood-filled away. Pair with --fill-holes.
        band = int(h_ * 0.40)
        edge_labels.update(np.unique(labelled[:band, 0]))
        edge_labels.update(np.unique(labelled[:band, -1]))
    else:
        edge_labels.update(np.unique(labelled[-1, :]))
        edge_labels.update(np.unique(labelled[:, 0]))
        edge_labels.update(np.unique(labelled[:, -1]))
    edge_labels.discard(0)
    bg_region = np.isin(labelled, list(edge_labels))

    scrubbed_pockets = 0
    scrubbed_pixels = 0
    if scrub_interior > 0:
        # Find interior pure-bg pockets. Two-stage strict-then-soft so
        # saturated specular highlights (score 240-250 but surrounded by
        # bright pixels) don't get scrubbed alongside true bg-bleed pockets
        # (surrounded by dark icon body).
        purity_threshold = min(254, hard + 3)
        strict_mask = score >= purity_threshold
        strict_labelled, n_strict = ndimage.label(strict_mask)

        strict_edge = set()
        strict_edge.update(np.unique(strict_labelled[0, :]))
        strict_edge.update(np.unique(strict_labelled[-1, :]))
        strict_edge.update(np.unique(strict_labelled[:, 0]))
        strict_edge.update(np.unique(strict_labelled[:, -1]))
        strict_edge.discard(0)
        interior_strict = np.setdiff1d(np.arange(1, n_strict + 1),
                                       np.array(list(strict_edge)))
        if interior_strict.size > 0:
            sizes = ndimage.sum(strict_mask, strict_labelled, index=interior_strict)
            size_pass = interior_strict[sizes >= scrub_interior]
            real_bg = []
            for lbl in size_pass:
                pocket = (strict_labelled == lbl)
                annulus = ndimage.binary_dilation(pocket, iterations=5) & ~pocket
                if annulus.sum() == 0:
                    continue
                if score[annulus].mean() < 150:
                    real_bg.append(lbl)
            if real_bg:
                real_bg = np.array(real_bg)
                chunky_seed = np.isin(strict_labelled, real_bg)
                chunky_dilated = ndimage.binary_dilation(chunky_seed, iterations=2)
                chunky_expanded = chunky_dilated & soft_mask
                bg_region = bg_region | chunky_expanded
                scrubbed_pockets = int(real_bg.size)
                scrubbed_pixels = int(chunky_expanded.sum())

    if fill_holes:
        # Reclaim any bg-classified region fully ENCLOSED by foreground - e.g.
        # near-black suit detail on a black background. Fill holes in the
        # foreground mask; only what stays outside it counts as background. This
        # is what lets the black-bg LRZ source cut out with Gordon's black suit
        # intact (pair with a TIGHT threshold so only ~pure-black is bg).
        fg_filled = ndimage.binary_fill_holes(~bg_region)
        bg_region = bg_region & ~fg_filled

    alpha = np.full_like(score, 255, dtype=np.uint8)
    in_bg = bg_region & soft_mask
    span = max(hard - soft, 1)
    ramp = 255 - np.clip(
        ((score[in_bg].astype(np.int32) - soft) * 255) // span,
        0, 255,
    ).astype(np.uint8)
    alpha[in_bg] = ramp

    out = rgba.copy()
    out[:, :, 3] = alpha

    stats = {
        "bg_pixels": int(bg_region.sum()),
        "transparent": int((alpha == 0).sum()),
        "feathered": int(((alpha > 0) & (alpha < 255)).sum()),
        "opaque": int((alpha == 255).sum()),
        "components": int(n_labels),
        "edge_labels": len(edge_labels),
        "scrubbed_pockets": scrubbed_pockets,
        "scrubbed_pixels": scrubbed_pixels,
    }
    return out, stats


def magenta_preview(rgba: np.ndarray) -> Image.Image:
    """Composite the transparent RGBA over a magenta background - makes
    alpha bleed and bg-removal mistakes obvious to the eye."""
    a = rgba[:, :, 3].astype(np.float32) / 255.0
    magenta = np.array([255, 0, 255], dtype=np.float32)
    composed = (
        rgba[:, :, :3].astype(np.float32) * a[..., None]
        + magenta * (1 - a[..., None])
    ).astype(np.uint8)
    return Image.fromarray(composed, "RGB")


# -----------------------------------------------------------------------------
# Stage 2 - ICNS assembly (legacy-only chunks)
# -----------------------------------------------------------------------------

def split_rgba(img: Image.Image) -> tuple[bytes, bytes, bytes, bytes]:
    """Return raw R, G, B, A channel bytes - faster + non-deprecated alternative
    to per-pixel iteration via getdata()."""
    r, g, b, a = img.split()
    return r.tobytes(), g.tobytes(), b.tobytes(), a.tobytes()


def rle_channel(data: bytes) -> bytes:
    """Apple ICNS legacy chunk RLE encoding.

      - Run of 3+ same bytes: 1 token byte (run_length + 125), 1 data byte. Run cap = 130.
      - Literal run:          1 token byte (length - 1),         N data bytes. Lit cap = 128.
    """
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        run = 1
        while i + run < n and data[i + run] == data[i] and run < 130:
            run += 1
        if run >= 3:
            out.append(run + 125)
            out.append(data[i])
            i += run
        else:
            ls = i
            while i < n:
                if i + 2 < n and data[i] == data[i + 1] == data[i + 2]:
                    break
                i += 1
                if i - ls >= 128:
                    break
            ll = i - ls
            out.append(ll - 1)
            out.extend(data[ls:ls + ll])
    return bytes(out)


def rgb_payload(img: Image.Image, size: int, with_it32_header: bool) -> bytes:
    """RGB chunk payload: three RLE'd channels concatenated.
    it32 (128x128) prefixes a 4-byte zero header; smaller sizes don't."""
    resized = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    r, g, b, _ = split_rgba(resized)
    payload = rle_channel(r) + rle_channel(g) + rle_channel(b)
    return (b"\x00\x00\x00\x00" + payload) if with_it32_header else payload


def mask_payload(img: Image.Image, size: int) -> bytes:
    """8-bit alpha mask payload: raw, uncompressed, 1 byte per pixel."""
    resized = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    _, _, _, a = split_rgba(resized)
    return a


def bw_pair(img: Image.Image, size: int) -> tuple[bytes, bytes]:
    """1-bit B&W bitmap + 1-bit mask (ICN# = 32×32, ics# = 16×16). The
    original Classic Mac OS icon format. Panther's Finder uses these as
    fallback when other chunks fail to parse.

    Bit packing: MSB-first, 8 pixels per byte. White = 0, black = 1.
    Mask bit = 1 where alpha > 16 (i.e. pixel is visible)."""
    resized = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    r, g, b, a = split_rgba(resized)
    bits = bytearray()
    mask = bytearray()
    bb = mb = nb = 0
    for i in range(len(a)):
        gray = (r[i] * 299 + g[i] * 587 + b[i] * 114) // 1000
        if a[i] > 16:
            bb = (bb << 1) | (1 if gray < 128 else 0)
            mb = (mb << 1) | 1
        else:
            bb = (bb << 1)
            mb = (mb << 1)
        nb += 1
        if nb == 8:
            bits.append(bb & 0xFF)
            mask.append(mb & 0xFF)
            bb = mb = nb = 0
    return bytes(bits), bytes(mask)


def chunk(fcc: bytes, payload: bytes) -> bytes:
    """One ICNS chunk = 4-byte FourCC + 4-byte big-endian total length + payload."""
    return fcc + struct.pack(">I", 8 + len(payload)) + payload


# The only modern chunk Panther will tolerate. See the module docstring for the
# hardware test that established this, and why ic09/ic10 are not here.
MODERN_CHUNKS = ((b"ic08", 256),)


def png_chunk(fcc: bytes, img: Image.Image, size: int) -> bytes:
    """A modern PNG-payload chunk (ic08/ic09/ic10), used by 10.5 and later."""
    buf = io.BytesIO()
    img.resize((size, size), Image.LANCZOS).save(buf, format="PNG", optimize=True)
    return chunk(fcc, buf.getvalue())


def build_icns(img: Image.Image, modern: bool = False) -> bytes:
    """Assemble the ICNS byte stream.

    The legacy chunks are always written and always first: they are the only
    ones Panther understands. `modern` appends the PNG-payload chunks that
    10.5+ uses for 256px and above, so Lion stops upscaling the 128px it32.

    No `TOC` chunk is written either way. A reader that does not know a FourCC
    can skip it using the per-chunk length, which is how the legacy-only file
    stays readable on Panther; a TOC is what actually trips old parsers up.
    """
    ib32, im32 = bw_pair(img, 32)
    ib16, im16 = bw_pair(img, 16)

    body = b""
    body += chunk(b"ICN#", ib32 + im32)
    body += chunk(b"ics#", ib16 + im16)
    body += chunk(b"is32", rgb_payload(img, 16, False))
    body += chunk(b"s8mk", mask_payload(img, 16))
    body += chunk(b"il32", rgb_payload(img, 32, False))
    body += chunk(b"l8mk", mask_payload(img, 32))
    body += chunk(b"ih32", rgb_payload(img, 48, False))
    body += chunk(b"h8mk", mask_payload(img, 48))
    body += chunk(b"it32", rgb_payload(img, 128, True))
    body += chunk(b"t8mk", mask_payload(img, 128))

    if modern:
        body += png_chunk(b"ic08", img, 256)

    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def append_modern(existing: bytes, img: Image.Image) -> bytes:
    """Add ic08/ic09/ic10 to an existing ICNS, leaving every current chunk alone.

    Skips any of the three that is already present, so this is idempotent.
    """
    assert existing[:4] == b"icns", "not an ICNS file"
    present, i = set(), 8
    while i < len(existing):
        fcc = existing[i:i + 4]
        n = struct.unpack(">I", existing[i + 4:i + 8])[0]
        if n < 8:
            raise ValueError("corrupt ICNS chunk length at offset %d" % i)
        present.add(fcc)
        i += n

    body = existing[8:]
    for fcc, size in MODERN_CHUNKS:
        if fcc in present:
            print("    %s already present, left as is" % fcc.decode())
            continue
        body += png_chunk(fcc, img, size)

    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def describe_icns(data: bytes) -> None:
    """Print chunk breakdown for verification."""
    total = struct.unpack(">I", data[4:8])[0]
    print(f"  ICNS total: {total:,} bytes")
    off = 8
    while off < total:
        fcc = data[off:off + 4].decode("ascii", errors="replace")
        sz = struct.unpack(">I", data[off + 4:off + 8])[0]
        print(f"    {fcc!r:<8s} {sz:>7,} bytes")
        off += sz


# -----------------------------------------------------------------------------
# Stage 3 - README hero-strip thumbnail refresh
# -----------------------------------------------------------------------------

def refresh_readme_thumbs(img: Image.Image, docs_dir: Path) -> None:
    """Write 256×256 and 1024×1024 Lanczos resamples to docs/images/. These
    are the PNGs that README.md references directly."""
    img.resize((256, 256), Image.LANCZOS).save(
        docs_dir / "halflife-icon-256.png", optimize=True)
    img.resize((1024, 1024), Image.LANCZOS).save(
        docs_dir / "halflife-icon.png", optimize=True)
    print(f"  refreshed README thumbs: {docs_dir}/halflife-icon-256.png + halflife-icon.png")


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__.strip(),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("source", type=Path, nargs="?", default=None,
                   help="source PNG (any bg). Required - there is deliberately no "
                        "default, so a bare invocation can't silently overwrite the "
                        "shipped icon with the wrong artwork. See docs/ICONS.md.")
    p.add_argument("-o", "--output", type=Path, default=None,
                   help="output .icns path (default: MacOSX/Half-Life.icns under repo root)")
    p.add_argument("--base", type=Path,
                   help="existing .icns whose chunks are kept verbatim; only the "
                        "modern PNG chunks are appended (implies --modern)")
    p.add_argument("--modern", action="store_true",
                   help="also emit the ic08 (256px) PNG chunk for 10.5+; larger "
                        "chunks are deliberately not offered, see the module docstring")
    p.add_argument("--bg", choices=["auto", "white", "black", "transparent"], default="auto",
                   help="background colour to strip (default: auto-detect from corners). "
                        "'transparent' = source already has an alpha channel, skip removal.")
    p.add_argument("--keep-bg", action="store_true",
                   help="alias for --bg transparent")
    p.add_argument("--hard", type=int, default=250,
                   help="hard threshold - pixels this 'pure' or more → alpha=0 (default 250)")
    p.add_argument("--soft", type=int, default=200,
                   help="soft threshold - start of anti-alias ramp (default 200)")
    p.add_argument("--top-seed", action="store_true",
                   help="seed background removal from the top + upper side edges "
                        "only, never the bottom (for a portrait/bust whose dark "
                        "subject touches the bottom/side frame, e.g. Gordon's "
                        "shoulders). Pair with --fill-holes.")
    p.add_argument("--fill-holes", action="store_true",
                   help="reclaim near-bg pockets fully enclosed by the subject "
                        "(fixes near-black subject detail on a black background - "
                        "e.g. Gordon's black suit on the black-bg LRZ render). Pair "
                        "with a tight --hard/--soft so only ~pure-black is stripped.")
    p.add_argument("--scrub-interior", type=int, default=0,
                   help="ALSO remove interior bg-coloured pockets ≥ N pixels in size "
                        "(default 0 = off, preserve all interior detail). Documented as "
                        "fragile - prefer Photoshop touch-up.")
    p.add_argument("--preview", type=Path, default=None,
                   help="also write a magenta-composited debug PNG to this path")
    p.add_argument("--intermediate", type=Path, default=None,
                   help="also save the post-bg-removal RGBA PNG here (for inspection)")
    p.add_argument("--no-readme-refresh", dest="readme_refresh",
                   action="store_false", default=True,
                   help="skip refreshing docs/images/halflife-icon{,-256}.png "
                        "(default: refresh if docs/images/ exists)")
    return p.parse_args()


def repo_root_from(script_path: Path) -> Path:
    return script_path.resolve().parent.parent


def main() -> None:
    args = parse_args()
    repo = repo_root_from(Path(__file__))

    if args.source is None:
        sys.exit(
            "make-icon: no source given. Pass one explicitly - and note the two\n"
            "shipped icons need a SQUARE CROP of their source first, because this\n"
            "tool's resize is non-uniform and the sources are 3:4 portrait.\n"
            "The crop boxes and thresholds are recorded in docs/ICONS.md; read it\n"
            "before regenerating either icon."
        )
    src = args.source
    if not src.is_file():
        sys.exit(f"make-icon: source not found: {src}")

    out = args.output or (repo / "MacOSX" / "Half-Life.icns")
    out.parent.mkdir(parents=True, exist_ok=True)

    print(f"  source: {src}")
    img = Image.open(src).convert("RGBA")
    arr = np.array(img)
    print(f"    size: {img.size}  RGBA")

    if args.keep_bg:
        args.bg = "transparent"

    if args.bg == "transparent":
        print("  bg removal: skipped (source already transparent)")
    else:
        bg = autodetect_bg(arr) if args.bg == "auto" else args.bg
        print(f"  bg removal: {bg} bg, hard={args.hard} soft={args.soft}"
              + (f" scrub-interior={args.scrub_interior}" if args.scrub_interior else ""))
        arr, stats = remove_background(arr, bg, args.hard, args.soft,
                                       args.scrub_interior, args.fill_holes,
                                       args.top_seed)
        img = Image.fromarray(arr, "RGBA")
        print(f"    components: {stats['components']:,}  edge-labels: {stats['edge_labels']}")
        if stats['scrubbed_pockets']:
            print(f"    scrubbed interior pockets: {stats['scrubbed_pockets']} "
                  f"({stats['scrubbed_pixels']:,} pixels)")
        print(f"    transparent: {stats['transparent']:,}  feathered: {stats['feathered']:,}  opaque: {stats['opaque']:,}")

    if args.intermediate:
        args.intermediate.parent.mkdir(parents=True, exist_ok=True)
        img.save(args.intermediate, optimize=True)
        print(f"  intermediate PNG: {args.intermediate}")

    if args.preview:
        args.preview.parent.mkdir(parents=True, exist_ok=True)
        magenta_preview(arr).save(args.preview, optimize=True)
        print(f"  preview PNG: {args.preview}")

    if args.base:
        # Keep an already-approved icon's legacy chunks byte-for-byte and only add
        # the large PNG ones. Regenerating from source does not reproduce a
        # previously shipped file (Pillow's resampling has drifted between
        # versions), and the 16-128px art is what has been eyeballed on the fleet.
        print("  appending modern chunks to %s (legacy chunks untouched):" % args.base)
        icns = append_modern(args.base.read_bytes(), img)
    else:
        print("  building ICNS (legacy chunks for Panther, +modern if asked):")
        icns = build_icns(img, modern=args.modern)
    out.write_bytes(icns)
    describe_icns(icns)
    print(f"  output: {out}")

    if args.readme_refresh:
        docs_dir = repo / "docs" / "images"
        if docs_dir.is_dir():
            refresh_readme_thumbs(img, docs_dir)
        else:
            print(f"  --readme-refresh skipped: {docs_dir} does not exist")


if __name__ == "__main__":
    main()
