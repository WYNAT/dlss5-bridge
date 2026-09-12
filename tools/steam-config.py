#!/usr/bin/env python3
"""
steam-config.py - Helper script to inspect and configure Steam Launch Options
and Proton Wine prefix registry (user.reg) for DLSS 5 Bridge.
"""

import argparse
import os
import re
import sys


def update_launch_options(existing: str, proxy: str = "dxgi", compiler: bool = True, fps: int = 60) -> str:
    """
    Extends existing Steam Launch Options with DLSS 5 Bridge requirements
    without overwriting existing user flags, environment variables, wrappers or commands.
    """
    existing = existing.strip()
    dlss_dlls = [proxy]
    if compiler:
        dlss_dlls.append("d3dcompiler_47")

    needed_overrides = ",".join(dlss_dlls) + "=n,b"

    if not existing:
        fps_part = f"DXVK_FRAME_RATE={fps} " if fps > 0 else ""
        return f'WINEDLLOVERRIDES="{needed_overrides}" {fps_part}PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 %command%'.replace("  ", " ")

    has_command = "%command%" in existing

    if has_command:
        prefix, suffix = existing.split("%command%", 1)
        prefix = prefix.strip()
        suffix = suffix.strip()
    else:
        prefix = ""
        suffix = existing

    # Check and update WINEDLLOVERRIDES
    winedll_match = re.search(r'WINEDLLOVERRIDES="([^"]*)"', prefix)
    if winedll_match:
        curr_val = winedll_match.group(1)
        to_add = [d for d in dlss_dlls if d not in curr_val]
        if to_add:
            sep = ";" if curr_val and not curr_val.endswith(";") else ""
            added_str = ",".join(to_add) + "=n,b"
            new_val = f"{curr_val}{sep}{added_str}"
            prefix = prefix[:winedll_match.start()] + f'WINEDLLOVERRIDES="{new_val}"' + prefix[winedll_match.end():]
    else:
        prefix = f'WINEDLLOVERRIDES="{needed_overrides}" {prefix}'.strip()

    new_vars = []
    if fps > 0 and "DXVK_FRAME_RATE=" not in prefix:
        new_vars.append(f"DXVK_FRAME_RATE={fps}")
    if "PROTON_ENABLE_NVAPI=" not in prefix:
        new_vars.append("PROTON_ENABLE_NVAPI=1")
    if "DXVK_ENABLE_NVAPI=" not in prefix:
        new_vars.append("DXVK_ENABLE_NVAPI=1")

    if new_vars:
        vars_str = " ".join(new_vars)
        prefix = f"{vars_str} {prefix}".strip()

    result = f"{prefix} %command%"
    if suffix:
        result = f"{result} {suffix}"
    return re.sub(r"\s+", " ", result).strip()


def revert_launch_options(current: str, proxy: str = "dxgi", compiler: bool = True) -> str:
    """
    Reverts DLSS 5 Bridge additions from Launch Options, preserving user-defined flags.
    """
    current = current.strip()
    if not current:
        return ""

    dlss_dlls = [proxy]
    if compiler:
        dlss_dlls.append("d3dcompiler_47")

    def clean_winedll(match):
        val = match.group(1)
        parts = [p.strip() for p in val.split(";") if p.strip()]
        new_parts = []
        for part in parts:
            if "=" in part:
                dlls, mode = part.split("=", 1)
                dll_list = [d.strip() for d in dlls.split(",") if d.strip() and d.strip() not in dlss_dlls]
                if dll_list:
                    new_parts.append(f"{','.join(dll_list)}={mode}")
            else:
                new_parts.append(part)
        if new_parts:
            return f'WINEDLLOVERRIDES="{";".join(new_parts)}"'
        return ""

    current = re.sub(r'WINEDLLOVERRIDES="([^"]*)"', clean_winedll, current)
    current = re.sub(r'\bPROTON_ENABLE_NVAPI=1\b', '', current)
    current = re.sub(r'\bDXVK_ENABLE_NVAPI=1\b', '', current)
    current = re.sub(r'\bDXVK_FRAME_RATE=\d+\b', '', current)

    current = re.sub(r"\s+", " ", current).strip()
    if current == "%command%":
        return ""
    if current.startswith("%command% "):
        current = current[len("%command% "):].strip()
    return current


