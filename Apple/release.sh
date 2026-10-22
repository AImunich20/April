#!/usr/bin/env bash
# =============================================================================
#  Apple/release.sh — ออกรุ่นใหม่ของ April ขึ้น GitHub Releases (แอปที่ติดตั้งแล้วอัปเดตจากที่นี่)
#
#  ./Apple/release.sh patch          2.1.0 -> 2.1.1   (แก้บั๊ก)
#  ./Apple/release.sh minor          2.1.0 -> 2.2.0   (ฟีเจอร์ใหม่)
#  ./Apple/release.sh major          2.1.0 -> 3.0.0
#  ./Apple/release.sh 2.3.0          กำหนดเลขเอง
#  ./Apple/release.sh current        ออกรุ่นตามเลขใน VERSION ตอนนี้ (ไม่ขึ้นเลข)
#  ตัวเลือก: --notes "ข้อความ"  (ไม่ใส่ = สรุปจาก commit ตั้งแต่รุ่นก่อน) · --draft · --allow-dirty
#           --beta  ออกเป็นรุ่นทดสอบ (prerelease) — แอปเห็นเฉพาะผู้ที่เปิด "รับรุ่นทดสอบ" ในตั้งค่า › อัปเดต
#
#  ขั้นตอน: เขียน VERSION -> commit "release vX" -> tag vX -> push main + tag -> build .dmg + .zip -> gh release create
#  ต้องมี gh ที่ล็อกอินแล้ว (gh auth login)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

BUMP="${1:-}"; shift || true
NOTES=""; DRAFT=""; BETA=""; DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift ;;
    --draft) DRAFT="--draft" ;;
    --beta) BETA="--prerelease" ;;
    --allow-dirty) DIRTY=1 ;;
    *) echo "ไม่รู้จัก option: $1"; exit 2 ;;
  esac
  shift
done
[ -n "$BUMP" ] || { sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo "ต้องมี gh ที่ล็อกอินแล้ว: brew install gh && gh auth login"; exit 1; }

if [ "$DIRTY" = 0 ] && [ -n "$(git status --porcelain)" ]; then
  echo "มีไฟล์ที่ยังไม่ commit — commit ก่อน (หรือใส่ --allow-dirty ให้รวมเข้า commit ของรุ่นนี้)"; git status --short; exit 1
fi

CUR="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.0.0)"
IFS=. read -r MA MI PA <<< "$CUR"
case "$BUMP" in
  patch) NEW="$MA.$MI.$((PA + 1))" ;;
  minor) NEW="$MA.$((MI + 1)).0" ;;
  major) NEW="$((MA + 1)).0.0" ;;
  current) NEW="$CUR" ;;
  [0-9]*.[0-9]*.[0-9]*) NEW="$BUMP" ;;
  *) echo "รูปแบบเลขรุ่นไม่ถูก: $BUMP"; exit 2 ;;
esac
TAG="v$NEW"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "มี tag $TAG แล้ว"; exit 1; }

PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -z "$NOTES" ]; then
  RANGE="${PREV:+$PREV..}HEAD"
  NOTES="$(printf '## April %s\n\n%s\n' "$NEW" "$(git log --no-merges --pretty='- %s' $RANGE | grep -v '^- release v' | head -40)")"
fi

echo "== ออกรุ่น $CUR -> $NEW ($TAG)"
echo "$NEW" > VERSION
git add -A
git commit -q -m "release $TAG" -m "$NOTES" || true
git tag -a "$TAG" -m "April $NEW"
git push -q origin HEAD
git push -q origin "$TAG"
echo "  ✔ push main + $TAG"

"$HERE/build.sh" --dmg
gh release create "$TAG" "$HERE/dist/April-$NEW.dmg" "$HERE/dist/April-$NEW.zip" \
  --title "April $NEW" --notes "$NOTES" $DRAFT $BETA
echo "  ✔ GitHub Release $TAG"
