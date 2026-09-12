# DLSS 5 Bridge under Linux / Proton

This guide covers running **DLSS 5 Bridge** on Linux using Valve's Proton / Wine, including prerequisites, limitations, configuration, and using the automated patching script `tools/patch-proton.sh`.

---

## 1. Feasibility & Architecture Overview

DLSS 5 Bridge is a ReShade 6.0+ add-on (`.addon64`) that mirrors a DirectX 11 DLSS pipeline onto a private DirectX 12 session, allowing a compatible neural rendering add-on to execute DLSS 5 Neural Reconstruction.

Under Linux / Proton:
- **DirectX 11 (D3D11) Games with Native DLSS:**  
  **Fully Supported & Verified.** Tested on NVIDIA RTX 40-series and 50-series (see [Issue #22](https://github.com/NIGos/dlss5-bridge/issues/22)). The bridge intercepts D3D11 DLSS calls, creates a private D3D12 device managed by `vkd3d-proton`, and executes the neural evaluate pass.
- **DirectX 11 (D3D11) Games without DLSS ("Substitute Contract"):**  
  **Supported with ReShade Motion Vector Shaders.** Hardware NVIDIA Optical Flow (NVOF) via D3D11/CUDA is currently unavailable or unstable under Wine/Proton. The bridge must be configured with `ofa_grid=0` to accept motion vectors from ReShade shaders. A `nvngx_dlss.dll` (version 3.1.13 or newer) must also be placed beside the game executable.
- **Vulkan Games (`vk_mirror=1`):**  
  **Not Recommended / Blocked.** ReShade does not support local DLL proxying for Vulkan games (`dxgi.dll` has no effect on Vulkan). Vulkan requires a Vulkan layer, and Win32 shared-handle texture sharing (`VK_KHR_external_memory_win32`) between `vkd3d-proton` and native Vulkan is unsupported or brittle under Wine.

---

## 2. External Prerequisites & Resources

The following external components are required:

| Component | Description & Source | Proton Setup |
| :--- | :--- | :--- |
| **NVIDIA GPU & Driver** | RTX series GPU with proprietary NVIDIA Linux driver (>= 550 recommended). | Verify via `nvidia-smi`. Nouveau does not support DLSS/NGX. |
| **Proton with NVAPI** | Proton 8.0+, 9.0+, 10.0+ or Proton Experimental. | Requires launch option `PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1`. |
| **ReShade (Addon Build)** | ReShade 6.0+ **with full add-on support** from [reshade.me](https://reshade.me/). Standard ReShade blocks add-ons. | Installed as `dxgi.dll` (or `d3d11.dll`) in the game executable folder. |
| **DLSS 5 Neural Add-on** | `addon-dlssnr-linux.addon64` (NapXDD) or compatible `renodx-dlss5.addon64`. | Placed in the game folder. Loaded automatically by ReShade. |
| **`nvngx_dlssnr.dll`** | DLSS 5 Neural Reconstruction model weights and runtime. | Shipped with the neural add-on. Placed in the game folder. |
| **`dlss5-bridge.addon64`** | This project's add-on binary. | Placed in the game folder. |
| **`nvngx_dlss.dll`** | DLSS Super Resolution DLL (>= 3.1.13). | Required only for the substitute path (`synth=1`). |

---

## 3. Automated Patching with `patch-proton.sh`

A dedicated patching script is provided in `tools/patch-proton.sh`.

### Setup Dependencies Folder
Place the required external binaries in a `deps/` directory (either in the repository root or anywhere specified via `--deps-dir`):
```text
deps/
├── dlss5-bridge.addon64
├── ReShade64.dll (or dxgi.dll)
├── addon-dlssnr-linux.addon64 (or renodx-dlss5.addon64)
├── nvngx_dlssnr.dll
└── nvngx_dlss.dll (optional; required if using --substitute)
```

### Automated Dependency Fetching
The patcher can automatically download all missing external dependencies directly from upstream releases (ReShade with add-on support from reshade.me, neural add-ons from GitHub/HuggingFace, and neural weights):
```bash
./tools/patch-proton.sh --download-deps
```
When running the patch command on a game, any missing dependencies in `deps/` will also be downloaded automatically on the fly (unless `--no-download` is specified).

### Usage Examples

1. **Pre-download all dependencies to `./deps`:**
   ```bash
   ./tools/patch-proton.sh --download-deps
   ```

2. **Patch a game with native DLSS (D3D11):**
   ```bash
   ./tools/patch-proton.sh "/path/to/steamapps/common/GameName/bin"
   ```

2. **Patch a game without native DLSS (Substitute Mode):**
   ```bash
   ./tools/patch-proton.sh --substitute "/path/to/steamapps/common/GameName"
   ```

3. **Check status of patched files:**
   ```bash
   ./tools/patch-proton.sh --status "/path/to/steamapps/common/GameName"
   ```

4. **Uninstall and restore original files:**
   ```bash
   ./tools/patch-proton.sh --uninstall "/path/to/steamapps/common/GameName"
   ```

---

## 4. Automated Steam Launch Options & Proton/DXVK Configuration

The patch script (`patch-proton.sh`) automatically configures Steam and Proton without requiring manual input. It employs a **fail-safe 3-tier model**:

1. **Tier 1: Local `dxvk.conf` (Immediate Effect)**
   - Writes `dxvk.enableNvapi = True` and `dxvk.frameRate = 60` (configurable via `--fps-cap <N>`) directly to `dxvk.conf` in the game directory.
   - DXVK parses this file on startup, enabling NVAPI and frame limiting immediately without needing environment variables or Steam restarts.

2. **Tier 2: Proton Wine Prefix Registry (`user.reg`) (Immediate Effect)**
   - Injects native DLL overrides into the Wine registry:
     `[Software\\Wine\\DllOverrides]`
     `"dxgi"="native,builtin"`
     `"d3dcompiler_47"="native,builtin"`
   - Found at `<SteamLibrary>/steamapps/compatdata/<AppID>/pfx/user.reg`.
   - Ensures ReShade and the DirectX compiler are loaded as native libraries regardless of Steam client state.

3. **Tier 3: Steam `localconfig.vdf` (Steam Client UI Integration)**
   - Automatically detects the game's Steam AppID via `steamapps/appmanifest_*.acf`.
   - Updates the game's `LaunchOptions` in `~/.local/share/Steam/userdata/<UserID>/config/localconfig.vdf`.
   - **Non-Destructive Extension:** Existing launch options (such as `STEAM_COMPAT_DATA_PATH="..."`, `PROTON_LOG=1`, or wrappers like `gamemoderun %command%`) are fully preserved and extended:
     ```bash
     DXVK_FRAME_RATE=60 PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 WINEDLLOVERRIDES="dxgi,d3dcompiler_47=n,b" <EXISTING_OPTIONS> %command%
     ```
   - *Note:* If Steam is running during patching, restart Steam to reflect the new launch options in Steam's GUI properties. Tiers 1 and 2 take effect immediately.

### Customization Options
- `--appid <ID>`: Manually specify the Steam AppID if running in a non-standard directory.
- `--fps-cap <N>`: Adjust DXVK frame rate limiter (default: `60`, pass `0` to disable).
- `--no-steam`: Skip modifying Steam `localconfig.vdf` and Proton `user.reg`.
- `--no-dxvk-conf`: Skip generating or modifying `dxvk.conf`.

### Uninstallation & Reverting
Running `./tools/patch-proton.sh --uninstall <GAME_DIR>`:
- Restores original Steam Launch Options in `localconfig.vdf` (retaining only your custom options).
- Removes injected DLL overrides from `user.reg` while preserving any other user overrides.
- Removes `dxvk.conf` (or restores pre-patch backup if one existed).

---

## 5. Critical Proton Configuration Keys (`dlss5-bridge.cfg`)

The patcher automatically creates a Proton-optimized `dlss5-bridge.cfg`:

```ini
# dlss5-bridge keep
unwrap=0
ofa_grid=0
synth=0
source=auto
vk_mirror=0
dred=0
```

### Key Explanations
* **`unwrap=0` (MANDATORY on Proton):**  
  Under Windows, `unwrap=1` strips ReShade's D3D12 proxy to pass the native device to NGX. Under Wine / `vkd3d-proton`, unwrapping can corrupt descriptor handles or cause access violations (see ReShade PR #435). `unwrap=0` preserves ReShade's proxy, which `addon-dlssnr-linux` requires.
* **`ofa_grid=0`:**  
  Disables NVIDIA Hardware Optical Flow (which fails in Proton translation) and instructs the bridge to use ReShade motion vectors on the substitute path.
* **`vk_mirror=0`:**  
  Disables Vulkan mirroring hooks when running in D3D11 translation mode.
* **`# dlss5-bridge keep`:**  
  Prevents future bridge versions from overwriting your custom configuration on first run.

---

## 6. Verification and Troubleshooting

1. **In-game Overlay:**  
   Press `Home` (or `Pos1`) to open ReShade. Verify that both **DLSS 5 Bridge** and your neural rendering add-on appear and show active status.
2. **Logs:**  
   Inspect `dlss5-bridge.log` in the game directory. Under Proton, the log should confirm:
   ```text
   [bridge] add-on attached
     wine: <wine-version>. The D3D12 runtime here is vkd3d-proton...
     D3D12 device created at feature level 12_1 (or 12_0).
   ```
3. **Black screen or crash on startup:**  
   - Verify `WINEDLLOVERRIDES="dxgi=n,b"` is set.
   - Verify `unwrap=0` is present in `dlss5-bridge.cfg`.
   - Ensure you are using a 64-bit ReShade build with full add-on support.
4. **Shader compile error `Unhandled attribute 'fastopt'`:**
   - In ReShade 6.8.0, the internal HLSL codegen emitted `[fastopt]` for loops when targeting shader model >= 40. Wine's vkd3d-shader compiler does not yet implement `[fastopt]` and aborts with `E5017: Aborting due to not yet implemented feature: Unhandled attribute 'fastopt'`.
   - The patcher (`patch-proton.sh`) automatically patches `ReShade64.dll` to replace `[fastopt]` with `[loop]` (matching upstream ReShade PR #438).
5. **Session displays "No DLSS yet" in Substitute Mode:**
   - Check `dlss5-bridge.log`. If it reports `motion vectors (MotVectTexVort): present but NOT BOUND`, `vort_Motion.fx` either failed compilation or is not enabled in ReShade.
   - Ensure `vort_MotionEffects@vort_Motion.fx` is checked in the "Home" tab (or active in `ReShadePreset.ini`).
   - Ensure `vort_BlueNoise.png` exists in `reshade-shaders/Textures/`.
   - Once motion vectors are generated, the session status immediately updates to show active DLSS dimensions (e.g. `D3D11. 5120x1440 in, 5120x1440 out`).
6. **HLSL Compile Errors (`E5005: Function "isnan" is not defined` / `RWTexture2D.GetDimensions`):**
   - Wine's built-in `d3dcompiler_47.dll` lacks support for standard HLSL intrinsics like `isnan()` (needed by RenoDX proxy encoder) and `.GetDimensions()` on `RWTexture2D` (needed by the bridge's depth blit).
   - Solution: Install the genuine Microsoft `d3dcompiler_47.dll` (4.7 MB) into the game folder and include `d3dcompiler_47=n,b` in `WINEDLLOVERRIDES`.
7. **System Freezes / Stuttering at Ultrawide Resolutions:**
   - **GPU Readback Stalls:** Set `hash_out=0` in `dlss5-bridge.cfg`. By default, the bridge reads the entire frame back to the CPU after 60 frames for diagnostics, which stalls the GPU pipeline for several seconds on large framebuffers (like 5120x1440).
   - **Queue Flooding:** Cap the framerate using `DXVK_FRAME_RATE=60` in Steam launch options to ensure the GPU command queue does not exhaust VRAM scratch generations.
   - **DLAA vs Upscaling:** At 5120x1440, DLAA evaluates 7.37 million pixels per frame on the neural tensor network across 4 concurrent scratch buffers. Enabling upscaling in RenoDX or reducing the game's internal resolution significantly decreases VRAM consumption and frame latency.

---

## 7. In-Game Usage & ReShade Effects

### Understanding Add-ons vs. Shaders
* **Add-ons ("Add-ons" tab in ReShade):**  
  DLSS 5 Bridge and the Neural Rendering add-on run as native DLL add-ons (`.addon64`), NOT as visual screen shaders. They operate at the graphics API level.
* **Shaders / Effects ("Home" tab in ReShade):**  
  Post-processing shaders (`.fx` files located in `reshade-shaders/Shaders`).
  - **For games with native DLSS:** No additional `.fx` shaders are required for DLSS 5 to function.
  - **For games without DLSS (Substitute Mode, e.g. *He is coming*):** Since NVIDIA Hardware Optical Flow is disabled on Proton (`ofa_grid=0`), motion vectors must be generated by a ReShade shader. Enable **`vort_Motion.fx`** in the "Home" tab.

### Step-by-Step In-Game Controls
1. **Open the Overlay:** Press `Home` (or `Pos1`).
2. **Configure Add-ons ("Add-ons" Tab):**
   - **DLSS 5 Bridge:** Verify that the bridge is attached. For substitute games, confirm that *"Replace DLSS when the game isn't using its own"* is enabled.
   - **RenoDX / DLSSNR Linux:** Enable Neural Rendering. You can adjust Model Style (Default, Natural, Cinematic) and intensity sliders.
3. **Configure Motion Vectors ("Home" Tab, Substitute Mode only):**
   - Locate and check **`vort_Motion.fx`** to feed motion vectors to the bridge.
   - (Optional) Check **`DisplayDepth.fx`** to verify that ReShade can see the 3D depth buffer of the game.
4. **Compare:** Press `F10` to toggle the DLSS 5 Neural pass on and off for immediate A/B visual comparison.
