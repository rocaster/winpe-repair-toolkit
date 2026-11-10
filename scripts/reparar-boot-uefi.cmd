@echo off
rem ======================================================================
rem  Reparar Boot UEFI - versao CMD/diskpart (funciona no WinRE puro,
rem  inclusive no pendrive de instalacao do Windows via Shift+F10).
rem  Uso:  reparar-boot-uefi.cmd            (reparo)
rem        reparar-boot-uefi.cmd /simular   (so detecta, nao altera nada)
rem  Textos sem acento de proposito (console do WinPE).
rem ======================================================================
setlocal EnableExtensions EnableDelayedExpansion
title Reparar Boot UEFI - CMD
set "SIMULAR=0"
if /i "%~1"=="/simular" set "SIMULAR=1"
set "ESPGUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
set "ASSIGNED=0"
set "LTR="
set "LETRAS=C D E F G H I J K L M N O P Q R S T U V W Y Z"

echo ==============================================================
echo   REPARAR BOOT UEFI DO WINDOWS  - versao CMD
if "%SIMULAR%"=="1" echo   MODO SIMULACAO: nada sera alterado
echo ==============================================================

rem ---------------------------------------------------------------- log
call :timestamp
set "LOGDIR="
for %%I in ("%~dp0..") do set "RAIZ=%%~fI"
if /i not "%~d0"=="X:" call :trylog "%RAIZ%"
if not defined LOGDIR for %%L in (%LETRAS%) do if not defined LOGDIR if exist "%%L:\ReparoBoot\" call :trylog "%%L:\ReparoBoot"
if not defined LOGDIR call :trylog "X:\ReparoBoot-logs"
if not defined LOGDIR (
  echo ERRO: nao foi possivel criar a pasta de log.
  pause
  exit /b 1
)
set "LOG=%LOGDIR%\reparo-boot.log"
set "TMPD=%LOGDIR%\tmp"
mkdir "%TMPD%" 2>nul
call :log "Log: %LOG%"
if /i "%LOGDIR:~0,2%"=="X:" call :log "AVISO: log gravado em X: - RAM. Some ao reiniciar."

rem ---------------------------------------------------------------- ambiente
if /i not "%SystemDrive%"=="X:" (
  if "%SIMULAR%"=="0" (
    call :log "ERRO: este script so altera discos rodando no WinPE/WinRE - unidade X:. Fora dele use /simular."
    goto falha
  )
  call :log "AVISO: fora do WinPE, rodando so a deteccao."
)

rem ---------------------------------------------------------------- 1. firmware
call :log ""
call :log "=== 1. Verificando firmware ==="
set "FW="
for /f "tokens=3" %%a in ('reg query "HKLM\System\CurrentControlSet\Control" /v PEFirmwareType 2^>nul ^| find /i "PEFirmwareType"') do set "FW=%%a"
if "%FW%"=="0x2" (
  call :log "OK: firmware UEFI - PEFirmwareType = 2."
  goto fw_ok
)
if "%FW%"=="0x1" (
  call :log "ERRO: o PC iniciou em modo BIOS/Legacy. Este metodo e so para UEFI. Inicie o pendrive pela entrada UEFI no menu de boot."
  goto falha
)
if "%SIMULAR%"=="1" (
  call :log "AVISO: PEFirmwareType ausente - ignorado na simulacao."
  goto fw_ok
)
call :log "ERRO: nao foi possivel confirmar o firmware. Abortando por seguranca."
goto falha
:fw_ok

