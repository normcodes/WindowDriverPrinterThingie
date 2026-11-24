#!/usr/bin/env python3
"""Windows print-to-BLE bridge for MX01 thermal printers.

A Windows queue named ``MX01 Thermal Printer`` renders jobs through the
Microsoft Print to PDF driver to a fixed handoff file. This bridge watches that
file, rasterizes PDF pages to 384 dots wide, then sends the data to the printer
using the custom BLE-GATT protocol implemented by n0rm0/printercontrol.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

PRINTER_NAME = "MX01 Thermal Printer"
TASK_NAME = "MXW01BluetoothBridge"
STARTUP_LINK = "MX01 Thermal Printer Bridge.lnk"
NAME_PREFIXES = ("MX01", "MXW01")
SERVICE_UUIDS = (
    "0000ae30-0000-1000-8000-00805f9b34fb",
    "0000af30-0000-1000-8000-00805f9b34fb",
)
CONTROL_UUID = "0000ae01-0000-1000-8000-00805f9b34fb"
DATA_UUID = "0000ae03-0000-1000-8000-00805f9b34fb"
RASTER_WIDTH = 384
BYTES_PER_ROW = RASTER_WIDTH // 8
DARKNESS = 200
THRESHOLD = 128
WRITE_CHUNK = 20
REGISTRY_KEY = r"Software\MX01Bridge"


def quiet_process_options() -> dict[str, int]:
    """Hide helper-console windows on Windows without changing other platforms."""
    if os.name == "nt":
        return {"creationflags": subprocess.CREATE_NO_WINDOW}
    return {}


def _registry_value(name: str, default: str = "") -> str:
    if os.name != "nt":
        return default
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, REGISTRY_KEY) as key:
            value, _ = winreg.QueryValueEx(key, name)
            return str(value)
    except (OSError, ImportError):
        return default


def data_dir() -> Path:
    override = os.environ.get("MX01BRIDGE_DATA_DIR") or _registry_value("DataDir")
    if override:
        return Path(override)
    if os.name == "nt":
        return Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "Libki" / "Printer"
    return Path.home() / ".local" / "share" / "MX01Bridge"


def config_path() -> Path:
    return data_dir() / "config.json"


def incoming_pdf_path() -> Path:
    return data_dir() / "incoming.pdf"


def error_path() -> Path:
    return data_dir() / "last-error.json"


def connection_state_path() -> Path:
    return data_dir() / "bridge-connection.json"


def write_connection_state(state: str, detail: str = "") -> None:
    try:
        data_dir().mkdir(parents=True, exist_ok=True)
        path = connection_state_path()
        temp_path = path.with_suffix(".tmp")
        temp_path.write_text(json.dumps({
            "state": state,
            "detail": detail[:240],
            "updated": time.time(),
        }), encoding="utf-8")
        temp_path.replace(path)
    except OSError:
        pass


def read_connection_state() -> tuple[str, str]:
    try:
        data = json.loads(connection_state_path().read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return str(data.get("state", "")), str(data.get("detail", ""))
    except (OSError, json.JSONDecodeError):
        pass
    return "", ""


def load_config() -> dict[str, Any]:
    path = config_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Cannot read saved device configuration at {path}: {exc}") from exc


def save_config(device: Any) -> None:
    data_dir().mkdir(parents=True, exist_ok=True)
    config_path().write_text(json.dumps({
        "device_name": device.name or "MX01",
        "address": device.address,
        "selected_at": datetime.now().astimezone().isoformat(timespec="seconds"),
    }, indent=2) + "\n", encoding="utf-8")


def write_error(exc: BaseException, code: int = 1) -> None:
    try:
        data_dir().mkdir(parents=True, exist_ok=True)
        error_path().write_text(json.dumps({
            "code": int(code), "message": str(exc),
            "at": datetime.now().astimezone().isoformat(timespec="seconds"),
        }, indent=2) + "\n", encoding="utf-8")
    except OSError:
        pass


def clear_error() -> None:
    try:
        error_path().unlink(missing_ok=True)
    except OSError:
        pass


def setup_logging() -> None:
    log_dir = data_dir()
    log_dir.mkdir(parents=True, exist_ok=True)
    handlers: list[logging.Handler] = [logging.FileHandler(log_dir / "bridge.log", encoding="utf-8")]
    if sys.stdout and getattr(sys.stdout, "isatty", lambda: False)():
        handlers.append(logging.StreamHandler(sys.stdout))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", handlers=handlers, force=True)


def is_windows_admin() -> bool:
    try:
        import ctypes
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except (AttributeError, OSError):
        return False


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def run_powershell(command: str, *, require_admin: bool = False) -> int:
    if os.name != "nt":
        print("This command must be run on Windows.", file=sys.stderr)
        return 2
    if require_admin and not is_windows_admin():
        print("Open PowerShell or Terminal as Administrator and run this command again.", file=sys.stderr)
        return 1
    try:
        result = subprocess.run([
            "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass", "-Command", command,
        ], capture_output=True, text=True, timeout=90, check=False, **quiet_process_options())
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        print(f"PowerShell failed: {exc}", file=sys.stderr)
        return 2
    if result.stdout.strip():
        print(result.stdout.strip())
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)
    return result.returncode


def install_queue() -> int:
    if os.name != "nt":
        print("This command must be run on Windows.", file=sys.stderr)
        return 2
    if not is_windows_admin():
        print("Print queue installation requires Administrator privileges.", file=sys.stderr)
        return 1
    data_dir().mkdir(parents=True, exist_ok=True)
    acl = subprocess.run(["icacls.exe", str(data_dir()), "/grant", "*S-1-5-18:(OI)(CI)M", "/T", "/C"], capture_output=True, text=True, check=False, **quiet_process_options())
    if acl.returncode != 0:
        print("Could not grant the Windows Print Spooler access to the handoff folder: " + (acl.stderr.strip() or acl.stdout.strip()), file=sys.stderr)
        return 3
    name, port = ps_quote(PRINTER_NAME), ps_quote(str(incoming_pdf_path()))
    ps = rf"""
