@echo off
setlocal
cd /d "%~dp0"
title Select MX01 Bluetooth Printer
echo MX01 Thermal Printer Bridge - Bluetooth setup
echo Keep the MX01 printer powered on and close to this PC.
echo The bridge will scan for BLE devices and verify the selected printer.
echo.
"%~dp0runtime\python.exe" "%~dp0mxw01_windows_print_menu.py" setup-device
if errorlevel 1 echo Bluetooth setup did not complete. Check that Bluetooth is enabled and retry from the Start menu.
