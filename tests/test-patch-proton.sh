#!/usr/bin/env bash
#
# test-patch-proton.sh - Unit tests for tools/patch-proton.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCH_SCRIPT="${REPO_ROOT}/tools/patch-proton.sh"

TEST_TMP="$(mktemp -d -t dlss5-test-XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_DEPS="${TEST_TMP}/mock_deps"
MOCK_GAME="${TEST_TMP}/mock_game"

mkdir -p "$MOCK_DEPS" "$MOCK_GAME"

echo "=== Running patch-proton.sh Unit Tests ==="

# Helper assert
assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "ASSERTION FAILED: $msg (Expected: '$expected', Got: '$actual')" >&2
        exit 1
    fi
}

assert_file_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "ASSERTION FAILED: File does not exist: $file" >&2
        exit 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        echo "ASSERTION FAILED: File should not exist: $file" >&2
        exit 1
    fi
}

# Test 1: Help message
echo "[Test 1] Testing --help..."
out=$("$PATCH_SCRIPT" --help)
echo "$out" | grep -q "DLSS 5 Bridge - Linux / Proton Game Patcher"
echo "  -> OK"

# Test 2: Missing game dir argument
echo "[Test 2] Testing missing game directory error..."
if "$PATCH_SCRIPT" >/dev/null 2>&1; then
    echo "ASSERTION FAILED: Expected failure on missing arguments" >&2
    exit 1
fi
echo "  -> OK"

# Test 3: Missing dependencies reporting
echo "[Test 3] Testing missing dependencies error..."
if "$PATCH_SCRIPT" --deps-dir "$MOCK_DEPS" --no-download --skip-system-check "$MOCK_GAME" >/dev/null 2>&1; then
    echo "ASSERTION FAILED: Expected failure when dependencies are missing" >&2
    exit 1
fi
echo "  -> OK"

# Setup mock dependencies
touch "${MOCK_DEPS}/dlss5-bridge.addon64"
touch "${MOCK_DEPS}/ReShade64.dll"
touch "${MOCK_DEPS}/addon-dlssnr-linux.addon64"
touch "${MOCK_DEPS}/nvngx_dlssnr.dll"
touch "${MOCK_DEPS}/nvngx_dlss.dll"

# Setup existing original file in game dir for backup testing
echo "ORIGINAL_DXGI" > "${MOCK_GAME}/dxgi.dll"

# Test 4: Successful install with backup
echo "[Test 4] Testing successful install and backup..."
"$PATCH_SCRIPT" --deps-dir "$MOCK_DEPS" --skip-system-check "$MOCK_GAME"

assert_file_exists "${MOCK_GAME}/dxgi.dll"
assert_file_exists "${MOCK_GAME}/dlss5-bridge.addon64"
assert_file_exists "${MOCK_GAME}/addon-dlssnr-linux.addon64"
assert_file_exists "${MOCK_GAME}/nvngx_dlssnr.dll"
assert_file_exists "${MOCK_GAME}/dlss5-bridge.cfg"
assert_file_exists "${MOCK_GAME}/.dlss5-backup/dxgi.dll"

# Verify backup contains original content
backup_content=$(cat "${MOCK_GAME}/.dlss5-backup/dxgi.dll")
assert_equals "ORIGINAL_DXGI" "$backup_content" "Backup file content mismatch"

# Verify config values (Proton optimizations)
cfg_content=$(cat "${MOCK_GAME}/dlss5-bridge.cfg")
echo "$cfg_content" | grep -q "unwrap=0"
echo "$cfg_content" | grep -q "ofa_grid=0"
echo "$cfg_content" | grep -q "synth=0"
echo "$cfg_content" | grep -q "vk_mirror=0"
echo "  -> OK"

# Test 5: Status command
echo "[Test 5] Testing --status inspection..."
status_out=$("$PATCH_SCRIPT" --status "$MOCK_GAME")
echo "$status_out" | grep -q "DLSS 5 Bridge addon:.*Present"
echo "$status_out" | grep -q "unwrap=0"
echo "  -> OK"

# Test 6: Substitute mode flag
echo "[Test 6] Testing --substitute flag with --force..."
"$PATCH_SCRIPT" --deps-dir "$MOCK_DEPS" --substitute --force --skip-system-check "$MOCK_GAME"
cfg_substitute=$(cat "${MOCK_GAME}/dlss5-bridge.cfg")
echo "$cfg_substitute" | grep -q "synth=1"
echo "  -> OK"

# Test 7: Uninstall / Restore
echo "[Test 7] Testing --uninstall and restore of original files..."
"$PATCH_SCRIPT" --uninstall "$MOCK_GAME"

