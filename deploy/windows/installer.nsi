; Subconscious NSIS Installer Script
; Requires NSIS 3.x and the following plugins: nsProcess (optional)
; Build with: makensis installer.nsi
; The PyInstaller output directory (dist\Subconscious\) must exist before running.

Unicode True

;------------------------------------------------------------------
; General configuration
;------------------------------------------------------------------
!define APP_NAME        "Subconscious"
!define APP_VERSION     "0.1.10"          ; updated by CI at build time
!define PUBLISHER       "Ancilla"
!define APP_URL         "https://subconscious.chat"
!define EXE_NAME        "Subconscious.exe"
!define INSTALL_DIR     "$LOCALAPPDATA\${PUBLISHER}\${APP_NAME}"
!define REG_KEY         "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
!define STARTMENU_DIR   "$SMPROGRAMS\${APP_NAME}"

; Output artifact name — CI renames this to subconscious-setup-x64.exe
OutFile "..\..\dist\windows\subconscious-setup-x64.exe"

Name "${APP_NAME} ${APP_VERSION}"
InstallDir "${INSTALL_DIR}"
RequestExecutionLevel user          ; no UAC prompt — installs to %LOCALAPPDATA%
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUnInstDetails show

;------------------------------------------------------------------
; Pages
;------------------------------------------------------------------
!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON   "..\..\src\subconscious\assets\favicon.ico"
!define MUI_UNICON "..\..\src\subconscious\assets\favicon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\..\LICENCE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;------------------------------------------------------------------
; Installation
;------------------------------------------------------------------
Section "Install" SecInstall
  SectionIn RO                        ; required section, can't be deselected

  SetOutPath "$INSTDIR"

  ; Copy all files produced by PyInstaller / flet pack
  ; Handle both onedir output (dist\Subconscious\*.*) and onefile output (dist\Subconscious.exe)
  File /nonfatal /r "..\..\dist\Subconscious\*.*"
  File /nonfatal "..\..\dist\Subconscious.exe"

  ; Write uninstaller
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; --- Registry: Add/Remove Programs entry ---
  WriteRegStr   HKCU "${REG_KEY}" "DisplayName"          "${APP_NAME}"
  WriteRegStr   HKCU "${REG_KEY}" "DisplayVersion"       "${APP_VERSION}"
  WriteRegStr   HKCU "${REG_KEY}" "Publisher"            "${PUBLISHER}"
  WriteRegStr   HKCU "${REG_KEY}" "URLInfoAbout"         "${APP_URL}"
  WriteRegStr   HKCU "${REG_KEY}" "InstallLocation"      "$INSTDIR"
  WriteRegStr   HKCU "${REG_KEY}" "UninstallString"      '"$INSTDIR\Uninstall.exe"'
  WriteRegStr   HKCU "${REG_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${REG_KEY}" "NoModify"             1
  WriteRegDWORD HKCU "${REG_KEY}" "NoRepair"             1
  WriteRegStr   HKCU "${REG_KEY}" "DisplayIcon"          "$INSTDIR\${EXE_NAME}"

  ; --- Start Menu shortcut (appears in "All apps") ---
  CreateDirectory "${STARTMENU_DIR}"
  CreateShortcut  "${STARTMENU_DIR}\${APP_NAME}.lnk" \
                  "$INSTDIR\${EXE_NAME}" \
                  "" \
                  "$INSTDIR\${EXE_NAME}" 0

  ; --- Optional: Desktop shortcut ---
  ; CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${EXE_NAME}" "" "$INSTDIR\${EXE_NAME}" 0

SectionEnd

;------------------------------------------------------------------
; Uninstallation
;------------------------------------------------------------------
Section "Uninstall"

  ; Remove application files
  RMDir /r "$INSTDIR"

  ; Remove Start Menu shortcuts
  RMDir /r "${STARTMENU_DIR}"

  ; Remove registry entries
  DeleteRegKey HKCU "${REG_KEY}"

SectionEnd
