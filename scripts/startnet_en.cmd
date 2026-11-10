@echo off
rem WinPE startnet.cmd (EN): initializes and opens the winpe_reparo_en menu (PowerShell).
wpeinit
wpeutil DisableFirewall >nul 2>&1
if exist "%SystemRoot%\System32\winpe_reparo_en.cmd" (
  call "%SystemRoot%\System32\winpe_reparo_en.cmd"
  goto :eof
)
rem fallback: old ReparoBoot menu (Reparar-Boot.cmd, Portuguese) if the script above is missing
set "RBDIR="
rem 1o: pasta no pendrive (permite gravar log/backup e atualizar scripts sem refazer o WinPE)
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if not defined RBDIR if exist "%%L:\ReparoBoot\Reparar-Boot.cmd" set "RBDIR=%%L:\ReparoBoot"
rem 2o: copia embutida no boot.wim
if not defined RBDIR if exist "X:\ReparoBoot\Reparar-Boot.cmd" set "RBDIR=X:\ReparoBoot"
if not defined RBDIR goto nao_achou
call "%RBDIR%\Reparar-Boot.cmd"
goto :eof
:nao_achou
echo ReparoBoot not found. Command prompt available.
