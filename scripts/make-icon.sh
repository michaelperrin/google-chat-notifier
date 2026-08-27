#!/usr/bin/env bash
#
# Génère Resources/AppIcon.icns à partir de scripts/make-icon.swift (CoreGraphics)
# via un dossier .iconset temporaire et iconutil (fourni avec les Command Line Tools).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "▸ Rendu des PNG"
swift scripts/make-icon.swift "$ICONSET"

echo "▸ iconutil → Resources/AppIcon.icns"
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

rm -rf "$(dirname "$ICONSET")"
echo "✓ Resources/AppIcon.icns généré"
