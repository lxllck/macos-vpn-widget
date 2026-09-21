#!/bin/bash
# Сборка VPN Widget. Xcode не нужен — хватает Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/VPNWidget.app"
DEST="${1:-/Applications}"

echo "==> компиляция"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Версию платформы задаём явно. По умолчанию swiftc проставляет её на
# основе установленных Command Line Tools, и при рассинхроне с системой
# получается минимум ВЫШЕ текущей ОС — тогда LaunchServices отказывается
# запускать приложение с kLSIncompatibleSystemVersionErr.
TARGET="$(uname -m)-apple-macosx14.0"
swiftc -O -target "$TARGET" -o "$APP/Contents/MacOS/VPNWidget" Sources/*.swift 2>&1 \
  | grep -v '^$' || true
[ -x "$APP/Contents/MacOS/VPNWidget" ] || { echo "сборка не удалась"; exit 1; }

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Иконка рисуется кодом (Icon/main.swift) и кешируется в Resources —
# перерисовывается только если её удалить.
if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> генерация иконки"
  TMP=$(mktemp -d)
  swiftc -O -o "$TMP/makeicon" Icon/main.swift
  mkdir -p "$TMP/AppIcon.iconset"
  "$TMP/makeicon" "$TMP/AppIcon.iconset" >/dev/null
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> подпись"
codesign --force --sign - --identifier com.aleksey.vpnwidget "$APP"

echo "==> установка в $DEST"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "    (нет прав на /Applications, ставлю в $DEST)"
fi
# Приложение нельзя перезаписывать на ходу — сначала выгружаем старое.
pkill -f "VPNWidget.app/Contents/MacOS/VPNWidget" 2>/dev/null || true
sleep 1
rm -rf "$DEST/VPNWidget.app"
cp -R "$APP" "$DEST/VPNWidget.app"

# Без регистрации в LaunchServices не работают ни уведомления, ни автозапуск.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST/VPNWidget.app" 2>/dev/null || true

echo "==> готово: $DEST/VPNWidget.app"
