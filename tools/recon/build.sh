#!/bin/bash
# Buduje narzedzie i pakuje w minimalny bundel .app.
#
# Dlaczego bundel: macOS (TCC) przyznaje uprawnienie Bluetooth tylko aplikacjom
# z prawdziwym Info.plist w bundlu. Goly plik wykonywalny jest ubijany od razu
# przy dotknieciu CoreBluetooth, bez zadnego komunikatu.
set -euo pipefail
cd "$(dirname "$0")"

CONF="${1:-debug}"
swift build -c "$CONF"
BIN=".build/$CONF/marshall-recon"

APP="marshall-recon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/marshall-recon"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Podpis ad-hoc. Uprawnienie Bluetooth jest wiazane z podpisem, wiec po kazdej
# przebudowie macOS moze zapytac o zgode ponownie - to normalne.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Gotowe: $APP/Contents/MacOS/marshall-recon"
echo
echo "Uzycie:  ./mr <komenda>      (albo pelna sciezka wyzej)"
