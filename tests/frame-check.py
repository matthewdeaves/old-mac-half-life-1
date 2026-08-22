#!/usr/bin/env python3
"""frame-check.py - does this frame look like a rendered game, or like a bug?

    tests/frame-check.py SHOT.png [SHOT.png ...]

Reads a screenshot the engine wrote and asserts properties every correct frame
of this game has, on every machine we ship to. Exit 0 if all pass.

WHY NOT A REFERENCE IMAGE

The obvious check is a golden frame per machine class, committed and diffed.
This repo cannot have one: a screenshot of a Half-Life map is Valve's content
and CLAUDE.md's rule is that we ship code, not content, ever. So this checks
properties of the picture rather than the picture itself.

That trade decides what it can catch. It catches a frame that is blank, black,
flat, one colour, or has lost its texture detail: old-mac-quake3 found world
surfaces rendering untextured while models and HUD were fine, and that is
exactly a loss of local detail. It does NOT catch geometry that is drawn with
the right textures in the wrong shape: old-mac-quake2 shipped warped AltiVec
vertex maths that its own benchmark scored as +4.3% faster. Catching that needs
a reference, and a reference needs a decision about the content rule that is
not mine to make.

DECODING WITHOUT A LIBRARY

Pillow is not installed on the fleet or on this box, and adding a dependency to
run one test is worse than the test. sips ships with every macOS from 10.4 to
26 and converts PNG to uncompressed BMP, which is 40 lines to parse with the
standard library.
"""
import struct, subprocess, sys, tempfile, os

def load_bmp(path):
	"""Return (w, h, rows) with rows[y][x] = (r, g, b), y from the top."""
	with open(path, 'rb') as f:
		data = f.read()
	if data[:2] != b'BM':
		raise ValueError(f"{path}: not a BMP")
	pixoff = struct.unpack_from('<I', data, 10)[0]
	hdrsize = struct.unpack_from('<I', data, 14)[0]
	w, h = struct.unpack_from('<ii', data, 18)
	bpp = struct.unpack_from('<H', data, 28)[0]
	comp = struct.unpack_from('<I', data, 30)[0]
	if bpp not in (24, 32) or comp not in (0, 3):
		raise ValueError(f"{path}: unsupported BMP ({bpp} bpp, compression {comp})")
	bytes_per_px = bpp // 8
	stride = ((w * bytes_per_px + 3) // 4) * 4
	flipped = h > 0          # a positive height means the rows are bottom-up
	h = abs(h)
	rows = []
	for y in range(h):
		off = pixoff + y * stride
		row = []
		for x in range(w):
			b, g, r = data[off + x*bytes_per_px : off + x*bytes_per_px + 3]
			row.append((r, g, b))
		rows.append(row)
	if flipped:
		rows.reverse()
	return w, h, rows

def to_bmp(png, tmpdir):
	out = os.path.join(tmpdir, 'frame.bmp')
	subprocess.run(['sips', '-s', 'format', 'bmp', png, '--out', out],
	               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
	return out

def luma(px):
	r, g, b = px
	return (r * 299 + g * 587 + b * 114) // 1000

def check(png):
	"""Print one line per property. Return a list of failures."""
	with tempfile.TemporaryDirectory() as tmp:
		w, h, rows = load_bmp(to_bmp(png, tmp))
	fails = []
	name = os.path.basename(png)
	print(f"{name}  {w}x{h}")

	lum = [[luma(p) for p in row] for row in rows]
	flat = [v for row in lum for v in row]
	mean = sum(flat) / len(flat)
	var = sum((v - mean) ** 2 for v in flat) / len(flat)
	sd = var ** 0.5

	# 1. Not black, not blown out. A frame the engine failed to draw into is
	#    usually all black; one drawn with no texture and full lighting is white.
	print(f"  mean luma      {mean:6.1f}   want 12 to 235")
	if not 12 <= mean <= 235:
		fails.append(f"mean luma {mean:.1f} outside 12 to 235")

	# 2. Contrast. A single flat colour has none. This is the cheapest catch for
	#    "the renderer drew nothing but sky" or "everything is one grey".
	print(f"  luma stddev    {sd:6.1f}   want > 12")
	if sd <= 12:
		fails.append(f"luma stddev {sd:.1f} too flat")

	# 3. LOCAL detail. This is the one that catches an untextured world: a
	#    flat-shaded surface still has plenty of global contrast against the sky,
	#    but the pixels inside it are all the same. Mean absolute difference
	#    between horizontally adjacent pixels, over the whole frame.
	#
	#    Calibrated, not guessed. Three real frames from this fleet, and the same
	#    three put through a 128x96 downsample and back up, which strips texture
	#    detail while keeping every shape and colour, i.e. what an untextured
	#    world looks like:
	#
	#      G3 crossfire 800x600      2.20 real   0.66 flattened
	#      G4 crossfire 1024x768     2.77 real   0.86 flattened
	#      G4 rapidcore 1024x768     2.53 real   0.88 flattened
	#
	#    1.4 sits in the middle of that gap, a factor of 1.6 clear of both sides.
	#    An earlier version of this test counted tiles above a threshold and
	#    would have failed all three REAL frames: sky and painted walls are
	#    legitimately smooth, and a fraction-of-tiles rule reads them as broken.
	acc = n = 0
	for row in lum:
		for x in range(w - 1):
			acc += abs(row[x] - row[x+1]); n += 1
	detail = acc / n if n else 0.0
	print(f"  local detail   {detail:6.2f}   want >= 1.40")
	if detail < 1.40:
		fails.append(f"local detail {detail:.2f}: the world looks untextured or blurred")

	# 4. Channel balance. The G5's cyan-light bug was a byte-order fault in the
	#    palette that pushed one channel far out; a frame where one channel
	#    dominates by more than 2x is not a Half-Life frame.
	ch = [sum(p[i] for row in rows for p in row) / (w*h) for i in range(3)]
	lo, hi = min(ch), max(ch)
	ratio = hi / lo if lo > 0 else 999
	print(f"  R,G,B means    {ch[0]:5.1f} {ch[1]:5.1f} {ch[2]:5.1f}  ratio {ratio:4.2f}  want < 2.0")
	if ratio >= 2.0:
		fails.append(f"channel means {ch[0]:.0f}/{ch[1]:.0f}/{ch[2]:.0f} are {ratio:.1f}x apart")

	for f in fails:
		print(f"  !! {f}")
	return fails

def main(argv):
	if len(argv) < 2:
		print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
		return 2
	bad = 0
	for png in argv[1:]:
		if check(png):
			bad += 1
	print()
	print(f"{len(argv)-1 - bad} frame(s) look right, {bad} do not")
	return 1 if bad else 0

if __name__ == '__main__':
	sys.exit(main(sys.argv))
