# Precompute ripple sampling coordinates with the original rounding

The software ripple renderer maps a small output texture back into the original
water texture. Its inner loop divides and converts coordinates for every pixel,
although the possible inputs are bounded by the output width and height.

Precompute the horizontal ripple coordinates and both source-coordinate tables
once per upload. Index them using the same signed remainders as the original
loop. The tables are local to the call, so a different texture, aspect ratio or
ripple setting cannot reuse stale coordinates. They need no CPU extensions and
work on the G3 as well as the other targets.

Keep the original floating-point division and integer truncation in those
tables. Multiplication by a reciprocal or integer resampling would be shorter,
but can round differently near a texel boundary, especially for negative
remainders. Changing the texture upload API or ripple resolution is unnecessary
for this change. Texture filtering, update frequency and graphics defaults stay
as they were.

Clamp the scaled texture dimensions to at least one pixel. An extreme aspect
ratio otherwise truncates the shorter side to zero and requests an empty GL
texture.

`tests/test-ripples.py` extracts the actual upload functions from a saved baseline
and the candidate source, substitutes GL calls, and compares the generated
pixels. It also emits standalone C for the legacy compiler and hardware checks.
Its timing is CPU time spent updating the ripple texture. It is not game FPS
and does not measure GPU upload time. Whole-game benchmarks remain separate.
