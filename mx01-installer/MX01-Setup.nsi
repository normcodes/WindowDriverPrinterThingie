!cd ".."
Unicode true
Name "MX01 Thermal Printer Bridge"
Caption "MX01 Thermal Printer Bridge Setup"
OutFile "MX01-Thermal-Printer-Bridge-Payload.exe"
Icon "mx01-installer/assets/mx01-bridge.ico"
UninstallIcon "mx01-installer/assets/mx01-bridge.ico"
InstallDir "C:\Program Files\Printer"
InstallDirRegKey HKLM "Software\MX01Bridge" "InstallRoot"
RequestExecutionLevel admin
ShowInstDetails show
ShowUnInstDetails show
SetCompressor /SOLID lzma
SetCompressorDictSize 64
SetDateSave on

!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"
!include "WinMessages.nsh"
!include "FileFunc.nsh"

!define APP_KEY "Software\MX01Bridge"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\MX01Bridge"
!define APP_TITLE "MX01 Thermal Printer Bridge"
!define APP_VERSION "1.4.5"

!define MUI_ABORTWARNING
!define MUI_DIRECTORYPAGE_TEXT_TOP "Choose the program install root. Setup places MX01 Thermal Printer Bridge in a dedicated subfolder here. The next page lets you choose the separate bridge data folder. Default: C:\Program Files\Printer"
!define MUI_FINISHPAGE_TITLE "MX01 bridge installation complete"
!define MUI_FINISHPAGE_TEXT "The Windows queue is installed and the bridge is set to start automatically for all Windows users. Open MX01 Bridge Manager to change startup and account settings."
!define MUI_FINISHPAGE_RUN "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
!define MUI_FINISHPAGE_RUN_PARAMETERS "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File $\"$INSTDIR\MX01-Bridge-Manager.ps1$\""
!define MUI_FINISHPAGE_RUN_TEXT "Open MX01 Bridge Manager"

Var IsInstalled
Var DataDir
Var InstallRoot
Var DataEdit
Var BrowseButton
Var StartupScope
Var MaintDialog
Var StatusLabel
Var StatusText
Var UninstallButton
Var ManagerButton
Var RefreshButton
Var ConnectButton
Var FinishButton
Var TempStatus
Var ExitCode

Page custom MaintenanceCreate MaintenanceLeave
!define MUI_PAGE_CUSTOMFUNCTION_PRE FreshOnlyPre
!insertmacro MUI_PAGE_DIRECTORY
Page custom DataPageCreate DataPageLeave FreshOnlyPre
!define MUI_PAGE_CUSTOMFUNCTION_PRE FreshOnlyPre
!insertmacro MUI_PAGE_INSTFILES
!define MUI_PAGE_CUSTOMFUNCTION_PRE FreshOnlyPre
!insertmacro MUI_PAGE_FINISH
UninstPage uninstConfirm
UninstPage instfiles
!insertmacro MUI_LANGUAGE "English"
VIProductVersion "1.4.5.0"
VIAddVersionKey /LANG=${LANG_ENGLISH} "ProductName" "MX01 Thermal Printer Bridge"
VIAddVersionKey /LANG=${LANG_ENGLISH} "FileDescription" "MX01 Thermal Printer Bridge Setup"
VIAddVersionKey /LANG=${LANG_ENGLISH} "LegalCopyright" "Copyright 2026 MX01 Thermal Printer Bridge"
VIAddVersionKey /LANG=${LANG_ENGLISH} "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=${LANG_ENGLISH} "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=${LANG_ENGLISH} "OriginalFilename" "MX01-Thermal-Printer-Bridge-Payload.exe"