rem ---------------------------------------------------------------- 2. BitLocker
call :log ""
call :log "=== 2. Verificando BitLocker ==="
call :tem manage-bde
if errorlevel 1 (
  call :log "AVISO: manage-bde nao existe neste ambiente; nao deu para checar BitLocker."
  call :log "AVISO: se o Windows nao for encontrado, o disco pode estar criptografado."
  goto bde_fim
)
manage-bde -status > "%TMPD%\bde.txt" 2>&1
>>"%LOG%" type "%TMPD%\bde.txt"
rem WinPE nao tem findstr: usa find (Locked sem Unlocked / Bloqueado sem Desbloqueado)
set "BDELOCK=1"
type "%TMPD%\bde.txt" | find /i "locked" | find /v /i "unlocked" >nul && set "BDELOCK=0"
type "%TMPD%\bde.txt" | find /i "bloqueado" | find /v /i "desbloqueado" >nul && set "BDELOCK=0"
cmd /c exit /b %BDELOCK%
if errorlevel 1 (
  call :log "OK: nenhum volume BitLocker bloqueado."
  goto bde_fim
)
call :log "AVISO: ha volume BitLocker BLOQUEADO. Veja acima a letra no manage-bde -status:"
type "%TMPD%\bde.txt"
call :log "Pegue a chave de recuperacao de 48 digitos em https://aka.ms/myrecoverykey e rode:"
call :log "    manage-bde -unlock C: -RecoveryPassword 111111-222222-333333-444444-555555-666666-777777-888888"
call :log "Troque C: pela letra do volume bloqueado. Depois rode este script de novo."
set "R="
set /p "R=Continuar mesmo assim? S/N [N]: "
if /i not "!R!"=="S" (
  call :log "Abortado para desbloquear o BitLocker."
  goto sair
)
:bde_fim

rem ---------------------------------------------------------------- 3. Windows
call :log ""
call :log "=== 3. Procurando a instalacao do Windows ==="
set "N=0"
for %%L in (%LETRAS%) do (
  if exist "%%L:\Windows\System32\winload.efi" (
    set /a N+=1
    set "WIN!N!=%%L"
    call :log "Encontrado: %%L:\Windows"
  )
)
if "%N%"=="0" (
  call :log "ERRO: nenhum Windows encontrado. Causas: BitLocker bloqueado, falta driver Intel RST/RAID - carregue com drvload - ou disco errado."
  goto falha
)
if "%N%"=="1" (
  set "WIN=!WIN1!"
  goto win_ok
)
call :log "AVISO: mais de um Windows encontrado:"
for /l %%i in (1,1,%N%) do echo   [%%i] !WIN%%i!:
:win_pergunta
set "R="
set /p "R=Numero do Windows a reparar: "
set "WIN="
for /l %%i in (1,1,%N%) do if "!R!"=="%%i" set "WIN=!WIN%%i!"
if not defined WIN goto win_pergunta
:win_ok
call :log "OK: Windows escolhido: %WIN%:"

