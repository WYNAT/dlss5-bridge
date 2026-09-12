#!/usr/bin/env bash
#
# patch-proton.sh - Patch games for DLSS 5 Bridge compatibility under Linux / Proton
#
# Usage:
#   ./tools/patch-proton.sh [OPTIONS] <GAME_DIRECTORY>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_CYAN="\033[36m"
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
fi

log_info() { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_err()  { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

print_usage() {
    echo -e "${C_BOLD}DLSS 5 Bridge - Linux / Proton Game Patcher${C_RESET}"
    echo ""
    echo -e "${C_BOLD}USAGE:${C_RESET}"
    echo "    $(basename "$0") [OPTIONS] <GAME_DIR>"
    echo ""
    echo -e "${C_BOLD}ARGUMENTS:${C_RESET}"
    echo "    <GAME_DIR>              Path to the game directory containing the main executable."
    echo ""
    echo -e "${C_BOLD}OPTIONS:${C_RESET}"
    echo "    -d, --deps-dir <DIR>    Directory containing external dependencies (default: ./deps or script directory)"
    echo "    -p, --proxy <TYPE>      ReShade proxy DLL name: 'dxgi' (default) or 'd3d11'"
    echo "    -s, --substitute        Enable substitute path for games without native DLSS (sets synth=1, ofa_grid=0)"
    echo "        --download-deps     Download all missing DLSS 5 external dependencies to deps directory and exit"
    echo "        --no-download       Do not automatically download missing dependencies when patching"
    echo "        --status            Check DLSS 5 patch status in the specified game directory"
    echo "        --appid <ID>        Explicit Steam AppID (auto-detected from steamapps if omitted)"
    echo "        --fps-cap <N>       Target DXVK Frame Rate cap (default: 60, set 0 to disable)"
    echo "        --no-steam          Skip modifying Steam Launch Options and Proton Wine prefix user.reg"
    echo "        --no-dxvk-conf      Skip creating or updating dxvk.conf in game directory"
    echo "    -u, --uninstall         Restore original files and remove DLSS 5 / ReShade files"
    echo "    -f, --force             Overwrite existing files without prompting"
    echo "        --skip-system-check Skip NVIDIA GPU / driver checks"
    echo "    -h, --help              Show this help message"
    echo ""
    echo -e "${C_BOLD}EXTERNAL RESOURCES (AUTOMATICALLY FETCHED IF MISSING):${C_RESET}"
    echo "    1. dlss5-bridge.addon64         (GitHub releases / local build)"
    echo "    2. ReShade64.dll or dxgi.dll    (ReShade 6.0+ WITH ADDON SUPPORT from reshade.me)"
    echo "    3. renodx-dlss5.addon64         (DLSS 5 neural add-on from NapXDD / HuggingFace)"
    echo "    4. nvngx_dlssnr.dll             (DLSS 5 Neural weights model, ~165MB)"
    echo "    5. nvngx_dlss.dll               (DLSS SR library, required for --substitute)"
    echo ""
    echo -e "${C_BOLD}STEAM LAUNCH OPTIONS AUTOMATION:${C_RESET}"
    echo "    The script automatically configures Steam Launch Options and Proton prefix overrides."
    echo "    Existing options (e.g. STEAM_COMPAT_DATA_PATH=... %command%) are preserved and extended."
}

# Defaults
GAME_DIR=""
DEPS_DIR=""
PROXY_TYPE="dxgi"
SUBSTITUTE_MODE=0
ACTION="install"
FORCE=0
SKIP_SYS_CHECK=0
AUTO_DOWNLOAD=1
APP_ID=""
FPS_CAP=60
AUTO_STEAM=1
APPLY_DXVK=1

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_usage
            exit 0
            ;;
        -d|--deps-dir)
            DEPS_DIR="$2"
            shift 2
            ;;
        -p|--proxy)
            PROXY_TYPE="$2"
            if [[ "$PROXY_TYPE" != "dxgi" && "$PROXY_TYPE" != "d3d11" ]]; then
                log_err "Invalid proxy type '$PROXY_TYPE'. Must be 'dxgi' or 'd3d11'."
                exit 1
            fi
            shift 2
            ;;
        -s|--substitute)
            SUBSTITUTE_MODE=1
            shift
            ;;
        --download-deps|--fetch-deps)
            ACTION="download_deps"
            shift
            ;;
        --no-download)
            AUTO_DOWNLOAD=0
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --appid)
            APP_ID="$2"
            shift 2
            ;;
        --fps-cap)
            FPS_CAP="$2"
            shift 2
            ;;
        --no-steam)
            AUTO_STEAM=0
            shift
            ;;
        --no-dxvk-conf)
            APPLY_DXVK=0
            shift
            ;;
        -u|--uninstall|--restore)
            ACTION="uninstall"
            shift
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        --skip-system-check)
            SKIP_SYS_CHECK=1
            shift
            ;;
        -*)
            log_err "Unknown option: $1"
            print_usage
            exit 1
            ;;
        *)
            if [[ -z "$GAME_DIR" ]]; then
                GAME_DIR="$1"
            else
                log_err "Unexpected argument: $1"
                print_usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ "$ACTION" != "download_deps" ]]; then
    if [[ -z "$GAME_DIR" ]]; then
        log_err "Missing <GAME_DIR> argument."
        print_usage
        exit 1
    fi

    if [[ ! -d "$GAME_DIR" ]]; then
        log_err "Game directory does not exist: $GAME_DIR"
        exit 1
    fi

    # Resolve absolute path for game directory
    GAME_DIR="$(cd "$GAME_DIR" && pwd)"
    BACKUP_DIR="${GAME_DIR}/.dlss5-backup"
    MANIFEST_FILE="${GAME_DIR}/.dlss5-installed.txt"
fi

