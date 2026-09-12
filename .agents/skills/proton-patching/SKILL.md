---
name: proton-patching
description: >-
  Use when patching Windows games for Linux/Proton compatibility in the dlss5-bridge project.
  Covers the full workflow: downloading DLSS5 + ReShade, patching game directories,
  configuring dxvk.conf, injecting Wine prefix (user.reg) DLL overrides, and
  non-destructively extending Steam LaunchOptions via tools/steam-config.py.
  Activate for any task involving patch-proton.sh, steam-config.py, Proton/DXVK,
  or Steam localconfig.vdf modifications.
---

# Proton Patching Workflow

## Core Tools

| Tool | Purpose |
|---|---|
| `tools/patch-proton.sh` | Main patch script (Tier 1: files, Tier 2: user.reg, Tier 3: localconfig.vdf) |
| `tools/steam-config.py` | VDF & user.reg CLI helper (`update-vdf`, `revert-vdf`, `get-vdf`, `update-reg`, `revert-reg`, `get-reg`) |
| `tests/test-patch-proton.sh` | Integration tests (14 tests) — always run after changes |

## Patch Workflow

```bash
# Install patch
bash tools/patch-proton.sh --appid <STEAMAPPID> --fps-cap 60 /path/to/game

# Check status
bash tools/patch-proton.sh --status /path/to/game

# Uninstall (fully reverts all 3 tiers)
bash tools/patch-proton.sh --uninstall /path/to/game
```

### CLI Options

| Option | Default | Description |
|---|---|---|
| `--appid <ID>` | auto-detect | Steam App ID (auto-detected from `appmanifest_*.acf`) |
| `--fps-cap <N>` | `60` | FPS cap written to `dxvk.conf` |
| `--no-steam` | off | Skip Tier 2 & 3 (user.reg + localconfig.vdf) |
| `--no-dxvk-conf` | off | Skip `dxvk.conf` generation |

## 3-Tier Configuration Levels

1. **Tier 1 — Game files:** `dxgi.dll`, `nvngx_dlss.dll`, `NvNGX_D3D11.dll`, `reshade-shaders/`, `reshade.ini`
2. **Tier 2 — Wine Prefix:** `user.reg` → `[Software\\Wine\\DllOverrides]`
   - `"dxgi"="native,builtin"`
   - `"d3dcompiler_47"="native,builtin"`
3. **Tier 3 — Steam LaunchOptions:** `localconfig.vdf` — **non-destructive extension only**
   - Existing options (`STEAM_COMPAT_DATA_PATH`, `gamemoderun`, `PROTON_LOG=1`, post-`%command%` args) are preserved
   - Only missing DLSS5 env vars and `WINEDLLOVERRIDES` entries are added

## Critical Implementation Details

### VDF Quote Encoding
`localconfig.vdf` stores inner quotes as `\"` (backslash-escaped).
In Python, always convert on read/write:
```python
# Reading from VDF
value = raw_value.replace(r'\"', '"')

# Writing back to VDF
raw_value = value.replace('"', r'\"')
```
Forgetting this causes assertion failures when comparing expected vs. actual LaunchOptions.

### Bash — Safe Empty Array Expansion
`"${arr[@]:-}"` passes one empty string argument when the array is empty — **wrong** when calling Python CLIs.
Correct idiom (passes nothing when empty, all elements when set):
```bash
${arr[@]+"${arr[@]}"}
```

### Test Environment Isolation
Tests inject mock paths via env vars so `find_steam_user_vdfs()` and `find_proton_prefix_reg()` return test paths instead of real system files:
```bash
STEAM_VDF_PATH=/tmp/.../localconfig.vdf \
STEAM_USER_REG=/tmp/.../user.reg \
bash tools/patch-proton.sh --appid 12345 /tmp/game-dir
```

## Running Tests

```bash
bash tests/test-patch-proton.sh
# Expected: 14/14 tests passed
```

## Typical Steam Paths on Linux

```
# Standard Steam
/mnt/<UUID>/SteamLibrary/steamapps/common/<GameName>/
~/.local/share/Steam/steamapps/common/<GameName>/

# Flatpak Steam
~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/<GameName>/

# localconfig.vdf
~/.local/share/Steam/userdata/<userid>/config/localconfig.vdf

# Proton Prefix user.reg
~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/user.reg
```

AppID is auto-detected from `appmanifest_*.acf` in the `steamapps/` directory — no manual lookup required.

## Steam VDF Cache Note
- Tier 1 (`dxvk.conf`) and Tier 2 (`user.reg`) take effect immediately.
- Tier 3 (`localconfig.vdf`) requires a **Steam restart** for the GUI to reflect the change, but DLL overrides and DXVK settings work without restart.