def update_vdf_file(vdf_path: str, appid: str, proxy: str = "dxgi", compiler: bool = True, fps: int = 60) -> str:
    """Updates localconfig.vdf for appid with extended launch options."""
    if not os.path.exists(vdf_path):
        return ""

    with open(vdf_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    path = []
    app_line_idx = -1
    app_brace_idx = -1
    launch_opt_idx = -1
    apps_brace_idx = -1
    existing_opts = ""

    for idx, raw_line in enumerate(lines):
        line = raw_line.strip()
        if not line or line.startswith("//"):
            continue
        m_key = re.match(r'^"([^"]+)"', line)
        if "}" in line:
            if path:
                path.pop()
            continue
        if m_key:
            key = m_key.group(1)
            rest = line[m_key.end():].strip()
            if not rest or rest == "{" or (idx + 1 < len(lines) and lines[idx + 1].strip().startswith("{")):
                path.append(key)
                if path == ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]:
                    apps_brace_idx = idx + 1 if "{" not in line else idx
                elif path == ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", appid]:
                    app_line_idx = idx
                    app_brace_idx = idx + 1 if "{" not in line else idx
                continue
            if path == ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", appid] and key == "LaunchOptions":
                launch_opt_idx = idx
                val_m = re.search(r'"LaunchOptions"\s+"(.*)"\s*$', line)
                if val_m:
                    existing_opts = val_m.group(1).replace(r'\"', '"')

    new_opts = update_launch_options(existing_opts, proxy, compiler, fps)
    escaped_opts = new_opts.replace('"', r'\"')

    if launch_opt_idx != -1:
        existing_line = lines[launch_opt_idx]
        indent = existing_line[: len(existing_line) - len(existing_line.lstrip())]
        lines[launch_opt_idx] = f'{indent}"LaunchOptions"\t\t"{escaped_opts}"\n'
    elif app_brace_idx != -1:
        brace_line = lines[app_brace_idx]
        indent = brace_line[: len(brace_line) - len(brace_line.lstrip())] + "\t"
        lines.insert(app_brace_idx + 1, f'{indent}"LaunchOptions"\t\t"{escaped_opts}"\n')
    elif apps_brace_idx != -1:
        brace_line = lines[apps_brace_idx]
        indent_app = brace_line[: len(brace_line) - len(brace_line.lstrip())] + "\t"
        indent_child = indent_app + "\t"
        block = [
            f'{indent_app}"{appid}"\n',
            f'{indent_app}{{\n',
            f'{indent_child}"LaunchOptions"\t\t"{escaped_opts}"\n',
            f'{indent_app}}}\n',
        ]
        for offset, l in enumerate(block):
            lines.insert(apps_brace_idx + 1 + offset, l)

    tmp_path = f"{vdf_path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    os.replace(tmp_path, vdf_path)
    return new_opts