# 1. System Requirements Check
check_system() {
    if [[ "$SKIP_SYS_CHECK" -eq 1 ]]; then
        log_info "Skipping system check (--skip-system-check)."
        return 0
    fi

    log_info "Checking system environment for NVIDIA DLSS support..."
    if ! command -v nvidia-smi &>/dev/null; then
        log_warn "nvidia-smi not found. Ensure the proprietary NVIDIA driver is installed."
        log_warn "Nouveau or non-NVIDIA GPUs do NOT support DLSS 5 Neural Rendering."
        return 0
    fi

    local gpu_info driver_ver
    gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || echo "Unknown NVIDIA GPU")
    driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 || echo "0")

    log_ok "Detected GPU: ${C_BOLD}${gpu_info}${C_RESET} (Driver version: ${driver_ver})"

    # Check driver major version (recommend >= 550)
    local major_ver="${driver_ver%%.*}"
    if [[ "$major_ver" =~ ^[0-9]+$ ]] && [[ "$major_ver" -lt 550 ]]; then
        log_warn "NVIDIA Driver ${driver_ver} is older than recommended (>= 550.x)."
        log_warn "DLSS 5 features and modern Proton translations may require newer drivers."
    fi
}

# Find dependencies
locate_deps() {
    local candidates=()
    if [[ -n "$DEPS_DIR" ]]; then
        candidates+=("$DEPS_DIR")
    else
        candidates+=(
            "${GAME_DIR}/deps"
            "${REPO_ROOT}/deps"
            "${REPO_ROOT}"
            "${SCRIPT_DIR}"
        )
    fi

    FOUND_BRIDGE=""
    FOUND_RESHADE=""
    FOUND_NEURAL=""
    FOUND_DLSSNR=""
    FOUND_DLSS=""
    FOUND_SHADERS=""
    FOUND_COMPILER=""

    for dir in "${candidates[@]}"; do
        [[ -d "$dir" ]] || continue

        # 1. dlss5-bridge.addon64
        if [[ -z "$FOUND_BRIDGE" && -f "${dir}/dlss5-bridge.addon64" ]]; then
            FOUND_BRIDGE="${dir}/dlss5-bridge.addon64"
        fi

        # 2. ReShade (Addon version)
        if [[ -z "$FOUND_RESHADE" ]]; then
            if [[ -f "${dir}/ReShade64.dll" ]]; then
                FOUND_RESHADE="${dir}/ReShade64.dll"
            elif [[ -f "${dir}/dxgi.dll" && "$dir" != "$GAME_DIR" ]]; then
                FOUND_RESHADE="${dir}/dxgi.dll"
            elif [[ -f "${dir}/d3d11.dll" && "$dir" != "$GAME_DIR" ]]; then
                FOUND_RESHADE="${dir}/d3d11.dll"
            fi
        fi

        # 3. Neural Add-on (renodx-dlss5 or addon-dlssnr-linux)
        if [[ -z "$FOUND_NEURAL" ]]; then
            local neural_candidate
            neural_candidate=$(find "$dir" -maxdepth 1 \( -name "*dlssnr*.addon64" -o -name "*dlss5*.addon64" \) ! -name "dlss5-bridge*" 2>/dev/null | head -n 1 || true)
            if [[ -n "$neural_candidate" && -f "$neural_candidate" ]]; then
                FOUND_NEURAL="$neural_candidate"
            fi
        fi

        # 4. nvngx_dlssnr.dll
        if [[ -z "$FOUND_DLSSNR" && -f "${dir}/nvngx_dlssnr.dll" ]]; then
            FOUND_DLSSNR="${dir}/nvngx_dlssnr.dll"
        fi

        # 5. nvngx_dlss.dll
        if [[ -z "$FOUND_DLSS" && -f "${dir}/nvngx_dlss.dll" ]]; then
            FOUND_DLSS="${dir}/nvngx_dlss.dll"
        fi

        # 6. reshade-shaders directory
        if [[ -z "$FOUND_SHADERS" && -d "${dir}/reshade-shaders" ]]; then
            FOUND_SHADERS="${dir}/reshade-shaders"
        fi

        # 7. d3dcompiler_47.dll (native Microsoft DirectX shader compiler)
        if [[ -z "$FOUND_COMPILER" && -f "${dir}/d3dcompiler_47.dll" ]]; then
            FOUND_COMPILER="${dir}/d3dcompiler_47.dll"
        fi
    done

    if [[ -z "$FOUND_COMPILER" && -n "${GAME_DIR:-}" ]]; then
        if [[ -f "${GAME_DIR}/d3dcompiler_47.dll" ]]; then
            FOUND_COMPILER="${GAME_DIR}/d3dcompiler_47.dll"
        fi
    fi
}

# Dependency Fetching / Automatic Download
download_file() {
    local url="$1"
    local dest="$2"
    local desc="$3"
    log_info "Downloading ${desc}..."
    if command -v curl &>/dev/null; then
        curl -f -L -# -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "$dest" "$url"
    else
        log_err "Neither curl nor wget found. Cannot download $desc."
        return 1
    fi
}

fetch_reshade() {
    local target_dir="$1"
    local tmp_dir
    tmp_dir=$(mktemp -d -t reshade-download-XXXXXX)
    trap 'rm -rf "$tmp_dir"' RETURN

    log_info "Fetching latest ReShade (with add-on support)..."
    local setup_url="https://reshade.me/downloads/ReShade_Setup_6.8.0_Addon.exe"
    local latest_detected
    latest_detected=$(curl -s "https://reshade.me" 2>/dev/null | grep -o -E "ReShade_Setup_[0-9]+\.[0-9]+\.[0-9]+_Addon\.exe" | head -n 1 || true)
    if [[ -n "$latest_detected" ]]; then
        setup_url="https://reshade.me/downloads/${latest_detected}"
    fi

    download_file "$setup_url" "${tmp_dir}/setup.exe" "ReShade Setup Installer"

    local p7z=""
    if command -v 7z &>/dev/null; then
        p7z="7z"
    elif command -v 7za &>/dev/null; then
        p7z="7za"
    else
        log_err "7z or 7za is required to extract ReShade64.dll from the installer."
        return 1
    fi

    log_info "Extracting ReShade64.dll using ${p7z}..."
    "$p7z" e -y "${tmp_dir}/setup.exe" ReShade64.dll -o"$target_dir" >/dev/null
    patch_reshade_wine_compat "${target_dir}/ReShade64.dll"
    log_ok "Extracted ReShade64.dll -> ${target_dir}/ReShade64.dll"
}

