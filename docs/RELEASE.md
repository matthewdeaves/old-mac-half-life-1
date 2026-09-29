# Release inputs

Fleet release procedure governs promotion; this page maps the Half-Life inputs.

## Package
Release DMGs build on a Tiger G4 using `-format UDZO`, with md5 checks of every binary. See the packaging decision in `docs/adr/` under 0005 and the command reference in `docs/BUILD-COMMANDS.md`.

## Verify
Run the checks in `docs/TESTS.md`. Claims in both the release notes and the publish script's `--title` must match the evidence; the mismatch story is in `docs/INCIDENTS.md`, 2026-08-28.
