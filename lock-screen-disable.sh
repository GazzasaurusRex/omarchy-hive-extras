#!/bin/bash
set -euo pipefail

config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}
state_dir="$state_home/omarchy-hive-theme"
plugin_dir="$config_home/omarchy/plugins"
shell_config="$config_home/omarchy/shell.json"
lock_plugin="$plugin_dir/hive.lock"
assume_yes=false

case "${1:-}" in
  --yes) assume_yes=true ;;
  -h|--help) echo "Usage: ./lock-screen-disable.sh [--yes]"; exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

[[ ${EUID:-$(id -u)} -ne 0 ]] || { echo "Run this as your normal user, not root." >&2; exit 1; }
[[ -f $state_dir/lock-installed ]] || { echo "The Hive lock screen is not recorded as installed." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required to restore the Shell configuration safely." >&2; exit 1; }
[[ -f $shell_config ]] || { echo "Missing Omarchy Shell configuration: $shell_config" >&2; exit 1; }
[[ -f $lock_plugin/manifest.json ]] || { echo "Missing installed Hive lock manifest." >&2; exit 1; }
if [[ $(jq -r '.id + ":" + (.omarchy.clonedFrom // "")' "$lock_plugin/manifest.json") != "hive.lock:omarchy.lock" ]]; then
  echo "Refusing to remove an unrecognized plugin directory: $lock_plugin" >&2
  exit 1
fi
keep_plugins_key=false
if [[ -f $state_dir/shell.before-lock.json ]]; then
  jq empty "$state_dir/shell.before-lock.json" || { echo "Invalid pre-lock Shell snapshot." >&2; exit 1; }
  keep_plugins_key=$(jq 'has("plugins")' "$state_dir/shell.before-lock.json")
fi

cat <<EOF
This will restore the stock omarchy.lock plugin in $shell_config and remove:
  $lock_plugin

It does not modify PAM or any system-owned Omarchy file.
EOF
if ! $assume_yes; then
  read -r -p "Continue? [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { echo "Cancelled."; exit 0; }
fi

timestamp=$(date +%Y%m%dT%H%M%S-%N)
mkdir -p "$state_dir/backups/$timestamp"
cp -a "$shell_config" "$state_dir/backups/$timestamp/shell.json"

tmp_shell=$(mktemp "${shell_config}.hive.XXXXXX")
jq --argjson keepPluginsKey "$keep_plugins_key" '
  .plugins = ((.plugins // []) | map(select(.id != "hive.lock"))) |
  if ((.plugins | length) == 0 and ($keepPluginsKey | not)) then del(.plugins) else . end |
  .cloneSourceRestores = ((.cloneSourceRestores // []) | map(select(. != "hive.lock"))) |
  if (.cloneSourceRestores | length) == 0 then del(.cloneSourceRestores) else . end |
  .disabledPlugins = ((.disabledPlugins // []) | map(select(. != "omarchy.lock"))) |
  if (.disabledPlugins | length) == 0 then del(.disabledPlugins) else . end
  ' "$shell_config" > "$tmp_shell"
jq empty "$tmp_shell"
mv "$tmp_shell" "$shell_config"

# Restore the stock service in the running shell before removing the clone.
timeout 3 omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

actual_tree_hash=$(
  cd "$lock_plugin"
  find . -type f -print0 | LC_ALL=C sort -z |
    while IFS= read -r -d '' file; do sha256sum "$file"; done |
    sha256sum | awk '{print $1}'
)
expected_tree_hash=""
[[ ! -f $state_dir/hive.lock.sha256 ]] || expected_tree_hash=$(<"$state_dir/hive.lock.sha256")
if [[ -n $expected_tree_hash && $actual_tree_hash == "$expected_tree_hash" ]] \
    || [[ -z $expected_tree_hash && $actual_tree_hash == "25db51f7dfe1977e75f741457713e0df0e94ad454c191e83c104fc55c73930d3" ]] \
    || [[ -z $expected_tree_hash && $actual_tree_hash == "e85f75ab220e5b53bc344ad311e9e163fe720a0a232c8982fab2fffa9e40fde5" ]]; then
  rm -rf -- "$lock_plugin"
else
  echo "Preserving modified or unverified Hive lock files: $lock_plugin" >&2
fi
rm -f -- "$state_dir/lock-installed" "$state_dir/shell.before-lock.json" "$state_dir/hive.lock.sha256"
timeout 3 omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "Hive lock screen disabled; stock omarchy.lock restored."
