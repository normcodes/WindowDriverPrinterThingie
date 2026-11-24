# External facts used to build the MX01 installer

- Libki current Windows client installer source: https://github.com/Libki/libki-client/blob/master/deploy/windows/installer-wizard.iss
  - It reads `%ProgramData%\Libki\Libki Kiosk Management System.ini`.
  - Its installer labels the setting “Run only for this user” and reads `[node] onlyRunFor`.
- Libki manual: https://manual.libki.org/master/libki-manual.pdf
  - Windows Libki client settings are in `C:\ProgramData\Libki\Libki Kiosk Management System.ini`.
  - The “Run only for this user” value limits the Libki client to that Windows account.
  - Print Manager configuration uses `physical_printer_name`, `type: PrintManager`, and optional `auto_release`.
- Libki Print Manager source: https://github.com/Libki/libki-print-manager/blob/master/networkclient.cpp
  - It invokes SumatraPDF with `-silent` and `-print-to "<physical_printer_name>"`, so released jobs do not require the Windows print dialog.
- Python official Windows download page: https://www.python.org/downloads/windows/
  - The current stable 3.13.17 Windows 64-bit installer link is https://www.python.org/ftp/python/3.13.17/python-3.13.17-amd64.exe.
  - The installer is being built for standard x64 Windows (not Windows ARM64).
- MX01 printer BLE protocol: https://github.com/n0rm0/printercontrol
  - Service UUID AE30 with AF30 fallback; control characteristic AE01; data characteristic AE03; 384-pixel raster width and custom framed control commands.
- User-provided test image URL: https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRJj0XLAG8NDoxZCaTrkCnfkmRr8NwCsT1pSzeSO5LtmQ&s=10

The bridge uses the official x64 embeddable Python 3.13.17 ZIP and pinned Bleak/PyMuPDF and Windows WinRT wheels, installed locally into its private runtime. The setup package also includes the official standard x64 Python 3.13.17 installer; it checks the HKLM and HKCU PythonCore registry entries and runs the installer for all users only when no registered Python executable is found. System setup leaves PATH, file associations, and the Python launcher unchanged. The bridge itself does not depend on system Python.

- NSIS scripting reference, Page callbacks: https://nsis.sourceforge.io/Docs/Chapter4.html
  - Built-in pages can be skipped in a pre callback with `Abort`; custom pages have creator/leave callbacks and can also be omitted from their creator function. This informs the setup/maintenance page branch.

## Dependency initialization repair

The Bluetooth WinRT projection imports companion modules for RFCOMM, device radios, and Windows networking. The original offline wheel bundle omitted those projections, which could make the setup smoke test fail even though the PC was online. Added these matching `4!10.0.28000.2957` wheels:

- `winrt_windows_devices_bluetooth_rfcomm-4!10.0.28000.2957-py3-none-any.whl` — https://pypi.org/project/winrt-Windows.Devices.Bluetooth.Rfcomm/
- `winrt_windows_devices_radios-4!10.0.28000.2957-py3-none-any.whl` — https://pypi.org/project/winrt-Windows.Devices.Radios/
- `winrt_windows_networking-4!10.0.28000.2957-py3-none-any.whl` — https://pypi.org/project/winrt-Windows.Networking/

The bootstrap script writes the Python traceback plus the wheel inventory, site-packages path, Bleak package-file status, and `sys.path` to `python-dependency-error.log` under the selected data folder if extraction or import validation fails. Windows diagnostics showed the Bleak file existed and site-packages was on `sys.path` despite the import failure. The bootstrap now invalidates Python's import caches after wheel extraction in case the initially empty site-packages folder had been cached at interpreter startup. The NSIS error message displays the log path; actual imports and installer behavior still require a Windows test.

Version `1.3.3` removes a leftover dedicated application subfolder at the start of a fresh install, without deleting the selected data folder, and moves the maintenance status label above the bottom navigation bar. Version `1.3.4` launches the bridge immediately after automatic startup is enabled, when the currently signed-in account is included in the selected scope; it still creates the normal sign-in shortcut. Version `1.3.5` hides console windows for non-interactive installer, maintenance, and test commands; the interactive Bluetooth selector is unchecked by default on the finish page. Version `1.3.6` also starts PowerShell, `icacls`, and identity-check helpers with `CREATE_NO_WINDOW` to avoid transient empty consoles. Version `1.3.7` writes live BLE connection state, adds Refresh, and shows Connect unless the bridge reports an active printer link. Connect opens the interactive selector, then relaunches the bridge when auto-start is enabled and refreshes status; reconnect attempts reload changed saved addresses. Compiled with NSIS 3.09 in the Linux ARM64 sandbox; Windows UI and printing behavior have not been tested.


