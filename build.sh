#!/bin/bash
# Builds "build/StudyO.app".  Usage: ./build.sh [--run] [--install] [--dmg] [--selftest]
set -euo pipefail
cd "$(dirname "$0")"

VLC="/Applications/VLC.app/Contents/MacOS"
if [ ! -d "$VLC/lib" ]; then
  echo "VLC.app is needed for the video engine. Install it:  brew install --cask vlc" >&2
  exit 1
fi
# The app reads a few libVLC 3 internals (live audio level), and VLC 4 removed APIs it uses.
# Bundle only an engine of the series it was written for.
VLC_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/VLC.app/Contents/Info.plist 2>/dev/null || echo unknown)"
case "$VLC_VERSION" in
  3.*) echo "Video engine: VLC $VLC_VERSION" ;;
  *) echo "StudyO Player needs VLC 3.x for its video engine (found: $VLC_VERSION)." >&2; exit 1 ;;
esac

# Prefer the full Xcode toolchain when it is installed (falls back to Command Line Tools).
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

FLAGS=()
for arg in "$@"; do [ "$arg" = "--selftest" ] && FLAGS+=(-D SELFTEST); done

APP="build/StudyO.app"
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/Frameworks"

# StudyO runs on Apple silicon Macs only (M1 and later). The video engine copied from VLC.app
# must therefore contain arm64 code, or the app would fail to start.
if ! lipo -archs "$VLC/lib/libvlc.dylib" | grep -qw arm64; then
  echo "The installed VLC.app has no Apple silicon (arm64) engine. Install the Apple silicon or Universal VLC 3.x." >&2
  exit 1
fi

echo "Compiling…"
swiftc -O -swift-version 5 -parse-as-library ${FLAGS[@]+"${FLAGS[@]}"} \
  -target "arm64-apple-macos14.0" \
  -import-objc-header Sources/CVLC/vlc_min.h \
  Sources/StudyOPlayer/*.swift \
  -L "$VLC/lib" -lvlc -lvlccore \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks/lib" \
  -o "$C/MacOS/StudyOPlayer"

echo "Bundling the video engine…"
cp -R "$VLC/lib" "$VLC/plugins" "$C/Frameworks/"
# A Universal VLC carries Intel code too; strip it, since the app is Apple silicon only.
for f in "$C/Frameworks/lib"/*.dylib "$C/Frameworks/plugins"/*.dylib; do
  if lipo -archs "$f" 2>/dev/null | grep -qw x86_64; then lipo "$f" -thin arm64 -output "$f"; fi
done
cp Resources/Info.plist "$C/Info.plist"

# Security: StudyO Player only plays local files, so every engine module that talks to the network,
# streams out, captures the screen/camera/microphone, takes remote commands, runs scripts
# or stores passwords is left out of the app.
P="$C/Frameworks/plugins"
REMOVE=(
  'access_output_*' 'stream_out_*' 'mux_*' access_mms access_srt access_imem imem adaptive
  ftp http https sftp nfs tcp udp rtp rtpvideo rist sap sdp satip live555 vod_rtsp nsc
  upnp bonjour podcast rss netsync remoteosd demux_chromecast audioscrobbler fingerprinter
  addonsvorepository addonsfsstorage lua oldrc ncurses macosx hotkeys gestures
  screen avcapture avaudiocapture shm gnutls securetransport keychain file_keystore
  memory_keystore syslog osx_notifications
)
for name in "${REMOVE[@]}"; do rm -f "$P"/lib${name}_plugin.dylib; done
rm -f "$P"/*.jar "$P"/plugins.dat
echo "Engine modules kept: $(ls "$P" | wc -l | tr -d ' ')"

# Resources/icon.png is the icon artwork; the .icns is rebuilt whenever that image changes.
if [ -f Resources/icon.png ] && { [ ! -f Resources/AppIcon.icns ] || [ Resources/icon.png -nt Resources/AppIcon.icns ]; }; then
  echo "Making the icon from Resources/icon.png…"
  TMP="$(mktemp -d)"
  swift scripts/icon_from_image.swift Resources/icon.png "$TMP/icon.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
elif [ ! -f Resources/AppIcon.icns ]; then
  echo "Making the icon…"
  TMP="$(mktemp -d)"
  swift scripts/make_icon.swift "$TMP/icon.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$C/Resources/AppIcon.icns"

# Security: sign everything with the hardened runtime. That blocks code injection through
# DYLD_* variables, debugger attachment, and running unsigned or writable memory, and macOS
# refuses to launch the app if any signed file is changed afterwards.
echo "Signing (hardened runtime)…"
codesign --force --sign - --options runtime --timestamp=none "$C/Frameworks/lib"/*.dylib "$P"/*.dylib
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements Resources/StudyOPlayer.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"

for arg in "$@"; do
  case "$arg" in
    --install) rm -rf "/Applications/StudyO.app"; cp -R "$APP" /Applications/; echo "Installed to /Applications" ;;
    --run) open "$APP" ;;
    --dmg)
      VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$C/Info.plist")"
      DMG="build/StudyO-$VERSION.dmg"
      STAGE="$(mktemp -d)"
      cp -R "$APP" "$STAGE/"
      ln -s /Applications "$STAGE/Applications"
      rm -f "$DMG"
      
      echo "Creating DMG..."
      TEMP_DMG="build/temp_dmg.dmg"
      rm -f "$TEMP_DMG"
      
      # Size the image from what goes in it (plus room for the Finder layout), so it never runs out.
      SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
      MOUNT_DIR="/Volumes/StudyO"
      # A volume left mounted by an earlier run would make the attach below fail.
      [ -d "$MOUNT_DIR" ] && { hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true; }
      hdiutil create -volname "StudyO" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size ${SIZE_MB}m "$TEMP_DMG" >/dev/null

      hdiutil attach "$TEMP_DMG" -readwrite -noverify -mountpoint "$MOUNT_DIR" >/dev/null
      
      osascript <<EOF
tell application "Finder"
    tell disk "StudyO"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        
        -- مقاس النافذة
        set the bounds of container window to {200, 150, 860, 520}
        
        set theViewOptions to the icon view options of container window
        set icon size of theViewOptions to 128
        set arrangement of theViewOptions to not arranged
        
        -- القيم المثالية ليتوسطا النافذة تماماً بمسافة متساوية وجميلة
        set position of item "StudyO.app" of container window to {160, 130}
        set position of item "Applications" of container window to {480, 130}
        
        close
    end tell
end tell
EOF
      
      sync
      sleep 2
      
      hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || diskutil eject "$MOUNT_DIR" >/dev/null 2>&1 || true
      sleep 2
      
      echo "Compressing DMG..."
      hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
      rm -f "$TEMP_DMG"
      rm -rf "$STAGE"
      
      codesign --force --sign - "$DMG"
      echo "Disk image: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
      ;;
  esac
done