def revert_vdf_file(vdf_path: str, appid: str, proxy: str = "dxgi", compiler: bool = True) -> str:
    """Reverts DLSS 5 Bridge options from localconfig.vdf for appid."""
    if not os.path.exists(vdf_path):
        return ""

    with open(vdf_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    path = []
    launch_opt_idx = -1
    existing_opts = ""

    for idx, raw_line in enumerate(lines):
        line = raw_line.strip()
        if not line or line.startswith("//"):
            continue
        m_key = re.match(r'^"([^"]+)"', line)
        if "}" in line:
            if path:
                path.pop()
            continue
        if m_key:
            key = m_key.group(1)
            rest = line[m_key.end():].strip()
            if not rest or rest == "{" or (idx + 1 < len(lines) and lines[idx + 1].strip().startswith("{")):
                path.append(key)
                continue
            if path == ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", appid] and key == "LaunchOptions":
                launch_opt_idx = idx
                val_m = re.search(r'"LaunchOptions"\s+"(.*)"\s*$', line)
                if val_m:
                    existing_opts = val_m.group(1).replace(r'\"', '"')

    if launch_opt_idx != -1:
        rev_opts = revert_launch_options(existing_opts, proxy, compiler)
        if rev_opts:
            escaped_rev = rev_opts.replace('"', r'\"')
            existing_line = lines[launch_opt_idx]
            indent = existing_line[: len(existing_line) - len(existing_line.lstrip())]
            lines[launch_opt_idx] = f'{indent}"LaunchOptions"\t\t"{escaped_rev}"\n'
        else:
            lines.pop(launch_opt_idx)
        tmp_path = f"{vdf_path}.tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.replace(tmp_path, vdf_path)
        return rev_opts
    return ""


def get_vdf_launch_options(vdf_path: str, appid: str) -> str:
    """Returns current LaunchOptions value for appid in localconfig.vdf."""
    if not os.path.exists(vdf_path):
        return ""

    with open(vdf_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    path = []
    for idx, raw_line in enumerate(lines):
        line = raw_line.strip()
        if not line or line.startswith("//"):
            continue
        m_key = re.match(r'^"([^"]+)"', line)
        if "}" in line:
            if path:
                path.pop()
            continue
        if m_key:
            key = m_key.group(1)
            rest = line[m_key.end():].strip()
            if not rest or rest == "{" or (idx + 1 < len(lines) and lines[idx + 1].strip().startswith("{")):
                path.append(key)
                continue
            if path == ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", appid] and key == "LaunchOptions":
                val_m = re.search(r'"LaunchOptions"\s+"(.*)"\s*$', line)
                if val_m:
                    return val_m.group(1).replace(r'\"', '"')
    return ""


def update_user_reg(reg_path: str, proxy: str = "dxgi", compiler: bool = True) -> bool:
    """Injects DLL overrides into Proton prefix user.reg."""
    if not os.path.exists(reg_path):
        return False

    with open(reg_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    section = "[Software\\\\Wine\\\\DllOverrides]"
    sec_idx = -1
    next_sec_idx = -1
    for idx, line in enumerate(lines):
        if line.strip().startswith(section):
            sec_idx = idx
        elif sec_idx != -1 and line.strip().startswith("[") and line.strip().endswith("]"):
            next_sec_idx = idx
            break

    dlss_keys = {f'"{proxy}"': '"native,builtin"'}
    if compiler:
        dlss_keys['"d3dcompiler_47"'] = '"native,builtin"'

    if sec_idx != -1:
        end_idx = next_sec_idx if next_sec_idx != -1 else len(lines)
        existing_keys = set()
        for i in range(sec_idx + 1, end_idx):
            for k in dlss_keys:
                if lines[i].strip().startswith(k):
                    existing_keys.add(k)
        insert_pos = sec_idx + 1
        for k, v in dlss_keys.items():
            if k not in existing_keys:
                lines.insert(insert_pos, f"{k}={v}\n")
                insert_pos += 1
    else:
        lines.append(f"\n{section}\n")
        for k, v in dlss_keys.items():
            lines.append(f"{k}={v}\n")

    tmp_path = f"{reg_path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    os.replace(tmp_path, reg_path)
    return True


def revert_user_reg(reg_path: str, proxy: str = "dxgi", compiler: bool = True) -> bool:
    """Removes DLSS 5 DLL overrides from Proton prefix user.reg."""
    if not os.path.exists(reg_path):
        return False

    with open(reg_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    section = "[Software\\\\Wine\\\\DllOverrides]"
    sec_idx = -1
    next_sec_idx = -1
    for idx, line in enumerate(lines):
        if line.strip().startswith(section):
            sec_idx = idx
        elif sec_idx != -1 and line.strip().startswith("[") and line.strip().endswith("]"):
            next_sec_idx = idx
            break

    dlss_keys = [f'"{proxy}"']
    if compiler:
        dlss_keys.append('"d3dcompiler_47"')

    if sec_idx != -1:
        end_idx = next_sec_idx if next_sec_idx != -1 else len(lines)
        new_lines = []
        for idx, line in enumerate(lines):
            if sec_idx < idx < end_idx:
                should_remove = any(line.strip().startswith(k) for k in dlss_keys)
                if not should_remove:
                    new_lines.append(line)
            else:
                new_lines.append(line)
        lines = new_lines

    tmp_path = f"{reg_path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    os.replace(tmp_path, reg_path)
    return True


def get_user_reg_overrides(reg_path: str) -> str:
    """Returns list of active DllOverrides in Proton user.reg."""
    if not os.path.exists(reg_path):
        return ""

    with open(reg_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    section = "[Software\\\\Wine\\\\DllOverrides]"
    sec_idx = -1
    next_sec_idx = -1
    for idx, line in enumerate(lines):
        if line.strip().startswith(section):
            sec_idx = idx
        elif sec_idx != -1 and line.strip().startswith("[") and line.strip().endswith("]"):
            next_sec_idx = idx
            break

    if sec_idx != -1:
        end_idx = next_sec_idx if next_sec_idx != -1 else len(lines)
        entries = []
        for i in range(sec_idx + 1, end_idx):
            cleaned = lines[i].strip()
            if cleaned and not cleaned.startswith("#"):
                entries.append(cleaned)
        return ", ".join(entries)
    return ""


def main():
    parser = argparse.ArgumentParser(description="Steam & Proton Configuration Helper for DLSS 5 Bridge")
    subparsers = parser.add_subparsers(dest="action", required=True)

    # update-vdf
    p_up_vdf = subparsers.add_parser("update-vdf", help="Update Steam localconfig.vdf launch options")
    p_up_vdf.add_argument("--vdf", required=True, help="Path to localconfig.vdf")
    p_up_vdf.add_argument("--appid", required=True, help="Steam AppID")
    p_up_vdf.add_argument("--proxy", default="dxgi", help="Proxy DLL name (dxgi or d3d11)")
    p_up_vdf.add_argument("--compiler", action="store_true", help="Include d3dcompiler_47 override")
    p_up_vdf.add_argument("--fps", type=int, default=60, help="Target frame rate cap (0 to disable)")

    # revert-vdf
    p_rev_vdf = subparsers.add_parser("revert-vdf", help="Revert Steam localconfig.vdf launch options")
    p_rev_vdf.add_argument("--vdf", required=True, help="Path to localconfig.vdf")
    p_rev_vdf.add_argument("--appid", required=True, help="Steam AppID")
    p_rev_vdf.add_argument("--proxy", default="dxgi", help="Proxy DLL name (dxgi or d3d11)")
    p_rev_vdf.add_argument("--compiler", action="store_true", help="Include d3dcompiler_47 override")

    # get-vdf
    p_get_vdf = subparsers.add_parser("get-vdf", help="Get Steam localconfig.vdf launch options")
    p_get_vdf.add_argument("--vdf", required=True, help="Path to localconfig.vdf")
    p_get_vdf.add_argument("--appid", required=True, help="Steam AppID")

    # update-reg
    p_up_reg = subparsers.add_parser("update-reg", help="Update Proton prefix user.reg DLL overrides")
    p_up_reg.add_argument("--reg", required=True, help="Path to user.reg")
    p_up_reg.add_argument("--proxy", default="dxgi", help="Proxy DLL name (dxgi or d3d11)")
    p_up_reg.add_argument("--compiler", action="store_true", help="Include d3dcompiler_47 override")

    # revert-reg
    p_rev_reg = subparsers.add_parser("revert-reg", help="Revert Proton prefix user.reg DLL overrides")
    p_rev_reg.add_argument("--reg", required=True, help="Path to user.reg")
    p_rev_reg.add_argument("--proxy", default="dxgi", help="Proxy DLL name (dxgi or d3d11)")
    p_rev_reg.add_argument("--compiler", action="store_true", help="Include d3dcompiler_47 override")

    # get-reg
    p_get_reg = subparsers.add_parser("get-reg", help="Get Proton prefix user.reg DLL overrides")
    p_get_reg.add_argument("--reg", required=True, help="Path to user.reg")

    args = parser.parse_args()

    if args.action == "update-vdf":
        res = update_vdf_file(args.vdf, args.appid, args.proxy, args.compiler, args.fps)
        print(res)
    elif args.action == "revert-vdf":
        res = revert_vdf_file(args.vdf, args.appid, args.proxy, args.compiler)
        print(res)
    elif args.action == "get-vdf":
        res = get_vdf_launch_options(args.vdf, args.appid)
        print(res)
    elif args.action == "update-reg":
        ok = update_user_reg(args.reg, args.proxy, args.compiler)
        print("OK" if ok else "FAILED")
    elif args.action == "revert-reg":
        ok = revert_user_reg(args.reg, args.proxy, args.compiler)
        print("OK" if ok else "FAILED")
    elif args.action == "get-reg":
        print(get_user_reg_overrides(args.reg))


if __name__ == "__main__":
    main()
