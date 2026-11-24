!cd ".."
Unicode true
Name "MX01 Thermal Printer Bridge Setup"
Caption "MX01 Thermal Printer Bridge Setup"
OutFile "MX01-Thermal-Printer-Bridge-Setup.exe"
RequestExecutionLevel admin
ShowInstDetails show
SetCompressor /SOLID lzma
SetCompressorDictSize 32
; This tiny downloader is fetched over HTTPS; bypass its startup CRC prompt for Windows compatibility.
CRCCheck off

!include "MUI2.nsh"
!include "LogicLib.nsh"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_TITLE "MX01 Bridge setup finished"
!define MUI_FINISHPAGE_TEXT "The latest MX01 Thermal Printer Bridge installer was launched."
!insertmacro MUI_PAGE_INSTFILES
!define MUI_PAGE_CUSTOMFUNCTION_PRE FinishPagePre
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "English"

!define PAYLOAD_URL "https://github.com/normcodes/WindowDriverPrinterThingie/releases/latest/download/MX01-Thermal-Printer-Bridge-Payload.exe"

Var ExitCode
Var PayloadPath

Function FinishPagePre
  GetDlgItem $0 $HWNDPARENT 1
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 3
  ShowWindow $0 ${SW_HIDE}
FunctionEnd

Section "Download and launch MX01 setup"
  StrCpy $PayloadPath "$TEMP\MX01-Thermal-Printer-Bridge-Payload.exe"
  Delete "$PayloadPath"
  DetailPrint "Downloading the latest MX01 Thermal Printer Bridge installer from GitHub…"
  SetOutPath "$PLUGINSDIR"
  File "mx01-installer\download-latest.ps1"
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$PLUGINSDIR\download-latest.ps1" -Uri "${PAYLOAD_URL}" -Destination "$PayloadPath"' $ExitCode
  Delete "$PLUGINSDIR\download-latest.ps1"
  ${If} $ExitCode != 0
    Delete "$PayloadPath"
    MessageBox MB_ICONSTOP "The latest installer could not be downloaded from GitHub. Check your internet connection and try again."
    Abort
  ${EndIf}
  IfFileExists "$PayloadPath" payload_downloaded payload_missing
  payload_missing:
    MessageBox MB_ICONSTOP "GitHub did not provide the MX01 installer payload. The project release may be unavailable."
    Abort
  payload_downloaded:
  DetailPrint "Starting the full MX01 installer…"
  ExecWait '"$PayloadPath"' $ExitCode
  Delete "$PayloadPath"
SectionEnd

VIProductVersion "1.0.0.0"
VIAddVersionKey /LANG=${LANG_ENGLISH} "ProductName" "MX01 Thermal Printer Bridge Setup"
VIAddVersionKey /LANG=${LANG_ENGLISH} "FileDescription" "Downloads the latest MX01 Bridge installer from GitHub"
VIAddVersionKey /LANG=${LANG_ENGLISH} "LegalCopyright" "Copyright 2026 MX01 Thermal Printer Bridge"
VIAddVersionKey /LANG=${LANG_ENGLISH} "FileVersion" "1.0.0"
VIAddVersionKey /LANG=${LANG_ENGLISH} "ProductVersion" "1.0.0"
VIAddVersionKey /LANG=${LANG_ENGLISH} "OriginalFilename" "MX01-Thermal-Printer-Bridge-Setup.exe"