rem ---------------------------------------------------------------- 4. disco
call :log ""
call :log "=== 4. Identificando disco e particao EFI ==="
(
  echo select volume %WIN%
  echo detail volume
) > "%TMPD%\dp_vol.txt"
call :dpr "%TMPD%\dp_vol.txt" "%TMPD%\out_vol.txt"
set "DISK="
for /f "usebackq tokens=1-3" %%a in ("%TMPD%\out_vol.txt") do if "%%a"=="*" if not defined DISK set "DISK=%%c"
if not defined DISK (
  call :log "ERRO: nao consegui descobrir o disco do volume %WIN%:. Veja o log."
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
if not defined MODEL set "MODEL=desconhecido"

(
  echo select disk %DISK%
  echo uniqueid disk
) > "%TMPD%\dp_uid.txt"
call :dpr "%TMPD%\dp_uid.txt" "%TMPD%\out_uid.txt"
set "EHGPT="
find "{" "%TMPD%\out_uid.txt" >nul && set "EHGPT=1"
rem confere tambem o asterisco na coluna Gpt do "list disk"
for /f "usebackq delims=" %%a in ("%TMPD%\out_ld.txt") do (
  set "LD=%%a"
  for /f "tokens=1,2" %%x in ("%%a") do if "%%y"=="%DISK%" (
    for /l %%n in (1,1,20) do if "!LD:~-1!"==" " set "LD=!LD:~0,-1!"
    if "!LD:~-1!"=="*" set "EHGPT=1"
  )
)
if not defined EHGPT (
  call :log "ERRO: o disco %DISK% nao e GPT - parece MBR. Boot UEFI precisa de GPT."
  call :log "Opcao manual, com backup antes: mbr2gpt /validate /disk:%DISK%  e depois  mbr2gpt /convert /disk:%DISK%"
  goto falha
)
call :log "Disco %DISK%: %MODEL% - %DSIZE% - GPT - livre %DFREE%"

set "MINESP=100"
fsutil fsinfo sectorinfo %WIN%: 2>nul | find /i "LogicalBytesPerSector" | find "4096" >nul
if not errorlevel 1 set "MINESP=260"
call :log "Tamanho minimo de EFI para este disco: %MINESP% MB"

rem procurar EFI pelo tipo GPT, nunca assumir particao 2
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
call :log "AVISO: mais de uma particao EFI neste disco: %ESPLIST%"
:esp_pergunta
set "R="
set /p "R=Numero da particao EFI a usar: "
set "OKP=0"
for %%p in (%ESPLIST%) do if "!R!"=="%%p" set "OKP=1"
if "%OKP%"=="0" goto esp_pergunta
set "ESP=!R!"
call :espsize %ESP%
:esp_ok
call :espoffset %ESP%
set "ESPMB=%ESPSIZE%"
if /i "%ESPUNIT%"=="GB" set /a ESPMB=ESPSIZE*1024
call :log "EFI: particao %ESP% - %ESPSIZE% %ESPUNIT% - offset %ESPOFFKB% KB"
set "MODO=A"
goto escolher_letra

:sem_esp
call :log "AVISO: nenhuma particao EFI no disco %DISK%. E preciso criar uma de %MINESP% MB."
call :log "Espaco livre no disco segundo o diskpart: %DFREE%"
echo   1 = criar a EFI no espaco nao alocado - precisa de pelo menos %MINESP% MB livres
echo   2 = encolher o Windows %WIN%: e criar a EFI no espaco liberado
echo   3 = cancelar
set "R="
set /p "R=Opcao [3]: "
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
call :log "Cancelado: sem EFI."
goto sair

rem ---------------------------------------------------------------- letra
:escolher_letra
for %%L in (S T U V W R Q P O N M L K) do if not defined LTR (
  mountvol %%L: /L >nul 2>&1 || set "LTR=%%L"
)
if not defined LTR (
  call :log "ERRO: nenhuma letra livre para montar a EFI."
  goto falha
)

if not "%MODO%"=="A" goto resumo
echo.
echo   A = SEGURO   : reformata a EFI existente em FAT32 e recria os arquivos de boot.
echo   B = COMPLETO : apaga a EFI com override, cria outra igual, formata e recria o boot.
echo                  Use B so se o A falhar ou a particao estiver danificada.
set "R="
set /p "R=Modo A/B [A]: "
if /i "!R!"=="B" set "MODO=B"
if "%MODO%"=="B" if %ESPMB% LSS %MINESP% (
  call :log "ERRO: a EFI atual tem %ESPMB% MB, menos que o minimo %MINESP% MB. O modo B nao caberia. Use o modo A."
  goto falha
)

rem ---------------------------------------------------------------- 5. resumo
:resumo
call :log ""
call :log "=== 5. RESUMO - confira com atencao ==="
call :log "  Disco ........: %DISK% - %MODEL% - %DSIZE% - GPT"
call :log "  Windows ......: %WIN%:\Windows"
if "%MODO%"=="C" (
  if "%ENCOLHER%"=="1" (call :log "  EFI ..........: NAO EXISTE - criar nova de %MINESP% MB encolhendo %WIN%:") else (call :log "  EFI ..........: NAO EXISTE - criar nova de %MINESP% MB no espaco livre")
) else (
  call :log "  EFI ..........: particao %ESP% - %ESPSIZE% %ESPUNIT%"
)
if "%MODO%"=="A" call :log "  Modo .........: A - reformatar EFI existente"
if "%MODO%"=="B" call :log "  Modo .........: B - apagar e recriar EFI"
if "%MODO%"=="C" call :log "  Modo .........: criar EFI nova"
call :log "  Letra temp. ..: %LTR%:"
call :log "  Comando boot .: bcdboot %WIN%:\Windows /f UEFI /s %LTR%: /l pt-BR"
call :log "  Backup/log ...: %LOGDIR%"
echo.
echo ATENCAO: a particao EFI acima sera FORMATADA. Outros sistemas, ex. Linux, nessa EFI perdem a entrada de boot.
set "CONF="
set /p "CONF=Digite SIM em maiusculo para continuar, qualquer outra coisa cancela: "
if not "!CONF!"=="SIM" (
  call :log "Cancelado pelo usuario. Nada foi alterado."
  goto sair
)
call :log "Confirmado - SIM."

rem ---------------------------------------------------------------- 6. backup
if "%MODO%"=="C" goto preparar
call :log ""
call :log "=== 6. Backup do BCD e dos arquivos da EFI ==="
(
  echo select disk %DISK%
  echo select partition %ESP%
  echo remove noerr
  echo assign letter=%LTR%
) > "%TMPD%\dp_01_montar.txt"
call :dpw "%TMPD%\dp_01_montar.txt" "%TMPD%\out_01.txt"
if errorlevel 1 (
  call :log "AVISO: nao deu para montar a EFI para backup. Seguindo sem copia dos arquivos."
) else (
  set "ASSIGNED=1"
)
if "%SIMULAR%"=="1" goto preparar
bcdedit /export "%LOGDIR%\BCD-export" >> "%LOG%" 2>&1
if errorlevel 1 (call :log "AVISO: bcdedit /export falhou - normal se o BCD estiver corrompido.") else (call :log "OK: BCD exportado para %LOGDIR%\BCD-export")
if exist "%LTR%:\" (
  xcopy "%LTR%:\*" "%LOGDIR%\EFI-backup\" /E /H /C /I /Y /Q >> "%LOG%" 2>&1
  call :log "Copia da EFI em %LOGDIR%\EFI-backup"
) else (
  call :log "AVISO: EFI ilegivel, provavelmente corrompida; sem copia de arquivos."
)

