#!/usr/bin/env python3
"""
gen-mod-artwork.py - build installer/artwork/<gamedir>.tga for every supported mod.

WHY THIS EXISTS
---------------
The installer shows a picture of the mod while it copies, and stages the same
picture as <gamedir>/game.tga so the engine's "Custom Game" list has a preview.
It reads that through installer/OMTGA.m, a deliberately tiny Targa decoder.

Only four mods ship a game.tga at all (bshift, cad, echoes, gearbox) and every
one of those is a 16x16..64x64 Steam *icon*, not a banner - useless at 224x168.
So we build the artwork ourselves, offline, from the mod content on the upstream
i386 release volume, and ship the results in the app bundle.

WHERE THE PIXELS COME FROM (best first)
---------------------------------------
  a  resource/background/ - the GoldSrc menu splash, stored as a tile grid.
     Two naming schemes are in the wild and both are parsed generically:
         800_<row>_<col>_loading.tga     row = 1.., col = a..     (most mods)
         <w>_<h>_<row>_<col>.tga         row/col 0-based          (echoes)
     The tiles are found on disk under resource/background/, or under
     resource/background_bak/ (noffice), or inside a Quake PAK (blackops).
  b  <gamedir>/game.tga - only used if it is at least MIN_ART_PX on a side,
     which in practice means never. Kept so the rule is explicit.
  c  a representative frame of media/logo.avi - the WON menu's 640x100 title
     strip. Needs ffmpeg; without it this source is skipped.
  d  a mod-specific still: gfx/shell/splash.bmp, the 640x480 WON launcher
     splash. Every mod that lacks background tiles has one. When the mod also
     has a usable logo.avi the strip is composited along the bottom of the
     splash, which is exactly how the mod's own launcher looked - and it is
     what puts the mod's NAME on the four splashes that lack one.
  e  a generated title plate, so a mod with no art still looks deliberate.

OUTPUT
------
224x168 (the in-game preview box in mainui's 1024x768 virtual space), 24-bit,
bottom-left origin, image type 2 (uncompressed) or 10 (RLE) - whichever is
smaller. Both are exactly what OMTGA.m parses. Source aspect is preserved and
letterboxed onto black; nothing is stretched.

USAGE
-----
    .venv/bin/python scripts/gen-mod-artwork.py
    .venv/bin/python scripts/gen-mod-artwork.py --preview-dir /tmp/artwork-png

Needs the upstream release volume mounted read-only at
"/Volumes/Half-Life Xash3D FWGS" (override with --source). Nothing else is
touched; this script never writes outside installer/artwork/.
"""

import argparse
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SOURCE = "/Volumes/Half-Life Xash3D FWGS"
OUT_DIR = os.path.join(REPO, "installer", "artwork")
MODS_MAP = os.path.join(REPO, "installer", "mods.map")

OUT_W, OUT_H = 224, 168          # the mainui Custom Game preview box
MIN_ART_PX = 200                 # below this a source is an icon, not artwork
LOGO_MIN_W = 320                 # a logo.avi narrower than this is an icon too
LOGO_FRAME_FRAC = 0.60           # 60% through the clip: past any fade-in

# The generic order below is right for 22 of the 25 mods. These three are the
# exceptions, kept here rather than as special cases buried in the code.
OVERRIDES = {
    # The Gate's menu background really is an almost-empty starfield; its
    # launcher splash is the painted "The Gate" title card. Skip (a).
    "TheGate": {"skip": "a"},
    # Residual Point's menu background is near-black line art that turns to
    # mud at 224x168; its splash is a high-contrast portrait. Neither carries
    # the title, so pick the one that is legible as a thumbnail.
    "rp": {"skip": "a"},
    # Case Closed's splash already reads "CASE CLOSED", and its logo.avi is the
    # same words again - compositing both just prints the title twice.
    "cc": {"no_logo_strip": True},
}


# --------------------------------------------------------------------------
# mods.map
# --------------------------------------------------------------------------

def read_mods_map(path):
    """[(gamedir, title)] in file order."""
    mods = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            mods.append((parts[0], parts[3].strip()))
    return mods


# --------------------------------------------------------------------------
# source volume: app bundle -> gamedir -> content root
# --------------------------------------------------------------------------