patch_reshade_wine_compat() {
    local dll="$1"
    if [[ -f "$dll" ]]; then
        python3 -c "
with open('$dll', 'rb') as f:
    d = f.read()
if b'[fastopt] \x00' in d:
    d = d.replace(b'[fastopt] \x00', b'[loop]    \x00', 1)
    with open('$dll', 'wb') as f:
        f.write(d)
" 2>/dev/null || true
    fi
}

fetch_bridge() {
    local target_dir="$1"
    if [[ -f "${HOME}/Downloads/dlss5-bridge.addon64" ]]; then
        cp -p "${HOME}/Downloads/dlss5-bridge.addon64" "${target_dir}/dlss5-bridge.addon64"
        log_ok "Copied dlss5-bridge.addon64 from ~/Downloads"
    else
        download_file "https://github.com/NIGos/dlss5-bridge/releases/latest/download/dlss5-bridge.addon64" "${target_dir}/dlss5-bridge.addon64" "DLSS 5 Bridge Addon"
    fi
}

fetch_neural() {
    local target_dir="$1"
    log_info "Fetching DLSS 5 Neural Rendering add-on..."
    download_file "https://github.com/NapXDD/addon-dlssnr-linux/releases/latest/download/dlssnr-linux.addon64" "${target_dir}/dlssnr-linux.addon64" "DLSSNR Linux Addon" || \
    download_file "https://huggingface.co/Bandukids/DLSS-Runtimes/resolve/main/renodx-dlss5.addon64" "${target_dir}/renodx-dlss5.addon64" "RenoDX DLSS5 Addon"
}

fetch_dlssnr_weights() {
    local target_dir="$1"
    download_file "https://huggingface.co/Bandukids/DLSS-Runtimes/resolve/main/nvngx_dlssnr.dll" "${target_dir}/nvngx_dlssnr.dll" "DLSS 5 Neural Weights (~165MB)"
}

fetch_dlss_sr() {
    local target_dir="$1"
    local local_found
    local_found=$(find /mnt ~/.local/share/Steam -name "nvngx_dlss.dll" 2>/dev/null | head -n 1 || true)
    if [[ -n "$local_found" && -f "$local_found" ]]; then
        log_info "Found local nvngx_dlss.dll in ${local_found}, copying..."
        cp -p "$local_found" "${target_dir}/nvngx_dlss.dll"
        log_ok "Copied local nvngx_dlss.dll -> ${target_dir}/nvngx_dlss.dll"
    else
        download_file "https://huggingface.co/Bandukids/DLSS-Runtimes/resolve/main/nvngx_dlss.dll" "${target_dir}/nvngx_dlss.dll" "DLSS Super Resolution DLL"
    fi
}

fetch_shaders() {
    local target_dir="$1"
    local shaders_dir="${target_dir}/reshade-shaders"
    local tmp_dir
    tmp_dir=$(mktemp -d -t reshade-shaders-XXXXXX)
    trap 'rm -rf "$tmp_dir"' RETURN

    log_info "Fetching ReShade standard effects and motion vector shaders..."
    mkdir -p "${shaders_dir}/Shaders" "${shaders_dir}/Textures"

    # 1. Standard ReShade shaders (crosire/reshade-shaders slim)
    if download_file "https://github.com/crosire/reshade-shaders/archive/refs/heads/slim.tar.gz" "${tmp_dir}/crosire.tar.gz" "ReShade standard shaders"; then
        tar -xzf "${tmp_dir}/crosire.tar.gz" -C "$tmp_dir"
        cp -rp "${tmp_dir}/reshade-shaders-slim/Shaders/"* "${shaders_dir}/Shaders/" 2>/dev/null || true
        cp -rp "${tmp_dir}/reshade-shaders-slim/Textures/"* "${shaders_dir}/Textures/" 2>/dev/null || true
    fi

    # 2. Motion Vector shaders (vort_Shaders)
    if download_file "https://github.com/vortigern11/vort_Shaders/archive/refs/heads/master.tar.gz" "${tmp_dir}/vort.tar.gz" "vort_Shaders (Motion Vectors)"; then
        tar -xzf "${tmp_dir}/vort.tar.gz" -C "$tmp_dir"
        cp -rp "${tmp_dir}/vort_Shaders-main/Shaders/"* "${shaders_dir}/Shaders/" 2>/dev/null || true
        cp -rp "${tmp_dir}/vort_Shaders-main/Textures/"* "${shaders_dir}/Textures/" 2>/dev/null || true
    fi

    log_ok "Installed ReShade effects & motion vector shaders -> ${shaders_dir}"
}

download_all_deps() {
    local target_dir="${DEPS_DIR:-${REPO_ROOT}/deps}"
    mkdir -p "$target_dir"
    log_info "Downloading all DLSS 5 external dependencies to: ${C_BOLD}${target_dir}${C_RESET}..."

    [[ -f "${target_dir}/dlss5-bridge.addon64" ]] || fetch_bridge "$target_dir"
    [[ -f "${target_dir}/ReShade64.dll" ]] || fetch_reshade "$target_dir"
    [[ -f "${target_dir}/dlssnr-linux.addon64" || -f "${target_dir}/renodx-dlss5.addon64" ]] || fetch_neural "$target_dir"
    [[ -f "${target_dir}/nvngx_dlssnr.dll" ]] || fetch_dlssnr_weights "$target_dir"
    [[ -f "${target_dir}/nvngx_dlss.dll" ]] || fetch_dlss_sr "$target_dir"
    [[ -d "${target_dir}/reshade-shaders" ]] || fetch_shaders "$target_dir"

    log_ok "All DLSS 5 external dependencies are ready in ${target_dir}."
}

# -----------------------------------------------------------------------------
# Steam & Proton Auto-Configuration Helpers
# -----------------------------------------------------------------------------