rem ---------------------------------------------------------------- 7. particao
:preparar
call :log ""
call :log "=== 7. Preparando a particao EFI ==="
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
call :log "AVISO: diskpart format falhou; tentando format.com..."
format %LTR%: /FS:FAT32 /Q /V:System /Y >> "%LOG%" 2>&1
if errorlevel 1 (
  call :log "ERRO: falha ao formatar a EFI. Tente o modo B."
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
  call :log "ERRO: nao foi possivel atribuir letra a EFI."
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
call :log "AVISO: falhou. Tentando criar com 1 MB a menos - arredondamento do diskpart..."
set /a ESPMB2=ESPMB-1
(
  echo select disk %DISK%
  echo create partition efi size=%ESPMB2%%OFFP%
  echo format quick fs=fat32 label=System
  echo assign letter=%LTR%
) > "%TMPD%\dp_03_criar_retry.txt"
call :dpw "%TMPD%\dp_03_criar_retry.txt" "%TMPD%\out_03.txt"
if not errorlevel 1 goto modo_b_ok
call :log "ERRO GRAVE: a EFI foi APAGADA e nao foi recriada. Faca manualmente no diskpart:"
call :log "    select disk %DISK%"
call :log "    create partition efi size=%MINESP%"
call :log "    format quick fs=fat32 label=System"
call :log "    assign letter=%LTR%"
call :log "e depois: bcdboot %WIN%:\Windows /f UEFI /s %LTR%: /l pt-BR"
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
  call :log "ERRO: falha ao criar a particao EFI. Veja o log."
  goto falha
)
set "ASSIGNED=1"
goto bcdboot

rem ---------------------------------------------------------------- 8. bcdboot
:bcdboot
call :log ""
call :log "=== 8. Gerando os arquivos de boot - bcdboot ==="
call :log "bcdboot %WIN%:\Windows /f UEFI /s %LTR%: /l pt-BR"
if "%SIMULAR%"=="1" (
  call :log "SIMULACAO: bcdboot nao executado."
  goto bootrec
)
if not exist "%LTR%:\" (
  call :log "ERRO: a EFI nao ficou acessivel em %LTR%:"
  goto falha
)
bcdboot %WIN%:\Windows /f UEFI /s %LTR%: /l pt-BR >> "%LOG%" 2>&1
if not errorlevel 1 goto bcd_verif
call :log "AVISO: falhou com /l pt-BR; tentando sem o idioma..."
bcdboot %WIN%:\Windows /f UEFI /s %LTR%: >> "%LOG%" 2>&1
if errorlevel 1 (
  call :log "ERRO: bcdboot falhou. Veja o log."
  goto falha
)
:bcd_verif
set "V1=NAO"
set "V2=NAO"
if exist "%LTR%:\EFI\Microsoft\Boot\bootmgfw.efi" set "V1=SIM"
if exist "%LTR%:\EFI\Microsoft\Boot\BCD" set "V2=SIM"
call :log "Verificacao: bootmgfw.efi=%V1%  BCD=%V2%"
if not "%V1%%V2%"=="SIMSIM" (
  call :log "ERRO: arquivos de boot nao encontrados apos o bcdboot."
  goto falha
)
call :log "OK: arquivos de boot criados."