Function .onInit
  SetRegView 64
  ReadEnvStr $DataDir "ProgramData"
  ${If} $DataDir == ""
    StrCpy $DataDir "$WINDIR\..\ProgramData"
  ${EndIf}
  StrCpy $DataDir "$DataDir\Libki\Printer"
  StrCpy $StartupScope "all"
  ReadRegStr $0 HKLM "${APP_KEY}" "InstallDir"
  ${If} $0 != ""
    IfFileExists "$0\MX01-Bridge-Manager.ps1" installed_manager_found repair_install
  installed_manager_found:
    IfFileExists "$0\runtime\pythonw.exe" installed_files_found repair_install
  installed_files_found:
    StrCpy $IsInstalled "1"
    StrCpy $INSTDIR $0
    SetOverwrite on
    SetOutPath "$INSTDIR"
    File "mxw01_windows_print_menu.py"
    File "mx01-installer/MX01-Bridge-Manager.ps1"
    WriteUninstaller "$INSTDIR\uninstall.exe"
    CreateDirectory "$INSTDIR\assets"
    SetOutPath "$INSTDIR\assets"
    File "mx01-installer/assets/test-image.jpg"
    File "mx01-installer/assets/crep.jpeg"
    File "mx01-installer/assets/mx01-bridge.ico"
    SetShellVarContext all
    CreateDirectory "$SMPROGRAMS\MX01 Thermal Printer Bridge"
    CreateShortcut "$SMPROGRAMS\MX01 Thermal Printer Bridge\MX01 Bridge Manager.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "$INSTDIR\MX01-Bridge-Manager.ps1"' "$INSTDIR\assets\mx01-bridge.ico"
    CreateShortcut "$SMPROGRAMS\MX01 Thermal Printer Bridge Manager.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "$INSTDIR\MX01-Bridge-Manager.ps1"' "$INSTDIR\assets\mx01-bridge.ico"
    CreateShortcut "$DESKTOP\MX01 Bridge Manager.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "$INSTDIR\MX01-Bridge-Manager.ps1"' "$INSTDIR\assets\mx01-bridge.ico"
    SetShellVarContext current
    WriteRegStr HKLM "${APP_KEY}" "Version" "${APP_VERSION}"
    WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
    ReadRegStr $1 HKLM "${APP_KEY}" "DataDir"
    ${If} $1 != ""
      StrCpy $DataDir $1
    ${EndIf}
    Goto init_done
  repair_install:
    StrCpy $IsInstalled "0"
    ReadRegStr $1 HKLM "${APP_KEY}" "InstallRoot"
    ${If} $1 != ""
      StrCpy $INSTDIR $1
    ${EndIf}
    ReadRegStr $1 HKLM "${APP_KEY}" "DataDir"
    ${If} $1 != ""
      StrCpy $DataDir $1
    ${EndIf}
    Goto init_done
  ${Else}
    StrCpy $IsInstalled "0"
  ${EndIf}
init_done:
FunctionEnd

Function FindSystemPython
  StrCpy $R4 "0"
  StrCpy $R0 0
find_python_hklm:
  EnumRegKey $R1 HKLM "Software\Python\PythonCore" $R0
  StrCmp $R1 "" find_python_hkcu_init
  ReadRegStr $R2 HKLM "Software\Python\PythonCore\$R1\InstallPath" ""
  IfFileExists "$R2\python.exe" find_python_found
  IntOp $R0 $R0 + 1
  Goto find_python_hklm
find_python_hkcu_init:
  StrCpy $R0 0
find_python_hkcu:
  EnumRegKey $R1 HKCU "Software\Python\PythonCore" $R0
  StrCmp $R1 "" find_python_done
  ReadRegStr $R2 HKCU "Software\Python\PythonCore\$R1\InstallPath" ""
  IfFileExists "$R2\python.exe" find_python_found
  IntOp $R0 $R0 + 1
  Goto find_python_hkcu
find_python_found:
  StrCpy $R4 "1"
  Return
find_python_done:
FunctionEnd

Function EnsureSystemPython
  Call FindSystemPython
  ${If} $R4 == "1"
    DetailPrint "A registered Python installation was found; skipping separate Python setup."
    Return
  ${EndIf}
  DetailPrint "No registered Python installation was found. Installing Python 3.13.17 for all users…"
  SetOutPath "$PLUGINSDIR"
  File "mx01-installer/python-3.13.17-amd64.exe"
  ExecWait '"$PLUGINSDIR\python-3.13.17-amd64.exe" /quiet InstallAllUsers=1 PrependPath=0 Include_launcher=0 Include_test=0 AssociateFiles=0 Shortcuts=0' $ExitCode
  Delete "$PLUGINSDIR\python-3.13.17-amd64.exe"
  ${If} $ExitCode != 0
  ${AndIf} $ExitCode != 3010
    MessageBox MB_ICONEXCLAMATION "Standard Python could not be installed (error $ExitCode). The MX01 bridge still includes its own private Python runtime and can operate without a system Python installation."
  ${EndIf}
FunctionEnd

