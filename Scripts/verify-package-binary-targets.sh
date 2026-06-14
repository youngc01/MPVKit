#!/usr/bin/env bash
set -euo pipefail

PACKAGE_FILE="${1:-Package.swift}"
if [[ ! -f "$PACKAGE_FILE" ]]; then
  echo "Package file not found: $PACKAGE_FILE" >&2
  exit 1
fi

if rg -n '0\.41\.3' "$PACKAGE_FILE"; then
  echo "Found stale 0.41.3 binary target URL in $PACKAGE_FILE" >&2
  exit 1
fi

DUMP_JSON="$(mktemp)"
URLS_JSON="$(mktemp)"
DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -f "$DUMP_JSON" "$URLS_JSON"; rm -rf "$DOWNLOAD_DIR"' EXIT

swift package dump-package --package-path "$(dirname "$PACKAGE_FILE")" >"$DUMP_JSON"

python3 - "$DUMP_JSON" >"$URLS_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    package = json.load(fh)

for target in package.get("targets", []):
    if target.get("type") != "binary":
        continue
    url = target.get("url")
    checksum = target.get("checksum")
    name = target.get("name")
    if url and checksum:
        print(json.dumps({"name": name, "url": url, "checksum": checksum}))
PY

while IFS= read -r line; do
  name="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$line")"
  url="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["url"])' "$line")"
  expected="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["checksum"])' "$line")"
  filename="${url##*/}"
  dest="$DOWNLOAD_DIR/$filename"

  status="$(curl -sS -L -I -o /dev/null -w '%{http_code}' "$url")"
  case "$status" in
    200|302) ;;
    *) echo "$name URL returned HTTP $status: $url" >&2; exit 1 ;;
  esac

  curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
  actual="$(swift package compute-checksum "$dest")"
  if [[ "$actual" != "$expected" ]]; then
    echo "$name checksum mismatch" >&2
    echo "  url:      $url" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  echo "Verified $name: $status $url"
done <"$URLS_JSON"