rem ---------------------------------------------------------------- 9. bootrec
:bootrec
if "%SIMULAR%"=="1" goto concluido
echo.
echo bootrec /rebuildbcd e opcional: depois do bcdboot ele e redundante e as vezes da acesso negado.
set "R="
set /p "R=Rodar bootrec /rebuildbcd mesmo assim? S/N [N]: "
if /i not "!R!"=="S" goto concluido
call :tem bootrec
if errorlevel 1 (
  call :log "AVISO: bootrec nao existe neste ambiente - normal no WinPE puro."
  goto concluido
)
echo n| bootrec /rebuildbcd >> "%LOG%" 2>&1
call :log "bootrec /rebuildbcd executado - resposta n."

:concluido
call :remover_letra
call :log ""
call :log "=== Concluido ==="
if "%SIMULAR%"=="1" (call :log "SIMULACAO concluida. Nada foi alterado.") else (call :log "OK: boot UEFI recriado. Remova o pendrive e reinicie - comando: wpeutil reboot")
call :log "Log e backup em: %LOGDIR%"
pause
endlocal
exit /b 0

:falha
call :remover_letra
echo.
echo Falhou. Log: %LOG%
pause
endlocal
exit /b 1

:sair
call :remover_letra
pause
endlocal
exit /b 0

rem ====================================================================== sub-rotinas
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
rem diskpart somente leitura
diskpart /s "%~1" > "%~2" 2>&1
set "RC=%errorlevel%"
>>"%LOG%" echo ----- diskpart /s %~nx1
>>"%LOG%" type "%~1"
>>"%LOG%" type "%~2"
exit /b %RC%

:dpw
rem diskpart que ALTERA o disco: respeita /simular
call :log "Script diskpart %~nx1:"
for /f "usebackq delims=" %%s in ("%~1") do call :log "    %%s"
if "%SIMULAR%"=="1" (
  call :log "SIMULACAO: diskpart NAO executado."
  exit /b 0
)
diskpart /s "%~1" > "%~2" 2>&1
set "RC=%errorlevel%"
type "%~2"
>>"%LOG%" type "%~2"
exit /b %RC%

:checkesp
rem %1=numero da particao  %2=tamanho  %3=unidade
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
call :log "Particao EFI encontrada: %1 - %2 %3"
exit /b 0

:espsize
rem le tamanho da particao %1 no list partition
for /f "usebackq tokens=1-5" %%a in ("%TMPD%\out_lp.txt") do if "%%b"=="%1" (
  set "ESPSIZE=%%d"
  set "ESPUNIT=%%e"
)
exit /b 0

:espoffset
rem offset em KB a partir de "Offset in Bytes" do detail partition; omitido se nao couber em 32 bits
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
  call :log "Removendo letra temporaria %LTR%:"
  mountvol %LTR%: /D >nul 2>&1
)
set "ASSIGNED=0"
exit /b 0

:tem
rem WinPE nao tem where.exe: procura %1.exe no PATH
set "_P="
for %%p in (%~1.exe) do set "_P=%%~$PATH:p"
if defined _P exit /b 0
exit /b 1

:ehnum
rem 0 se %1 (sem espacos) e numero inteiro positivo sem zero a esquerda
set "_N=%~1"
if not defined _N exit /b 1
set "_N=%_N: =%"
if not defined _N exit /b 1
for /f "delims=0123456789" %%z in ("%_N%") do exit /b 1
if "%_N:~0,1%"=="0" exit /b 1
exit /b 0
