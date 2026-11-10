@echo off
rem ======================================================================
rem  UEFI Boot Repair - CMD/diskpart version, English (works in plain WinRE,
rem  including the Windows setup USB via Shift+F10).
rem  Usage: repair-boot-uefi-en.cmd             (repair)
rem         repair-boot-uefi-en.cmd /simulate   (detect only, changes nothing; /simular also works)
rem  ASCII-only text on purpose (WinPE console).
rem ======================================================================
setlocal EnableExtensions EnableDelayedExpansion
title UEFI Boot Repair - CMD
set "SIMULAR=0"
if /i "%~1"=="/simular" set "SIMULAR=1"
if /i "%~1"=="/simulate" set "SIMULAR=1"
set "ESPGUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
set "ASSIGNED=0"
set "LTR="
set "LETRAS=C D E F G H I J K L M N O P Q R S T U V W Y Z"

echo ==============================================================
echo   WINDOWS UEFI BOOT REPAIR  - CMD version
if "%SIMULAR%"=="1" echo   SIMULATION MODE: nothing will be changed
echo ==============================================================

rem ---------------------------------------------------------------- log
call :timestamp
set "LOGDIR="
for %%I in ("%~dp0..") do set "RAIZ=%%~fI"
if /i not "%~d0"=="X:" call :trylog "%RAIZ%"
if not defined LOGDIR for %%L in (%LETRAS%) do if not defined LOGDIR if exist "%%L:\ReparoBoot\" call :trylog "%%L:\ReparoBoot"
if not defined LOGDIR call :trylog "X:\ReparoBoot-logs"
if not defined LOGDIR (
  echo ERROR: could not create the log folder.
  pause
  exit /b 1
)
set "LOG=%LOGDIR%\repair-boot.log"
set "TMPD=%LOGDIR%\tmp"
mkdir "%TMPD%" 2>nul
call :log "Log: %LOG%"
if /i "%LOGDIR:~0,2%"=="X:" call :log "WARNING: log saved on X: - RAM. It is lost on reboot."

rem ---------------------------------------------------------------- ambiente
if /i not "%SystemDrive%"=="X:" (
  if "%SIMULAR%"=="0" (
    call :log "ERROR: this script only changes disks when running in WinPE/WinRE - drive X:. Outside it use /simulate."
    goto falha
  )
  call :log "WARNING: outside WinPE, running detection only."
)

rem ---------------------------------------------------------------- 1. firmware
call :log ""
call :log "=== 1. Checking firmware ==="
set "FW="
for /f "tokens=3" %%a in ('reg query "HKLM\System\CurrentControlSet\Control" /v PEFirmwareType 2^>nul ^| find /i "PEFirmwareType"') do set "FW=%%a"
if "%FW%"=="0x2" (
  call :log "OK: UEFI firmware - PEFirmwareType = 2."
  goto fw_ok
)
if "%FW%"=="0x1" (
  call :log "ERROR: the PC booted in BIOS/Legacy mode. This method is UEFI only. Boot the USB drive from its UEFI entry in the boot menu."
  goto falha
)
if "%SIMULAR%"=="1" (
  call :log "WARNING: PEFirmwareType missing - ignored in simulation."
  goto fw_ok
)
call :log "ERROR: could not confirm the firmware. Aborting for safety."
goto falha
:fw_ok

rem ---------------------------------------------------------------- 2. BitLocker
call :log ""
call :log "=== 2. Checking BitLocker ==="
call :tem manage-bde
if errorlevel 1 (
  call :log "WARNING: manage-bde does not exist in this environment; could not check BitLocker."
  call :log "WARNING: if Windows is not found, the disk may be encrypted."
  goto bde_fim
)
manage-bde -status > "%TMPD%\bde.txt" 2>&1
>>"%LOG%" type "%TMPD%\bde.txt"
rem WinPE has no findstr: use find (Locked without Unlocked / Bloqueado without Desbloqueado)
set "BDELOCK=1"
type "%TMPD%\bde.txt" | find /i "locked" | find /v /i "unlocked" >nul && set "BDELOCK=0"
type "%TMPD%\bde.txt" | find /i "bloqueado" | find /v /i "desbloqueado" >nul && set "BDELOCK=0"
cmd /c exit /b %BDELOCK%
if errorlevel 1 (
  call :log "OK: no locked BitLocker volume."
  goto bde_fim
)
call :log "WARNING: there is a LOCKED BitLocker volume. See its letter in the manage-bde -status output:"
type "%TMPD%\bde.txt"
call :log "Get the 48-digit recovery key at https://aka.ms/myrecoverykey and run:"
call :log "    manage-bde -unlock C: -RecoveryPassword 111111-222222-333333-444444-555555-666666-777777-888888"
call :log "Replace C: with the letter of the locked volume. Then run this script again."
set "R="
set /p "R=Continue anyway? Y/N [N]: "
if /i not "!R!"=="Y" (
  call :log "Aborted so you can unlock BitLocker."
  goto sair
)
:bde_fim

