#!/usr/bin/env bash
# Prints the CHANGELOG.md section for one version (without its heading), for
# use as GitHub Release notes: scripts/release_notes.sh 0.15.0
set -euo pipefail
version="${1:?usage: release_notes.sh <version>}"
awk -v v="$version" '
  /^## \[/ { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
  found { print }
' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
