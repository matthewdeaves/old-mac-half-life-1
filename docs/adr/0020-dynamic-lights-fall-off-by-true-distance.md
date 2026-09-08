# Dynamic lights fall off by true distance

The classic dynamic-light accumulator combines an in-plane texture-space offset
with a world-space distance to the face's plane. Its value at a shared point can
change with the face orientation and texture mapping. Taking a square root of
those same mixed units does not make the result continuous.

## Decision

With `r_dlight_spherical` enabled, invert each face's lightmap mapping on its
plane. For texture axes S and T and unit plane normal N, the dual basis is
`cross(T,N) / dot(S,cross(T,N))` and
`cross(N,S) / dot(S,cross(T,N))`. Multiplying signed, fractional lightmap offsets
by these vectors recovers the in-plane world displacement. Combine its squared
length with squared plane distance to obtain the distance to the light.

This handles scaled, skewed and non-tangent texture axes. Sample search bounds
use the lengths of the texture axes projected onto the plane. Surface marking
uses the world sphere's plane bound and skips the classic texture-space rectangle
rejection, which can otherwise discard a surface containing lit samples.

The flashlight chooses its world radius once from the face hit by its trace.
For enlarged textures, the projected texture area determines a uniform scale;
radius grows by its reciprocal and colour is reduced by that scale to retain
peak brightness, subject to byte rounding. Unit-scale faces retain radius 80.
Degenerate mappings and enlargement beyond 16 use the base radius. This is an
area-based approximation to the classic footprint on skewed or unequal texture
axes. All receiving faces use that one radius, rather than choosing their own.
Other dynamic lights retain their supplied world radii.

`r_dlight_spherical 0` retains the classic accumulator and flashlight sizing.
The software renderer retains its classic accumulator.

## Rejected approaches

- Combining texture offsets with world plane distance under a square root.
  `tests/test-flashlight.py` demonstrates that the previous candidate gives
  different values at a shared world point. The test executes the actual
  accumulator with renderer dependencies stubbed.
- Dividing by texture-vector lengths alone. Texture axes can have components
  along the plane normal and need not be orthogonal, so lengths are not the
  inverse of their mapping on the plane.
- Changing every flashlight to radius 80 in world space without compensating
  its footprint. That shrinks the beam on walls carrying enlarged textures.

The geometry test verifies accumulation, not the player's complete rendered
scene. Hardware and hand testing remain necessary, including checking static
lightmap seams, the beam footprint and frame cost. Broader conservative surface
marking can rebuild more lightmaps than the classic rectangle test.