assert_file_not_exists "${MOCK_GAME}/dlss5-bridge.addon64"
assert_file_not_exists "${MOCK_GAME}/addon-dlssnr-linux.addon64"
assert_file_not_exists "${MOCK_GAME}/nvngx_dlssnr.dll"
assert_file_not_exists "${MOCK_GAME}/dlss5-bridge.cfg"
assert_file_not_exists "${MOCK_GAME}/.dlss5-backup"

# Verify original dxgi was restored
restored_content=$(cat "${MOCK_GAME}/dxgi.dll")
assert_equals "ORIGINAL_DXGI" "$restored_content" "Restored dxgi content mismatch"
echo "  -> OK"

# Test 8: Custom proxy (d3d11.dll)
echo "[Test 8] Testing --proxy d3d11..."
rm -f "${MOCK_GAME}/dxgi.dll"
"$PATCH_SCRIPT" --deps-dir "$MOCK_DEPS" --proxy d3d11 --skip-system-check "$MOCK_GAME"
assert_file_exists "${MOCK_GAME}/d3d11.dll"
assert_file_not_exists "${MOCK_GAME}/dxgi.dll"
"$PATCH_SCRIPT" --proxy d3d11 --uninstall "$MOCK_GAME"
assert_file_not_exists "${MOCK_GAME}/d3d11.dll"
echo "  -> OK"

# Test 9: Wine compatibility patching ([fastopt] -> [loop])
echo "[Test 9] Testing Wine compatibility patching ([fastopt] -> [loop])..."
printf "test_prefix\x00[fastopt] \x00test_suffix" > "${MOCK_DEPS}/ReShade64.dll"
"$PATCH_SCRIPT" --deps-dir "$MOCK_DEPS" --skip-system-check "$MOCK_GAME"
if grep -a -q "\[fastopt\] " "${MOCK_GAME}/dxgi.dll"; then
    echo "ASSERTION FAILED: [fastopt] was not replaced in installed proxy DLL" >&2
    exit 1
fi
if ! grep -a -q "\[loop\]    " "${MOCK_GAME}/dxgi.dll"; then
    echo "ASSERTION FAILED: [loop] replacement pattern not found in installed proxy DLL" >&2
    exit 1
fi
echo "  -> OK"

# Test 10: Substitute mode ReShadePreset.ini creation
echo "[Test 10] Testing ReShadePreset.ini in substitute mode..."
"$PATCH_SCRIPT" --deps-dir "$MOCK_DEPS" --substitute --force --skip-system-check "$MOCK_GAME"
assert_file_exists "${MOCK_GAME}/ReShadePreset.ini"
preset_content=$(cat "${MOCK_GAME}/ReShadePreset.ini")
echo "$preset_content" | grep -q "vort_MotionEffects@vort_Motion.fx"
echo "  -> OK"

# Test 11: Steam AppID Auto-Detection, dxvk.conf, user.reg and localconfig.vdf
echo "[Test 11] Testing Steam AppID detection, dxvk.conf, and LaunchOptions extension..."
MOCK_STEAM_DIR="${TEST_TMP}/mock_steam"
MOCK_STEAM_GAME="${MOCK_STEAM_DIR}/steamapps/common/mock_game_steam"
MOCK_COMPAT="${MOCK_STEAM_DIR}/steamapps/compatdata/12345/pfx"
MOCK_VDF_DIR="${TEST_TMP}/mock_userdata/config"
mkdir -p "$MOCK_STEAM_GAME" "$MOCK_COMPAT" "$MOCK_VDF_DIR"

# Create mock appmanifest
cat > "${MOCK_STEAM_DIR}/steamapps/appmanifest_12345.acf" <<EOF
"AppState"
{
	"appid"		"12345"
	"installdir"		"mock_game_steam"
}
EOF

# Create mock Proton user.reg
cat > "${MOCK_COMPAT}/user.reg" <<EOF
WINE REGISTRY Version 2
[Software\\\\Wine\\\\DllOverrides]
"user_custom_dll"="native"
EOF

# Create mock localconfig.vdf with existing user options
cat > "${MOCK_VDF_DIR}/localconfig.vdf" <<EOF
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"12345"
					{
						"LaunchOptions"		"STEAM_COMPAT_DATA_PATH=\\"\$HOME/.local/share/Steam/steamapps\\" PROTON_LOG=1 %command%"
					}
				}
			}
		}
	}
}
EOF

# Run patch-proton with STEAM_VDF_PATH pointing to our mock vdf
STEAM_VDF_PATH="${MOCK_VDF_DIR}/localconfig.vdf" "$PATCH_SCRIPT" \
    --deps-dir "$MOCK_DEPS" \
    --fps-cap 120 \
    --skip-system-check \
    "$MOCK_STEAM_GAME"

