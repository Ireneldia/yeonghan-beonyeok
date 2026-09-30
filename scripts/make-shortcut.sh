#!/bin/zsh
# 바탕화면에 "영한번역.command" 바로가기를 만들고 아이콘을 붙인다 (macOS).
# 사용: ./scripts/make-shortcut.sh [만들 위치, 기본 ~/Desktop]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Desktop}"
TARGET="$DEST/영한번역.command"
ICON="$ROOT/assets/icon.png"

cat > "$TARGET" <<SH
#!/bin/zsh
exec "$ROOT/start.sh"
SH
chmod +x "$TARGET" "$ROOT/start.sh" "$ROOT/run.sh"

if [[ -f "$ICON" ]]; then
  YH_ICON="$ICON" YH_TARGET="$TARGET" osascript -l JavaScript -e '
    ObjC.import("AppKit"); ObjC.import("stdlib");
    var img = $.NSImage.alloc.initWithContentsOfFile($.getenv("YH_ICON"));
    $.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, $.getenv("YH_TARGET"), 0);' >/dev/null \
    && echo "아이콘 적용" || echo "아이콘 적용 실패 (바로가기는 만들어짐)"
fi
echo "만들었습니다: $TARGET"
