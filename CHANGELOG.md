# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- **Linux / Proton Game Patcher (`tools/patch-proton.sh`)**:
  - Automated Bash script to patch games running under Valve's Proton with DLSS 5 Bridge.
  - Automatic system check for NVIDIA GPU and proprietary driver support via `nvidia-smi`.
  - Automatic download and extraction of missing external dependencies (`--download-deps`):
    - ReShade 64-bit with add-on support extracted from reshade.me setup installer via `7z`.
    - Standard ReShade effects and motion vector shaders (`vort_Motion.fx`) downloaded and configured in `reshade-shaders/`.
    - DLSS 5 neural add-ons (`dlssnr-linux.addon64`, `renodx-dlss5.addon64`) from GitHub and HuggingFace.
    - DLSS 5 Neural Weights (`nvngx_dlssnr.dll`, ~165MB) from HuggingFace.
    - DLSS SR (`nvngx_dlss.dll`) from local installations or HuggingFace.
  - Automatic `ReShade.ini` configuration for `EffectSearchPaths` and `TextureSearchPaths`.
  - External dependency validation (`dlss5-bridge.addon64`, ReShade with add-on support, neural add-on, `nvngx_dlssnr.dll`, and `nvngx_dlss.dll`).
  - Automatic generation of Proton-optimized `dlss5-bridge.cfg` with `unwrap=0` (preventing `vkd3d-proton` descriptor crashes) and `ofa_grid=0` (disabling unavailable hardware optical flow).
  - Backup system (`.dlss5-backup/`) with manifest tracking to safely restore original game files.
  - `--status` inspection and `--uninstall` / `--restore` commands.
  - Command line prompt for required Steam launch options (`WINEDLLOVERRIDES="dxgi=n,b" PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 %command%`).
  - Automatic binary patching of `ReShade64.dll` replacing `[fastopt]` with `[loop]` for Wine/vkd3d shader compiler compatibility (resolving `E5017: Unhandled attribute 'fastopt'`).
  - Automatic detection and installation of native Microsoft `d3dcompiler_47.dll` to resolve Wine HLSL compiler issues (`E5005: Function isnan is not defined` and `RWTexture2D.GetDimensions`).
  - Added `hash_out=0` to default `dlss5-bridge.cfg` to prevent synchronous GPU readback stalls on high-resolution framebuffers.
  - Added `DXVK_FRAME_RATE=60` to recommended Steam launch options to prevent queue flooding and compositor freezing.
  - **Automated Steam Launch Options & 3-Tier Proton Configuration**:
    - Automatic Steam AppID detection from `steamapps/appmanifest_*.acf` matching the game installation directory.
    - Automatic generation of `dxvk.conf` in the game directory setting `dxvk.enableNvapi = True` and target frame rate limit.
    - Direct injection of native DLL overrides (`dxgi`, `d3dcompiler_47`) into the Proton prefix Wine registry (`compatdata/<AppID>/pfx/user.reg`) for immediate operation without Steam restarts.
    - Non-destructive extension of Steam's `localconfig.vdf` `LaunchOptions`, preserving existing environment variables, custom paths (`STEAM_COMPAT_DATA_PATH`), wrappers (`gamemoderun`), and arguments.
    - Dedicated helper `tools/steam-config.py` handling VDF and Wine registry modification and clean reversion.
    - New CLI options: `--appid <ID>`, `--fps-cap <N>`, `--no-steam`, and `--no-dxvk-conf`.
    - Clean uninstallation (`--uninstall`) restoring original LaunchOptions and user registry state.
- **Proton Documentation (`docs/proton-guide.md`)**:
  - Detailed feasibility breakdown covering D3D11 native DLSS, D3D11 substitute path, and Vulkan limitations.
  - Complete list of external resource requirements and sources.
  - Explanation of critical Proton configuration parameters and troubleshooting advice.
  - Added troubleshooting section for `fastopt` shader compilation failure and substitute "No DLSS yet" diagnostics.
  - Added documentation for the automated Steam launch options and 3-tier Proton/DXVK configuration system.
- **Automated Test Suite (`tests/test-patch-proton.sh`)**:
  - Comprehensive unit and integration tests (14 test cases) covering argument parsing, dependency verification, mock installation, configuration generation, status inspection, backup handling, Wine compatibility binary patching, substitute preset generation, Steam AppID detection, LaunchOptions extension/reversion, and clean uninstallation.