# 11a: Verify dxvk.conf
assert_file_exists "${MOCK_STEAM_GAME}/dxvk.conf"
dxvk_c=$(cat "${MOCK_STEAM_GAME}/dxvk.conf")
echo "$dxvk_c" | grep -q "dxvk.enableNvapi = True"
echo "$dxvk_c" | grep -q "dxvk.frameRate = 120"
echo "  -> dxvk.conf OK"

# 11b: Verify Wine user.reg
reg_c=$(cat "${MOCK_COMPAT}/user.reg")
echo "$reg_c" | grep -q '"dxgi"="native,builtin"'
echo "$reg_c" | grep -q '"user_custom_dll"="native"'
echo "  -> user.reg OK"

# 11c: Verify localconfig.vdf extended (existing options preserved)
vdf_c=$(cat "${MOCK_VDF_DIR}/localconfig.vdf")
echo "$vdf_c" | grep -q 'STEAM_COMPAT_DATA_PATH'
echo "$vdf_c" | grep -q 'PROTON_LOG=1'
echo "$vdf_c" | grep -q 'DXVK_FRAME_RATE=120'
echo "$vdf_c" | grep -q 'PROTON_ENABLE_NVAPI=1'
echo "$vdf_c" | grep -q 'DXVK_ENABLE_NVAPI=1'
echo "$vdf_c" | grep -q 'WINEDLLOVERRIDES=\\"dxgi=n,b\\"'
echo "  -> localconfig.vdf extended OK"

# Test 12: Status reporting for Steam and DXVK
echo "[Test 12] Testing --status with Steam & DXVK configuration..."
status_steam_out=$(STEAM_VDF_PATH="${MOCK_VDF_DIR}/localconfig.vdf" "$PATCH_SCRIPT" --status "$MOCK_STEAM_GAME")
echo "$status_steam_out" | grep -q "Steam AppID:.*12345"
echo "$status_steam_out" | grep -q "DXVK Configuration (dxvk.conf):.*Present"
echo "$status_steam_out" | grep -q "Proton user.reg:.*Present"
echo "$status_steam_out" | grep -q "STEAM_COMPAT_DATA_PATH"
echo "  -> OK"

# Test 13: Uninstall and full revert of Steam options
echo "[Test 13] Testing --uninstall restoration of Steam options and dxvk.conf..."
STEAM_VDF_PATH="${MOCK_VDF_DIR}/localconfig.vdf" "$PATCH_SCRIPT" --uninstall "$MOCK_STEAM_GAME"

# dxvk.conf should be removed
assert_file_not_exists "${MOCK_STEAM_GAME}/dxvk.conf"

# user.reg should have dxgi removed, but user_custom_dll preserved
reg_c_after=$(cat "${MOCK_COMPAT}/user.reg")
if echo "$reg_c_after" | grep -q '"dxgi"'; then
    echo "ASSERTION FAILED: dxgi was not removed from user.reg after uninstall" >&2
    exit 1
fi
echo "$reg_c_after" | grep -q '"user_custom_dll"="native"'
echo "  -> user.reg reverted OK"

# localconfig.vdf should be reverted back to user's original launch options
vdf_c_after=$(cat "${MOCK_VDF_DIR}/localconfig.vdf")
echo "$vdf_c_after" | grep -q 'STEAM_COMPAT_DATA_PATH'
echo "$vdf_c_after" | grep -q 'PROTON_LOG=1'
if echo "$vdf_c_after" | grep -q 'PROTON_ENABLE_NVAPI'; then
    echo "ASSERTION FAILED: PROTON_ENABLE_NVAPI was not removed from localconfig.vdf after uninstall" >&2
    exit 1
fi
if echo "$vdf_c_after" | grep -q 'DXVK_FRAME_RATE'; then
    echo "ASSERTION FAILED: DXVK_FRAME_RATE was not removed from localconfig.vdf after uninstall" >&2
    exit 1
fi
echo "  -> localconfig.vdf reverted OK"

# Test 14: --no-steam and --no-dxvk-conf flags
echo "[Test 14] Testing --no-steam and --no-dxvk-conf flags..."
"$PATCH_SCRIPT" --deps-dir "$MOCK_DEPS" --no-steam --no-dxvk-conf --skip-system-check "$MOCK_STEAM_GAME"
assert_file_not_exists "${MOCK_STEAM_GAME}/dxvk.conf"
"$PATCH_SCRIPT" --uninstall "$MOCK_STEAM_GAME" >/dev/null 2>&1 || true
echo "  -> OK"

echo "=== All patch-proton.sh tests PASSED successfully! ==="