Function FreshOnlyPre
  ${If} $IsInstalled == "1"
    Abort
  ${EndIf}
  GetDlgItem $0 $HWNDPARENT 1
  ShowWindow $0 ${SW_SHOW}
  EnableWindow $0 1
  GetDlgItem $0 $HWNDPARENT 3
  ShowWindow $0 ${SW_SHOW}
  EnableWindow $0 1
FunctionEnd

Function MaintenanceCreate
  ${If} $IsInstalled != "1"
    Abort
  ${EndIf}
  GetDlgItem $0 $HWNDPARENT 1
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 3
  ShowWindow $0 ${SW_HIDE}
  nsDialogs::Create 1018
  Pop $MaintDialog
  ${If} $MaintDialog == error
    Abort
  ${EndIf}
  ${NSD_CreateLabel} 0 0 100% 38u "MX01 Thermal Printer Bridge is installed. Use the Manager from Start or the desktop to change startup settings and select Windows accounts."
  Pop $0
  ${NSD_CreateButton} 0 48u 48u 20u "Uninstall"
  Pop $UninstallButton
  ${NSD_OnClick} $UninstallButton OnUninstallClick
  ${NSD_CreateButton} 58u 48u 72u 20u "Open Manager"
  Pop $ManagerButton
  ${NSD_OnClick} $ManagerButton OnOpenManagerClick
  ${NSD_CreateButton} 140u 48u 48u 20u "Refresh"
  Pop $RefreshButton
  ${NSD_OnClick} $RefreshButton OnRefreshClick
  ${NSD_CreateButton} 196u 48u 48u 20u "Connect"
  Pop $ConnectButton
  ${NSD_OnClick} $ConnectButton OnOpenManagerClick
  ${NSD_CreateButton} 81% 78u 19% 20u "Finish"
  Pop $FinishButton
  ${NSD_OnClick} $FinishButton OnFinishClick
  ${NSD_CreateLabel} 0 78u 78% 30u "Status: checking…"
  Pop $StatusLabel
  Call RefreshHealth
  nsDialogs::Show
FunctionEnd

Function MaintenanceLeave
FunctionEnd

Function DataPageCreate
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}
  ${NSD_CreateLabel} 0 0 100% 42u "Choose where MX01 saves its settings, saved printer address, PDF handoff, print history, and logs. This folder is separate from the program folder. Uninstall removes the entire selected data folder, so use a dedicated folder with no unrelated files. Default: C:\ProgramData\Libki\Printer"
  Pop $1
  ${NSD_CreateText} 0 48u 78% 14u "$DataDir"
  Pop $DataEdit
  ${NSD_CreateButton} 81% 48u 19% 14u "Browse…"
  Pop $BrowseButton
  ${NSD_OnClick} $BrowseButton OnBrowseData
  nsDialogs::Show
FunctionEnd

Function OnBrowseData
  ${NSD_GetText} $DataEdit $DataDir
  nsDialogs::SelectFolderDialog "Select MX01 bridge data folder" "$DataDir"
  Pop $0
  ${If} $0 != ""
    ${NSD_SetText} $DataEdit $0
  ${EndIf}
FunctionEnd

Function DataPageLeave
  ${NSD_GetText} $DataEdit $DataDir
  ${If} $DataDir == ""
    MessageBox MB_ICONEXCLAMATION "Choose a data folder for bridge settings and logs."
    Abort
  ${EndIf}
FunctionEnd

Function RefreshHealth
  GetTempFileName $TempStatus
  ExecWait '"$INSTDIR\runtime\pythonw.exe" "$INSTDIR\mxw01_windows_print_menu.py" status --output "$TempStatus"' $ExitCode
  StrCpy $StatusText "ERROR $ExitCode | Could not read bridge health status."
  IfFileExists "$TempStatus" 0 status_done
    FileOpen $0 "$TempStatus" r
    FileRead $0 $StatusText
    FileClose $0
    Delete "$TempStatus"
  status_done:
  ${NSD_SetText} $StatusLabel "Status: $StatusText"
  StrCpy $0 $StatusText 9
  ${If} $0 == "CONNECTED"
    ShowWindow $RefreshButton ${SW_HIDE}
    ShowWindow $ConnectButton ${SW_HIDE}
  ${Else}
    ShowWindow $RefreshButton ${SW_SHOW}
    ShowWindow $ConnectButton ${SW_SHOW}
  ${EndIf}
FunctionEnd

Function OnRefreshClick
  Call RefreshHealth
FunctionEnd

Function OnOpenManagerClick
  ExecShell "open" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "$INSTDIR\MX01-Bridge-Manager.ps1"'