## Version 1.4.0 source/build update

- Added `MX01-Bridge-Manager.ps1`, a dark WinForms settings app with live bridge/BLE status, Refresh and Connect actions, automatic-startup toggle, local Windows-profile selection, and selected-user-only / all-except-selected-user / all-users scopes. The Manager reads/writes the `SelectedUser` contract through the bridge; it does not inspect Libki INI settings. The former Test button is intentionally absent.
- The bridge prefers the saved device address, but can run with no saved address and automatically scans for BLE names beginning `MX01` or `MXW01`; it validates service AE30/AF30 and characteristics AE01/AE03 before saving/connecting.
- The fresh NSIS flow asks for the program install root only, keeps data under `%ProgramData%\Libki\Printer`, includes the Manager in fresh installs and upgrades, refreshes the uninstaller on upgrades, and offers the Manager after setup. Version metadata is 1.4.0.
- Validation in the Linux ARM64 sandbox: Python `py_compile` passed; mocked scanner/address-priority/GATT checks passed; NSIS 3.09 compiled a 58,465,918-byte PE32 Windows installer. The final installer SHA-256 is `6a750dcaaa6584bcb3ddd55555315d2535e079bccadbea2ab58677bc1d7d8800`.
- A PowerShell runtime and Windows host were unavailable, so Manager syntax/UI behavior, UAC and account scopes, Windows Print Spooler, physical BLE, and print delivery remain unverified on Windows.
- At the time of v1.4.0, the user-owned destination repository had not yet been confirmed. The user later explicitly selected `https://github.com/normcodes/WindowDriverPrinterThingie`; do not publish project files to `n0rm0/printercontrol`, which is only a third-party protocol reference repository.


## Version 1.4.1 follow-up

Added an all-users Desktop shortcut alongside the Start-menu Manager shortcut, enabled the common startup task on fresh installs by default, and launches the bridge immediately after successful startup configuration. The Manager therefore opens with automatic startup checked on new installs; users can change the setting and scope in the app. The v1.4.1 NSIS build completed successfully as a 58,467,619-byte Windows PE installer; SHA-256: `ef13eca869dd7a058dfd2315113d429b555a6b528c231e7710b0349303359044`. As before, the Windows UI, account permissions, BLE, and real printing are not tested in this Linux environment.

## Version 1.4.2 and GitHub release packaging

- Added the separate data-folder picker (default `%ProgramData%\Libki\Printer`) alongside the program install-root page. The Manager is linked from Start and the Desktop; fresh installs enable all-users startup by default. Automatic BLE discovery accepts `MX01`/`MXW01` name prefixes and validates the expected service/characteristics.
- Made the main NSIS script build from repository-relative paths and output `MX01-Thermal-Printer-Bridge-Payload.exe`. Added `MX01-Bootstrapper.nsi` and `download-latest.ps1`; the small user-facing `MX01-Thermal-Printer-Bridge-Setup.exe` fetches the payload from `https://github.com/normcodes/WindowDriverPrinterThingie/releases/latest/download/MX01-Thermal-Printer-Bridge-Payload.exe` and launches the full installer. The bootstrapper itself asks only for Administrator permission; the full installer asks for the program and data locations.
- Compiled with NSIS 3.09 in the Linux ARM64 sandbox. Payload: 58,466,283 bytes, SHA-256 `eaf835329c6ab17717d33d6e4814165b0ddafe5d843a6d535bf087ad40e4725e`. Bootstrapper: 136,227 bytes, SHA-256 `a6a8d80f940034b387b1ad940b3db750ea5929660747dea8fd4297488c37a671`.
- Python syntax, mocked BLE discovery/GATT checks, and NSIS compilation passed in the sandbox. Windows PowerShell UI behavior, UAC and selected-account permissions, BLE radio discovery, Windows Print Spooler behavior, and actual physical printing remain unverified and require testing on a Windows machine.