def map_source_roots(source):
    """{gamedir: /path/to/<app>/Contents/Resources/Half-Life/<gamedir>}

    The gamedir is whatever the bundle's own launcher passes to -game, which is
    the only authoritative link between "Foo Xash3D 0.21.app" and "foo/".
    """
    roots = {}
    if not os.path.isdir(source):
        return roots
    for entry in sorted(os.listdir(source)):
        if not entry.endswith(".app"):
            continue
        sh = os.path.join(source, entry, "Contents", "MacOS", "xash3d.sh")
        try:
            with open(sh, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        m = re.search(r"-game\s+(\S+)", text)
        if not m:
            continue
        gamedir = m.group(1)
        root = os.path.join(source, entry, "Contents", "Resources",
                            "Half-Life", gamedir)
        if os.path.isdir(root):
            roots[gamedir] = root
    return roots


# --------------------------------------------------------------------------
# case-insensitive lookups (mod content is full of GFX/SHELL, MEDIA, LIBLIST.GAM)
# --------------------------------------------------------------------------

def ci_child(parent, name):
    try:
        entries = os.listdir(parent)
    except OSError:
        return None
    low = name.lower()
    for e in entries:
        if e.lower() == low:
            return os.path.join(parent, e)
    return None


def ci_path(root, *parts):
    cur = root
    for p in parts:
        cur = ci_child(cur, p)
        if cur is None:
            return None
    return cur


# --------------------------------------------------------------------------
# Quake PAK reader (blackops keeps its background tiles in pak0.pak)
# --------------------------------------------------------------------------

def pak_entries(path):
    """{lowercased entry name: (offset, length)} or {} if not a PAK."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(12)
            if len(head) < 12 or head[:4] != b"PACK":
                return {}
            dir_off, dir_len = struct.unpack("<ii", head[4:12])
            fh.seek(dir_off)
            blob = fh.read(dir_len)
    except OSError:
        return {}
    out = {}
    for i in range(len(blob) // 64):
        rec = blob[i * 64:(i + 1) * 64]
        name = rec[:56].split(b"\0")[0].decode("latin-1")
        off, length = struct.unpack("<ii", rec[56:64])
        out[name.lower().replace("\\", "/")] = (off, length)
    return out


def pak_read(path, offset, length):
    with open(path, "rb") as fh:
        fh.seek(offset)
        return fh.read(length)


def iter_paks(root):
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.lower().endswith(".pak"):
                yield os.path.join(dirpath, f)


def read_mod_file(root, relpath):
    """(bytes, where) for a file in the mod, on disk or inside a PAK.

    Redemption ships its whole gfx/ tree inside pak0.PAK, so "is it on disk"
    is not a safe test for anything.
    """
    p = ci_path(root, *relpath.split("/"))
    if p and os.path.isfile(p):
        with open(p, "rb") as fh:
            return fh.read(), relpath
    want = relpath.lower()
    for pak in iter_paks(root):
        hit = pak_entries(pak).get(want)
        if hit:
            return pak_read(pak, *hit), "%s:%s" % (os.path.basename(pak), relpath)
    return None, None


# --------------------------------------------------------------------------
# (a) background tile grid
# --------------------------------------------------------------------------

TILE_RE = re.compile(
    r"^(\d+)(?:_(\d+))?_([0-9]+|[a-z])_([0-9]+|[a-z])(?:_loading)?$", re.I)


def _axis_key(tok):
    return (0, int(tok)) if tok.isdigit() else (1, tok.lower())


def collect_background_tiles(root):
    """[(label, {stem: bytes})] candidate tile sets, best-guess order.

    On-disk resource/background* directories first, then any PAK's
    resource/background/ entries.
    """
    sets = []
    resource = ci_child(root, "resource")
    if resource:
        try:
            children = sorted(os.listdir(resource))
        except OSError:
            children = []
        # plain "background" before "background_bak" etc.
        children.sort(key=lambda n: (n.lower() != "background", n.lower()))
        for child in children:
            d = os.path.join(resource, child)
            if not os.path.isdir(d) or not child.lower().startswith("background"):
                continue
            blobs = {}
            for f in sorted(os.listdir(d)):
                stem, ext = os.path.splitext(f)
                if ext.lower() != ".tga":
                    continue
                with open(os.path.join(d, f), "rb") as fh:
                    blobs[stem] = fh.read()
            if blobs:
                sets.append(("resource/%s" % child, blobs))

    for pak in iter_paks(root):
        entries = pak_entries(pak)
        blobs = {}
        for name, (off, length) in entries.items():
            m = re.match(r"^resource/background/(.+)\.tga$", name)
            if m:
                blobs[m.group(1)] = pak_read(pak, off, length)
        if blobs:
            sets.append(("%s:resource/background" % os.path.basename(pak), blobs))
    return sets


def _lay_out(cells, rows, cols, decl_w, decl_h):
    """(col widths, row heights, matched_declared) for one candidate grid.

    A tile can be LARGER than the slot it fills: Residual Point's right-hand
    column is stored 256 wide in rows 1-2 and 32 wide in row 3, i.e. padded up
    to a power of two for GL. The real slot is therefore the SMALLEST tile in
    that column, and the surplus is filler to be cropped away. When even that
    does not add up to the width baked into the filename, the last row/column
    absorbs the difference.
    """
    widths = [min(cells[(r, c)].size[0] for r in rows) for c in cols]
    heights = [min(cells[(r, c)].size[1] for c in cols) for r in rows]
    matched = 0
    if decl_w:
        if sum(widths) == decl_w:
            matched += 1
        else:
            rest = decl_w - sum(widths[:-1])
            if 0 < rest <= cells[(rows[0], cols[-1])].size[0]:
                widths[-1] = rest
    if decl_h:
        if sum(heights) == decl_h:
            matched += 1
        else:
            rest = decl_h - sum(heights[:-1])
            if 0 < rest <= cells[(rows[-1], cols[0])].size[1]:
                heights[-1] = rest
    return widths, heights, matched


def stitch_tiles(blobs):
    """Assemble one tile set into an Image, or return (None, None).

    Groups by the dimension token(s) in the filename and uses the widest group.
    Which of the two trailing tokens is the row and which the column is
    *measured*, not assumed: the right answer is the one whose slot widths add
    up to the width baked into the filename.
    """
    groups = {}
    for stem, data in blobs.items():
        m = TILE_RE.match(stem)
        if not m:
            continue
        w = int(m.group(1))
        h = int(m.group(2)) if m.group(2) else None
        groups.setdefault((w, h), {})[(m.group(3), m.group(4))] = data
    if not groups:
        return None, None

    (decl_w, decl_h), tiles = max(
        groups.items(), key=lambda kv: (kv[0][0], len(kv[1])))

    images = {}
    for key, data in tiles.items():
        try:
            images[key] = Image.open(io.BytesIO(data)).convert("RGB")
        except Exception:
            return None, None

    best = None
    for swap in (False, True):
        cells = {(b, a) if swap else (a, b): im for (a, b), im in images.items()}
        rows = sorted({r for r, _ in cells}, key=_axis_key)
        cols = sorted({c for _, c in cells}, key=_axis_key)
        if len(cells) != len(rows) * len(cols):
            continue                       # incomplete grid, not a grid at all
        widths, heights, matched = _lay_out(cells, rows, cols, decl_w, decl_h)
        if best is None or matched > best[0]:
            best = (matched, cells, rows, cols, widths, heights)
    if best is None:
        return None, None

    _matched, cells, rows, cols, widths, heights = best
    out = Image.new("RGB", (sum(widths), sum(heights)))
    y = 0
    for ri, r in enumerate(rows):
        x = 0
        for ci, c in enumerate(cols):
            tile = cells[(r, c)]
            if tile.size != (widths[ci], heights[ri]):
                tile = tile.crop((0, 0, widths[ci], heights[ri]))
            out.paste(tile, (x, y))
            x += widths[ci]
        y += heights[ri]

    note = "%dx%d grid" % (len(rows), len(cols))
    if decl_w and out.size[0] != decl_w:
        note += " (declared width %d, got %d)" % (decl_w, out.size[0])
    if decl_h and out.size[1] != decl_h:
        note += " (declared height %d, got %d)" % (decl_h, out.size[1])
    return out, note


def source_background(root):
    for label, blobs in collect_background_tiles(root):
        img, note = stitch_tiles(blobs)
        if img is not None and min(img.size) >= MIN_ART_PX:
            return img, "a", "%s, %s" % (label, note)
    return None, None, None


# --------------------------------------------------------------------------
# (b) the mod's own game.tga
# --------------------------------------------------------------------------

def source_game_tga(root):
    p = ci_path(root, "game.tga")
    if not p:
        return None, None, None
    try:
        img = Image.open(p).convert("RGB")
    except Exception:
        return None, None, None
    if min(img.size) < MIN_ART_PX:
        return None, None, None          # it is a Steam icon, not artwork
    return img, "b", "game.tga %dx%d" % img.size


# --------------------------------------------------------------------------
# (c) a frame out of media/logo.avi
# --------------------------------------------------------------------------

def have_ffmpeg():
    return shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None


def find_logo_avi(root):
    media = ci_child(root, "media")
    if not media:
        return None
    best = None
    for f in sorted(os.listdir(media)):
        if not f.lower().endswith(".avi"):
            continue
        if "logo" in f.lower():
            return os.path.join(media, f)
        best = best or os.path.join(media, f)
    return best


def avi_frame(path):
    """A representative frame, or None. Skips fade-in by seeking ~60% in."""
    try:
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height,nb_frames",
             "-of", "csv=p=0", path],
            capture_output=True, text=True, timeout=30)
        w, h, nb = (probe.stdout.strip().split(",") + ["", "", ""])[:3]
        w, h = int(w), int(h)
        nb = int(nb) if nb.isdigit() else 1
    except Exception:
        return None, None
    if w < LOGO_MIN_W:
        return None, None
    frame = max(0, min(nb - 1, int(nb * LOGO_FRAME_FRAC)))
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "f.png")
        try:
            subprocess.run(
                ["ffmpeg", "-v", "error", "-y", "-i", path,
                 "-vf", "select=eq(n\\,%d)" % frame, "-frames:v", "1", out],
                capture_output=True, timeout=60)
            if not os.path.exists(out):
                return None, None
            img = Image.open(out).convert("RGB")
        except Exception:
            return None, None
    return img, "%s frame %d/%d (%dx%d)" % (os.path.basename(path), frame, nb, w, h)


def source_avi(root, ffmpeg_ok):
    if not ffmpeg_ok:
        return None, None, None
    path = find_logo_avi(root)
    if not path:
        return None, None, None
    img, note = avi_frame(path)
    if img is None:
        return None, None, None
    return img, "c", note


# --------------------------------------------------------------------------
# (d) gfx/shell/splash.bmp, optionally with the logo strip composited on
# --------------------------------------------------------------------------

def source_splash(root, ffmpeg_ok, allow_logo_strip=True):
    data, where = read_mod_file(root, "gfx/shell/splash.bmp")
    if data is None:
        return None, None, None
    try:
        img = Image.open(io.BytesIO(data)).convert("RGB")
    except Exception:
        return None, None, None
    if min(img.size) < MIN_ART_PX:
        return None, None, None
    note = "%s %dx%d" % (where, img.size[0], img.size[1])

    # The WON launcher drew the animated logo strip under the splash. Several
    # of the mods that get here have an unnamed or stock splash; the strip is
    # what carries the mod's title, so put it back.
    strip, strip_note = None, None
    if ffmpeg_ok and allow_logo_strip:
        path = find_logo_avi(root)
        if path:
            strip, strip_note = avi_frame(path)
    if strip is not None:
        sw, sh = img.size
        scale = sw / strip.size[0]
        strip = strip.resize((sw, max(1, round(strip.size[1] * scale))),
                             Image.LANCZOS)
        img = img.copy()
        img.paste(strip, (0, sh - strip.size[1]))
        note += " + " + strip_note
    return img, "d", note


def source_other_image(root):
    """Last resort before the placeholder: any reasonably large loose still."""
    for rel in (("gfx", "shell", "logo.bmp"),
                ("gfx", "shell", "splash8bit.bmp")):
        p = ci_path(root, *rel)
        if not p:
            continue
        try:
            img = Image.open(p).convert("RGB")
        except Exception:
            continue
        if min(img.size) >= MIN_ART_PX:
            return img, "d", "/".join(rel) + " %dx%d" % img.size
    return None, None, None


# --------------------------------------------------------------------------
# (e) generated title plate
# --------------------------------------------------------------------------

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial Bold.ttf",
]


def load_font(size):
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def source_placeholder(title):
    """A dark Half-Life-ish plate with the mod's name. Deliberate, not broken."""
    w, h = OUT_W * 4, OUT_H * 4
    img = Image.new("RGB", (w, h), (12, 14, 18))
    d = ImageDraw.Draw(img)
    for y in range(h):                      # subtle vertical falloff
        t = y / (h - 1)
        v = int(34 - 22 * t)
        d.line([(0, y), (w, y)], fill=(v // 2, int(v * 0.62), v))
    d.rectangle([0, 0, w - 1, h - 1], outline=(58, 72, 88), width=4)
    d.rectangle([14, 14, w - 15, h - 15], outline=(30, 38, 48), width=2)

    words, lines, cur = title.split(), [], ""
    font = load_font(int(h * 0.16))
    for word in words:
        trial = (cur + " " + word).strip()
        if d.textlength(trial, font=font) > w * 0.82 and cur:
            lines.append(cur)
            cur = word
        else:
            cur = trial
    lines.append(cur)
    while len(lines) > 1 and d.textlength(max(lines, key=len), font=font) > w * 0.82:
        font = load_font(max(10, font.size - 4))
    lh = int(font.size * 1.22)
    y0 = (h - lh * len(lines)) // 2
    for i, line in enumerate(lines):
        tw = d.textlength(line, font=font)
        d.text(((w - tw) / 2, y0 + i * lh + 3), line, font=font, fill=(0, 0, 0))
        d.text(((w - tw) / 2, y0 + i * lh), line, font=font, fill=(232, 176, 64))
    d.line([(w * 0.30, h * 0.80), (w * 0.70, h * 0.80)], fill=(232, 176, 64), width=3)
    return img, "e", "generated title plate"


# --------------------------------------------------------------------------
# fit + TGA writing
# --------------------------------------------------------------------------

def fit_letterbox(img, size=(OUT_W, OUT_H)):
    """Scale to fit inside `size` keeping aspect; centre on black. No stretch."""
    out = Image.new("RGB", size, (0, 0, 0))
    scaled = img.copy()
    scaled.thumbnail(size, Image.LANCZOS)
    out.paste(scaled, ((size[0] - scaled.size[0]) // 2,
                       (size[1] - scaled.size[1]) // 2))
    return out


def tga_header(w, h, imgtype):
    return bytes([0, 0, imgtype, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + \
        struct.pack("<HH", w, h) + bytes([24, 0])   # 24bpp, bottom-left origin


def encode_tga(img):
    """Uncompressed (2) or per-scanline RLE (10), whichever is smaller.

    Both are what OMTGA.m parses; bottom-left origin is TGA's default and what
    stock Half-Life game.tga files use.
    """
    w, h = img.size
    px = img.load()
    rows = []
    for y in range(h - 1, -1, -1):           # bottom-up
        row = bytearray()
        for x in range(w):
            r, g, b = px[x, y]
            row += bytes((b, g, r))          # TGA is BGR
        rows.append(bytes(row))
    plain = tga_header(w, h, 2) + b"".join(rows)

    rle = bytearray(tga_header(w, h, 10))
    for row in rows:
        pixels = [row[i:i + 3] for i in range(0, len(row), 3)]
        i = 0
        n = len(pixels)
        while i < n:
            run = 1
            while run < 128 and i + run < n and pixels[i + run] == pixels[i]:
                run += 1
            if run >= 2:
                rle.append(0x80 | (run - 1))
                rle += pixels[i]
                i += run
                continue
            j = i
            while j < n and len(pixels[j:j + 1]) and (j - i) < 128:
                if j + 2 < n and pixels[j] == pixels[j + 1] == pixels[j + 2]:
                    break
                j += 1
            count = max(1, j - i)
            rle.append(count - 1)
            for k in range(count):
                rle += pixels[i + k]
            i += count
    rle = bytes(rle)
    return rle if len(rle) < len(plain) else plain


def decode_like_omtga(data):
    """A faithful transcription of installer/OMTGA.m, used to self-check output.

    Returns (w, h, top-left-ordered RGB bytes) or None on the same conditions
    that make OMTGA.m return nil.
    """
    if len(data) < 18:
        return None
    b = data
    id_len, cmap_type, img_type = b[0], b[1], b[2]
    width = b[12] | (b[13] << 8)
    height = b[14] | (b[15] << 8)
    bpp, descriptor = b[16], b[17]
    if cmap_type != 0 or img_type not in (2, 10):
        return None
    if bpp not in (24, 32) or width == 0 or height == 0:
        return None
    if width > 4096 or height > 4096:
        return None
    bypp = bpp // 8
    count = width * height
    top_down = bool(descriptor & 0x20)
    off = 18 + id_len
    if off > len(b):
        return None
    rgb = bytearray(count * 3)
    if img_type == 2:
        if off + count * bypp > len(b):
            return None
        for i in range(count):
            s = off + i * bypp
            rgb[i * 3] = b[s + 2]
            rgb[i * 3 + 1] = b[s + 1]
            rgb[i * 3 + 2] = b[s]
    else:
        out = 0
        p = off
        while out < count:
            if p >= len(b):
                return None
            packet = b[p]
            p += 1
            n = (packet & 0x7F) + 1
            if out + n > count:
                return None
            if packet & 0x80:
                if p + bypp > len(b):
                    return None
                for k in range(n):
                    rgb[(out + k) * 3] = b[p + 2]
                    rgb[(out + k) * 3 + 1] = b[p + 1]
                    rgb[(out + k) * 3 + 2] = b[p]
                p += bypp
            else:
                if p + n * bypp > len(b):
                    return None
                for k in range(n):
                    s = p + k * bypp
                    rgb[(out + k) * 3] = b[s + 2]
                    rgb[(out + k) * 3 + 1] = b[s + 1]
                    rgb[(out + k) * 3 + 2] = b[s]
                p += n * bypp
            out += n
    if not top_down:
        stride = width * 3
        for r in range(height // 2):
            a0, a1 = r * stride, (r + 1) * stride
            c0, c1 = (height - 1 - r) * stride, (height - r) * stride
            rgb[a0:a1], rgb[c0:c1] = rgb[c0:c1], rgb[a0:a1]
    return width, height, bytes(rgb)


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------

def build_one(gamedir, title, root, ffmpeg_ok):
    if root is None:
        img, code, note = source_placeholder(title)
        return img, code, note + " (no content found on source volume)"
    over = OVERRIDES.get(gamedir, {})
    skip = over.get("skip", "")
    strip = not over.get("no_logo_strip", False)
    chain = (
        ("a", lambda: source_background(root)),
        ("b", lambda: source_game_tga(root)),
        ("d", lambda: source_splash(root, ffmpeg_ok, strip)),
        ("c", lambda: source_avi(root, ffmpeg_ok)),
        ("d", lambda: source_other_image(root)),
    )
    for code, fn in chain:
        if code in skip:
            continue
        img, got, note = fn()
        if img is not None:
            return img, got, note
    return source_placeholder(title)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default=DEFAULT_SOURCE,
                    help="mounted upstream release volume (read-only)")
    ap.add_argument("--out", default=OUT_DIR, help="output directory")
    ap.add_argument("--preview-dir", default=None,
                    help="also write PNG previews here, for eyeballing")
    ap.add_argument("--only", default=None, help="comma-separated gamedirs")
    args = ap.parse_args()

    mods = read_mods_map(MODS_MAP)
    if args.only:
        want = {s.strip() for s in args.only.split(",")}
        mods = [m for m in mods if m[0] in want]
    roots = map_source_roots(args.source)
    ffmpeg_ok = have_ffmpeg()
    if not ffmpeg_ok:
        print("note: ffmpeg/ffprobe not found - logo.avi sources are skipped")

    os.makedirs(args.out, exist_ok=True)
    if args.preview_dir:
        os.makedirs(args.preview_dir, exist_ok=True)

    rows = []
    failures = 0
    for gamedir, title in mods:
        root = roots.get(gamedir)
        img, code, note = build_one(gamedir, title, root, ffmpeg_ok)
        final = fit_letterbox(img)
        blob = encode_tga(final)

        decoded = decode_like_omtga(blob)
        if decoded is None:
            print("FAIL %s: OMTGA.m would reject this file" % gamedir)
            failures += 1
            continue
        dw, dh, drgb = decoded
        if (dw, dh) != final.size or drgb != final.tobytes():
            print("FAIL %s: round-trip mismatch" % gamedir)
            failures += 1
            continue

        path = os.path.join(args.out, gamedir + ".tga")
        with open(path, "wb") as fh:
            fh.write(blob)
        if args.preview_dir:
            final.save(os.path.join(args.preview_dir, gamedir + ".png"))
        rows.append((gamedir, code, len(blob), "RLE" if blob[2] == 10 else "raw",
                     "%dx%d" % img.size, note))

    width = max((len(r[0]) for r in rows), default=8)
    print()
    print("%-*s  src  %8s  fmt  %-10s  origin" % (width, "gamedir", "bytes", "source px"))
    for r in rows:
        print("%-*s   %s   %8d  %-3s  %-10s  %s" % (width, r[0], r[1], r[2], r[3], r[4], r[5]))
    print("\n%d artwork files in %s" % (len(rows), args.out))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
