#!/bin/bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}
state_dir="$state_home/omarchy-hive-theme"
plugin_dir="$config_home/omarchy/plugins"
shell_config="$config_home/omarchy/shell.json"
stock_lock_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/lock"
hive_lock_dir="$repo_root/plugins/hive.lock"
lock_plugin="$plugin_dir/hive.lock"
assume_yes=false

case "${1:-}" in
  --yes) assume_yes=true ;;
  -h|--help) echo "Usage: ./lock-screen-enable.sh [--yes]"; exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

[[ ${EUID:-$(id -u)} -ne 0 ]] || { echo "Run this as your normal user, not root." >&2; exit 1; }
for command in jq omarchy sha256sum; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done
[[ -f $shell_config ]] || { echo "Missing Omarchy Shell configuration: $shell_config" >&2; exit 1; }
jq empty "$shell_config" || { echo "Invalid JSON: $shell_config" >&2; exit 1; }
for required in Service.qml LockView.qml manifest.json stock-service.sha256; do
  [[ -f $hive_lock_dir/$required ]] || { echo "Incomplete Hive lock plugin: missing $required" >&2; exit 1; }
done
[[ -f $stock_lock_dir/Service.qml ]] || { echo "Cannot find the installed Omarchy lock service." >&2; exit 1; }
[[ -f /etc/pam.d/omarchy-lock-password ]] || {
  echo "The stock Omarchy password PAM service is unavailable; refusing to install a lock clone." >&2
  exit 1
}

expected_lock_hash=$(awk 'NR == 1 { print $1 }' "$hive_lock_dir/stock-service.sha256")
packaged_lock_hash=$(sha256sum "$hive_lock_dir/Service.qml" | awk '{print $1}')
installed_lock_hash=$(sha256sum "$stock_lock_dir/Service.qml" | awk '{print $1}')
if [[ $packaged_lock_hash != "$expected_lock_hash" || $installed_lock_hash != "$expected_lock_hash" ]]; then
  cat >&2 <<EOF
The Hive lock clone was built for a different Omarchy lock-service revision.
Packaged:  $packaged_lock_hash
Installed: $installed_lock_hash
Expected:  $expected_lock_hash
No files were changed. Update the Hive lock plugin before enabling it.
EOF
  exit 1
fi
omarchy plugin validate "$hive_lock_dir" >/dev/null || {
  echo "The packaged Hive lock plugin failed Omarchy validation; no files were changed." >&2
  exit 1
}

already_managed=false
[[ -f $state_dir/lock-installed ]] && already_managed=true
if ! $already_managed && jq -e '
  ((.disabledPlugins // []) | index("omarchy.lock") != null) or
  any(.plugins[]?; .id == "hive.lock") or
  any(.cloneSourceRestores[]?; . == "hive.lock")
' "$shell_config" >/dev/null; then
  echo "An unmanaged lock replacement is already configured; refusing to install hive.lock." >&2
  exit 1
fi
shopt -s nullglob
for manifest in "$plugin_dir"/*/manifest.json; do
  [[ $manifest == "$lock_plugin/manifest.json" ]] && continue
  if [[ $(jq -r '.omarchy.clonedFrom // empty' "$manifest" 2>/dev/null) == "omarchy.lock" ]]; then
    echo "Another omarchy.lock clone is installed: $manifest" >&2
    exit 1
  fi
done
shopt -u nullglob
if [[ -e $lock_plugin ]] && ! $already_managed; then
  echo "Refusing to replace pre-existing plugin directory: $lock_plugin" >&2
  exit 1
fi
if $already_managed; then
  actual_tree_hash=$(
    cd "$lock_plugin"
    find . -type f -print0 | LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do sha256sum "$file"; done |
      sha256sum | awk '{print $1}'
  )
  expected_tree_hash=""
  [[ ! -f $state_dir/hive.lock.sha256 ]] || expected_tree_hash=$(<"$state_dir/hive.lock.sha256")
  if [[ -n $expected_tree_hash && $actual_tree_hash != "$expected_tree_hash" ]] \
      || [[ -z $expected_tree_hash \
        && $actual_tree_hash != "25db51f7dfe1977e75f741457713e0df0e94ad454c191e83c104fc55c73930d3" \
        && $actual_tree_hash != "e85f75ab220e5b53bc344ad311e9e163fe720a0a232c8982fab2fffa9e40fde5" ]]; then
    echo "Refusing to overwrite user-modified Hive lock files: $lock_plugin" >&2
    exit 1
  fi
fi

cat <<EOF
The optional Hive lock screen will:
  - copy the verified visual lock clone to $lock_plugin
  - add hive.lock to plugins and cloneSourceRestores in $shell_config
  - add omarchy.lock to disabledPlugins while the clone is active
  - leave PAM, fingerprint configuration, and /usr/share/omarchy untouched
  - store a shell.json backup under $state_dir/backups/
EOF
if ! $assume_yes; then
  read -r -p "Continue? [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { echo "Cancelled."; exit 0; }
fi

timestamp=$(date +%Y%m%dT%H%M%S-%N)
mkdir -p "$state_dir/backups/$timestamp" "$plugin_dir"
cp -a "$shell_config" "$state_dir/backups/$timestamp/shell.json"
if ! $already_managed; then
  cp -a "$shell_config" "$state_dir/shell.before-lock.json"
fi

tmp_lock=$(mktemp -d "$plugin_dir/.hive.lock.tmp.XXXXXX")
tmp_shell=$(mktemp "${shell_config}.hive.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_lock"
  rm -f -- "$tmp_shell"
}
trap cleanup EXIT
cp -a "$hive_lock_dir/." "$tmp_lock/"
jq '
  .plugins = ((.plugins // []) | if any(.[]; .id == "hive.lock") then . else . + [{"id":"hive.lock"}] end) |
  .disabledPlugins = ((.disabledPlugins // []) | if index("omarchy.lock") then . else . + ["omarchy.lock"] end) |
  .cloneSourceRestores = ((.cloneSourceRestores // []) | if index("hive.lock") then . else . + ["hive.lock"] end)
  ' "$shell_config" > "$tmp_shell"
jq empty "$tmp_shell"

rm -rf -- "$lock_plugin"
mv "$tmp_lock" "$lock_plugin"
mv "$tmp_shell" "$shell_config"
trap - EXIT
touch "$state_dir/lock-installed"
(
  cd "$lock_plugin"
  find . -type f -print0 | LC_ALL=C sort -z |
    while IFS= read -r -d '' file; do sha256sum "$file"; done
) | sha256sum | awk '{print $1}' > "$state_dir/hive.lock.sha256"
timeout 3 omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "Hive lock screen enabled. Restore stock visuals with: $repo_root/lock-screen-disable.sh"
