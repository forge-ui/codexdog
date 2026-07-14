#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

stage_app() {
  local configuration="$1"
  local destination="$2"
  rm -rf "$destination"
  mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
  /usr/bin/ditto ".build/$configuration/CodexRelayMenu" "$destination/Contents/MacOS/CodexRelayMenu"
  /usr/bin/ditto ".build/$configuration/codex-relay" "$destination/Contents/MacOS/codex-relay"
  /usr/bin/ditto "Support/CodexRelay-Info.plist" "$destination/Contents/Info.plist"
  build_icon "$destination/Contents/Resources/AppIcon.icns"
  chmod 755 "$destination/Contents/MacOS/CodexRelayMenu" "$destination/Contents/MacOS/codex-relay"
  sign_app "$destination"
}

sign_app() {
  local app="$1"
  local identity="${CODEXRELAY_SIGNING_IDENTITY:--}"
  local -a flags=(--force --sign "$identity")
  if [[ "$identity" != "-" ]]; then
    flags+=(--options runtime --timestamp)
  fi
  /usr/bin/codesign "${flags[@]}" "$app/Contents/MacOS/codex-relay"
  /usr/bin/codesign "${flags[@]}" "$app/Contents/MacOS/CodexRelayMenu"
  /usr/bin/codesign "${flags[@]}" "$app"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
}

build_icon() {
  local output="$1"
  local iconset="$PWD/.build/CodexRelay.iconset"
  local master="$PWD/.build/CodexRelay-1024.png"
  rm -rf "$iconset"
  mkdir -p "$iconset"
  /usr/bin/sips -s format png "Support/CodexRelayDogTwoAccounts.png" --out "$master" >/dev/null
  for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    local doubled=$((size * 2))
    /usr/bin/sips -z "$doubled" "$doubled" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$iconset" -o "$output"
}

launch_app() {
  local app="$1"
  /usr/bin/open -n "$app"
}

stop_running_app() {
  local pid child deadline
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      /usr/bin/pkill -TERM -P "$child" 2>/dev/null || true
      /bin/kill -TERM -- "-$child" 2>/dev/null || true
      /bin/kill -TERM "$child" 2>/dev/null || true
    done < <(/usr/bin/pgrep -P "$pid" 2>/dev/null || true)
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done < <(/usr/bin/pgrep -x CodexRelayMenu 2>/dev/null || true)

  deadline=$((SECONDS + 3))
  while /usr/bin/pgrep -x CodexRelayMenu >/dev/null 2>&1 && (( SECONDS < deadline )); do
    /bin/sleep 0.05
  done
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    /bin/kill -KILL "$pid" 2>/dev/null || true
  done < <(/usr/bin/pgrep -x CodexRelayMenu 2>/dev/null || true)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    /bin/kill -TERM -- "-$pid" 2>/dev/null || true
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done < <(/usr/bin/pgrep -f '/CodexRelay.app/Contents/MacOS/codex-relay run --parent-pid' 2>/dev/null || true)
  deadline=$((SECONDS + 2))
  while /usr/bin/pgrep -f '/CodexRelay.app/Contents/MacOS/codex-relay run --parent-pid' >/dev/null 2>&1 && (( SECONDS < deadline )); do
    /bin/sleep 0.05
  done
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    /bin/kill -KILL -- "-$pid" 2>/dev/null || true
    /bin/kill -KILL "$pid" 2>/dev/null || true
  done < <(/usr/bin/pgrep -f '/CodexRelay.app/Contents/MacOS/codex-relay run --parent-pid' 2>/dev/null || true)
}

verify_running_app() {
  local app="$1"
  local menu_pids worker_pids menu_count worker_count menu_pid worker_pid version build parent
  /usr/bin/codesign --verify --deep --strict "$app"
  menu_pids=$(/usr/bin/pgrep -x CodexRelayMenu 2>/dev/null || true)
  worker_pids=$(/usr/bin/pgrep -f "$app/Contents/MacOS/codex-relay run --parent-pid" 2>/dev/null || true)
  menu_count=$(print -r -- "$menu_pids" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  worker_count=$(print -r -- "$worker_pids" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  [[ "$menu_count" == "1" ]]
  [[ "$worker_count" == "1" ]]
  menu_pid=$(print -r -- "$menu_pids" | /usr/bin/head -n 1)
  worker_pid=$(print -r -- "$worker_pids" | /usr/bin/head -n 1)
  [[ "$(/bin/ps -p "$menu_pid" -o command= | /usr/bin/sed 's/^ *//;s/ *$//')" == "$app/Contents/MacOS/CodexRelayMenu" ]]
  parent=$(/bin/ps -p "$worker_pid" -o ppid= | /usr/bin/tr -d ' ')
  [[ "$parent" == "$menu_pid" ]]
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
  build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
  [[ "$version" == "0.7.1" && "$build" == "10" ]]
  echo "CodexRelay.app $version ($build) is running"
}

install_staged_app() {
  local staged="$1"
  local destination="$HOME/Applications/CodexRelay.app"
  local replacement="$HOME/Applications/.CodexRelay.app.new"
  local backup="$HOME/Applications/.CodexRelay.app.previous"
  rm -rf "$replacement" "$backup"
  /usr/bin/ditto "$staged" "$replacement"
  if [[ -e "$destination" ]]; then
    /bin/mv "$destination" "$backup"
  fi
  if ! /bin/mv "$replacement" "$destination"; then
    [[ -e "$backup" ]] && /bin/mv "$backup" "$destination"
    return 1
  fi
  rm -rf "$backup"
}

case "${1:-}" in
  --test)
    swift test
    ;;
  --install)
    swift build -c release
    stage_app release "$PWD/.build/CodexRelay.app"
    stop_running_app
    mkdir -p "$HOME/Applications"
    install_staged_app "$PWD/.build/CodexRelay.app"
    .build/release/codex-relay uninstall || true
    launch_app "$HOME/Applications/CodexRelay.app"
    sleep 2
    verify_running_app "$HOME/Applications/CodexRelay.app"
    ;;
  --verify)
    swift build
    stage_app debug "$PWD/dist/CodexRelay.app"
    stop_running_app
    launch_app "$PWD/dist/CodexRelay.app"
    sleep 2
    verify_running_app "$PWD/dist/CodexRelay.app"
    ;;
  *)
    swift build
    stage_app debug "$PWD/dist/CodexRelay.app"
    stop_running_app
    launch_app "$PWD/dist/CodexRelay.app"
    ;;
esac
