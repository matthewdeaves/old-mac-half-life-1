# Dynamic lights fall off by true distance

The engine's dynamic light accumulation, inherited from Quake and shared with
GoldSrc, measures each luxel's offset inside its own face's plane with a
Manhattan-style sum and subtracts the light's height above that plane. Two
faces that meet at a fold therefore give the same point in space two different
values. A flashlight beam landing near a fold is drawn right up to the edge on
the face it hits and not at all on the neighbour, so it ends in a hard line
wherever a wall changes angle.

Measured on the mini G4 on the `c0a0` tunnel, with the frame rate capped so the
tram sits at the same place in every capture: the line is present with the
single-pass renderer and, frame for frame, with the classic two-pass path, and
setting `r_dlight_virtual_radius` back to upstream's 3 changes nothing. So it
is the light model, not this port's renderer, and Intel and arm64 show it too.

`r_dlight_spherical`, default on, makes the falloff the luxel's true distance
from the light: in-plane offset, converted from the face's texture units to
world units by its lightmap vectors, and the height above the plane, taken as
one vector. Both faces at a fold compute the same number for their shared edge,
so the beam wraps across it. The peak at the impact point, the reach and the
colour scaling are the classic ones, and the spherical value never exceeds the
classic value anywhere, since a hypotenuse is never longer than the sum of its
sides. The search bounds widen to the sphere's chord at the plane's height.
The classic path is kept verbatim at `r_dlight_spherical 0`.

The cost is one square root per lit luxel per light. A flashlight touches a
handful of faces and a few hundred luxels a frame, which is nothing beside the
lightmap rebuild those faces already pay for.

Rejected: leaving it as upstream behaviour. It is authentic to GoldSrc, but the
hard line reads as a rendering fault on every machine, and the player who
reported it did so twice. Also rejected: fixing it at the marking stage. The
neighbouring face is marked and its lightmap is rebuilt; it is the per-luxel
distance that leaves it dark.

The software renderer keeps the classic model. It is a fallback here, not a
target.