rem ---------------------------------------------------------------- 3. Windows
call :log ""
call :log "=== 3. Looking for the Windows installation ==="
set "N=0"
for %%L in (%LETRAS%) do (
  if exist "%%L:\Windows\System32\winload.efi" (
    set /a N+=1
    set "WIN!N!=%%L"
    call :log "Found: %%L:\Windows"
  )
)
if "%N%"=="0" (
  call :log "ERROR: no Windows found. Causes: BitLocker locked, missing Intel RST/RAID driver - load it with drvload - or wrong disk."
  goto falha
)
if "%N%"=="1" (
  set "WIN=!WIN1!"
  goto win_ok
)
call :log "WARNING: more than one Windows found:"
for /l %%i in (1,1,%N%) do echo   [%%i] !WIN%%i!:
:win_pergunta
set "R="
set /p "R=Number of the Windows to repair: "
set "WIN="
for /l %%i in (1,1,%N%) do if "!R!"=="%%i" set "WIN=!WIN%%i!"
if not defined WIN goto win_pergunta
:win_ok
call :log "OK: selected Windows: %WIN%:"

rem ---------------------------------------------------------------- 4. disco
call :log ""
call :log "=== 4. Identifying disk and EFI partition ==="
(
  echo select volume %WIN%
  echo detail volume
) > "%TMPD%\dp_vol.txt"
call :dpr "%TMPD%\dp_vol.txt" "%TMPD%\out_vol.txt"
set "DISK="
for /f "usebackq tokens=1-3" %%a in ("%TMPD%\out_vol.txt") do if "%%a"=="*" if not defined DISK set "DISK=%%c"
if not defined DISK (
  call :log "ERROR: could not find the disk of volume %WIN%:. See the log."
  goto falha
)

(
  echo list disk
) > "%TMPD%\dp_ld.txt"
call :dpr "%TMPD%\dp_ld.txt" "%TMPD%\out_ld.txt"
set "DSIZE=?"
set "DFREE=?"
for /f "usebackq tokens=1-7" %%a in ("%TMPD%\out_ld.txt") do if "%%b"=="%DISK%" set "DSIZE=%%d %%e" & set "DFREE=%%f %%g"

(
  echo select disk %DISK%
  echo detail disk
) > "%TMPD%\dp_dd.txt"
call :dpr "%TMPD%\dp_dd.txt" "%TMPD%\out_dd.txt"
set "PREV="
set "MODEL="
for /f "usebackq delims=" %%a in ("%TMPD%\out_dd.txt") do (
  set "LINE=%%a"
  if not defined MODEL if not "!LINE:ID=!"=="!LINE!" if not "!LINE::=!"=="!LINE!" set "MODEL=!PREV!"
  set "PREV=%%a"
)
if not defined MODEL set "MODEL=unknown"

(
  echo select disk %DISK%
  echo uniqueid disk
) > "%TMPD%\dp_uid.txt"
call :dpr "%TMPD%\dp_uid.txt" "%TMPD%\out_uid.txt"
set "EHGPT="
find "{" "%TMPD%\out_uid.txt" >nul && set "EHGPT=1"
rem also checks the asterisk in the Gpt column of "list disk"
for /f "usebackq delims=" %%a in ("%TMPD%\out_ld.txt") do (
  set "LD=%%a"
  for /f "tokens=1,2" %%x in ("%%a") do if "%%y"=="%DISK%" (
    for /l %%n in (1,1,20) do if "!LD:~-1!"==" " set "LD=!LD:~0,-1!"
    if "!LD:~-1!"=="*" set "EHGPT=1"
  )
)
if not defined EHGPT (
  call :log "ERROR: disk %DISK% is not GPT - looks like MBR. UEFI boot needs GPT."
  call :log "Manual option, back up first: mbr2gpt /validate /disk:%DISK%  and then  mbr2gpt /convert /disk:%DISK%"
  goto falha
)
call :log "Disk %DISK%: %MODEL% - %DSIZE% - GPT - free %DFREE%"

