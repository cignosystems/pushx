#!/usr/bin/env bash
# Prints the CHANGELOG.md section for one version (without its heading), for
# use as GitHub Release notes: scripts/release_notes.sh 0.15.0
# Exits 1 if CHANGELOG.md has no section for that exact version.
set -euo pipefail
version="${1:?usage: release_notes.sh <version>}"
awk -v v="$version" '
  /^## \[/ { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
  # The link-reference block ("[x.y.z]: https://...") trails the last section.
  found && /^\[[^]]+\]: / { exit }
  found { print }
  END { if (!found) { print "release_notes.sh: no CHANGELOG section for version " v > "/dev/stderr"; exit 1 } }
' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
