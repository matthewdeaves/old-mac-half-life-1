#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch-timerefresh.py - add a demo-free `timerefresh` benchmark command to the
Xash3D engine (libxash), applied to one or more engine source trees.

Why this exists
---------------
The stock `timedemo` benchmark depends on the demo subsystem, which is broken on
the big-endian PPC builds in *both* directions: recording crashes (SIGBUS in the
demo writer) and playing an Intel-recorded .dem fails (`svc_bad` / CL_EDICT_NUM).
So `timedemo` cannot give us reproducible cross-fleet numbers.

`timerefresh` renders a fixed number of frames flat-out (no host-loop pacing)
while spinning the view a full 360 degrees from the current spot, then reports
the average fps. It touches no demo file, so it is immune to the endian demo
bugs and produces identical, deterministic measurements on every machine and
renderer (Intel + all PPC, GL + soft). It is the classic id-engine
`timerefresh`, which GoldSrc/Xash dropped.

Usage in game / headless:
    map c0a0            # or any map; spawn is deterministic
    timerefresh 600     # render 600 frames flat-out, print result
The result line (grep anchor):
    timerefresh: <N> frames <T> seconds <F> fps

This script is idempotent: re-running it on an already-patched tree is a no-op.

Invoke:
    python3 patch-timerefresh.py <engine-tree> [<engine-tree> ...]
where each <engine-tree> is the root of an xash3d-fwgs checkout (the dir that
contains engine/client/cl_main.c).
"""
import os
import sys

FUNC = r'''/*
=================
CL_TimeRefresh_f

Demo-free deterministic render benchmark. Renders <numframes> frames flat-out
(bypassing the host-loop frame pacing) while spinning the view a full 360
degrees from the current position, then reports the average fps. Unlike
"timedemo" it needs no demo file, so it is immune to the big-endian demo-format
bugs on PPC and yields identical, reproducible numbers on every machine and
renderer. This is the classic id-engine "timerefresh".

Usage: timerefresh [numframes]   (default 128)
=================
*/
static void CL_TimeRefresh_f( void )
{
	int	i, frames = 128;
	double	start, stop, timelen;
	float	saved_yaw;

	if( cls.state != ca_active )
	{
		Con_Printf( "timerefresh: not connected (load a map first)\n" );
		return;
	}

	if( Cmd_Argc() > 1 )
		frames = Q_atoi( Cmd_Argv( 1 ));
	if( frames < 1 )
		frames = 128;

	saved_yaw = cl.viewangles[YAW];

	start = Platform_DoubleTime();
	for( i = 0; i < frames; i++ )
	{
		cl.viewangles[YAW] = anglemod(( (float)i / (float)frames ) * 360.0f );
		SCR_UpdateScreen();
	}
	stop = Platform_DoubleTime();

	cl.viewangles[YAW] = saved_yaw;

	timelen = stop - start;
	if( timelen <= 0.0 )
		timelen = 0.0001;

	Con_Printf( "timerefresh: %i frames %5.3f seconds %5.3f fps\n",
		frames, timelen, (double)frames / timelen );
}

'''

FUNC_ANCHOR = """/*
=================
CL_InitLocal
=================
*/
static void CL_InitLocal( void )
"""

REG_ANCHOR = '\tCmd_AddCommand ("timedemo", CL_TimeDemo_f, "demo benchmark" );\n'
REG_LINE = ('\tCmd_AddCommand ("timerefresh", CL_TimeRefresh_f, '
            '"render N frames flat-out and report fps (demo-free benchmark)" );\n')

MARKER = "CL_TimeRefresh_f"


def patch_tree(tree):
    path = os.path.join(tree, "engine", "client", "cl_main.c")
    if not os.path.isfile(path):
        print("  SKIP (not found): %s" % path)
        return False
    with open(path, "r") as f:
        src = f.read()

    if MARKER in src:
        print("  already patched: %s" % path)
        return True

    if FUNC_ANCHOR not in src:
        print("  ERROR: function anchor (CL_InitLocal) not found in %s" % path)
        return False
    if REG_ANCHOR not in src:
        print("  ERROR: registration anchor (timedemo) not found in %s" % path)
        return False

    # insert the function definition immediately before CL_InitLocal
    src = src.replace(FUNC_ANCHOR, FUNC + FUNC_ANCHOR, 1)
    # register the command right after the timedemo registration
    src = src.replace(REG_ANCHOR, REG_ANCHOR + REG_LINE, 1)

    with open(path, "w") as f:
        f.write(src)
    print("  patched: %s" % path)
    return True


def main():
    trees = sys.argv[1:]
    if not trees:
        print(__doc__)
        sys.exit(2)
    ok = True
    for tree in trees:
        print("== %s ==" % tree)
        ok = patch_tree(tree) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
