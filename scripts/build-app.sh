#!/usr/bin/env bash
#
# Build GoogleChatNotifier as a proper macOS .app bundle (menu bar app).
#
# Usage:
#   ./scripts/build-app.sh          # build (release) + bundle + ad-hoc sign
#   ./scripts/build-app.sh --run    # idem puis lance l'app
#   ./scripts/build-app.sh --debug  # build en configuration debug
#
set -euo pipefail

CONFIG="release"
RUN=0
for arg in "$@"; do
	case "$arg" in
		--run) RUN=1 ;;
		--debug) CONFIG="debug" ;;
		*) echo "Argument inconnu : $arg" >&2; exit 1 ;;
	esac
done

# Racine du projet (dossier parent de scripts/)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="GoogleChatNotifier"
BUNDLE="$APP_NAME.app"
EXECUTABLE="$APP_NAME"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assemblage de $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN_PATH/$EXECUTABLE" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

# Icône optionnelle : copiée seulement si présente
if [[ -f "Resources/AppIcon.icns" ]]; then
	cp "Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
	/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

echo "▸ Signature ad-hoc"
codesign --force --deep --sign - "$BUNDLE"

echo "✓ $BUNDLE prêt dans $ROOT"

if [[ "$RUN" -eq 1 ]]; then
	echo "▸ Lancement"
	open "$BUNDLE"
fi
