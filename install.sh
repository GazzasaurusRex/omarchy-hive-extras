#!/bin/bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}

# Keep the original application ID so existing Hive Extras installations can
# be upgraded and removed without orphaning their state.
state_dir="$state_home/omarchy-hive-theme"
data_dir="$data_home/omarchy-hive-theme"
plugin_dir="$config_home/omarchy/plugins"
shell_config="$config_home/omarchy/shell.json"
starship_config="$config_home/starship.toml"

assume_yes=false
with_starship=false
with_lock_screen=false
screensaver_seconds=""
lock_seconds=""
theme_dir_override=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --yes                     Do not ask for confirmation.
  --with-starship           Install the optional Hive Starship prompt.
  --with-lock-screen        Install the visual-only Hive lock-screen clone.
  --screensaver-seconds N   Set the idle screensaver timeout.
  --lock-seconds N          Set the idle lock timeout.
  --theme-dir PATH          Check PATH as the installed Hive base theme.
  -h, --help                Show this help.

Without timeout options, existing idle timings are preserved. Event sounds
are copied as inert assets but are never attached to desktop events.
EOF
}

while (($#)); do
  case "$1" in
    --yes) assume_yes=true; shift ;;
    --with-starship) with_starship=true; shift ;;
    --with-lock-screen) with_lock_screen=true; shift ;;
    --screensaver-seconds)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      screensaver_seconds=$2; shift 2 ;;
    --lock-seconds)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      lock_seconds=$2; shift 2 ;;
    --theme-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      theme_dir_override=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ ${EUID:-$(id -u)} -ne 0 ]] || { echo "Run this installer as your normal user, not root." >&2; exit 1; }
for value in "$screensaver_seconds" "$lock_seconds"; do
  [[ -z $value || $value =~ ^[0-9]+$ ]] || { echo "Timeouts must be whole seconds." >&2; exit 2; }
done

missing=()
for command in python3 jq omarchy omarchy-shell sha256sum find sort; do
  command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
if $with_starship && ! command -v starship >/dev/null 2>&1; then
  missing+=("starship")