detect_steam_appid() {
    if [[ -n "$APP_ID" ]]; then
        echo "$APP_ID"
        return 0
    fi

    local dir="$GAME_DIR"
    local curr="$dir"
    local steamapps_dir=""

    while [[ "$curr" != "/" && -n "$curr" ]]; do
        if [[ "$(basename "$curr")" == "steamapps" ]]; then
            steamapps_dir="$curr"
            break
        fi
        curr="$(dirname "$curr")"
    done

    if [[ -n "$steamapps_dir" && -d "$steamapps_dir" ]]; then
        for acf in "$steamapps_dir"/appmanifest_*.acf; do
            [[ -f "$acf" ]] || continue
            local instdir
            instdir=$(grep -i '"installdir"' "$acf" 2>/dev/null | head -n 1 | awk -F'"' '{print $4}' || true)
            if [[ -n "$instdir" ]]; then
                if [[ "$dir" == *"/common/${instdir}"* || "$dir" == *"/common/${instdir}" ]]; then
                    local id
                    id=$(grep -i '"appid"' "$acf" 2>/dev/null | head -n 1 | awk -F'"' '{print $4}' || true)
                    if [[ -n "$id" ]]; then
                        APP_ID="$id"
                        echo "$APP_ID"
                        return 0
                    fi
                fi
            fi
        done
    fi

    return 1
}

