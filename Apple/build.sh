#!/usr/bin/env bash
# =============================================================================
#  Apple/build.sh — build แอป macOS ของ April (SwiftUI native) จากโค้ดใน Apple/Sources
#
#  ./Apple/build.sh                 build -> Apple/build/April.app
#  ./Apple/build.sh --dmg           build + แพ็ก Apple/dist/April-<เวอร์ชัน>.dmg และ .zip (ไฟล์อัปเดต)
#  ./Apple/build.sh --install [APP] build แล้วติดตั้งทับ APP (ค่าเริ่มต้น /Applications/April.app)
#  ออกรุ่นใหม่ขึ้น GitHub Releases: ./Apple/release.sh
#
#  เวอร์ชันมาจากไฟล์ VERSION · โค้ด April (เฉพาะไฟล์ที่ git ติดตาม — ไม่มี .env/data) ถูกใส่ใน
#  April.app/Contents/Resources/April -> เครื่องใหม่ติดตั้งได้เองโดยไม่ต้อง clone repo (Installer.swift)
#  ต้องมี Xcode Command Line Tools (xcode-select --install) · macOS 14+
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="$HERE/build"
APP="$BUILD/April.app"
DMG=0; INSTALL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dmg) DMG=1 ;;
    --install) INSTALL="${2:-/Applications/April.app}"; [ $# -gt 1 ] && shift ;;
    -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ไม่รู้จัก option: $1"; exit 2 ;;
  esac
  shift
done

command -v swiftc >/dev/null || { echo "ไม่พบ swiftc -> xcode-select --install"; exit 1; }

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
COMMITS="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null || echo https://github.com/AImunich20/April.git)"

echo "== build April $VERSION (build $COMMITS · $SHA)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINS=()
for arch in arm64 x86_64; do
  out="$BUILD/April-$arch"
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" \
    -module-name April -o "$out" "$HERE"/Sources/*.swift
  BINS+=("$out")
done
lipo -create -output "$APP/Contents/MacOS/April" "${BINS[@]}"
rm -f "${BINS[@]}"

sed -e "s|__VERSION__|$VERSION|" -e "s|__BUILD__|$COMMITS|" -e "s|__COMMIT__|$SHA|" -e "s|__ROOT__|$ROOT|" \
  -e "s|__REPO__|$REPO|" "$HERE/Info.plist" > "$APP/Contents/Info.plist"

ICNS="$BUILD/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$HERE/make-icon.swift" -nt "$ICNS" ]; then
  ICONSET="$BUILD/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift "$HERE/make-icon.swift" "$BUILD/icon-1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET" "$BUILD/icon-1024.png"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# โค้ด April สำหรับติดตั้งบนเครื่องใหม่ — เฉพาะไฟล์ที่ git ติดตาม/ยังไม่ commit แต่ไม่ถูก ignore
CODE="$APP/Contents/Resources/April"
mkdir -p "$CODE"
( cd "$ROOT" && git ls-files -co --exclude-standard -z \
    | grep -zv -e '^Apple/' -e '^tests/' -e '\.DS_Store$' \
    | xargs -0 -I{} sh -c '[ -f "{}" ] && printf "%s\0" "{}"' \
    | rsync -a --from0 --files-from=- ./ "$CODE/" )
echo "  ✔ โค้ด April ในแอป: $(du -sh "$CODE" | cut -f1) ($(find "$CODE" -type f | wc -l | tr -d ' ') ไฟล์)"

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "  ✔ $APP"

if [ -n "$INSTALL" ]; then
  rm -rf "$INSTALL.new"
  ditto "$APP" "$INSTALL.new"
  rm -rf "$INSTALL"
  mv "$INSTALL.new" "$INSTALL"
  echo "  ✔ ติดตั้งที่ $INSTALL"
fi

if [ "$DMG" = 1 ]; then
  mkdir -p "$HERE/dist"
  STAGE="$BUILD/dmg"
  OUT="$HERE/dist/April-$VERSION.dmg"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/April.app"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/อ่านก่อนติดตั้ง.txt" <<TXT
April $VERSION — พ่อบ้าน AI ส่วนตัว

1) ลาก April ไปไว้ที่ Applications
2) เปิดครั้งแรก: macOS จะเตือนว่าไม่รู้จักผู้พัฒนา
   -> เปิด System Settings › Privacy & Security เลื่อนลงไปกด "Open Anyway" แล้วเปิด April อีกครั้ง
3) ครั้งแรก April จะติดตั้งตัวเองให้ (Python, Ollama, โมเดลในเครื่อง ~3 GB) — ต้องต่ออินเทอร์เน็ต ใช้เวลา 5–20 นาที
   ไม่ต้องใช้ Homebrew หรือรหัสผ่านเครื่อง · ข้อมูลทั้งหมดอยู่ที่ ~/Library/Application Support/April
4) ใส่ชื่อของคุณและคีย์ cloud (ถ้ามี) ที่เมนู April › Settings… (⌘,)
5) คุยด้วยเสียง: ⇧⌘A · เปิด "เรียกด้วยเสียง April" ในตั้งค่าเสียงเพื่อเรียกได้ตลอดเวลา
TXT
  rm -f "$OUT"
  hdiutil create -volname "April $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
  rm -rf "$STAGE"
  echo "  ✔ $OUT"
  ZIP="$HERE/dist/April-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "  ✔ $ZIP"
fi