fi
if ((${#missing[@]})); then
  printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
  exit 1
fi

theme_dir=$theme_dir_override
if [[ -z $theme_dir ]]; then
  theme_dir=$(omarchy theme dir hive 2>/dev/null || true)
fi
if [[ -z $theme_dir && -d $config_home/omarchy/themes/hive ]]; then
  theme_dir="$config_home/omarchy/themes/hive"
fi
if [[ ! -f $theme_dir/colors.toml || ! -d $theme_dir/backgrounds ]] \
    || ! grep -Fqx 'accent = "#b5121b"' "$theme_dir/colors.toml" \
    || ! grep -Fqx 'background = "#0b0d0f"' "$theme_dir/colors.toml"; then
  cat >&2 <<EOF
The Hive base theme is not installed or could not be verified.
Install it first with:
  omarchy theme install https://github.com/GazzasaurusRex/omarchy-hive-theme.git

Checked: ${theme_dir:-<no theme directory found>}
EOF
  exit 1
fi

if ! python3 -c 'import cairo, ctypes.util, gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk; assert ctypes.util.find_library("GL")' 2>/dev/null; then
  cat >&2 <<'EOF'
Missing a screensaver dependency. Omarchy normally provides these packages:
python, gtk4, python-gobject, python-cairo, and libglvnd.
No files were changed.
EOF
  exit 1
fi
[[ -f $shell_config ]] || { echo "Missing Omarchy shell configuration: $shell_config" >&2; exit 1; }
jq empty "$shell_config" || { echo "Invalid JSON: $shell_config" >&2; exit 1; }
for required in \
  "$repo_root/screensaver/renderer-gl.py" \
  "$repo_root/plugins/hive.idle/manifest.json" \
  "$repo_root/plugins/hive.workspaces/manifest.json" \
  "$repo_root/sounds/access-confirm.wav" \
  "$repo_root/starship/hive.toml"; do
  [[ -f $required ]] || { echo "Incomplete Hive Extras checkout: missing $required" >&2; exit 1; }
done

tree_digest() {
  local directory=$1
  (
    cd "$directory"
    find . -type f -print0 | LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do sha256sum "$file"; done
  ) | sha256sum | awk '{print $1}'
}

require_managed_tree() {
  local directory=$1
  local digest_file=$2
  local legacy_source=$3
  local label=$4
  shift 4

  [[ -d $directory ]] || { echo "Managed $label directory is missing: $directory" >&2; exit 1; }
  local actual
  actual=$(tree_digest "$directory")
  if [[ -f $digest_file ]]; then
    local expected
    expected=$(<"$digest_file")
    [[ $actual == "$expected" ]] || {
      echo "Refusing to overwrite user-modified $label files: $directory" >&2
      exit 1
    }
  elif [[ -n $legacy_source ]]; then
    local legacy
    legacy=$(tree_digest "$legacy_source")
    local matched=false candidate
    [[ $actual == "$legacy" ]] && matched=true
    for candidate in "$@"; do
      [[ $actual == "$candidate" ]] && matched=true
    done
    $matched || {
      echo "Refusing to overwrite untracked or user-modified $label files: $directory" >&2
      exit 1
    }
  else
    echo "Cannot verify ownership of $label files: $directory" >&2
    exit 1
  fi
}

fresh_install=true
[[ -f $state_dir/installed ]] && fresh_install=false

if $fresh_install; then
  for collision in "$data_dir" "$plugin_dir/hive.idle" "$plugin_dir/hive.workspaces"; do
    [[ ! -e $collision ]] || { echo "Refusing to replace pre-existing path: $collision" >&2; exit 1; }
  done
  if jq -e '
    any(.plugins[]?; .id == "hive.idle") or
    any(.cloneSourceRestores[]?; . == "hive.idle") or
    any(.bar.layout[]?[]?; .id == "hive.workspaces")
  ' "$shell_config" >/dev/null; then
    echo "Hive idle/workspace entries already exist without installer state; refusing an unsafe collision." >&2
    exit 1
  fi
else
  require_managed_tree "$plugin_dir/hive.idle" "$state_dir/hive.idle.sha256" "$repo_root/plugins/hive.idle" "hive.idle" \
    0721a123b4d37c677cdb5dab8a53e8dbc1d8c5291cb74a64ec1d875fb15c73c7
  require_managed_tree "$plugin_dir/hive.workspaces" "$state_dir/hive.workspaces.sha256" "$repo_root/plugins/hive.workspaces" "hive.workspaces"
  if [[ -f $state_dir/data.sha256 ]]; then
    require_managed_tree "$data_dir" "$state_dir/data.sha256" "" "screensaver/data"
  else
    [[ -d $data_dir/screensaver ]] || { echo "Legacy Hive screensaver data is incomplete." >&2; exit 1; }
    [[ -z $(find "$data_dir" -mindepth 1 -maxdepth 1 ! -name screensaver -print -quit) ]] || {
      echo "Refusing to overwrite untracked files in $data_dir" >&2
      exit 1
    }
    require_managed_tree "$data_dir/screensaver" "$state_dir/screensaver.sha256" "$repo_root/screensaver" "legacy screensaver" \
      a05978eaad760fa95a48bb06afeb2b879a8ddfac0da510511408d89196d895b1
  fi
fi

if $with_starship && [[ -f $state_dir/starship-installed.sha256 ]]; then
  expected=$(<"$state_dir/starship-installed.sha256")
  actual=$([[ -f $starship_config ]] && sha256sum "$starship_config" | awk '{print $1}' || true)
  [[ $actual == "$expected" ]] || {
    echo "Refusing to overwrite a Starship configuration edited after Hive Extras installation." >&2
    exit 1
  }
fi

if $with_lock_screen; then
  stock_lock_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/lock"
  hive_lock_dir="$repo_root/plugins/hive.lock"
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
No files were changed. Update Hive Extras before enabling the lock screen.
EOF
    exit 1
  fi
  omarchy plugin validate "$hive_lock_dir" >/dev/null || {
    echo "The packaged Hive lock plugin failed Omarchy validation; no files were changed." >&2
    exit 1
  }

  already_managed=false
  [[ -f $state_dir/lock-installed ]] && already_managed=true
  if $already_managed; then
    require_managed_tree "$plugin_dir/hive.lock" "$state_dir/hive.lock.sha256" "$hive_lock_dir" "hive.lock" \
      25db51f7dfe1977e75f741457713e0df0e94ad454c191e83c104fc55c73930d3 \
      e85f75ab220e5b53bc344ad311e9e163fe720a0a232c8982fab2fffa9e40fde5
  else
    [[ ! -e $plugin_dir/hive.lock ]] || { echo "Refusing to replace pre-existing plugin directory: $plugin_dir/hive.lock" >&2; exit 1; }
    if jq -e '
      ((.disabledPlugins // []) | index("omarchy.lock") != null) or
      any(.plugins[]?; .id == "hive.lock") or
      any(.cloneSourceRestores[]?; . == "hive.lock")
    ' "$shell_config" >/dev/null; then
      echo "An unmanaged lock replacement is already configured; refusing to install hive.lock." >&2
      exit 1
    fi
    shopt -s nullglob
    for manifest in "$plugin_dir"/*/manifest.json; do
      if [[ $(jq -r '.omarchy.clonedFrom // empty' "$manifest" 2>/dev/null) == "omarchy.lock" ]]; then
        echo "Another omarchy.lock clone is installed: $manifest" >&2
        exit 1
      fi
    done
    shopt -u nullglob
  fi
fi

cat <<EOF
The optional Hive Extras will:
  - use the verified base theme at $theme_dir
  - copy the GPU screensaver and inert sound assets to $data_dir
  - install the hive.idle and hive.workspaces Omarchy Shell plugins
  - disable the stock omarchy.idle service while hive.idle is enabled
  - replace an existing omarchy.workspaces bar entry with hive.workspaces
  - preserve your current idle timings unless timeout options were supplied
EOF
$with_starship && printf '  - back up and replace %s with the Hive Starship prompt\n' "$starship_config"
$with_lock_screen && cat <<EOF
  - install hive.lock as a hash-verified visual clone of Omarchy's lock service
  - disable omarchy.lock in shell.json while routing stock lock IPC to hive.lock
  - leave PAM files and the system-owned omarchy.lock plugin untouched
EOF
[[ -n $screensaver_seconds ]] && printf '  - set the screensaver timeout to %s seconds\n' "$screensaver_seconds"
[[ -n $lock_seconds ]] && printf '  - set the lock timeout to %s seconds\n' "$lock_seconds"
printf 'Backups and installation state will be stored in %s\n' "$state_dir"

if ! $assume_yes; then
  read -r -p "Continue? [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { echo "Cancelled."; exit 0; }
fi

timestamp=$(date +%Y%m%dT%H%M%S-%N)
mkdir -p "$state_dir/backups/$timestamp" "$plugin_dir" "$(dirname -- "$data_dir")"
cp -a "$shell_config" "$state_dir/backups/$timestamp/shell.json"

if $fresh_install; then
  rm -f -- "$state_dir"/{replaced-workspaces,disabled-stock-idle,added-clone-restore,prior-idle.json,installed-idle.json,plugins-key-existed,data.sha256,hive.idle.sha256,hive.workspaces.sha256,hive.lock.sha256,starship-installed.sha256,starship-was-missing,starship.before-extras.toml}
  cp -a "$shell_config" "$state_dir/shell.before-extras.json"
  jq 'has("plugins")' "$shell_config" > "$state_dir/plugins-key-existed"
  if jq -e '[.bar.layout[]?[]? | select(.id == "omarchy.workspaces")] | length > 0' "$shell_config" >/dev/null; then
    touch "$state_dir/replaced-workspaces"
  fi
  if ! jq -e '(.disabledPlugins // []) | index("omarchy.idle") != null' "$shell_config" >/dev/null; then
    touch "$state_dir/disabled-stock-idle"
  fi
  if ! jq -e '(.cloneSourceRestores // []) | index("hive.idle") != null' "$shell_config" >/dev/null; then
    touch "$state_dir/added-clone-restore"
  fi
  if [[ -n $screensaver_seconds || -n $lock_seconds ]]; then
    jq -c '.idle // null' "$shell_config" > "$state_dir/prior-idle.json"
  fi
fi

tmp_data=$(mktemp -d "$data_home/.omarchy-hive-theme.tmp.XXXXXX")
tmp_idle=$(mktemp -d "$plugin_dir/.hive.idle.tmp.XXXXXX")
tmp_workspaces=$(mktemp -d "$plugin_dir/.hive.workspaces.tmp.XXXXXX")
tmp_lock=""
tmp_shell=$(mktemp "$shell_config.hive.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_data" "$tmp_idle" "$tmp_workspaces"
  [[ -z $tmp_lock ]] || rm -rf -- "$tmp_lock"
  rm -f -- "$tmp_shell"
}
trap cleanup EXIT

cp -a "$repo_root/screensaver" "$tmp_data/"
cp -a "$repo_root/sounds" "$tmp_data/"
cp -a "$repo_root/plugins/hive.idle/." "$tmp_idle/"
cp -a "$repo_root/plugins/hive.workspaces/." "$tmp_workspaces/"
if $with_lock_screen; then
  tmp_lock=$(mktemp -d "$plugin_dir/.hive.lock.tmp.XXXXXX")
  cp -a "$repo_root/plugins/hive.lock/." "$tmp_lock/"
fi

jq \
  --arg screensaver "$screensaver_seconds" \
  --arg lock "$lock_seconds" \
  --argjson withLock "$with_lock_screen" '
  .bar.layout |= ((. // {}) | with_entries(.value |= map(if .id == "omarchy.workspaces" then .id = "hive.workspaces" else . end))) |
  .plugins = ((.plugins // []) | if any(.[]; .id == "hive.idle") then . else . + [{"id":"hive.idle"}] end) |
  .disabledPlugins = ((.disabledPlugins // []) | if index("omarchy.idle") then . else . + ["omarchy.idle"] end) |
  .cloneSourceRestores = ((.cloneSourceRestores // []) | if index("hive.idle") then . else . + ["hive.idle"] end) |
  if $withLock then
    .plugins = ((.plugins // []) | if any(.[]; .id == "hive.lock") then . else . + [{"id":"hive.lock"}] end) |
    .disabledPlugins = ((.disabledPlugins // []) | if index("omarchy.lock") then . else . + ["omarchy.lock"] end) |
    .cloneSourceRestores = ((.cloneSourceRestores // []) | if index("hive.lock") then . else . + ["hive.lock"] end)
  else . end |
  if $screensaver != "" then .idle.screensaver = ($screensaver | tonumber) else . end |
  if $lock != "" then .idle.lock = ($lock | tonumber) else . end
  ' "$shell_config" > "$tmp_shell"
jq empty "$tmp_shell"

rm -rf -- "$data_dir" "$plugin_dir/hive.idle" "$plugin_dir/hive.workspaces"
mv "$tmp_data" "$data_dir"
mv "$tmp_idle" "$plugin_dir/hive.idle"
mv "$tmp_workspaces" "$plugin_dir/hive.workspaces"
if $with_lock_screen; then
  rm -rf -- "$plugin_dir/hive.lock"
  mv "$tmp_lock" "$plugin_dir/hive.lock"
  tmp_lock=""
fi
mv "$tmp_shell" "$shell_config"
trap - EXIT

tree_digest "$data_dir" > "$state_dir/data.sha256"
tree_digest "$plugin_dir/hive.idle" > "$state_dir/hive.idle.sha256"
tree_digest "$plugin_dir/hive.workspaces" > "$state_dir/hive.workspaces.sha256"
if $with_lock_screen; then
  touch "$state_dir/lock-installed"
  tree_digest "$plugin_dir/hive.lock" > "$state_dir/hive.lock.sha256"
fi

if [[ -n $screensaver_seconds || -n $lock_seconds ]]; then
  jq -c '.idle // null' "$shell_config" > "$state_dir/installed-idle.json"
fi

if $with_starship; then
  if [[ ! -f $state_dir/starship.before-extras.toml && ! -f $state_dir/starship-was-missing ]]; then
    if [[ -f $starship_config ]]; then
      cp -a "$starship_config" "$state_dir/starship.before-extras.toml"
    else
      touch "$state_dir/starship-was-missing"
    fi
  fi
  mkdir -p "$(dirname -- "$starship_config")"
  cp -a "$repo_root/starship/hive.toml" "$starship_config"
  sha256sum "$starship_config" | awk '{print $1}' > "$state_dir/starship-installed.sha256"
fi

date -Iseconds > "$state_dir/installed"
timeout 3 omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

cat <<EOF
Hive Extras installed.
Preview: $data_dir/screensaver/hive-screensaver preview
Remove only the extras: $repo_root/uninstall.sh
EOF
