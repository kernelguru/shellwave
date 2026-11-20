#!/usr/bin/env bash
# Lädt NetBird in der Version aus go.mod, wendet die iOS-Embed-Patches an und
# bindet die gepatchte Kopie per replace ein.
set -euo pipefail
cd "$(dirname "$0")"
go mod download github.com/netbirdio/netbird
SRC=$(go list -m -f '{{.Dir}}' github.com/netbirdio/netbird)
rm -rf third_party/netbird
mkdir -p third_party
cp -R "$SRC" third_party/netbird
chmod -R u+w third_party/netbird
for p in patches/*.patch; do
  echo "Patch: $p"
  patch -d third_party/netbird -p1 --forward < "$p"
done
go mod edit -replace github.com/netbirdio/netbird=./third_party/netbird
