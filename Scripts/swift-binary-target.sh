#!/bin/bash
# Points Package.swift's TraciveReportCore at a released XCFramework, or back at the local build.
#
#   Scripts/swift-binary-target.sh <url> <checksum>
#   Scripts/swift-binary-target.sh --local
#
# The checksum comes from `swift package compute-checksum TraciveReportCore.xcframework.zip`.
set -euo pipefail

manifest="$(cd "$(dirname "$0")/.." && pwd)/Package.swift"

if [[ $# -eq 1 && $1 == --local ]]; then
  source_lines='  path: "Frameworks/TraciveReportCore.xcframework"'
elif [[ $# -eq 2 ]]; then
  url=$1
  checksum=$2
  [[ $url == https://* ]] || { echo "error: the url must be https: $url" >&2; exit 1; }
  [[ $checksum =~ ^[0-9a-f]{64}$ ]] || { echo "error: not a SHA-256 checksum: $checksum" >&2; exit 1; }
  source_lines="  url: \"$url\",
  checksum: \"$checksum\""
else
  echo "usage: $0 <url> <checksum> | --local" >&2
  exit 2
fi

SOURCE_LINES="$source_lines" python3 - "$manifest" <<'PY'
import os, re, sys

path = sys.argv[1]
text = open(path).read()
block = (
    "// swift-binary-target:begin\n"
    "let reportCore: Target = .binaryTarget(\n"
    '  name: "TraciveReportCore",\n'
    + os.environ["SOURCE_LINES"] + "\n"
    ")\n"
    "// swift-binary-target:end"
)
updated, count = re.subn(
    r"// swift-binary-target:begin.*?// swift-binary-target:end", block, text, flags=re.S
)
if count != 1:
    sys.exit("error: the swift-binary-target block is missing from Package.swift")
open(path, "w").write(updated)
PY