set "MINESP=100"
fsutil fsinfo sectorinfo %WIN%: 2>nul | find /i "LogicalBytesPerSector" | find "4096" >nul
if not errorlevel 1 set "MINESP=260"
call :log "Minimum EFI size for this disk: %MINESP% MB"

rem find the EFI by GPT type, never assume partition 2
(
  echo select disk %DISK%
  echo list partition
) > "%TMPD%\dp_lp.txt"
call :dpr "%TMPD%\dp_lp.txt" "%TMPD%\out_lp.txt"
set "ESP="
set "ESPCOUNT=0"
set "ESPLIST="
for /f "usebackq tokens=1-5" %%a in ("%TMPD%\out_lp.txt") do (
  call :ehnum "%%b" && call :checkesp %%b %%d %%e
)
if "%ESPCOUNT%"=="0" goto sem_esp
if "%ESPCOUNT%"=="1" goto esp_ok
call :log "WARNING: more than one EFI partition on this disk: %ESPLIST%"
:esp_pergunta
set "R="
set /p "R=Number of the EFI partition to use: "
set "OKP=0"
for %%p in (%ESPLIST%) do if "!R!"=="%%p" set "OKP=1"
if "%OKP%"=="0" goto esp_pergunta
set "ESP=!R!"
call :espsize %ESP%
:esp_ok
call :espoffset %ESP%
set "ESPMB=%ESPSIZE%"
if /i "%ESPUNIT%"=="GB" set /a ESPMB=ESPSIZE*1024
call :log "EFI: partition %ESP% - %ESPSIZE% %ESPUNIT% - offset %ESPOFFKB% KB"
set "MODO=A"
goto escolher_letra

:sem_esp
call :log "WARNING: no EFI partition on disk %DISK%. One of %MINESP% MB must be created."
call :log "Free space on the disk according to diskpart: %DFREE%"
echo   1 = create the EFI in unallocated space - needs at least %MINESP% MB free
echo   2 = shrink Windows %WIN%: and create the EFI in the freed space
echo   3 = cancel
set "R="
set /p "R=Option [3]: "
if "!R!"=="1" (
  set "MODO=C"
  set "ENCOLHER=0"
  goto escolher_letra
)
if "!R!"=="2" (
  set "MODO=C"
  set "ENCOLHER=1"
  goto escolher_letra
)
call :log "Cancelled: no EFI."
goto sair

rem ---------------------------------------------------------------- letter
:escolher_letra
for %%L in (S T U V W R Q P O N M L K) do if not defined LTR (
  mountvol %%L: /L >nul 2>&1 || set "LTR=%%L"
)
if not defined LTR (
  call :log "ERROR: no free letter to mount the EFI."
  goto falha
)

if not "%MODO%"=="A" goto resumo
echo.
echo   A = SAFE     : reformats the existing EFI as FAT32 and recreates the boot files.
echo   B = FULL     : deletes the EFI with override, creates an identical one, formats it and recreates boot.
echo                  Use B only if A fails or the partition is damaged.
set "R="
set /p "R=Mode A/B [A]: "
if /i "!R!"=="B" set "MODO=B"
if "%MODO%"=="B" if %ESPMB% LSS %MINESP% (
  call :log "ERROR: the current EFI has %ESPMB% MB, less than the minimum %MINESP% MB. Mode B would not fit. Use mode A."
  goto falha
)