FunctionEnd

Function OnFinishClick
  Quit
FunctionEnd

Function OnUninstallClick
  MessageBox MB_YESNO|MB_ICONQUESTION "Completely uninstall the MX01 bridge? This removes its user or all-users startup link, Windows print queue, installed files, saved printer address, logs, and job archives in the selected data folder." IDNO uninstall_done
  IfFileExists "$INSTDIR\uninstall.exe" 0 uninstall_missing
    ExecWait '"$INSTDIR\uninstall.exe" /S' $ExitCode
    StrCpy $IsInstalled "0"
    EnableWindow $UninstallButton 0
    StrCpy $StatusText "DISABLED | Bridge and its data were removed."
    ${NSD_SetText} $StatusLabel "Status: $StatusText"
    Return
  uninstall_missing:
    StrCpy $StatusText "ERROR 7 | The uninstaller is missing."
    ${NSD_SetText} $StatusLabel "Status: $StatusText"
  uninstall_done:
FunctionEnd

Section "Install MX01 Thermal Printer Bridge" SEC_MAIN
  SetRegView 64
  Call EnsureSystemPython
  StrCpy $InstallRoot $INSTDIR
  StrCpy $INSTDIR "$InstallRoot\MX01 Thermal Printer Bridge"
  RMDir /r "$INSTDIR"
  CreateDirectory "$INSTDIR"
  SetOutPath "$INSTDIR"
  File "mxw01_windows_print_menu.py"
  File "mx01-installer/MX01-Bridge-Manager.ps1"
  File "mx01-installer/install_dependencies.py"
  File "mx01-installer/Select-MX01-Printer.bat"
  SetOutPath "$INSTDIR\runtime"
  File /r "mx01-installer/runtime\*.*"
  SetOutPath "$INSTDIR\assets"
  File "mx01-installer/assets/test-image.jpg"
  File "mx01-installer/assets/crep.jpeg"
  File "mx01-installer/assets/mx01-bridge.ico"
  SetOutPath "$INSTDIR\wheels"
  File /r "mx01-installer/wheels\*.*"

  CreateDirectory "$DataDir"
  WriteRegStr HKLM "${APP_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${APP_KEY}" "InstallRoot" "$InstallRoot"
  WriteRegStr HKLM "${APP_KEY}" "DataDir" "$DataDir"
  WriteRegStr HKLM "${APP_KEY}" "Version" "${APP_VERSION}"
  WriteRegStr HKLM "${APP_KEY}" "SelectedUser" ""
  WriteRegStr HKLM "${APP_KEY}" "StartupScope" "$StartupScope"
  WriteRegStr HKLM "${APP_KEY}" "StartupEnabled" "0"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayName" "${APP_TITLE}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "Publisher" "MX01 Thermal Printer Bridge"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoRepair" 0

  DetailPrint "Installing offline Python dependencies…"
  nsExec::ExecToLog '"$INSTDIR\runtime\python.exe" "$INSTDIR\install_dependencies.py" "$INSTDIR\wheels" "$INSTDIR\runtime\Lib\site-packages" "$DataDir\python-dependency-error.log"'
  Pop $ExitCode
  ${If} $ExitCode != 0
    MessageBox MB_ICONSTOP "The bundled Python components could not be initialized (error $ExitCode). Setup will stop. Diagnostic details, if available, were saved to: $DataDir\python-dependency-error.log"
    DeleteRegKey HKLM "${UNINSTALL_KEY}"
    DeleteRegKey HKLM "${APP_KEY}"
    Delete "$INSTDIR\mxw01_windows_print_menu.py"
    Delete "$INSTDIR\MX01-Bridge-Manager.ps1"
    Delete "$INSTDIR\install_dependencies.py"
    Delete "$INSTDIR\Select-MX01-Printer.bat"
    RMDir /r "$INSTDIR\runtime"
    RMDir /r "$INSTDIR\assets"
    RMDir /r "$INSTDIR\wheels"
    RMDir "$INSTDIR"
    Abort
  ${EndIf}
  Delete "$INSTDIR\install_dependencies.py"
  RMDir /r "$INSTDIR\wheels"

  DetailPrint "Installing the MX01 Thermal Printer Windows queue…"
  nsExec::ExecToLog '"$INSTDIR\runtime\python.exe" "$INSTDIR\mxw01_windows_print_menu.py" install-queue'
  Pop $ExitCode
  ${If} $ExitCode != 0
    MessageBox MB_ICONEXCLAMATION "The bridge files were installed, but the Windows print queue could not be created (error $ExitCode). Check that Microsoft Print to PDF is enabled. You can rerun setup after enabling it."
    FileOpen $1 "$DataDir\last-error.json" w
    FileWrite $1 '{"code":6,"message":"Windows print queue installation failed. Enable Microsoft Print to PDF and rerun setup."}'
    FileClose $1
  ${Else}
    DetailPrint "Windows queue created as MX01 Thermal Printer."
  ${EndIf}

  DetailPrint "Enabling automatic startup for all Windows users…"
  nsExec::ExecToLog '"$INSTDIR\runtime\python.exe" "$INSTDIR\mxw01_windows_print_menu.py" install-startup --scope all'
  Pop $ExitCode
  ${If} $ExitCode != 0
    WriteRegStr HKLM "${APP_KEY}" "StartupEnabled" "0"
    MessageBox MB_ICONEXCLAMATION "The bridge was installed, but automatic startup could not be enabled (error $ExitCode). Open MX01 Bridge Manager and use Apply / Save to enable it."
  ${Else}
    Exec '"$INSTDIR\runtime\pythonw.exe" "$INSTDIR\mxw01_windows_print_menu.py" run'
    Sleep 800
  ${EndIf}

  WriteUninstaller "$INSTDIR\uninstall.exe"
  SetShellVarContext all
  CreateDirectory "$SMPROGRAMS\MX01 Thermal Printer Bridge"
  CreateShortcut "$SMPROGRAMS\MX01 Thermal Printer Bridge\MX01 Bridge Manager.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "$INSTDIR\MX01-Bridge-Manager.ps1"' "$INSTDIR\assets\mx01-bridge.ico"
  CreateShortcut "$SMPROGRAMS\MX01 Thermal Printer Bridge Manager.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "$INSTDIR\MX01-Bridge-Manager.ps1"' "$INSTDIR\assets\mx01-bridge.ico"
  CreateShortcut "$DESKTOP\MX01 Bridge Manager.lnk" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "$INSTDIR\MX01-Bridge-Manager.ps1"' "$INSTDIR\assets\mx01-bridge.ico"
  CreateShortcut "$SMPROGRAMS\MX01 Thermal Printer Bridge\Uninstall.lnk" "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  SetRegView 64
  SetShellVarContext all
  ReadRegStr $DataDir HKLM "${APP_KEY}" "DataDir"
  IfFileExists "$INSTDIR\runtime\python.exe" 0 skip_bridge_cleanup
    nsExec::ExecToLog '"$INSTDIR\runtime\python.exe" "$INSTDIR\mxw01_windows_print_menu.py" remove-startup'
    Pop $ExitCode
    nsExec::ExecToLog '"$INSTDIR\runtime\python.exe" "$INSTDIR\mxw01_windows_print_menu.py" remove-queue'
    Pop $ExitCode
  skip_bridge_cleanup:
  Delete "$SMPROGRAMS\MX01 Thermal Printer Bridge\MX01 Bridge Manager.lnk"
  Delete "$SMPROGRAMS\MX01 Thermal Printer Bridge Manager.lnk"
  Delete "$DESKTOP\MX01 Bridge Manager.lnk"
  Delete "$SMPROGRAMS\MX01 Thermal Printer Bridge\Select MX01 Bluetooth Printer.lnk"
  Delete "$SMPROGRAMS\MX01 Thermal Printer Bridge\Uninstall.lnk"
  RMDir "$SMPROGRAMS\MX01 Thermal Printer Bridge"
  DeleteRegKey HKLM "${UNINSTALL_KEY}"
  DeleteRegKey HKLM "${APP_KEY}"
  Delete "$INSTDIR\mxw01_windows_print_menu.py"
  Delete "$INSTDIR\MX01-Bridge-Manager.ps1"
  Delete "$INSTDIR\Select-MX01-Printer.bat"
  Delete "$INSTDIR\assets\mx01-bridge.ico"
  Delete "$INSTDIR\uninstall.exe"
  Delete "$INSTDIR\install_dependencies.py"
  RMDir /r "$INSTDIR\runtime"
  RMDir /r "$INSTDIR\assets"
  RMDir /r "$INSTDIR\wheels"
  RMDir "$INSTDIR"
  ${If} $DataDir != ""
    RMDir /r "$DataDir"
  ${EndIf}
SectionEnd