find_steam_user_vdfs() {
    local vdfs=()
    if [[ -n "${STEAM_VDF_PATH:-}" && -f "$STEAM_VDF_PATH" ]]; then
        echo "$STEAM_VDF_PATH"
        return 0
    fi

    local candidates=(
        "$HOME/.local/share/Steam/userdata"
        "$HOME/.steam/steam/userdata"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/userdata"
    )
    for base in "${candidates[@]}"; do
        if [[ -d "$base" ]]; then
            for vdf in "$base"/*/config/localconfig.vdf; do
                if [[ -f "$vdf" ]]; then
                    local canon
                    canon="$(realpath "$vdf" 2>/dev/null || echo "$vdf")"
                    local exists=0
                    for existing in "${vdfs[@]:-}"; do
                        if [[ "$existing" == "$canon" ]]; then
                            exists=1
                            break
                        fi
                    done
                    if [[ "$exists" -eq 0 ]]; then
                        vdfs+=("$canon")
                    fi
                fi
            done
        fi
    done
    printf "%s\n" "${vdfs[@]:-}"
}

find_proton_prefix_reg() {
    local appid="$1"
    [[ -z "$appid" ]] && return 1

    if [[ -n "${STEAM_USER_REG:-}" && -f "$STEAM_USER_REG" ]]; then
        echo "$STEAM_USER_REG"
        return 0
    fi

    local curr="$GAME_DIR"
    local steamapps_dir=""
    while [[ "$curr" != "/" && -n "$curr" ]]; do
        if [[ "$(basename "$curr")" == "steamapps" ]]; then
            steamapps_dir="$curr"
            break
        fi
        curr="$(dirname "$curr")"
    done

    local candidates=()
    if [[ -n "$steamapps_dir" ]]; then
        candidates+=("${steamapps_dir}/compatdata/${appid}/pfx/user.reg")
    fi
    candidates+=(
        "$HOME/.local/share/Steam/steamapps/compatdata/${appid}/pfx/user.reg"
        "$HOME/.steam/steam/steamapps/compatdata/${appid}/pfx/user.reg"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/compatdata/${appid}/pfx/user.reg"
    )

    for reg in "${candidates[@]}"; do
        if [[ -f "$reg" ]]; then
            echo "$reg"
            return 0
        fi
    done
    return 1
}

apply_dxvk_conf() {
    if [[ "$APPLY_DXVK" -eq 0 ]]; then
        return 0
    fi

    local dxvk_file="${GAME_DIR}/dxvk.conf"
    if [[ ! -f "$dxvk_file" ]]; then
        cat > "$dxvk_file" <<EOF
# Generated by dlss5-bridge
dxvk.enableNvapi = True
EOF
        if [[ "$FPS_CAP" -gt 0 ]]; then
            echo "dxvk.frameRate = ${FPS_CAP}" >> "$dxvk_file"
        fi
        record_installed "dxvk.conf"
        log_ok "Created dxvk.conf (enableNvapi=True, frameRate=${FPS_CAP})"
    else
        # Back up existing if not backed up
        if [[ ! -f "${BACKUP_DIR}/dxvk.conf" ]]; then
            mkdir -p "$BACKUP_DIR"
            cp -p "$dxvk_file" "${BACKUP_DIR}/dxvk.conf"
        fi
        if ! grep -qi "dxvk.enableNvapi" "$dxvk_file"; then
            echo "dxvk.enableNvapi = True" >> "$dxvk_file"
        fi
        if [[ "$FPS_CAP" -gt 0 ]] && ! grep -qi "dxvk.frameRate" "$dxvk_file"; then
            echo "dxvk.frameRate = ${FPS_CAP}" >> "$dxvk_file"
        fi
        record_installed "dxvk.conf"
        log_ok "Updated dxvk.conf with NVAPI and frameRate settings."
    fi
}

apply_steam_configurations() {
    if [[ "$AUTO_STEAM" -eq 0 ]]; then
        log_info "Skipping Steam auto-configuration (--no-steam)."
        return 0
    fi

    APP_ID="$(detect_steam_appid || true)"
    if [[ -z "$APP_ID" ]]; then
        log_info "Could not detect Steam AppID for game directory. Skipping Steam launch options."
        log_info "(Use --appid <ID> to manually specify the Steam AppID)."
        return 0
    fi

    log_info "Detected Steam AppID: ${C_BOLD}${APP_ID}${C_RESET}"

    if ! command -v python3 &>/dev/null; then
        log_warn "python3 not found; skipping automatic VDF / user.reg configuration."
        return 0
    fi

    local compiler_arg=()
    if [[ -n "${FOUND_COMPILER:-}" || -f "${GAME_DIR}/d3dcompiler_47.dll" ]]; then
        compiler_arg=("--compiler")
    fi

    # 1. Update Proton Wine prefix user.reg DLL overrides
    local reg_file
    reg_file=$(find_proton_prefix_reg "$APP_ID" || true)
    if [[ -n "$reg_file" ]]; then
        local reg_res
        reg_res=$(python3 "${SCRIPT_DIR}/steam-config.py" update-reg --reg "$reg_file" --proxy "$PROXY_TYPE" ${compiler_arg[@]+"${compiler_arg[@]}"})
        if [[ "$reg_res" == "OK" ]]; then
            log_ok "Injected DLL overrides (dxgi/d3dcompiler_47) into Proton prefix user.reg: ${reg_file}"
        fi
    else
        log_info "No existing Proton prefix user.reg found for AppID ${APP_ID} (game might not have been launched yet)."
    fi

    # 2. Update Steam localconfig.vdf Launch Options
    local vdf_files
    mapfile -t vdf_files < <(find_steam_user_vdfs)
    if [[ ${#vdf_files[@]} -gt 0 ]]; then
        for vdf in "${vdf_files[@]}"; do
            [[ -f "$vdf" ]] || continue
            local updated_opts
            updated_opts=$(python3 "${SCRIPT_DIR}/steam-config.py" update-vdf --vdf "$vdf" --appid "$APP_ID" --proxy "$PROXY_TYPE" --fps "$FPS_CAP" ${compiler_arg[@]+"${compiler_arg[@]}"})
            log_ok "Updated Steam Launch Options in ${vdf}:"
            echo -e "      ${C_CYAN}${updated_opts}${C_RESET}"
        done
    else
        log_warn "No Steam localconfig.vdf files found to update."
    fi
}

revert_steam_configurations() {
    APP_ID="$(detect_steam_appid || true)"
    if [[ -z "$APP_ID" ]]; then
        return 0
    fi

    if ! command -v python3 &>/dev/null; then
        return 0
    fi

    local compiler_arg=()
    if [[ -f "${GAME_DIR}/d3dcompiler_47.dll" || -f "${BACKUP_DIR}/d3dcompiler_47.dll" ]]; then
        compiler_arg=("--compiler")
    fi

    # 1. Revert user.reg
    local reg_file
    reg_file=$(find_proton_prefix_reg "$APP_ID" || true)
    if [[ -n "$reg_file" ]]; then
        python3 "${SCRIPT_DIR}/steam-config.py" revert-reg --reg "$reg_file" --proxy "$PROXY_TYPE" ${compiler_arg[@]+"${compiler_arg[@]}"} >/dev/null || true
        log_info "Reverted DLSS 5 DLL overrides from Proton prefix user.reg."
    fi

    # 2. Revert localconfig.vdf
    local vdf_files
    mapfile -t vdf_files < <(find_steam_user_vdfs)
    for vdf in "${vdf_files[@]:-}"; do
        [[ -f "$vdf" ]] || continue
        local rev_opts
        rev_opts=$(python3 "${SCRIPT_DIR}/steam-config.py" revert-vdf --vdf "$vdf" --appid "$APP_ID" --proxy "$PROXY_TYPE" ${compiler_arg[@]+"${compiler_arg[@]}"})
        if [[ -n "$rev_opts" ]]; then
            log_info "Restored original Steam Launch Options in ${vdf}:"
            echo -e "      ${C_CYAN}${rev_opts}${C_RESET}"
        else
            log_info "Removed DLSS 5 Steam Launch Options from ${vdf}."
        fi
    done
}

# Status Check
check_status() {
    log_info "Inspecting game directory: ${C_BOLD}${GAME_DIR}${C_RESET}"
    echo ""
    echo "--- File Status ---"

    local proxy_file="${GAME_DIR}/${PROXY_TYPE}.dll"
    if [[ -f "$proxy_file" ]]; then
        echo -e "Proxy DLL (${PROXY_TYPE}.dll):         ${C_GREEN}Present${C_RESET} ($(stat -c %s "$proxy_file" 2>/dev/null || stat -f %z "$proxy_file") bytes)"
    else
        echo -e "Proxy DLL (${PROXY_TYPE}.dll):         ${C_YELLOW}Not present${C_RESET}"
    fi

    if [[ -f "${GAME_DIR}/dlss5-bridge.addon64" ]]; then
        echo -e "DLSS 5 Bridge addon:              ${C_GREEN}Present${C_RESET}"
    else
        echo -e "DLSS 5 Bridge addon:              ${C_YELLOW}Not present${C_RESET}"
    fi

    local neural_in_game
    neural_in_game=$(find "$GAME_DIR" -maxdepth 1 \( -name "*dlssnr*.addon64" -o -name "*dlss5*.addon64" \) ! -name "dlss5-bridge*" 2>/dev/null | head -n 1 || true)
    if [[ -n "$neural_in_game" ]]; then
        echo -e "Neural rendering addon:           ${C_GREEN}Present${C_RESET} ($(basename "$neural_in_game"))"
    else
        echo -e "Neural rendering addon:           ${C_YELLOW}Not present${C_RESET}"
    fi

    if [[ -f "${GAME_DIR}/nvngx_dlssnr.dll" ]]; then
        echo -e "Neural weights (nvngx_dlssnr.dll):${C_GREEN}Present${C_RESET}"
    else
        echo -e "Neural weights (nvngx_dlssnr.dll):${C_YELLOW}Not present${C_RESET}"
    fi

    if [[ -f "${GAME_DIR}/nvngx_dlss.dll" ]]; then
        echo -e "DLSS SR (nvngx_dlss.dll):         ${C_GREEN}Present${C_RESET}"
    else
        echo -e "DLSS SR (nvngx_dlss.dll):         ${C_YELLOW}Not present (Required if using substitute mode)${C_RESET}"
    fi

    if [[ -f "${GAME_DIR}/dlss5-bridge.cfg" ]]; then
        echo -e "Configuration (dlss5-bridge.cfg): ${C_GREEN}Present${C_RESET}"
        echo "----------------------------------------"
        echo "Config contents:"
        cat "${GAME_DIR}/dlss5-bridge.cfg"
        echo "----------------------------------------"
    else
        echo -e "Configuration (dlss5-bridge.cfg): ${C_YELLOW}Not present${C_RESET}"
    fi

    if [[ -d "$BACKUP_DIR" ]]; then
        echo -e "Backup directory:                 ${C_CYAN}Present${C_RESET} (${BACKUP_DIR})"
    fi

    echo ""
    echo "--- Steam & Proton Configuration ---"
    local appid
    appid=$(detect_steam_appid || true)
    if [[ -n "$appid" ]]; then
        echo -e "Steam AppID:                      ${C_GREEN}${appid}${C_RESET}"
    else
        echo -e "Steam AppID:                      ${C_YELLOW}Not detected (Game not in standard Steam library)${C_RESET}"
    fi

    if [[ -f "${GAME_DIR}/dxvk.conf" ]]; then
        echo -e "DXVK Configuration (dxvk.conf):   ${C_GREEN}Present${C_RESET}"
        echo "----------------------------------------"
        cat "${GAME_DIR}/dxvk.conf"
        echo "----------------------------------------"
    else
        echo -e "DXVK Configuration (dxvk.conf):   ${C_YELLOW}Not present${C_RESET}"
    fi

    if [[ -n "$appid" ]]; then
        local reg_file
        reg_file=$(find_proton_prefix_reg "$appid" || true)
        if [[ -n "$reg_file" ]]; then
            echo -e "Proton user.reg:                  ${C_GREEN}Present${C_RESET} (${reg_file})"
            if command -v python3 &>/dev/null; then
                local overrides
                overrides=$(python3 "${SCRIPT_DIR}/steam-config.py" get-reg --reg "$reg_file" 2>/dev/null || true)
                echo -e "Wine DLL Overrides:               ${C_CYAN}${overrides:-None}${C_RESET}"
            fi
        else
            echo -e "Proton user.reg:                  ${C_YELLOW}Not found${C_RESET}"
        fi

        if command -v python3 &>/dev/null; then
            local vdf_files
            mapfile -t vdf_files < <(find_steam_user_vdfs)
            for vdf in "${vdf_files[@]:-}"; do
                [[ -f "$vdf" ]] || continue
                local lopts
                lopts=$(python3 "${SCRIPT_DIR}/steam-config.py" get-vdf --vdf "$vdf" --appid "$appid" 2>/dev/null || true)
                echo -e "Steam Launch Options (${vdf}):"
                echo -e "  ${C_CYAN}${lopts:-[None]}${C_RESET}"
            done
        fi
    fi
}

# Uninstall / Restore
do_uninstall() {
    log_info "Uninstalling DLSS 5 Bridge from: ${C_BOLD}${GAME_DIR}${C_RESET}"

    # Revert Steam launch options and Wine registry overrides
    revert_steam_configurations

    local files_to_remove=(
        "dlss5-bridge.addon64"
        "dlss5-bridge.cfg"
        "dlss5-bridge.log"
        "ReShade.ini"
        "ReShade.log"
        "dxvk.conf"
    )

    # Read installed files from manifest if present
    if [[ -f "$MANIFEST_FILE" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && files_to_remove+=("$line")
        done < "$MANIFEST_FILE"
    else
        # Fallback heuristic
        files_to_remove+=("${PROXY_TYPE}.dll" "nvngx_dlssnr.dll")
        local neural_in_game
        neural_in_game=$(find "$GAME_DIR" -maxdepth 1 \( -name "*dlssnr*.addon64" -o -name "*dlss5*.addon64" \) ! -name "dlss5-bridge*" 2>/dev/null | head -n 1 || true)
        if [[ -n "$neural_in_game" ]]; then
            files_to_remove+=("$(basename "$neural_in_game")")
        fi
    fi

    # Deduplicate files_to_remove
    local unique_files=()
    for f in "${files_to_remove[@]}"; do
        if [[ ! " ${unique_files[*]:-} " =~ " ${f} " ]]; then
            unique_files+=("$f")
        fi
    done

    # Remove installed files
    for f in "${unique_files[@]}"; do
        if [[ -f "${GAME_DIR}/${f}" ]]; then
            rm -f "${GAME_DIR}/${f}"
            log_info "Removed: ${f}"
        fi
    done

    if [[ -d "${GAME_DIR}/reshade-shaders" ]]; then
        rm -rf "${GAME_DIR}/reshade-shaders"
        log_info "Removed: reshade-shaders/"
    fi

    # Restore backups if available
    if [[ -d "$BACKUP_DIR" ]]; then
        log_info "Restoring original files from backup..."
        for orig in "$BACKUP_DIR"/*; do
            [[ -e "$orig" ]] || continue
            local fname
            fname=$(basename "$orig")
            cp -p "$orig" "${GAME_DIR}/${fname}"
            log_ok "Restored original: ${fname}"
        done
        rm -rf "$BACKUP_DIR"
        log_ok "Removed backup directory."
    fi

    rm -f "$MANIFEST_FILE"
    log_ok "DLSS 5 Bridge successfully uninstalled."
}

# Install / Patch
do_install() {
    check_system
    locate_deps

    log_info "Preparing to patch game directory: ${C_BOLD}${GAME_DIR}${C_RESET}"

    # If dependencies are missing and auto-download is enabled, fetch them
    if [[ "$AUTO_DOWNLOAD" -eq 1 ]]; then
        local target_deps="${DEPS_DIR:-${REPO_ROOT}/deps}"
        mkdir -p "$target_deps"
        local needs_fetch=0

        if [[ -z "$FOUND_BRIDGE" ]]; then
            log_info "Missing dlss5-bridge.addon64. Automatically downloading..."
            fetch_bridge "$target_deps" || true
            needs_fetch=1
        fi
        if [[ -z "$FOUND_RESHADE" ]]; then
            log_info "Missing ReShade with add-on support. Automatically downloading..."
            fetch_reshade "$target_deps" || true
            needs_fetch=1
        fi
        if [[ -z "$FOUND_NEURAL" ]]; then
            log_info "Missing DLSS 5 Neural add-on. Automatically downloading..."
            fetch_neural "$target_deps" || true
            needs_fetch=1
        fi
        if [[ -z "$FOUND_DLSSNR" ]]; then
            log_info "Missing nvngx_dlssnr.dll. Automatically downloading..."
            fetch_dlssnr_weights "$target_deps" || true
            needs_fetch=1
        fi
        if [[ "$SUBSTITUTE_MODE" -eq 1 && -z "$FOUND_DLSS" && ! -f "${GAME_DIR}/nvngx_dlss.dll" ]]; then
            log_info "Missing nvngx_dlss.dll (required for substitute mode). Automatically downloading..."
            fetch_dlss_sr "$target_deps" || true
            needs_fetch=1
        fi

        if [[ "$needs_fetch" -eq 1 ]]; then
            locate_deps
        fi
    fi

    local missing=0

    if [[ -z "$FOUND_BRIDGE" ]]; then
        log_err "Missing 'dlss5-bridge.addon64'."
        log_err " -> Build or download dlss5-bridge.addon64 and place it in the deps directory."
        missing=1
    else
        log_ok "Found DLSS 5 Bridge: $FOUND_BRIDGE"
    fi

    if [[ -z "$FOUND_RESHADE" ]]; then
        log_err "Missing ReShade 64-bit with add-on support (ReShade64.dll or dxgi.dll)."
        log_err " -> Download ReShade with full add-on support from https://reshade.me"
        missing=1
    else
        log_ok "Found ReShade binary: $FOUND_RESHADE"
    fi

    if [[ -z "$FOUND_NEURAL" ]]; then
        log_err "Missing DLSS 5 Neural Rendering add-on (*dlssnr*.addon64 or *dlss5*.addon64)."
        log_err " -> Obtain renodx-dlss5.addon64 or NapXDD's addon-dlssnr-linux."
        missing=1
    else
        log_ok "Found Neural Add-on: $FOUND_NEURAL"
    fi

    if [[ -z "$FOUND_DLSSNR" ]]; then
        log_err "Missing 'nvngx_dlssnr.dll'."
        log_err " -> Supplied with the DLSS 5 neural rendering add-on."
        missing=1
    else
        log_ok "Found Neural Weights: $FOUND_DLSSNR"
    fi

    if [[ "$SUBSTITUTE_MODE" -eq 1 && -z "$FOUND_DLSS" && ! -f "${GAME_DIR}/nvngx_dlss.dll" ]]; then
        log_err "Missing 'nvngx_dlss.dll' (required for substitute mode in games without native DLSS)."
        log_err " -> Copy nvngx_dlss.dll (>= 3.1.13) from any game with DLSS into the deps folder."
        missing=1
    elif [[ -n "$FOUND_DLSS" ]]; then
        log_ok "Found DLSS SR library: $FOUND_DLSS"
    fi

    if [[ "$missing" -eq 1 ]]; then
        echo ""
        log_err "Cannot proceed due to missing dependencies."
        log_info "Please place the required files in '${DEPS_DIR:-${REPO_ROOT}/deps}' or specify --deps-dir <DIR>."
        exit 1
    fi

    # Load existing manifest into a list if it exists
    local previously_installed=()
    if [[ -f "$MANIFEST_FILE" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && previously_installed+=("$line")
        done < "$MANIFEST_FILE"
    fi

    record_installed() {
        local fname="$1"
        if [[ ! -f "$MANIFEST_FILE" ]] || ! grep -Fxq "$fname" "$MANIFEST_FILE"; then
            echo "$fname" >> "$MANIFEST_FILE"
        fi
    }

    backup_and_copy() {
        local src="$1"
        local dst_name="$2"
        local dst="${GAME_DIR}/${dst_name}"

        # Only back up if file exists AND was not previously installed by us
        local is_our_file=0
        for f in "${previously_installed[@]:-}"; do
            if [[ "$f" == "$dst_name" ]]; then
                is_our_file=1
                break
            fi
        done

        if [[ -f "$dst" && "$is_our_file" -eq 0 && ! -f "${BACKUP_DIR}/${dst_name}" ]]; then
            mkdir -p "$BACKUP_DIR"
            cp -p "$dst" "${BACKUP_DIR}/${dst_name}"
            log_info "Backed up original ${dst_name} -> .dlss5-backup/${dst_name}"
        fi

        cp -p "$src" "$dst"
        record_installed "$dst_name"
        log_ok "Installed: ${dst_name}"
    }

    # 1. Install ReShade as proxy DLL (dxgi.dll or d3d11.dll)
    patch_reshade_wine_compat "$FOUND_RESHADE"
    backup_and_copy "$FOUND_RESHADE" "${PROXY_TYPE}.dll"

    # 2. Install dlss5-bridge.addon64
    backup_and_copy "$FOUND_BRIDGE" "dlss5-bridge.addon64"

    # 3. Install neural rendering add-on
    backup_and_copy "$FOUND_NEURAL" "$(basename "$FOUND_NEURAL")"

    # 4. Install nvngx_dlssnr.dll
    backup_and_copy "$FOUND_DLSSNR" "nvngx_dlssnr.dll"

    # 5. Install nvngx_dlss.dll if provided
    if [[ -n "$FOUND_DLSS" ]]; then
        backup_and_copy "$FOUND_DLSS" "nvngx_dlss.dll"
    fi

    # 5b. Install native d3dcompiler_47.dll if found
    if [[ -n "$FOUND_COMPILER" ]]; then
        backup_and_copy "$FOUND_COMPILER" "d3dcompiler_47.dll"
    fi

    # 6. Install ReShade shaders & textures if found
    if [[ -n "$FOUND_SHADERS" ]]; then
        mkdir -p "${GAME_DIR}/reshade-shaders"
        cp -rp "${FOUND_SHADERS}"/* "${GAME_DIR}/reshade-shaders/"
        record_installed "reshade-shaders"
        log_ok "Installed ReShade shaders & textures -> reshade-shaders/"
    fi

    # 7. Configure ReShade.ini search paths so no warning appears
    local ini_file="${GAME_DIR}/ReShade.ini"
    if [[ ! -f "$ini_file" ]]; then
        cat > "$ini_file" <<EOF
[GENERAL]
EffectSearchPaths=.\\reshade-shaders\\Shaders,.\\reshade-shaders\\Shaders\\Includes,.\\
TextureSearchPaths=.\\reshade-shaders\\Textures,.\\
PresetPath=.\\ReShadePreset.ini
EOF
        record_installed "ReShade.ini"
        log_ok "Created default ReShade.ini with shader search paths."
    else
        if ! grep -q "reshade-shaders" "$ini_file"; then
            sed -i 's|^EffectSearchPaths=.*|EffectSearchPaths=.\\reshade-shaders\\Shaders,.\\reshade-shaders\\Shaders\\Includes,.\\|' "$ini_file" || true
            sed -i 's|^TextureSearchPaths=.*|TextureSearchPaths=.\\reshade-shaders\\Textures,.\\|' "$ini_file" || true
            log_ok "Updated ReShade.ini effect search paths."
        fi
    fi

    # 8. Configure ReShadePreset.ini for substitute mode (motion vectors)
    local preset_file="${GAME_DIR}/ReShadePreset.ini"
    if [[ "$SUBSTITUTE_MODE" -eq 1 ]]; then
        if [[ ! -f "$preset_file" ]]; then
            cat > "$preset_file" <<EOF
Techniques=vort_MotionEffects@vort_Motion.fx
TechniqueSorting=vort_MotionEffects@vort_Motion.fx
EOF
            record_installed "ReShadePreset.ini"
            log_ok "Created ReShadePreset.ini with vort_MotionEffects enabled for substitute mode."
        elif ! grep -q "vort_MotionEffects@vort_Motion.fx" "$preset_file"; then
            if grep -q "^Techniques=" "$preset_file"; then
                sed -i 's|^Techniques=\(..\)|Techniques=vort_MotionEffects@vort_Motion.fx,\1|; s|^Techniques=$|Techniques=vort_MotionEffects@vort_Motion.fx|' "$preset_file" || true
            else
                echo "Techniques=vort_MotionEffects@vort_Motion.fx" >> "$preset_file"
            fi
            log_ok "Enabled vort_MotionEffects in existing ReShadePreset.ini."
        fi
    fi

    # 9. Generate Proton-optimized dlss5-bridge.cfg
    local cfg_file="${GAME_DIR}/dlss5-bridge.cfg"
    if [[ -f "$cfg_file" && "$FORCE" -eq 0 ]]; then
        log_warn "dlss5-bridge.cfg already exists in target directory. Leaving intact."
        log_warn "Ensure it contains 'unwrap=0' and 'ofa_grid=0' for Proton compatibility."
    else
        log_info "Writing Proton-optimized dlss5-bridge.cfg..."
        cat > "$cfg_file" <<EOF
# dlss5-bridge keep
unwrap=0
ofa_grid=0
synth=${SUBSTITUTE_MODE}
source=auto
vk_mirror=0
dred=0
hash_out=0
EOF
        record_installed "dlss5-bridge.cfg"
        log_ok "Created dlss5-bridge.cfg with Proton defaults (unwrap=0, ofa_grid=0, synth=${SUBSTITUTE_MODE}, hash_out=0)."
    fi

    # 10. Configure local dxvk.conf
    apply_dxvk_conf

    # 11. Configure Steam Launch Options and Proton Wine prefix
    apply_steam_configurations

    echo ""
    log_ok "${C_BOLD}Game patching complete!${C_RESET}"
    echo ""
    echo "================================================================================"
    local overrides="${PROXY_TYPE}"
    [[ -n "$FOUND_COMPILER" || -f "${GAME_DIR}/d3dcompiler_47.dll" ]] && overrides="${overrides},d3dcompiler_47"

    if [[ "$AUTO_STEAM" -eq 1 && -n "${APP_ID:-}" ]]; then
        echo -e "${C_BOLD}STEAM & PROTON AUTOMATION:${C_RESET}"
        echo "  - DXVK configuration written to: dxvk.conf"
        echo "  - Proton Wine DLL overrides injected: [Software\\Wine\\DllOverrides] ${overrides}"
        echo "  - Steam Launch Options updated in localconfig.vdf (existing options preserved)"
        echo ""
        echo "  Note: If Steam was running, restart Steam to reflect the launch options"
        echo "  in the Steam Properties UI. The DLL overrides and dxvk.conf are already active!"
    else
        echo -e "${C_BOLD}MANUAL STEAM LAUNCH OPTIONS (IF NOT AUTO-APPLIED):${C_RESET}"
        echo "Right-click the game in Steam -> Properties -> General -> Launch Options:"
        echo -e "  ${C_CYAN}WINEDLLOVERRIDES=\"${overrides}=n,b\" DXVK_FRAME_RATE=${FPS_CAP} PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 %command%${C_RESET}"
    fi
    echo ""
    echo -e "${C_BOLD}PROTON NOTES:${C_RESET}"
    echo "  - unwrap=0 is configured to prevent vkd3d-proton descriptor crashes."
    echo "  - hash_out=0 prevents synchronous GPU readback stalls."
    if [[ "$SUBSTITUTE_MODE" -eq 1 ]]; then
        echo "  - Substitute mode is enabled (synth=1). Hardware Optical Flow is disabled"
        echo "    (ofa_grid=0) under Proton; motion vectors will come from ReShade MV shaders."
    fi
    echo "  - In-game: Press Home / Pos1 to open the ReShade overlay and verify that"
    echo "    both DLSS 5 Bridge and the Neural Rendering add-on are active."
    echo "================================================================================"
}

# Main dispatcher
case "$ACTION" in
    download_deps)
        download_all_deps
        ;;
    status)
        check_status
        ;;
    uninstall)
        do_uninstall
        ;;
    install)
        do_install
        ;;
esac