rem ---------------------------------------------------------------- 5. summary
:resumo
call :log ""
call :log "=== 5. SUMMARY - check carefully ==="
call :log "  Disk .........: %DISK% - %MODEL% - %DSIZE% - GPT"
call :log "  Windows ......: %WIN%:\Windows"
if "%MODO%"=="C" (
  if "%ENCOLHER%"=="1" (call :log "  EFI ..........: DOES NOT EXIST - create a new one of %MINESP% MB by shrinking %WIN%:") else (call :log "  EFI ..........: DOES NOT EXIST - create a new one of %MINESP% MB in free space")
) else (
  call :log "  EFI ..........: partition %ESP% - %ESPSIZE% %ESPUNIT%"
)
if "%MODO%"=="A" call :log "  Mode .........: A - reformat existing EFI"
if "%MODO%"=="B" call :log "  Mode .........: B - delete and recreate EFI"
if "%MODO%"=="C" call :log "  Mode .........: create new EFI"
call :log "  Temp letter ..: %LTR%:"
call :log "  Boot command .: bcdboot %WIN%:\Windows /f UEFI /s %LTR%: /l pt-BR"
call :log "  Backup/log ...: %LOGDIR%"
echo.
echo WARNING: the EFI partition above will be FORMATTED. Other systems, e.g. Linux, on this EFI lose their boot entry.
set "CONF="
set /p "CONF=Type YES in uppercase to continue, anything else cancels: "
if not "!CONF!"=="YES" (
  call :log "Cancelled by the user. Nothing was changed."
  goto sair
)
call :log "Confirmed - YES."

rem ---------------------------------------------------------------- 6. backup
if "%MODO%"=="C" goto preparar
call :log ""
call :log "=== 6. Backup of the BCD and EFI files ==="
(
  echo select disk %DISK%
  echo select partition %ESP%
  echo remove noerr
  echo assign letter=%LTR%
) > "%TMPD%\dp_01_montar.txt"
call :dpw "%TMPD%\dp_01_montar.txt" "%TMPD%\out_01.txt"
if errorlevel 1 (
  call :log "WARNING: could not mount the EFI for backup. Continuing without a file copy."
) else (
  set "ASSIGNED=1"
)
if "%SIMULAR%"=="1" goto preparar
bcdedit /export "%LOGDIR%\BCD-export" >> "%LOG%" 2>&1
if errorlevel 1 (call :log "WARNING: bcdedit /export failed - normal if the BCD is corrupt.") else (call :log "OK: BCD exported to %LOGDIR%\BCD-export")
if exist "%LTR%:\" (
  xcopy "%LTR%:\*" "%LOGDIR%\EFI-backup\" /E /H /C /I /Y /Q >> "%LOG%" 2>&1
  call :log "EFI copy in %LOGDIR%\EFI-backup"
) else (
  call :log "WARNING: EFI unreadable, probably corrupt; no file copy."
)

rem ---------------------------------------------------------------- 7. particao
:preparar
call :log ""
call :log "=== 7. Preparing the EFI partition ==="
if "%MODO%"=="A" goto modo_a
if "%MODO%"=="B" goto modo_b
goto modo_c

:modo_a
(
  echo select disk %DISK%
  echo select partition %ESP%
  echo format quick fs=fat32 label=System override
) > "%TMPD%\dp_02_formatar.txt"
call :dpw "%TMPD%\dp_02_formatar.txt" "%TMPD%\out_02.txt"
if not errorlevel 1 goto modo_a_letra
call :log "WARNING: diskpart format failed; trying format.com..."
format %LTR%: /FS:FAT32 /Q /V:System /Y >> "%LOG%" 2>&1
if errorlevel 1 (
  call :log "ERROR: failed to format the EFI. Try mode B."
  goto falha
)
:modo_a_letra
if "%ASSIGNED%"=="1" goto bcdboot
(
  echo select disk %DISK%
  echo select partition %ESP%
  echo assign letter=%LTR%
) > "%TMPD%\dp_03_montar.txt"
call :dpw "%TMPD%\dp_03_montar.txt" "%TMPD%\out_03.txt"
if errorlevel 1 (
  call :log "ERROR: could not assign a letter to the EFI."
  goto falha
)
set "ASSIGNED=1"
goto bcdboot

