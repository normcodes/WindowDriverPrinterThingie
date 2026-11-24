# MX01 Thermal Printer Bridge

The Windows bridge installs an **MX01 Thermal Printer** queue and forwards its Microsoft Print to PDF output to a compatible MX01-family thermal printer over Bluetooth LE. The bridge uses a bundled Python runtime and pinned BLE/PDF/WinRT dependencies.

## Install

Download and run **MX01-Thermal-Printer-Bridge-Setup.exe** from the [latest GitHub Release](https://github.com/normcodes/WindowDriverPrinterThingie/releases/latest). The small setup bootstrapper requires internet access, downloads the current full installer from this repository, then launches it. The full installer requests Administrator permission and offers two folder choices:

- Program install root: default `C:\Program Files\Printer`; the application is placed in its dedicated `MX01 Thermal Printer Bridge` subfolder.
- Bridge data folder: default `C:\ProgramData\Libki\Printer`; it holds settings, the saved printer address, PDF handoff, logs, and print-job history. Uninstall removes this entire selected folder, so choose a dedicated location without unrelated files.

Setup creates the Windows queue named **MX01 Thermal Printer** using the built-in **Microsoft Print to PDF** driver. Fresh installs enable automatic startup for all Windows users by default and start the bridge. The Manager is listed directly in Start as **MX01 Thermal Printer Bridge Manager**, is also in the **MX01 Thermal Printer Bridge** Start folder, and has a Desktop shortcut; setup's finish page can open it too. If Setup finds an old install record but the Manager or bundled runtime files are missing, it returns to the installation-path pages rather than showing a misleading maintenance screen. Re-running Setup on a valid existing install recreates the Start and Desktop shortcuts.

## MX01 Bridge Manager

The Manager reports the actual BLE connection state and has **Refresh** and **Connect** actions. The bridge automatically scans for BLE devices with advertised names beginning `MX01` or `MXW01`, validates service AE30/AF30 plus characteristics AE01 and AE03, and saves a compatible device name/address for reconnects. Discovery also works when no address has been saved. **Connect** opens the interactive device selector for manual selection.

In the Manager, turn automatic startup on/off and choose **Selected user only**, **All except selected user**, or **All Windows users**. The account dropdown is populated from local Windows profiles; account/scope settings are stored in the bridge registry configuration, not read from Libki's INI. Changing shared startup settings may require Administrator approval. Enabling startup also starts the bridge immediately when the current account is included; disabling startup removes the startup shortcut and stops the running bridge.

## Libki printing

Set Libki Print Manager's physical queue to `MX01 Thermal Printer` and use printer type `PrintManager`. Jobs released by staff print silently through the Windows queue and bridge. Ordinary Windows applications can select the same queue from their Print dialog. The Manager intentionally has no Test button because the previous test did not reliably represent the regular queue-printing route.

The bridge log is in the selected data folder as `bridge.log`; `last-error.json` records the latest error. Uninstall removes the bridge-created queue and unused port, Start-menu/Desktop shortcuts, startup links, installed program folder, registry values, and the selected data folder.

## Build

Build from the repository root with NSIS 3.09 or newer:

```sh
makensis mx01-installer/MX01-Setup.nsi
makensis mx01-installer/MX01-Bootstrapper.nsi
```

`MX01-Setup.nsi` produces `MX01-Thermal-Printer-Bridge-Payload.exe`, the full offline app installer. `MX01-Bootstrapper.nsi` produces the user-facing `MX01-Thermal-Printer-Bridge-Setup.exe`; it downloads the payload from this repository's latest Release. The pinned wheel bundle, embeddable Python runtime, official Python installer (used only if no system Python is registered), and print assets are included under `mx01-installer/`.

The current build was compiled in a Linux ARM64 sandbox for x64 Windows. Python syntax, mocked BLE discovery logic, and NSIS compilation can be checked here, but Windows PowerShell UI behavior, UAC/account permissions, Print Spooler behavior, BLE radio discovery, and physical printing must still be validated on a Windows PC.