$ErrorActionPreference = 'Stop'
$printerName = {name}; $portName = {port}; $driverName = 'Microsoft Print To PDF'
$existing = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
if ($existing) {{
  if ($existing.DriverName -ne $driverName -or $existing.PortName -ne $portName) {{ throw "A different queue named '$printerName' already exists; no changes were made." }}
  Write-Output "Already installed: $printerName"; exit 0
}}
$driver = Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue
if (-not $driver) {{ throw "The built-in '$driverName' driver is unavailable. Enable Microsoft Print to PDF in Windows Features, then retry." }}
$port = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
if (-not $port) {{ Add-PrinterPort -Name $portName }}
Add-Printer -Name $printerName -DriverName $driver.Name -PortName $portName
Write-Output "Installed print queue: $printerName"
Write-Output "Internal PDF handoff: $portName"
"""
    return run_powershell(ps, require_admin=True)


def remove_queue() -> int:
    name, port = ps_quote(PRINTER_NAME), ps_quote(str(incoming_pdf_path()))
    ps = rf"""
$ErrorActionPreference = 'Stop'
$printerName = {name}; $portName = {port}
$printer = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
if ($printer) {{
  if ($printer.PortName -ne $portName -or $printer.DriverName -ne 'Microsoft Print To PDF') {{ throw 'Refusing to remove a queue not created for this bridge.' }}
  Remove-Printer -Name $printerName -Confirm:$false; Write-Output "Removed queue: $printerName"
}} else {{ Write-Output 'Queue was not installed.' }}
$stillUsed = Get-Printer | Where-Object {{ $_.PortName -eq $portName }}
if (-not $stillUsed -and (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {{ Remove-PrinterPort -Name $portName; Write-Output 'Removed bridge local port.' }}
"""
    return run_powershell(ps, require_admin=True)


def resolve_profile(account: str) -> tuple[str, str]:
    """Return (SID, profile path) for a Windows account selected in the manager."""
    if os.name != "nt":
        raise RuntimeError("Windows account resolution is available only on Windows.")
    if not account:
        raise RuntimeError("Select a Windows account in the MX01 Bridge Manager.")
    account_ps = ps_quote(account)
    command = rf"""
$ErrorActionPreference='Stop'; $account={account_ps}
try {{ $sid=(New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value }}
catch {{
  if ($account -notmatch '\\') {{ $account="$env:COMPUTERNAME\$account" }}
  $sid=(New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
}}
$key='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$sid
$profile=(Get-ItemProperty -LiteralPath $key -ErrorAction Stop).ProfileImagePath
if (-not $profile) {{ throw "Windows profile not found for $account" }}
Write-Output ($sid+'|'+[Environment]::ExpandEnvironmentVariables($profile))
"""
    result = subprocess.run(["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command], capture_output=True, text=True, timeout=30, check=False, **quiet_process_options())
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"Could not resolve Windows account {account!r}.")
    line = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    sid, sep, profile = line.partition("|")
    if not sep or not sid.startswith("S-") or not profile:
        raise RuntimeError(f"Could not locate the Windows profile for account {account!r}.")
    return sid, profile


def write_registry_value(name: str, value: str) -> None:
    if os.name != "nt":
        return
    import winreg
    with winreg.CreateKeyEx(winreg.HKEY_LOCAL_MACHINE, REGISTRY_KEY, 0, winreg.KEY_SET_VALUE) as key:
        winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)


def common_startup_dir() -> Path:
    return Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup"


def grant_data_access(sid: str = "", *, all_users: bool = False) -> None:
    data_dir().mkdir(parents=True, exist_ok=True)
    principals = ["*S-1-5-18:(OI)(CI)M"]
    if all_users:
        principals.append("*S-1-5-32-545:(OI)(CI)M")
    elif sid:
        principals.append(f"*{sid}:(OI)(CI)M")
    result = subprocess.run([
        "icacls.exe", str(data_dir()), "/grant", *principals, "/T", "/C",
    ], capture_output=True, text=True, check=False, **quiet_process_options())
    if result.returncode != 0:
        audience = "all Windows users" if all_users else "the configured Windows account"
        raise RuntimeError(f"Could not grant {audience} and the Windows Print Spooler access to the bridge data folder: " + (result.stderr.strip() or result.stdout.strip()))


def install_startup(scope: str = "all", account: str = "") -> int:
    if os.name != "nt":
        print("This command must be run on Windows.", file=sys.stderr)
        return 2
    if not is_windows_admin():
        print("Startup setup must run elevated so the shortcut and data permissions can be configured.", file=sys.stderr)
        return 1
    if scope not in {"only", "except", "all"}:
        print("Startup scope must be only, except, or all.", file=sys.stderr)
        return 2
    account = account.strip() if scope != "all" else ""
    if scope != "all" and not account:
        user = os.environ.get("USERNAME", "").strip()
        domain = os.environ.get("USERDOMAIN", "").strip()
        account = f"{domain}\\{user}" if domain and user else user
    sid, profile = "", ""
    try:
        if scope != "all":
            if not account:
                raise RuntimeError("Select a Windows account for the selected startup option.")
            sid, profile = resolve_profile(account)
        grant_data_access(sid, all_users=(scope != "only"))
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 3
    script = str(Path(__file__).resolve())
    runner = Path(sys.executable).with_name("pythonw.exe")
    if not runner.exists():
        runner = Path(sys.executable)
    startup = str(Path(profile) / "AppData" / "Roaming" / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup") if scope == "only" else str(common_startup_dir())
    if scope == "only":
        description = f"Run the MX01 thermal printer bridge only for {account}."
        status_message = f"Startup configured only for {account}"
    elif scope == "except":
        description = f"Run the MX01 thermal printer bridge for all users except {account}."
        status_message = f"Startup configured for all users except {account}"
    else:
        description = "Run the MX01 thermal printer bridge for all Windows users."
        status_message = "Startup configured for all Windows users"
    stale_links = {str(common_startup_dir() / STARTUP_LINK)}
    for old_profile in {_registry_value("ProfileDir"), profile}:
        if old_profile:
            stale_links.add(str(Path(old_profile) / "AppData" / "Roaming" / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / STARTUP_LINK))
    stale_links.discard(str(Path(startup) / STARTUP_LINK))
    stale_paths = ",".join(ps_quote(link) for link in sorted(stale_links))
    command = rf"""
$ErrorActionPreference='Stop'; $startup={ps_quote(startup)}
New-Item -ItemType Directory -Path $startup -Force | Out-Null
$ws=New-Object -ComObject WScript.Shell
$link=$ws.CreateShortcut((Join-Path $startup {ps_quote(STARTUP_LINK)}))
$link.TargetPath={ps_quote(str(runner))}; $link.Arguments={ps_quote('"' + script + '" run')}
$link.WorkingDirectory={ps_quote(str(Path(script).parent))}; $link.Description={ps_quote(description)}
$link.Save()
$stale=@({stale_paths})
foreach ($p in $stale) {{ if (Test-Path -LiteralPath $p) {{ Remove-Item -LiteralPath $p -Force }} }}
Write-Output {ps_quote(status_message)}
"""
    code = run_powershell(command, require_admin=True)
    if code == 0:
        write_registry_value("SelectedUser", account)
        write_registry_value("ProfileDir", profile)
        write_registry_value("StartupScope", scope)
        write_registry_value("StartupEnabled", "1")
        clear_error()
    return code


def remove_startup(*, stop_bridge: bool = True) -> int:
    if os.name != "nt":
        print("This command must be run on Windows.", file=sys.stderr)
        return 2
    profiles = {_registry_value("ProfileDir")}
    for account in {_registry_value("SelectedUser"), _registry_value("LibkiUser")}:
        if not account:
            continue
        try:
            _, profile = resolve_profile(account)
            profiles.add(profile)
        except Exception:
            pass
    links = {str(common_startup_dir() / STARTUP_LINK)}
    for profile in profiles:
        if profile:
            links.add(str(Path(profile) / "AppData" / "Roaming" / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / STARTUP_LINK))
    script = str(Path(__file__).resolve())
    paths = ",".join(ps_quote(link) for link in sorted(links))
    ps = rf"""
$ErrorActionPreference='Stop'
$paths=@({paths})
foreach ($p in $paths) {{ if (Test-Path -LiteralPath $p) {{ Remove-Item -LiteralPath $p -Force; Write-Output 'Removed bridge startup shortcut.' }} }}
"""
    if stop_bridge:
        ps += rf"""
$scriptPath={ps_quote(script)}
$running=Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -and $_.CommandLine.Contains($scriptPath) -and $_.CommandLine -match '\srun(\s|$)' }}
foreach ($proc in $running) {{ Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }}
if ($running) {{ Start-Sleep -Seconds 2; Write-Output 'Stopped the MX01 bridge process.' }}
"""
    return run_powershell(ps, require_admin=True)


def disable_startup() -> int:
    code = remove_startup(stop_bridge=True)
    if code == 0:
        write_registry_value("StartupEnabled", "0")
    return code


def status_text() -> str:
    if os.name != "nt":
        return "DISABLED | This bridge runs on Windows only."
    if not _registry_value("InstallDir"):
        return "DISABLED | The MX01 bridge is not installed."
    try:
        check = subprocess.run(
            ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
             f"$p=Get-Printer -Name {ps_quote(PRINTER_NAME)} -ErrorAction SilentlyContinue; if($p){{'OK'}}else{{'MISSING'}}"],
            capture_output=True, text=True, timeout=15, check=False, **quiet_process_options())
        if check.returncode != 0 or check.stdout.strip().splitlines()[-1:] != ["OK"]:
            return "ERROR 6 | The MX01 Thermal Printer Windows queue is missing. Reinstall or repair the queue."
    except (OSError, subprocess.TimeoutExpired):
        return "ERROR 6 | Could not query the Windows print queue."
    scope = _registry_value("StartupScope", "only").casefold()
    if scope not in {"only", "except", "all"}:
        return "ERROR 8 | Startup scope is invalid; reopen setup and choose a valid option."
    if _registry_value("StartupEnabled", "1") == "0":
        return "DISABLED | Automatic startup is turned off."
    account = (_registry_value("SelectedUser") or _registry_value("LibkiUser")) if scope != "all" else ""
    if scope != "all" and not account:
        return "DISABLED | Select a Windows account in MX01 Bridge Manager."
    if scope == "only":
        profile = _registry_value("ProfileDir")
        if not profile:
            try:
                _, profile = resolve_profile(account)
            except Exception as exc:
                return f"ERROR 3 | Selected Windows account cannot be resolved: {exc}"
        link = Path(profile) / "AppData" / "Roaming" / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / STARTUP_LINK
        scope_label = f"only for {account}"
    else:
        link = common_startup_dir() / STARTUP_LINK
        scope_label = "for all users" if scope == "all" else f"for all users except {account}"
    if not link.exists():
        return "DISABLED | Automatic startup shortcut is missing."
    lock_path = data_dir() / "bridge.running"
    active = False
    try:
        import msvcrt
        handle = lock_path.open("a+b")
        handle.seek(0)
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        except OSError:
            active = True
        handle.close()
    except OSError:
        pass
    if active:
        state, detail = read_connection_state()
        if state == "connected":
            return f"CONNECTED | BLE printer connection is active ({scope_label})."
        if state == "connecting":
            return f"DISCONNECTED | Bridge is active and trying to connect to the MX01. {detail}".strip()
        if detail:
            return f"DISCONNECTED | Bridge is active but not connected to the MX01. {detail}"
        return "DISCONNECTED | Bridge is active but has not connected to the MX01 yet."
    config = load_config()
    if not config.get("address"):
        return "DISABLED | No printer is saved yet. Connect once, or let automatic MX01 discovery finish."
    if error_path().exists():
        try:
            error = json.loads(error_path().read_text(encoding="utf-8"))
            return f"ERROR {int(error.get('code', 1))} | {error.get('message', 'Bridge startup failed.')}"
        except Exception:
            return "ERROR 1 | A bridge error was recorded; see bridge.log."
    if scope == "only":
        return f"DISABLED | Waiting for {account} to sign in."
    return f"DISABLED | Waiting for an allowed user to sign in ({scope_label})."


def write_status_file(path: str) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(status_text() + "\n", encoding="utf-8")


def _canonical_user(value: str) -> str:
    return value.strip().strip('"').strip("'").replace("/", "\\").casefold()


def current_user_names() -> set[str]:
    names = {os.environ.get("USERNAME", "").casefold()}
    if os.name == "nt":
        try:
            result = subprocess.run(["whoami.exe"], capture_output=True, text=True, timeout=10, check=False, **quiet_process_options())
            if result.returncode == 0:
                names.add(result.stdout.strip().casefold())
        except (OSError, subprocess.TimeoutExpired):
            pass
        domain = os.environ.get("USERDOMAIN", "").casefold()
        user = os.environ.get("USERNAME", "").casefold()
        if user:
            names.update({user, f"{domain}\\{user}", f".\\{user}"})
    return {item for item in names if item}


def ensure_allowed_user() -> bool:
    scope = _registry_value("StartupScope", "only").casefold()
    if scope == "all":
        return True
    if scope not in {"only", "except"}:
        raise RuntimeError(f"Invalid bridge startup scope {scope!r}; run setup to choose a valid option.")
    configured = _canonical_user(_registry_value("SelectedUser") or _registry_value("LibkiUser"))
    if not configured:
        raise RuntimeError("No Windows account is selected in MX01 Bridge Manager; bridge will remain disabled.")
    candidates = {_canonical_user(value) for value in current_user_names()}
    candidates.update(value.split("\\", 1)[-1] for value in tuple(candidates))
    is_selected_user = configured in candidates
    if scope == "only" and not is_selected_user:
        logging.info("Bridge skipped for this account; it is configured to run only for %s", configured)
        return False
    if scope == "except" and is_selected_user:
        logging.info("Bridge skipped for %s by the all-except-selected-user setting", configured)
        return False
    return True


def setup_device_sync() -> None:
    from bleak import BleakScanner
    devices = asyncio.run(BleakScanner.discover(timeout=8.0))
    if not devices:
        raise RuntimeError("No Bluetooth LE devices found. Turn on the MX01 printer and retry.")
    print("Nearby BLE devices:")
    for index, device in enumerate(devices, 1):
        hint = " [MX-name match]" if (device.name or "").upper().startswith(NAME_PREFIXES) else ""
        print(f" {index}. {device.name or '(unnamed)'}  {device.address}{hint}")
    while True:
        answer = input("Select the MX01 number (or q to cancel): ").strip()
        if answer.lower() in {"q", "quit", "cancel"}:
            return
        try:
            selected = devices[int(answer) - 1]
        except (ValueError, IndexError):
            print("Enter one of the listed numbers.")
            continue
        try:
            asyncio.run(validate_printer(selected))
            save_config(selected)
            clear_error()
            print(f"Verified and saved {selected.name or 'MX01'} at {selected.address}.")
            return
        except Exception as exc:
            print(f"Not a compatible printer: {exc}")


def setup_device_gui() -> int:
    if os.name != "nt":
        print("Bluetooth selection is available only on Windows.", file=sys.stderr)
        return 2
    print("A console will list nearby Bluetooth LE devices. Select the MX01 and confirm its address.")
    setup_device_sync()
    return 0


async def validate_printer(device: Any) -> None:
    from bleak import BleakClient
    client = BleakClient(device, timeout=25.0)
    await client.connect()
    try:
        services = client.services
        if not any(services.get_service(uuid) is not None for uuid in SERVICE_UUIDS):
            raise RuntimeError("expected AE30 or AF30 printer service was not found")
        if services.get_characteristic(CONTROL_UUID) is None:
            raise RuntimeError("control characteristic AE01 was not found")
        if services.get_characteristic(DATA_UUID) is None:
            raise RuntimeError("raster-data characteristic AE03 was not found")
    finally:
        await client.disconnect()


def crc8(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (((crc << 1) ^ 0x07) if crc & 0x80 else (crc << 1)) & 0xFF
    return crc


async def send_control(client: Any, characteristic: Any, command: int, payload: bytes = b"") -> None:
    packet = bytes((0x22, 0x21, command, 0x00, len(payload) & 0xFF, (len(payload) >> 8) & 0xFF))
    packet += payload + bytes((crc8(payload), 0xFF))
    for start in range(0, len(packet), WRITE_CHUNK):
        await client.write_gatt_char(characteristic, packet[start:start + WRITE_CHUNK], response=False)
        await asyncio.sleep(0.001)


def rasterize_page(page: Any) -> tuple[int, bytes]:
    import pymupdf as fitz
    rect = page.rect
    if rect.width <= 0 or rect.height <= 0:
        raise ValueError("PDF page has an invalid size")
    pix = page.get_pixmap(matrix=fitz.Matrix(RASTER_WIDTH / rect.width, RASTER_WIDTH / rect.width), colorspace=fitz.csGRAY, alpha=False)
    if pix.width != RASTER_WIDTH or pix.n != 1:
        raise ValueError(f"Could not render page at {RASTER_WIDTH}-pixel grayscale width")
    width, height = pix.width, pix.height
    if height > 65535:
        raise ValueError("Page exceeds the printer protocol's 65,535-row limit")
    values = [float(value) for value in pix.samples]
    for y in range(height):
        for x in range(width):
            index = y * width + x
            old = values[index]
            new = 0.0 if old < THRESHOLD else 255.0
            values[index] = new
            error = (old - new) / 8.0
            if x + 1 < width: values[index + 1] += error
            if x + 2 < width: values[index + 2] += error
            if y + 1 < height:
                if x > 0: values[index + width - 1] += error
                values[index + width] += error
                if x + 1 < width: values[index + width + 1] += error
            if y + 2 < height: values[index + width * 2] += error
    packed = bytearray(height * BYTES_PER_ROW)
    for y in range(height):
        line_start, out_start = y * width, y * BYTES_PER_ROW
        for x in range(width):
            if values[line_start + x] < 128:
                packed[out_start + x // 8] |= 1 << (x % 8)
    return height, bytes(packed)


async def send_pdf(client: Any, control: Any, data: Any, pdf_path: Path) -> None:
    import pymupdf as fitz
    pdf = fitz.open(pdf_path)
    try:
        if pdf.page_count == 0:
            raise ValueError("PDF contains no pages")
        for page_number, page in enumerate(pdf, start=1):
            height, image = rasterize_page(page)
            logging.info("Printing %s page %d/%d (%d raster rows)", pdf_path.name, page_number, pdf.page_count, height)
            await send_control(client, control, 0xA2, bytes((DARKNESS, 0x00)))
            await asyncio.sleep(0.1)
            await send_control(client, control, 0xA9, bytes((height & 0xFF, (height >> 8) & 0xFF, 0x30, 0x00)))
            await asyncio.sleep(0.1)
            for offset in range(0, len(image), WRITE_CHUNK):
                await client.write_gatt_char(data, image[offset:offset + WRITE_CHUNK], response=False)
                await asyncio.sleep(0.001)
    finally:
        pdf.close()


def create_test_pdf(path: Path) -> None:
    import pymupdf as fitz
    doc = fitz.open()
    page = doc.new_page(width=384, height=600)
    page.insert_text((18, 38), "TEST", fontsize=28, fontname="helv")
    page.insert_text((18, 56), "MX01 BLE printer bridge", fontsize=10, fontname="helv")
    assets = Path(__file__).resolve().parent / "assets"
    cali_path = assets / "test-image.jpg"
    creeper_path = assets / "crep.jpeg"
    for image_path in (cali_path, creeper_path):
        if not image_path.exists():
            raise FileNotFoundError(f"Bundled test image is missing: {image_path}")
    page.insert_text((36, 74), "CALI CAT", fontsize=9, fontname="helv")
    page.insert_text((230, 74), "CREEPER", fontsize=9, fontname="helv")
    page.insert_image(fitz.Rect(18, 80, 186, 228), filename=str(cali_path), keep_proportion=True)
    page.insert_image(fitz.Rect(198, 80, 366, 228), filename=str(creeper_path), keep_proportion=True)
    page.insert_text((18, 256), "The quick brown fox jumps over the lazy dog.", fontsize=10, fontname="helv")
    page.insert_text((18, 294), "9 x 9 DOT GRID", fontsize=10, fontname="helv")
    dot_radius = 3.0
    dot_spacing = 11.0
    grid_left, grid_top = 142.0, 310.0
    for row in range(9):
        for column in range(9):
            center = fitz.Point(grid_left + column * dot_spacing, grid_top + row * dot_spacing)
            page.draw_circle(center, dot_radius, color=(0, 0, 0), fill=(0, 0, 0), width=0.5)

    face_center = fitz.Point(192, 478)
    face_radius = 34
    page.draw_circle(face_center, face_radius, color=(0, 0, 0), width=2)
    page.draw_circle(fitz.Point(face_center.x - 12, face_center.y - 9), 3, color=(0, 0, 0), fill=(0, 0, 0))
    page.draw_circle(fitz.Point(face_center.x + 12, face_center.y - 9), 3, color=(0, 0, 0), fill=(0, 0, 0))
    smile = page.new_shape()
    smile.draw_bezier(
        fitz.Point(face_center.x - 16, face_center.y + 7),
        fitz.Point(face_center.x - 9, face_center.y + 25),
        fitz.Point(face_center.x + 9, face_center.y + 25),
        fitz.Point(face_center.x + 16, face_center.y + 7),
    )
    smile.finish(color=(0, 0, 0), width=2)
    smile.commit()
    page.insert_text((18, 558), "If this page printed, the BLE path is working.", fontsize=9, fontname="helv")
    doc.save(path)
    doc.close()


async def test_print() -> None:
    from bleak import BleakClient
    import pymupdf  # noqa: F401
    cfg = load_config()
    if not cfg.get("address"):
        raise RuntimeError("No printer is selected. Finish Bluetooth setup first.")
    data_dir().mkdir(parents=True, exist_ok=True)
    pdf_path = data_dir() / f"MX01-TEST-{datetime.now():%Y%m%d-%H%M%S}.pdf"
    create_test_pdf(pdf_path)
    client = BleakClient(str(cfg["address"]), timeout=25.0)
    try:
        await client.connect()
        services = client.services
        if not any(services.get_service(uuid) is not None for uuid in SERVICE_UUIDS):
            raise RuntimeError("Connected device does not expose the expected AE30/AF30 printer service.")
        control = services.get_characteristic(CONTROL_UUID)
        data = services.get_characteristic(DATA_UUID)
        if control is None or data is None:
            raise RuntimeError("Printer is missing control AE01 or raster-data AE03 characteristic.")
        await send_pdf(client, control, data, pdf_path)
        print("Test page sent to the MX01 printer.")
    finally:
        if client.is_connected:
            await client.disconnect()
        try:
            pdf_path.unlink(missing_ok=True)
        except OSError:
            pass


def ensure_job_dirs() -> tuple[Path, Path, Path]:
    base = data_dir()
    pending, sent, failed = base / "pending", base / "sent", base / "failed"
    for folder in (pending, sent, failed):
        folder.mkdir(parents=True, exist_ok=True)
    return pending, sent, failed


def unique_job_path(folder: Path, original_name: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    return folder / f"{stamp}-{Path(original_name).name.replace(' ', '_')}"


async def watch_print_queue(queue: asyncio.Queue[Path], pending_dir: Path) -> None:
    incoming = incoming_pdf_path()
    incoming.parent.mkdir(parents=True, exist_ok=True)
    while True:
        try:
            if incoming.exists() and incoming.stat().st_size > 100:
                first = incoming.stat()
                await asyncio.sleep(1.5)
                if not incoming.exists():
                    continue
                second = incoming.stat()
                if first.st_size == second.st_size and first.st_mtime_ns == second.st_mtime_ns:
                    with incoming.open("rb") as handle:
                        signature = handle.read(5)
                    if signature != b"%PDF-":
                        logging.warning("Handoff file is not a PDF yet; waiting for another stable check")
                        await asyncio.sleep(1.0)
                        continue
                    destination = unique_job_path(pending_dir, incoming.name)
                    try:
                        os.replace(incoming, destination)
                        logging.info("Captured Windows print job: %s", destination.name)
                        await queue.put(destination)
                    except FileNotFoundError:
                        pass
            await asyncio.sleep(0.5)
        except asyncio.CancelledError:
            raise
        except Exception:
            logging.exception("Print-queue watcher error")
            await asyncio.sleep(2.0)


async def scan_candidate_devices(config: dict[str, Any]) -> list[Any]:
    from bleak import BleakScanner
    devices = await BleakScanner.discover(timeout=6.0)
    address = str(config.get("address", "")).replace(":", "").replace("-", "").lower()
    ordered: list[Any] = []
    seen: set[str] = set()

    def add(matches: list[Any]) -> None:
        for device in matches:
            key = str(device.address).replace(":", "").replace("-", "").casefold()
            if key and key not in seen:
                seen.add(key)
                ordered.append(device)

    if address:
        add([dev for dev in devices if str(dev.address).replace(":", "").replace("-", "").casefold() == address.casefold()])
    name = str(config.get("device_name", "")).strip().lower()
    if name:
        add([dev for dev in devices if dev.name and dev.name.strip().casefold() == name.casefold()])
    add([dev for dev in devices if dev.name and dev.name.strip().casefold().startswith(("mx01", "mxw01"))])
    return ordered


async def connect_printer(config: dict[str, Any]) -> tuple[Any, Any, Any]:
    from bleak import BleakClient
    while True:
        latest_config = load_config()
        if latest_config.get("address") != config.get("address"):
            config.clear()
            config.update(latest_config)
            logging.info("Reloaded selected printer configuration for reconnect")
        write_connection_state("connecting", "Searching for the saved MX01 Bluetooth printer.")
        try:
            devices = await scan_candidate_devices(config)
            if not devices:
                write_connection_state("disconnected", "Saved MX01 not found; scanning again shortly.")
                logging.info("No saved device or MX01-named BLE printer found; scanning again shortly")
                await asyncio.sleep(4.0)
                continue
            last_error = "No candidate exposed the MX01 printer protocol."
            for device in devices:
                client = BleakClient(device, timeout=25.0)
                try:
                    write_connection_state("connecting", f"Checking {device.name or 'unnamed BLE device'}.")
                    await client.connect()
                    services = client.services
                    if not any(services.get_service(uuid) is not None for uuid in SERVICE_UUIDS):
                        raise RuntimeError("expected AE30 or AF30 printer service was not found")
                    control, data = services.get_characteristic(CONTROL_UUID), services.get_characteristic(DATA_UUID)
                    if control is None or data is None:
                        raise RuntimeError("printer is missing control AE01 or raster-data AE03 characteristic")
                    if device.address != config.get("address") or device.name != config.get("device_name"):
                        save_config(device)
                        config.update(load_config())
                    logging.info("Connected to %s at %s", device.name or "MX01", device.address)
                    write_connection_state("connected", f"Connected to {device.name or 'MX01'} at {device.address}.")
                    return client, control, data
                except Exception as exc:
                    last_error = f"{device.name or 'Unnamed BLE device'} was not a compatible printer: {exc}"
                    logging.info("Skipping BLE candidate %s at %s: %s", device.name or "unnamed", device.address, exc)
                    try:
                        if client.is_connected:
                            await client.disconnect()
                    except Exception:
                        pass
            write_connection_state("disconnected", last_error)
            await asyncio.sleep(5.0)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            write_connection_state("disconnected", f"Bluetooth connection failed: {exc}")
            logging.warning("Bluetooth connect failed (%s); retrying in 5 seconds", exc)
            await asyncio.sleep(5.0)


async def bridge_worker(queue: asyncio.Queue[Path], pending_dir: Path, sent_dir: Path, failed_dir: Path) -> None:
    config = load_config()
    for path in sorted(pending_dir.glob("*.pdf")):
        await queue.put(path)
    client = control = data = None
    while True:
        try:
            if client is None or not client.is_connected:
                client, control, data = await connect_printer(config)
            try:
                job_path = await asyncio.wait_for(queue.get(), timeout=1.0)
            except asyncio.TimeoutError:
                continue
            try:
                await send_pdf(client, control, data, job_path)
                destination = unique_job_path(sent_dir, job_path.name)
                shutil.move(str(job_path), str(destination))
                logging.info("Printed successfully; archived at %s", destination)
            except Exception as exc:
                destination = unique_job_path(failed_dir, job_path.name)
                if job_path.exists(): shutil.move(str(job_path), str(destination))
                logging.exception("Print failed for %s: %s", job_path.name, exc)
            finally:
                queue.task_done()
        except asyncio.CancelledError:
            raise
        except Exception:
            logging.exception("Bridge worker error; reconnecting")
            if client is not None:
                try: await client.disconnect()
                except Exception: pass
            client = control = data = None
            await asyncio.sleep(3.0)


async def run_bridge() -> None:
    if not ensure_allowed_user():
        return
    try:
        import bleak  # noqa: F401
        import pymupdf  # noqa: F401
    except ImportError as exc:
        raise RuntimeError(f"Missing bundled dependency: {exc}") from exc
    setup_logging()
    clear_error()
    data_dir().mkdir(parents=True, exist_ok=True)
    pending, sent, failed = ensure_job_dirs()
    queue: asyncio.Queue[Path] = asyncio.Queue()
    logging.info("MX01 bridge started with scope=%s (selected user=%s)", _registry_value("StartupScope", "all"), _registry_value("SelectedUser") or "not used")
    watcher = asyncio.create_task(watch_print_queue(queue, pending))
    worker = asyncio.create_task(bridge_worker(queue, pending, sent, failed))
    try:
        await asyncio.gather(watcher, worker)
    finally:
        watcher.cancel(); worker.cancel()
        await asyncio.gather(watcher, worker, return_exceptions=True)


class FileLock:
    def __init__(self) -> None:
        self.handle: Any = None
    def __enter__(self) -> "FileLock":
        import msvcrt
        path = data_dir() / "bridge.running"
        path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = path.open("a+b")
        self.handle.seek(0)
        if self.handle.read(1) == b"":
            self.handle.seek(0); self.handle.write(b"0"); self.handle.flush()
        self.handle.seek(0)
        try:
            msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            self.handle.close()
            self.handle = None
            raise BridgeAlreadyRunning("The MX01 bridge is already active in another Windows session.") from exc
        return self
    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if self.handle:
            try:
                import msvcrt
                self.handle.seek(0); msvcrt.locking(self.handle.fileno(), msvcrt.LK_UNLCK, 1)
            finally:
                self.handle.close()


class BridgeAlreadyRunning(RuntimeError):
    pass


def main() -> int:
    parser = argparse.ArgumentParser(description="MX01 Windows print queue to Bluetooth thermal printer bridge")
    parser.add_argument("action", choices=("setup-device", "setup-device-gui", "install-queue", "install-startup", "run", "status", "test-print", "remove-queue", "remove-startup", "disable-startup"))
    parser.add_argument("--scope", choices=("only", "except", "all"), default="all", help="Startup audience when installing the startup shortcut")
    parser.add_argument("--user", default="", help="Windows account selected for the only/except startup options")
    parser.add_argument("--output", help="Write one-line health status to this file")
    args = parser.parse_args()
    if args.action == "setup-device":
        if os.name != "nt":
            print("Bluetooth selection must be run on Windows.", file=sys.stderr); return 2
        try: setup_device_sync(); return 0
        except Exception as exc: print(str(exc), file=sys.stderr); return 1
    if args.action == "setup-device-gui":
        try: return setup_device_gui()
        except Exception as exc: print(str(exc), file=sys.stderr); return 1
    if args.action == "install-queue": return install_queue()
    if args.action == "install-startup": return install_startup(args.scope, args.user)
    if args.action == "remove-queue": return remove_queue()
    if args.action == "remove-startup": return remove_startup(stop_bridge=True)
    if args.action == "disable-startup": return disable_startup()
    if args.action == "status":
        text = status_text()
        if args.output:
            write_status_file(args.output)
        else:
            print(text)
        return 0
    if args.action == "test-print":
        try:
            setup_logging()
            asyncio.run(test_print())
            clear_error()
            return 0
        except Exception as exc:
            write_error(exc, 4)
            print(f"Test print failed: {exc}", file=sys.stderr)
            return 4
    if args.action == "run":
        if os.name != "nt":
            print("The bridge must run on Windows.", file=sys.stderr); return 2
        try:
            setup_logging()
            if not ensure_allowed_user():
                return 0
            with FileLock():
                asyncio.run(run_bridge())
        except BridgeAlreadyRunning as exc:
            logging.info("%s", exc)
            return 0
        except KeyboardInterrupt:
            logging.info("Bridge stopped by user"); return 0
        except Exception as exc:
            logging.exception("Bridge stopped: %s", exc)
            write_error(exc, 5)
            return 5
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