:modo_b
if "%ASSIGNED%"=="1" if "%SIMULAR%"=="0" mountvol %LTR%: /D >nul 2>&1
set "ASSIGNED=0"
set "OFFP="
if defined ESPOFFKB set "OFFP= offset=%ESPOFFKB%"
(
  echo select disk %DISK%
  echo select partition %ESP%
  echo delete partition override
  echo create partition efi size=%ESPMB%%OFFP%
  echo format quick fs=fat32 label=System
  echo assign letter=%LTR%
) > "%TMPD%\dp_02_recriar.txt"
call :dpw "%TMPD%\dp_02_recriar.txt" "%TMPD%\out_02.txt"
if not errorlevel 1 goto modo_b_ok
call :log "WARNING: failed. Trying to create it 1 MB smaller - diskpart rounding..."
set /a ESPMB2=ESPMB-1
(
  echo select disk %DISK%
  echo create partition efi size=%ESPMB2%%OFFP%
  echo format quick fs=fat32 label=System
  echo assign letter=%LTR%
) > "%TMPD%\dp_03_criar_retry.txt"
call :dpw "%TMPD%\dp_03_criar_retry.txt" "%TMPD%\out_03.txt"
if not errorlevel 1 goto modo_b_ok
call :log "SERIOUS ERROR: the EFI was DELETED and was not recreated. Do it manually in diskpart:"
call :log "    select disk %DISK%"
call :log "    create partition efi size=%MINESP%"
call :log "    format quick fs=fat32 label=System"
call :log "    assign letter=%LTR%"
call :log "and then: bcdboot %WIN%:\Windows /f UEFI /s %LTR%: /l pt-BR"
goto falha
:modo_b_ok
set "ASSIGNED=1"
goto bcdboot

:modo_c
set /a SHRINKMB=MINESP+50
(
  if "%ENCOLHER%"=="1" echo select volume %WIN%
  if "%ENCOLHER%"=="1" echo shrink desired=%SHRINKMB% minimum=%SHRINKMB%
  echo select disk %DISK%
  echo create partition efi size=%MINESP%
  echo format quick fs=fat32 label=System
  echo assign letter=%LTR%
) > "%TMPD%\dp_02_criar.txt"
call :dpw "%TMPD%\dp_02_criar.txt" "%TMPD%\out_02.txt"
if errorlevel 1 (
  call :log "ERROR: failed to create the EFI partition. See the log."
  goto falha
)
set "ASSIGNED=1"
goto bcdboot

rem ---------------------------------------------------------------- 8. bcdboot
:bcdboot
call :log ""
call :log "=== 8. Generating the boot files - bcdboot ==="
call :log "bcdboot %WIN%:\Windows /f UEFI /s %LTR%: /l pt-BR"
if "%SIMULAR%"=="1" (
  call :log "SIMULATION: bcdboot not run."
  goto bootrec
)
if not exist "%LTR%:\" (
  call :log "ERROR: the EFI is not accessible at %LTR%:"
  goto falha
)
bcdboot %WIN%:\Windows /f UEFI /s %LTR%: /l pt-BR >> "%LOG%" 2>&1
if not errorlevel 1 goto bcd_verif
call :log "WARNING: failed with /l pt-BR; trying without the locale..."
bcdboot %WIN%:\Windows /f UEFI /s %LTR%: >> "%LOG%" 2>&1
if errorlevel 1 (
  call :log "ERROR: bcdboot failed. See the log."
  goto falha
)
:bcd_verif
set "V1=NO"
set "V2=NO"
if exist "%LTR%:\EFI\Microsoft\Boot\bootmgfw.efi" set "V1=YES"
if exist "%LTR%:\EFI\Microsoft\Boot\BCD" set "V2=YES"
call :log "Check: bootmgfw.efi=%V1%  BCD=%V2%"
if not "%V1%%V2%"=="YESYES" (
  call :log "ERROR: boot files not found after bcdboot."
  goto falha
)
call :log "OK: boot files created."

rem ---------------------------------------------------------------- 9. bootrec
:bootrec
if "%SIMULAR%"=="1" goto concluido
echo.
echo bootrec /rebuildbcd is optional: after bcdboot it is redundant and sometimes gives access denied.
set "R="
set /p "R=Run bootrec /rebuildbcd anyway? Y/N [N]: "
if /i not "!R!"=="Y" goto concluido
call :tem bootrec
if errorlevel 1 (
  call :log "WARNING: bootrec does not exist in this environment - normal in plain WinPE."
  goto concluido
)
echo n| bootrec /rebuildbcd >> "%LOG%" 2>&1
call :log "bootrec /rebuildbcd run - answer n."

:concluido
call :remover_letra
call :log ""
call :log "=== Done ==="
if "%SIMULAR%"=="1" (call :log "SIMULATION finished. Nothing was changed.") else (call :log "OK: UEFI boot recreated. Remove the USB drive and reboot - command: wpeutil reboot")
call :log "Log and backup in: %LOGDIR%"
pause
endlocal
exit /b 0

