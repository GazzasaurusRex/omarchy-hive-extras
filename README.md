# Hive Extras

Hive Extras is the optional executable companion to [The Hive Omarchy
theme](https://github.com/GazzasaurusRex/omarchy-hive-theme). It contains
scripts and Omarchy Shell plugins; unlike the base theme, this repository is
code and should be reviewed before installation.

It adds:

- a hardware-accelerated GTK 4/OpenGL screensaver with five Hive scenes;
- a Hive-aware idle service and two-digit sector workspace widget;
- an opt-in custom Hive lock screen using Omarchy's stock authentication
  service implementation;
- an opt-in Starship prompt;
- three optional synthetic event sounds, installed but never bound to events.

The base theme remains a separate, declarative package. Install it first:

```bash
omarchy theme install https://github.com/GazzasaurusRex/omarchy-hive-theme.git
```

The installer verifies that the installed `hive` theme contains the expected
Hive palette and backgrounds. Hive Extras does not need to live inside the
theme directory and does not write to it.

## Install

Clone this repository anywhere in your home directory, review the scripts,
then run:

```bash
git clone https://github.com/GazzasaurusRex/omarchy-hive-extras.git
cd omarchy-hive-extras
./install.sh
```

The default installation enables the screensaver, idle integration, and
workspace widget. Existing idle timeouts are preserved. Useful options:

```text
--with-lock-screen        Enable the custom visual lock screen
--with-starship           Back up and install the Hive Starship prompt
--screensaver-seconds N   Set the screensaver idle timeout
--lock-seconds N          Set the lock idle timeout
--theme-dir PATH          Verify a Hive theme at an explicit path
--yes                     Run non-interactively
```

For the original timing and all opt-in presentation features:

```bash
./install.sh --with-lock-screen --with-starship \
  --screensaver-seconds 150 --lock-seconds 300
```

The scripts honor `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME`,
falling back to the usual locations under `$HOME`. The stable data/state name
`omarchy-hive-theme` is retained so installations made before the repository
split can be upgraded or removed safely.

## Dependencies

Hive Extras expects an Omarchy user session and these commands/libraries:

- Bash, coreutils, `find`, `sort`, and `jq`;
- `omarchy` and `omarchy-shell`;
- Python 3, GTK 4, PyGObject (`python-gobject`), and pycairo (`python-cairo`);
- OpenGL through `libglvnd` and a Wayland/OpenGL driver supporting OpenGL 3.3+;
- Starship only when `--with-starship` is selected.

The installer checks dependencies before changing files. It does not install
packages and does not use `sudo`.

## Files and rollback

The installer manages only user-owned paths:

- `${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json`;
- `${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/hive.*`;
- `${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-hive-theme/`;
- `${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml` when requested;
- `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-hive-theme/` for state and
  timestamped backups.

It preserves unrelated Shell keys, plugins, and bar items. Pre-existing Hive
paths or unmanaged Hive entries are treated as unsafe collisions. Re-running
the installer is supported when its managed files are unchanged; if a managed
plugin or Starship file was edited, the installer refuses to overwrite it.

To remove all enabled extras while keeping the base theme:

```bash
./uninstall.sh
```

The uninstaller reverses only entries recorded by the installer. Idle timings
and Starship are restored only when they still match the installed values.
Modified Hive-owned files are disconnected but retained and reported instead
of being deleted. Backups remain in the state directory for manual recovery.

## Screensaver

The renderer keeps static scene content cached and animates CRT scanlines,
sweep, noise, glow, vignette, interference, and scene transitions in a small
GLSL pass at approximately 24 FPS. GTK selects the system's normal OpenGL
device; there are no Intel, AMD, or NVIDIA-specific paths. Each monitor gets a
fullscreen surface, with aspect fitting and letterboxing where necessary.

Scenes:

- Hive Security Terminal
- Biological Containment Lockdown
- T-virus Diagnostic
- Red Queen AI Core
- Hive CCTV Surveillance

Preview it manually after installation:

```bash
${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-hive-theme/screensaver/hive-screensaver preview
```

Pointer movement, clicks, scrolling, or a key press dismisses the preview.
When another theme is active, the dispatcher falls back to Omarchy's stock
screensaver.

## Custom lock screen

The lock screen is separately opt-in because it handles authentication UI:

```bash
./lock-screen-enable.sh
```

`hive.lock` packages a byte-for-byte copy of the supported stock Omarchy
`Service.qml` and replaces only the visual `LockView.qml`. Before installation,
the script verifies both the packaged and locally installed service against the
recorded SHA-256. If Omarchy has changed the service, installation stops until
Hive Extras is reviewed and rebased.

Restore the stock lock presentation without removing the other extras:

```bash
./lock-screen-disable.sh
```

The scripts never edit PAM files, fingerprint enrollment, `/usr/share/omarchy`,
or any other system-owned file. Omarchy's stock PAM service and session-lock
flow remain in use.

## Idle and workspace integrations

`hive.idle` replaces the stock idle service through Omarchy's supported user
plugin configuration. It launches the Hive screensaver only while the Hive
theme is active, keeps the normal lock deadline, respects Stay Awake, and uses
the stock `omarchy-system-lock` command. `hive.workspaces` replaces an existing
`omarchy.workspaces` bar item in place so its section and neighboring widgets
remain unchanged.

The defaults are 150 seconds for the screensaver and 300 seconds for lock only
when no valid values exist. Existing configured values are otherwise retained
unless timeout flags are supplied.

## Starship prompt

`--with-starship` backs up the current `starship.toml` (or records that it was
absent) and installs `starship/hive.toml`. Uninstall restores the backup only
if the installed Hive prompt has not since been edited.

## Sounds

The three WAV cues under `sounds/` are copied to the data directory but remain
disabled. Preview one with:

```bash
pw-play "${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-hive-theme/sounds/access-confirm.wav"
```

No hooks or event bindings are installed. If you bind sounds yourself, prefer
rare explicit events rather than clicks, focus changes, typing, or recurring
notifications.

## Security model

- No root privileges or `sudo` calls.
- No PAM or system-owned Omarchy modifications.
- Dependency, theme, JSON, collision, and lock-service checks occur before
  configuration changes.
- Timestamped `shell.json` backups are retained.
- Plugin and data digests prevent silent overwrites or deletion of user edits.
- Shell changes target only Hive plugin IDs and installer-owned stock entries.

## Troubleshooting

**The installer cannot verify the base theme**

Run `omarchy theme dir hive` and confirm that it contains `colors.toml` and
`backgrounds/`. Reinstall the base theme if necessary, or pass its path with
`--theme-dir`.

**A screensaver dependency is missing**

Confirm `python`, `gtk4`, `python-gobject`, `python-cairo`, and `libglvnd` are
installed. The installer intentionally does not invoke a package manager.

**OpenGL context creation fails or the display is black**

Update the active Mesa/NVIDIA driver and verify that ordinary GTK 4 OpenGL
applications work in the Wayland session. No CPU-heavy fallback is provided.

**The lock-service hash does not match**

Omarchy has updated its authentication service. Keep the stock lock screen and
update Hive Extras when a compatible revision is available; do not bypass the
hash check.

**The screensaver never starts automatically**

Check `omarchy-shell idle status`. An `"enabled": false` result means Stay
Awake is suppressing idle timers. Disable Stay Awake from the bar and retry.

**The shell did not reload a plugin**

Run:

```bash
omarchy-shell shell rescanPlugins
```

## Licensing

Code and configuration are MIT licensed. Original audio assets are CC BY 4.0
to the extent the author can license them. See `LICENSE`, `LICENSE-ASSETS.md`,
and `NOTICE`.
