@echo off
rem startnet.cmd do WinPE (PT): inicializa e abre o menu winpe_reparo_pt (PowerShell).
wpeinit
wpeutil DisableFirewall >nul 2>&1
if exist "%SystemRoot%\System32\winpe_reparo_pt.cmd" (
  call "%SystemRoot%\System32\winpe_reparo_pt.cmd"
  goto :eof
)
rem reserva: menu antigo do ReparoBoot (Reparar-Boot.cmd), se o script acima nao existir
set "RBDIR="
rem 1o: pasta no pendrive (permite gravar log/backup e atualizar scripts sem refazer o WinPE)
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if not defined RBDIR if exist "%%L:\ReparoBoot\Reparar-Boot.cmd" set "RBDIR=%%L:\ReparoBoot"
rem 2o: copia embutida no boot.wim
if not defined RBDIR if exist "X:\ReparoBoot\Reparar-Boot.cmd" set "RBDIR=X:\ReparoBoot"
if not defined RBDIR goto nao_achou
call "%RBDIR%\Reparar-Boot.cmd"
goto :eof
:nao_achou
echo ReparoBoot nao encontrado. Prompt de comando liberado.