:falha
call :remover_letra
echo.
echo Failed. Log: %LOG%
pause
endlocal
exit /b 1

:sair
call :remover_letra
pause
endlocal
exit /b 0

rem ====================================================================== subroutines
:log
echo(%~1
if defined LOG >>"%LOG%" echo(%~1
exit /b 0

:timestamp
set "TS="
for /f "tokens=2 delims==" %%a in ('wmic os get localdatetime /value 2^>nul ^| find "="') do set "TS=%%a"
if defined TS (
  set "TS=!TS:~0,8!-!TS:~8,6!"
  exit /b 0
)
set "TS=%date%-%time%"
set "TS=!TS:/=!"
set "TS=!TS::=!"
set "TS=!TS:,=!"
set "TS=!TS:.=!"
set "TS=!TS: =0!"
exit /b 0

:trylog
set "T=%~1\logs\%TS%"
mkdir "%T%" 2>nul
(echo ok) > "%T%\teste.tmp" 2>nul || exit /b 1
del "%T%\teste.tmp" >nul 2>&1
set "LOGDIR=%T%"
exit /b 0

:dpr
rem read-only diskpart
diskpart /s "%~1" > "%~2" 2>&1
set "RC=%errorlevel%"
>>"%LOG%" echo ----- diskpart /s %~nx1
>>"%LOG%" type "%~1"
>>"%LOG%" type "%~2"
exit /b %RC%

:dpw
rem diskpart that CHANGES the disk: honors /simulate
call :log "diskpart script %~nx1:"
for /f "usebackq delims=" %%s in ("%~1") do call :log "    %%s"
if "%SIMULAR%"=="1" (
  call :log "SIMULATION: diskpart NOT run."
  exit /b 0
)
diskpart /s "%~1" > "%~2" 2>&1
set "RC=%errorlevel%"
type "%~2"
>>"%LOG%" type "%~2"
exit /b %RC%

:checkesp
rem %1=partition number  %2=size  %3=unit
(
  echo select disk %DISK%
  echo select partition %1
  echo detail partition
) > "%TMPD%\dp_p%1.txt"
call :dpr "%TMPD%\dp_p%1.txt" "%TMPD%\out_p%1.txt"
find /i "%ESPGUID%" "%TMPD%\out_p%1.txt" >nul || exit /b 0
set /a ESPCOUNT+=1
set "ESPLIST=%ESPLIST% %1"
if not defined ESP (
  set "ESP=%1"
  set "ESPSIZE=%2"
  set "ESPUNIT=%3"
)
call :log "EFI partition found: %1 - %2 %3"
exit /b 0

:espsize
rem reads the size of partition %1 from list partition
for /f "usebackq tokens=1-5" %%a in ("%TMPD%\out_lp.txt") do if "%%b"=="%1" (
  set "ESPSIZE=%%d"
  set "ESPUNIT=%%e"
)
exit /b 0

:espoffset
rem offset in KB from "Offset in Bytes" of detail partition; omitted if it does not fit in 32 bits
set "ESPOFFKB="
set "OFFB="
for /f "tokens=2 delims=:" %%a in ('type "%TMPD%\out_p%1.txt" ^| find /i "bytes"') do call :ehnum "%%a" && set "OFFB=%%a"
if not defined OFFB exit /b 0
set "OFFB=%OFFB: =%"
if not "%OFFB:~9,1%"=="" exit /b 0
set /a ESPOFFKB=OFFB/1024
exit /b 0

:remover_letra
if "%ASSIGNED%"=="1" if "%SIMULAR%"=="0" if defined LTR (
  call :log "Removing temporary letter %LTR%:"
  mountvol %LTR%: /D >nul 2>&1
)
set "ASSIGNED=0"
exit /b 0

:tem
rem WinPE has no where.exe: looks for %1.exe in PATH
set "_P="
for %%p in (%~1.exe) do set "_P=%%~$PATH:p"
if defined _P exit /b 0
exit /b 1

:ehnum
rem 0 if %1 (without spaces) is a positive integer without a leading zero
set "_N=%~1"
if not defined _N exit /b 1
set "_N=%_N: =%"
if not defined _N exit /b 1
for /f "delims=0123456789" %%z in ("%_N%") do exit /b 1
if "%_N:~0,1%"=="0" exit /b 1
exit /b 0
