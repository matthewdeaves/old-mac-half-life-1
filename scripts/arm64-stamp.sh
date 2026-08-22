# arm64-stamp.sh - what an arm64 slice was built from, so a stale one is refused.
#
# Sourced, never run. Used by the four drivers either side of the arm64 hand-off:
#
#   build-installer-arm64.sh  writes dist/installer-arm64/BUILD-STAMP
#   build-sysreport-arm64.sh  writes dist/sysreport-arm64/BUILD-STAMP
#   build-installer.sh        reads it back before fusing, on the mini
#   build-sysreport.sh        reads it back before fusing, on the mini
#
# WHY THIS EXISTS
#
# arm64 is the one slice no mini can build, so it is built on the dev box and
# carried over. Nothing cleans it up, so the copy on the mini can be weeks old,
# and both fuses used to test only that the file existed. An ordinary commit to
# installer/ or sysreport/ was enough: the mini rebuilt its four slices from the
# new source, fused the old arm64 one, and printed "arm64 slice present, fusing
# it in". The shipped app then ran old code on Apple Silicon and new code
# everywhere else. Issue #4.
#
# WHY A CONTENT HASH AND NOT A COMMIT ID
#
# The engine stamps a commit id (build-arm64.sh) because it builds from a pinned
# clone, and make-universal.sh checks it against build-pins.sh. That cannot work
# here. These two apps build from directories inside this repo, and ~/oldmac on
# the mini is a hand-managed tree rather than a clone: there is no git there and
# nothing pulls (sync-build-host.sh:12). The side that has to CHECK the stamp
# therefore cannot name the commit it is building, so a commit id would be a
# value only one of the two machines could compute.
#
# A content hash both can compute. md5 is the one digest spelling present on
# 10.3 through macOS 26, which is why this repo already leans on it elsewhere
# (sync-build-host.sh:82).
#
# WHAT IS HASHED, AND WHAT IS NOT
#
# Only the code that determines the Mach-O: the driver's own $SOURCES list plus
# the headers beside it. Deliberately NOT:
#
#   * Resources. ca-roots.pem, mods.map, artwork/ and the rest are copied into
#     Contents/Resources from the MINI's own installer/ (build-installer.sh:268-288).
#     They never enter any slice, so they cannot make one stale.
#   * vendor/. mbedTLS, zlib and lzma are compiled into the installer, but the
#     vendor trees are hand-managed per machine and are allowed to differ, so
#     hashing them would refuse every legitimate build. This is a real gap and
#     it is recorded as one in docs/adr/0015; a vendor bump still needs the
#     arm64 drivers re-run by hand.
#   * The pin values for those three. Writing a pin into a stamp records what
#     was ASKED FOR rather than what was BUILT, which is the exact defect
#     sync-build-host.sh:26 was written up for.
#
# The set is an explicit file list, not a glob of the directory, so an untracked
# file on the dev box cannot make the two sides disagree. The mini's copy of
# installer/ arrives by `git archive HEAD` (sync-build-host.sh:187), i.e. exactly
# the tracked files, while the dev box is a working tree.
#
# Files are keyed by BASENAME, because the absolute path differs between the two
# machines and only the contents matter.

# oldmac_src_stamp FILE...  ->  one md5 on stdout
oldmac_src_stamp () {
	for _f in "$@"; do
		if [ ! -f "$_f" ]; then
			echo "!! arm64-stamp: no such source file: $_f" >&2
			return 1
		fi
	done
	# LC_ALL=C so the sort order cannot depend on the locale of the box, and
	# sorting so the caller's argument order cannot change the answer.
	for _f in "$@"; do
		printf '%s  %s\n' "$( basename "$_f" )" "$( md5 -q "$_f" )"
	done | LC_ALL=C sort | md5 -q
}
