#!/usr/bin/env python
# Idempotently patch game_launch/game.cpp so the launcher resolves libxash.dylib
# next to its own executable (Contents/MacOS in a .app) instead of dlopen()'ing a
# bare leaf name that only resolves against the current working directory. Without
# this a Finder-launched .app (cwd = "/") dies with "libxash.dylib image not found".
# Applies to every engine tree. Python 2.5+ safe.
import sys

for f in sys.argv[1:]:
    s = open(f).read()
    if '_NSGetExecutablePath' in s:
        print('already patched:', f)
        continue

    anchor = '#define FreeLibrary( x ) dlclose( x )\n'
    incl = (anchor +
            '#if XASH_APPLE\n'
            '#include <AvailabilityMacros.h> // MAC_OS_X_VERSION_MAX_ALLOWED for the SDK guard below\n'
            '#include <mach-o/dyld.h> // _NSGetExecutablePath: resolve libxash next to\n'
            '                         // the executable so a Finder-launched .app (cwd=/)\n'
            '                         // still finds it. (oldmac .app fix.)\n'
            '#endif\n')
    assert anchor in s, ('anchor A not found in ' + f)
    s = s.replace(anchor, incl, 1)

    oldB = '\thEngine = dlopen( XASHLIB, RTLD_NOW );\n'
    newB = ('\tconst char *xashlib = XASHLIB;\n'
            '#if XASH_APPLE\n'
            '\t// Resolve libxash next to this executable, cwd-independent.\n'
            '\tstatic char xashpath[4096];\n'
            '\tchar execpath[4096];\n'
            '\tuint32_t execpathlen = sizeof( execpath );\n'
            '#if defined( MAC_OS_X_VERSION_MAX_ALLOWED ) && MAC_OS_X_VERSION_MAX_ALLOWED < 1040\n'
            '\t// The 10.3.9 SDK declares _NSGetExecutablePath(char*, unsigned long*); uint32_t and\n'
            '\t// unsigned long are the same width on ppc32 but distinct types, so cast to match\n'
            '\t// the older prototype (10.4+ uses uint32_t* and takes the #else path unchanged).\n'
            '\tif( _NSGetExecutablePath( execpath, (unsigned long *)&execpathlen ) == 0 )\n'
            '#else\n'
            '\tif( _NSGetExecutablePath( execpath, &execpathlen ) == 0 )\n'
            '#endif\n'
            '\t{\n'
            "\t\tchar *slash = strrchr( execpath, '/' );\n"
            '\t\tif( slash )\n'
            '\t\t{\n'
            '\t\t\t*slash = 0;\n'
            '\t\t\tsnprintf( xashpath, sizeof( xashpath ), "%s/%s", execpath, XASHLIB );\n'
            '\t\t\txashlib = xashpath;\n'
            '\t\t}\n'
            '\t}\n'
            '#endif\n'
            '\thEngine = dlopen( xashlib, RTLD_NOW );\n')
    assert oldB in s, ('anchor B not found in ' + f)
    s = s.replace(oldB, newB, 1)

    s = s.replace(
        'Launch_Error( "Unable to load %s: %s", XASHLIB, dlerror( ));',
        'Launch_Error( "Unable to load %s: %s", xashlib, dlerror( ));', 1)

    open(f, 'w').write(s)
    print('patched:', f)
