#!/bin/bash
set -euo pipefail

config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}
state_dir="$state_home/omarchy-hive-theme"
data_dir="$data_home/omarchy-hive-theme"
plugin_dir="$config_home/omarchy/plugins"
shell_config="$config_home/omarchy/shell.json"
starship_config="$config_home/starship.toml"
assume_yes=false

case "${1:-}" in
  --yes) assume_yes=true ;;
  -h|--help) echo "Usage: ./uninstall.sh [--yes]"; exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

[[ ${EUID:-$(id -u)} -ne 0 ]] || { echo "Run this uninstaller as your normal user, not root." >&2; exit 1; }
[[ -f $state_dir/installed ]] || { echo "Hive Extras are not recorded as installed." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required to edit Omarchy's shell configuration safely." >&2; exit 1; }
[[ -f $shell_config ]] || { echo "Missing Omarchy shell configuration: $shell_config" >&2; exit 1; }
[[ -f $state_dir/shell.before-extras.json ]] || { echo "Missing the pre-install Shell snapshot; refusing a partial rollback." >&2; exit 1; }
jq empty "$shell_config" || { echo "Invalid JSON: $shell_config" >&2; exit 1; }
jq empty "$state_dir/shell.before-extras.json" || { echo "Invalid pre-install Shell snapshot." >&2; exit 1; }

plugins_key_existed=$(jq 'has("plugins")' "$state_dir/shell.before-extras.json")
if [[ -f $state_dir/plugins-key-existed ]]; then
  plugins_key_existed=$(<"$state_dir/plugins-key-existed")
fi

cat <<EOF
This removes Hive Extras from the Omarchy Shell configuration, restores the
stock workspace, idle, and lock entries changed by the installer, and restores
Starship only if its installed file has not been edited. Modified Hive-owned
files are preserved on disk and reported instead of being deleted.
EOF
if ! $assume_yes; then
  read -r -p "Continue? [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { echo "Cancelled."; exit 0; }
fi

timestamp=$(date +%Y%m%dT%H%M%S-%N)
mkdir -p "$state_dir/backups/$timestamp"
cp -a "$shell_config" "$state_dir/backups/$timestamp/shell.json"

tmp_shell=$(mktemp "$shell_config.hive.XXXXXX")
cleanup() { rm -f -- "$tmp_shell"; }
trap cleanup EXIT

jq --argjson keepPluginsKey "$plugins_key_existed" '
  .plugins = ((.plugins // []) | map(select(.id != "hive.idle"))) |
  if ((.plugins | length) == 0 and ($keepPluginsKey | not)) then del(.plugins) else . end
  ' "$shell_config" > "$tmp_shell"

if [[ -f $state_dir/added-clone-restore ]]; then
  next=$(mktemp "$shell_config.hive.XXXXXX")
  jq '
    .cloneSourceRestores = ((.cloneSourceRestores // []) | map(select(. != "hive.idle"))) |
    if (.cloneSourceRestores | length) == 0 then del(.cloneSourceRestores) else . end
    ' "$tmp_shell" > "$next"
  mv "$next" "$tmp_shell"
fi
if [[ -f $state_dir/replaced-workspaces ]]; then
  next=$(mktemp "$shell_config.hive.XXXXXX")
  jq '.bar.layout |= with_entries(.value |= map(if .id == "hive.workspaces" then .id = "omarchy.workspaces" else . end))' "$tmp_shell" > "$next"
  mv "$next" "$tmp_shell"
fi
if [[ -f $state_dir/disabled-stock-idle ]]; then
  next=$(mktemp "$shell_config.hive.XXXXXX")
  jq '
    .disabledPlugins = ((.disabledPlugins // []) | map(select(. != "omarchy.idle"))) |
    if (.disabledPlugins | length) == 0 then del(.disabledPlugins) else . end
    ' "$tmp_shell" > "$next"
  mv "$next" "$tmp_shell"
fi
if [[ -f $state_dir/lock-installed ]]; then
  next=$(mktemp "$shell_config.hive.XXXXXX")
  jq --argjson keepPluginsKey "$plugins_key_existed" '
    .plugins = ((.plugins // []) | map(select(.id != "hive.lock"))) |
    if ((.plugins | length) == 0 and ($keepPluginsKey | not)) then del(.plugins) else . end |
    .cloneSourceRestores = ((.cloneSourceRestores // []) | map(select(. != "hive.lock"))) |
    if (.cloneSourceRestores | length) == 0 then del(.cloneSourceRestores) else . end |
    .disabledPlugins = ((.disabledPlugins // []) | map(select(. != "omarchy.lock"))) |
    if (.disabledPlugins | length) == 0 then del(.disabledPlugins) else . end
    ' "$tmp_shell" > "$next"
  mv "$next" "$tmp_shell"
fi
if [[ -f $state_dir/prior-idle.json && -f $state_dir/installed-idle.json ]]; then
  current_idle=$(jq -c '.idle // null' "$tmp_shell")
  installed_idle=$(<"$state_dir/installed-idle.json")
  if [[ $current_idle == "$installed_idle" ]]; then
    prior_idle=$(<"$state_dir/prior-idle.json")
    next=$(mktemp "$shell_config.hive.XXXXXX")
    jq --argjson prior "$prior_idle" 'if $prior == null then del(.idle) else .idle = $prior end' "$tmp_shell" > "$next"
    mv "$next" "$tmp_shell"
  else
    echo "Idle timings changed after installation; leaving them untouched." >&2
  fi
fi
jq empty "$tmp_shell"
mv "$tmp_shell" "$shell_config"
trap - EXIT

if [[ -f $state_dir/starship-installed.sha256 ]]; then
  expected=$(<"$state_dir/starship-installed.sha256")
  actual=$([[ -f $starship_config ]] && sha256sum "$starship_config" | awk '{print $1}' || true)
  if [[ $actual == "$expected" ]]; then
    if [[ -f $state_dir/starship.before-extras.toml ]]; then
      cp -a "$state_dir/starship.before-extras.toml" "$starship_config"
    elif [[ -f $state_dir/starship-was-missing ]]; then
      rm -f -- "$starship_config"
    fi
  else
    echo "Starship configuration changed after installation; leaving it untouched." >&2
  fi
fi

tree_digest() {
  local directory=$1
  (
    cd "$directory"
    find . -type f -print0 | LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do sha256sum "$file"; done
  ) | sha256sum | awk '{print $1}'
}

remove_managed_tree() {
  local directory=$1
  local digest_file=$2
  local label=$3
  shift 3

  [[ -e $directory ]] || return 0
  local actual expected candidate matched=false
  actual=$(tree_digest "$directory")
  if [[ -f $digest_file ]]; then
    expected=$(<"$digest_file")
    [[ $actual == "$expected" ]] && matched=true
  else
    for candidate in "$@"; do
      [[ $actual == "$candidate" ]] && matched=true
    done
  fi

  if $matched; then
    rm -rf -- "$directory"
  else
    echo "Preserving modified or unverified $label files: $directory" >&2
  fi
}

# The fallback digests identify releases from the former bundled-extras layout.
remove_managed_tree "$data_dir" "$state_dir/data.sha256" "screensaver/data" \
  37b7a9fcbfbc8027afc6d143bdd6a3ded4bf8208180ebb94f017d490c42ed66f
remove_managed_tree "$plugin_dir/hive.idle" "$state_dir/hive.idle.sha256" "hive.idle" \
  0721a123b4d37c677cdb5dab8a53e8dbc1d8c5291cb74a64ec1d875fb15c73c7
remove_managed_tree "$plugin_dir/hive.workspaces" "$state_dir/hive.workspaces.sha256" "hive.workspaces" \
  13cad6f5e6519de71e52f6526ad93ccb39c80f85d302fdd9d48c928eafdf79be
if [[ -f $state_dir/lock-installed ]]; then
  remove_managed_tree "$plugin_dir/hive.lock" "$state_dir/hive.lock.sha256" "hive.lock" \
    25db51f7dfe1977e75f741457713e0df0e94ad454c191e83c104fc55c73930d3 \
    e85f75ab220e5b53bc344ad311e9e163fe720a0a232c8982fab2fffa9e40fde5
fi

rm -f -- "$state_dir"/{installed,lock-installed,data.sha256,hive.idle.sha256,hive.workspaces.sha256,hive.lock.sha256}
date -Iseconds > "$state_dir/uninstalled"
timeout 3 omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "Hive Extras removed. The base Hive theme and retained backups remain installed."
