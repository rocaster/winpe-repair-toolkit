<#
.SYNOPSIS
    winpe_reparo_en.ps1 - Windows repair kit for WinPE (replaces bash_reparo.sh). English version.

.DESCRIPTION
    A single PowerShell 5.1 file with the menu and the 12 tools + advanced mode:
      1  UEFI boot repair (GPT detection from 4 sources)
      2  Intel RST driver injection (automatic detection)
      3  BCD rebuild (bootrec if present, otherwise bcdboot/bcdedit) / restore backup
      4  SFC and DISM in sequence with log
      5  Profile extraction (AppData and favorites; destination inside the profile is refused)
      6  Printer export
      7  C: root scan (hides desktop.ini, thumbs.db, *.marker, .GamingRoot, empty items)
      8  Event Log (optional)
      9  Registry hive backup (SAM/SECURITY only if confirmed; default N)
     10  File integrity checker (offline)
     11  S.M.A.R.T. checker (optional; implausible temperature ignored, no duplicate disks)
     12  Storage drivers for Windows 7
      B  Boot repair via the CMD version   L  drvload   A  advanced mode (cmd/PowerShell)
      T  simulation   R  reboot   D  shut down   0/Q  exit
    Does not use findstr, where, bash, or require bootrec (they do not exist in WinPE).
    Nothing destructive without typing YES. In simulation no command that writes is run.
    ASCII-only text on purpose (WinPE console).

.PARAMETER Ferramenta
    Tool number (1 to 12). Runs only that tool and exits. Without it the menu opens. Alias: -Tool.

.PARAMETER Simular
    Alias: -Simulate. Turns simulation on: commands that write are shown as [SIMULATION] and not run.

.EXAMPLE
    winpe_reparo_en
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File winpe_reparo_en.ps1 -Tool 11 -Simulate
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 12)]
    [Alias('Tool')]
    [int]$Ferramenta = 0,
    [Alias('Simulate')]
    [switch]$Simular
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'

$script:Sim = [bool]$Simular
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Aqui = $PSScriptRoot
function Find-PastaKit {
    <# Pasta do kit (ReparoBoot: drivers, tools, scripts, logs). Funciona rodando de X:\Windows\System32,
       de ReparoBoot\scripts ou de qualquer pasta. #>
    $c = @()
    if ($env:REPARO_RB) { $c += $env:REPARO_RB.TrimEnd('\') }
    if ($script:Aqui) {
        if ((Split-Path -Leaf $script:Aqui) -eq 'scripts') { $c += (Split-Path -Parent $script:Aqui) }
        $c += (Join-Path $script:Aqui 'ReparoBoot')
    }
    $c += 'X:\ReparoBoot'
    if ($env:OS -eq 'Windows_NT') {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) { try { $c += (Join-Path $d.RootDirectory.FullName 'ReparoBoot') } catch { $null = $_ } }
    }
    foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { return $p } }
    if ($script:Aqui -and (Split-Path -Leaf $script:Aqui) -ne 'System32') { return $script:Aqui }
    return 'X:\ReparoBoot'
}
$script:RB = Find-PastaKit
$script:LogDir = $null
$script:LogFile = $null
$script:Transcricao = $false
$script:EmWinPE = $false
$script:EhWindows = ($env:OS -eq 'Windows_NT')
$script:SysDrive = 'C:'
$script:WinRaiz = $null      # D:\
$script:WinDir = $null       # D:\Windows
$script:WinLetra = $null     # D
$script:WinOnline = $false
$script:ModoStorage = 'UNKNOWN'
$script:EspGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:Hives = New-Object 'System.Collections.Generic.List[string]'
$script:EspTemp = $null
$script:Consulta = '*[System[(Level=1 or Level=2)]]'
$script:EvtxRe = '^(system|application|setup|security|microsoft-windows-kernel-.*|microsoft-windows-ntfs.*|microsoft-windows-storage.*|microsoft-windows-diagnostics-performance.*|microsoft-windows-windowsupdateclient.*|microsoft-windows-winlogon.*)\.evtx$'

# ================================================================== saida e log
function Add-Log {
    param([AllowEmptyString()][string]$Texto)
    if (-not $script:LogFile) { return }
    try { Add-Content -LiteralPath $script:LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto) -Encoding UTF8 } catch { $null = $_ }
}

function Write-Registro {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Mensagem,
        [ValidateSet('INFO', 'OK', 'AVISO', 'ERRO', 'PASSO', 'SIM')][string]$Nivel = 'INFO'
    )
    $cor = switch ($Nivel) {
        'OK' { 'Green' } 'AVISO' { 'Yellow' } 'ERRO' { 'Red' } 'PASSO' { 'Cyan' } 'SIM' { 'Magenta' } default { 'Gray' }
    }
    if ($Nivel -eq 'PASSO') { Write-Host ''; Write-Host ('=== ' + $Mensagem + ' ===') -ForegroundColor $cor }
    elseif ($Nivel -eq 'AVISO') { Write-Host ('WARNING: ' + $Mensagem) -ForegroundColor $cor }
    elseif ($Nivel -eq 'ERRO') { Write-Host ('ERROR: ' + $Mensagem) -ForegroundColor $cor }
    else { Write-Host $Mensagem -ForegroundColor $cor }
    Add-Log ('[' + $Nivel + '] ' + $Mensagem)
}

function Read-Linha {
    <# Read-Host seguro: fim da entrada (EOF) ou erro vira texto vazio. #>
    param([string]$Pergunta)
    $r = $null
    try { $r = Read-Host $Pergunta } catch { $r = $null }
    if ($null -eq $r) { Write-Host ''; Add-Log ('Input [' + $Pergunta + ']: (end of input)'); return '' }
    $r = ([string]$r).Trim()
    Add-Log ('Input [' + $Pergunta + ']: [' + $r + ']')
    return $r
}

function Read-SimNao {
    param([string]$Pergunta, [ValidateSet('S', 'N')][string]$Padrao = 'N')
    for ($t = 0; $t -lt 5; $t++) {
        $pad = $(if ($Padrao -eq 'S') { 'Y' } else { 'N' })
        $r = (Read-Linha ('{0} (Y/N) [{1}]' -f $Pergunta, $pad)).ToUpperInvariant()
        if (-not $r) { $r = $pad }
        if ($r -eq 'Y' -or $r -eq 'YES') { return $true }
        if ($r -eq 'N' -or $r -eq 'NO') { return $false }
        Write-Host 'Answer Y or N.'
    }
    return $false
}

function Confirm-Sim {
    param([string]$Pergunta)
    Write-Host ''
    Write-Host $Pergunta -ForegroundColor Yellow
    if ($script:Sim) { Write-Host '(SIMULATION on: even with YES nothing that writes will run)' -ForegroundColor Magenta }
    $r = Read-Linha 'Type YES (uppercase) to continue, anything else cancels'
    $ok = ($r -ceq 'YES')
    Add-Log ('Confirmation [' + $Pergunta + ']: ' + $ok)
    if (-not $ok) { Write-Registro 'Cancelled. Nothing was done in this step.' }
    return $ok
}

function Wait-Enter { $null = Read-Linha 'Press ENTER to continue' }

function Get-Prop {
    param($Objeto, [string]$Nome)
    if ($null -eq $Objeto) { return $null }
    $p = $Objeto.PSObject.Properties[$Nome]
    if ($p) { return $p.Value }
    return $null
}

function Get-Caminho {
    <# Junta base + caminho relativo com \ (funciona em Windows e, para testes, no Linux). #>
    param([string]$Base, [string]$Relativo)
    $r = $Base
    foreach ($p in ($Relativo -split '[\\/]')) { if ($p) { $r = [System.IO.Path]::Combine($r, $p) } }
    return $r
}

function Format-Tamanho {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

# ================================================================== comandos
function Format-Comando {
    param([string]$Exe, [string[]]$Argumentos)
    $p = @($Exe)
    foreach ($a in @($Argumentos)) {
        if ($null -eq $a) { continue }
        if ($a -eq '' -or $a -match '\s') { $p += ('"' + $a + '"') } else { $p += $a }
    }
    return ($p -join ' ')
}

function Test-Exe {
    param([string]$Nome)
    return [bool](Get-Command $Nome -CommandType Application -ErrorAction SilentlyContinue)
}

function Test-Requisitos {
    <# Comandos do Windows necessarios. Em simulacao a falta vira aviso (o plano ainda e mostrado). #>
    param([string[]]$Exes)
    $falta = @($Exes | Where-Object { -not (Test-Exe $_) })
    if ($falta.Count -eq 0) { return $true }
    if ($script:Sim) {
        Write-Registro ('Not present in this environment: ' + ($falta -join ', ') + ' (the simulation continues only to show the plan).') 'AVISO'
        return $true
    }
    Write-Registro ('Windows command(s) missing in this environment: ' + ($falta -join ', ')) 'ERRO'
    return $false
}

function New-Resultado {
    param([int]$Codigo, [string[]]$Saida = @(), [bool]$Simulado = $false)
    return [pscustomobject]@{ Codigo = $Codigo; Saida = @($Saida); Texto = (@($Saida) -join "`r`n"); Simulado = $Simulado }
}

function Invoke-Nativo {
    <# Executa um .exe, limpa a saida (o sfc escreve UTF-16) e grava no log. #>
    param([string]$Exe, [string[]]$Argumentos = @(), [switch]$Mostrar, [switch]$Silencioso, [switch]$SemSaidaNoLog)
    Add-Log ('EXEC: ' + (Format-Comando $Exe $Argumentos))
    if (-not (Test-Exe $Exe)) {
        if (-not $Silencioso) { Write-Registro ($Exe + ' does not exist in this environment.') 'ERRO' }
        return (New-Resultado 9009 @() $false)
    }
    $saida = New-Object 'System.Collections.Generic.List[string]'
    $codigo = 0
    try {
        & $Exe @Argumentos 2>&1 | ForEach-Object {
            $s = ([string]$_) -replace "`0", ''
            $saida.Add($s)
            if ($Mostrar) { Write-Host $s }
        }
        $codigo = $LASTEXITCODE
    } catch {
        $saida.Add($_.Exception.Message)
        $codigo = 1
    }
    if ($null -eq $codigo) { $codigo = 0 }
    if ($script:LogFile -and -not $SemSaidaNoLog -and $saida.Count -gt 0) {
        try { Add-Content -LiteralPath $script:LogFile -Value $saida.ToArray() -Encoding UTF8 } catch { $null = $_ }
    }
    Add-Log ('CODE: ' + $codigo)
    return (New-Resultado ([int]$codigo) $saida.ToArray() $false)
}

function Invoke-Destrutivo {
    <# Comando que grava/altera algo: em simulacao so imprime [SIMULACAO]. #>
    param([string]$Exe, [string[]]$Argumentos = @(), [switch]$Interativo, [switch]$SemSaidaNoLog)
    $linha = Format-Comando $Exe $Argumentos
    if ($script:Sim) {
        Write-Registro ('[SIMULATION] ' + $linha) 'SIM'
        return (New-Resultado 0 @() $true)
    }
    Write-Registro ('> ' + $linha)
    if ($Interativo) {
        if (-not (Test-Exe $Exe)) { Write-Registro ($Exe + ' does not exist in this environment.') 'ERRO'; return (New-Resultado 9009 @() $false) }
        $c = 0
        try { & $Exe @Argumentos; $c = $LASTEXITCODE } catch { Write-Registro $_.Exception.Message 'ERRO'; $c = 1 }
        if ($null -eq $c) { $c = 0 }
        Add-Log ('CODE: ' + $c)
        return (New-Resultado ([int]$c) @() $false)
    }
    return (Invoke-Nativo -Exe $Exe -Argumentos $Argumentos -Mostrar -SemSaidaNoLog:$SemSaidaNoLog)
}

function Invoke-Escrita {
    <# Acao PowerShell que grava (copia, cria pasta, arquivo): em simulacao so imprime. #>
    param([string]$Descricao, [scriptblock]$Acao)
    if ($script:Sim) { Write-Registro ('[SIMULATION] ' + $Descricao) 'SIM'; return $true }
    Add-Log ('WRITE: ' + $Descricao)
    try { $null = & $Acao; return $true }
    catch { Write-Registro ('Failed: ' + $Descricao + ' (' + $_.Exception.Message + ')') 'ERRO'; return $false }
}

function New-Pasta {
    param([string]$Caminho)
    if (Test-Path -LiteralPath $Caminho) { return $true }
    $pastaNova = $Caminho
    return (Invoke-Escrita ('create folder ' + $pastaNova) { New-Item -ItemType Directory -Path $pastaNova -Force -ErrorAction Stop | Out-Null })
}

function Copy-Arquivo {
    <# Copia um arquivo para dentro de uma pasta (robocopy /B se o Copy-Item falhar). #>
    param([string]$Origem, [string]$Pasta, [string]$NomeDestino = '')
    if (-not $NomeDestino) { $NomeDestino = Split-Path -Leaf $Origem }
    $alvoArq = Get-Caminho $Pasta $NomeDestino
    $origArq = $Origem
    if ($script:Sim) { Write-Registro ('[SIMULATION] copy ' + $origArq + ' -> ' + $alvoArq) 'SIM'; return $true }
    try {
        if (-not (Test-Path -LiteralPath $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force -ErrorAction Stop | Out-Null }
        Copy-Item -LiteralPath $origArq -Destination $alvoArq -Force -ErrorAction Stop
        Add-Log ('COPY: ' + $origArq + ' -> ' + $alvoArq)
        return $true
    } catch {
        Add-Log ('Copy-Item failed: ' + $_.Exception.Message)
    }
    if ((Test-Exe 'robocopy.exe') -and $NomeDestino -eq (Split-Path -Leaf $Origem)) {
        $r = Invoke-Nativo 'robocopy.exe' @((Split-Path -Parent $Origem), $Pasta, (Split-Path -Leaf $Origem), '/B', '/R:1', '/W:1', '/NP', '/NJH', '/NJS') -Silencioso
        if ($r.Codigo -lt 8 -and (Test-Path -LiteralPath $alvoArq)) { return $true }
    }
    return $false
}

function Copy-Robocopy {
    <# Pasta: copia o CONTEUDO de Origem para Destino. Com -Arquivo copia so esse arquivo. #>
    param([string]$Origem, [string]$Destino, [string[]]$ExcluirPastas = @(), [string]$Arquivo = '')
    $log = Join-Path $script:LogDir 'robocopy.log'
    $o = $Origem; if ($o.Length -gt 3) { $o = $o.TrimEnd('\') }
    $d = $Destino; if ($d.Length -gt 3) { $d = $d.TrimEnd('\') }
    if ($Arquivo) {
        $a = @($o, $d, $Arquivo, '/COPY:DAT', '/R:1', '/W:1', '/NP', ('/LOG+:' + $log), '/TEE')
    } else {
        $a = @($o, $d, '/E', '/COPY:DAT', '/R:1', '/W:1', '/XJ', '/NP', ('/LOG+:' + $log), '/TEE')
        $exc = @($ExcluirPastas | Where-Object { $_ })
        if ($exc.Count -gt 0) { $a += '/XD'; $a += $exc }
    }
    if (-not $script:Sim -and -not (Test-Exe 'robocopy.exe')) { Write-Registro 'robocopy.exe does not exist in this environment.' 'ERRO'; return $false }
    $r = Invoke-Destrutivo 'robocopy.exe' $a -SemSaidaNoLog
    if ($r.Simulado) { return $true }
    if ($r.Codigo -lt 8) { Write-Registro ('robocopy finished with code ' + $r.Codigo + ' (0 to 7 = success).') 'OK'; return $true }
    Write-Registro ('robocopy finished with code ' + $r.Codigo + ' (8 or more = failure). See ' + $log) 'ERRO'
    return $false
}

# ================================================================== ambiente
function Initialize-Ambiente {
    $sd = [string]$env:SystemDrive
    if ($sd) { $script:SysDrive = $sd.ToUpperInvariant() }
    $mini = $false
    if ($script:EhWindows) {
        try { $mini = Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT' } catch { $mini = $false }
    }
    $script:EmWinPE = ($mini -or $script:SysDrive -eq 'X:')
}

function Get-DescAmbiente {
    if (-not $script:EhWindows) { return 'NON-WINDOWS (test/simulation only)' }
    if ($script:EmWinPE) { return ('WinPE (system on ' + $script:SysDrive + ', Windows offline)') }
    return ('Windows online (system on ' + $script:SysDrive + ')')
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $true }
}

function Initialize-Log {
    $candidatas = @()
    if ($script:RB -and -not $script:RB.StartsWith('X:', [StringComparison]::OrdinalIgnoreCase)) { $candidatas += $script:RB }
    if ($script:EhWindows) {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            try {
                $p = Join-Path $d.RootDirectory.FullName 'ReparoBoot'
                if ($d.Name -notlike 'X:*' -and (Test-Path -LiteralPath $p) -and ($candidatas -notcontains $p)) { $candidatas += $p }
            } catch { $null = $_ }
        }
        $candidatas += 'X:\ReparoBoot-logs'
    }
    if ($script:RB -and ($candidatas -notcontains $script:RB)) { $candidatas += $script:RB }
    $candidatas += (Join-Path ([System.IO.Path]::GetTempPath()) 'ReparoBoot-logs')
    $sufixo = $script:Stamp + '-winpe-repair'
    if ($Ferramenta -gt 0) { $sufixo = $script:Stamp + '-tool' + $Ferramenta }
    foreach ($c in $candidatas) {
        try {
            $dir = Join-Path (Join-Path $c 'logs') $sufixo
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            $teste = Join-Path $dir 'teste.tmp'
            Set-Content -LiteralPath $teste -Value 'ok' -Encoding Ascii -ErrorAction Stop
            Remove-Item -LiteralPath $teste -Force -ErrorAction Stop
            $script:LogDir = $dir
            $script:LogFile = Join-Path $dir 'winpe-repair.log'
            try {
                Start-Transcript -Path (Join-Path $dir 'transcript.txt') -Append -ErrorAction Stop | Out-Null
                $script:Transcricao = $true
            } catch { $null = $_ }
            if ($dir -like 'X:*') { Write-Registro 'Log saved on X: (RAM). It is LOST on reboot. Copy it first if you need it.' 'AVISO' }
            return
        } catch { $null = $_ }
    }
    throw 'Could not create the log folder.'
}

function Get-FreeLetter {
    $usadas = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) { [void]$usadas.Add($d.Name.Substring(0, 1).ToUpperInvariant()) }
    try { foreach ($v in Get-Volume -ErrorAction Stop) { if ($v.DriveLetter) { [void]$usadas.Add(([string]$v.DriveLetter).ToUpperInvariant()) } } } catch { $null = $_ }
    foreach ($l in 'S', 'T', 'U', 'V', 'W', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K') {
        if (-not $usadas.Contains($l)) { return $l }
    }
    return $null
}

function Get-BitLockerBloqueados {
    if (-not (Test-Exe 'manage-bde.exe')) { return @() }
    $r = Invoke-Nativo 'manage-bde.exe' @('-status') -Silencioso
    $bloq = @(); $atual = $null
    foreach ($s in $r.Saida) {
        if ($s -match '^\s*Volume\s+([A-Za-z]:)') { $atual = $Matches[1].ToUpperInvariant() }
        elseif ($atual -and $s -match ':\s*(Locked|Bloqueado)\s*$') { $bloq += $atual }
    }
    return $bloq
}

# ================================================================== selecao
function Select-Item {
    <# Lista numerada. Devolve o indice (0..n-1) ou -1 (ENTER, C ou fim da entrada). #>
    param([string]$Titulo, [string[]]$Itens)
    $Itens = @($Itens)
    if ($Itens.Count -eq 0) { return -1 }
    if ($Itens.Count -eq 1) { Write-Registro ($Titulo.TrimEnd(':') + ': ' + $Itens[0] + ' (only one, selected)'); return 0 }
    Write-Host $Titulo
    for ($i = 0; $i -lt $Itens.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i + 1), $Itens[$i]) }
    for ($t = 0; $t -lt 5; $t++) {
        $r = Read-Linha 'Number (ENTER or C cancels)'
        if (-not $r -or $r.ToUpperInvariant() -eq 'C') { return -1 }
        $n = 0
        if ([int]::TryParse($r, [ref]$n) -and $n -ge 1 -and $n -le $Itens.Count) { return ($n - 1) }
        Write-Host 'Invalid option.'
    }
    return -1
}

function Select-Windows {
    <# Define WinRaiz (D:\), WinDir (D:\Windows), WinLetra e WinOnline. #>
    if ($script:WinRaiz) {
        Write-Registro ('Windows: ' + $script:WinDir + $(if ($script:WinOnline) { ' (ONLINE)' } else { ' (offline)' }))
        return $true
    }
    Write-Registro 'Looking for Windows (C: to Z:, not X:)' 'PASSO'
    $cands = @(); $descs = @()
    if ($env:REPARO_RAIZ_WIN) {
        $cands += $env:REPARO_RAIZ_WIN
        $descs += ($env:REPARO_RAIZ_WIN + '  (set in REPARO_RAIZ_WIN)')
    } else {
        foreach ($c in [char[]]'CDEFGHIJKLMNOPQRSTUVWYZ') {
            $raiz = ([string]$c) + ':\'
            $sys = Get-Caminho $raiz 'Windows\System32\config\SYSTEM'
            if (-not (Test-Path -LiteralPath $sys)) { continue }
            $info = ''
            try { $v = Get-Volume -DriveLetter ([string]$c) -ErrorAction Stop; $info = ('{0}, {1:N1} GB, label "{2}"' -f $v.FileSystem, ($v.Size / 1GB), $v.FileSystemLabel) } catch { $null = $_ }
            try { $info += (', SYSTEM modified on ' + (Get-Item -LiteralPath $sys -Force).LastWriteTime.ToString('yyyy-MM-dd HH:mm')) } catch { $null = $_ }
            $estado = '(offline)'
            if (-not $script:EmWinPE -and (([string]$c) + ':') -eq $script:SysDrive) { $estado = '(THIS Windows, online)' }
            $cands += $raiz
            $descs += ('{0}Windows  {1}  {2}' -f $raiz, $estado, $info)
        }
    }
    if ($cands.Count -eq 0) {
        Write-Registro 'No Windows found (\Windows\System32\config\SYSTEM).' 'ERRO'
        $bl = @(Get-BitLockerBloqueados)
        if ($bl.Count -gt 0) {
            Write-Registro ('LOCKED BitLocker volume(s): ' + ($bl -join ', ')) 'AVISO'
            Write-Host '  Unlock with the recovery key (48 digits, https://aka.ms/myrecoverykey):'
            Write-Host '    manage-bde -unlock C: -RecoveryPassword <key>'
        }
        Write-Host '  Common causes: BitLocker locked, disk without a driver in WinPE (Intel RST/VMD:'
        Write-Host '  tool 2 or drvload <driver>.inf) or volume without a letter (diskpart > assign).'
        return $false
    }
    $i = Select-Item 'Windows installations found:' $descs
    if ($i -lt 0) { Write-Registro 'No Windows selected.'; return $false }
    $raizEsc = $cands[$i]
    $script:WinRaiz = $raizEsc
    $script:WinDir = Get-Caminho $raizEsc 'Windows'
    $script:WinLetra = $null
    if ($raizEsc -match '^([A-Za-z]):') { $script:WinLetra = $Matches[1].ToUpperInvariant() }
    $script:WinOnline = ((-not $script:EmWinPE) -and $script:WinLetra -and (($script:WinLetra + ':') -eq $script:SysDrive))
    if ($script:WinOnline) { Write-Registro 'This is the RUNNING Windows: ONLINE mode (dism /Online, reg save, wevtutil epl).' 'AVISO' }
    Write-Registro ('Windows: ' + $script:WinDir + $(if ($script:WinOnline) { ' (ONLINE)' } else { ' (offline)' })) 'OK'
    return $true
}

function Get-RaizImagem {
    <# Valor para /Image: e /offbootdir= (ex.: D:\). #>
    $r = $script:WinRaiz
    if (-not $r.EndsWith('\') -and -not $r.EndsWith('/')) { $r += '\' }
    return $r
}

function ConvertTo-CaminhoNormal {
    param([string]$Caminho)
    $c = $Caminho -replace '/', '\'
    try { $c = [System.IO.Path]::GetFullPath($Caminho) -replace '/', '\' } catch { $null = $_ }
    return ($c.TrimEnd('\') + '\').ToLowerInvariant()
}

function Test-Dentro {
    <# Devolve a base que contem Caminho (ou $null). #>
    param([string]$Caminho, [string[]]$Bases)
    $c = ConvertTo-CaminhoNormal $Caminho
    foreach ($b in @($Bases)) {
        if (-not $b) { continue }
        $nb = ConvertTo-CaminhoNormal $b
        if ($c.StartsWith($nb)) { return $b }
    }
    return $null
}

function Get-EspacoLivre {
    param([string]$Caminho)
    try {
        $raiz = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Caminho))
        $d = New-Object System.IO.DriveInfo $raiz
        if ($d.IsReady) { return [int64]$d.AvailableFreeSpace }
    } catch { $null = $_ }
    return [int64]-1
}

function Test-EspacoOk {
    param([string]$Destino, [int64]$Bytes)
    $livre = Get-EspacoLivre $Destino
    if ($livre -lt 0) { Write-Registro 'Could not measure free space; check it yourself.' 'AVISO'; return $true }
    Write-Registro ('Needed ~' + (Format-Tamanho $Bytes) + ' | free ' + (Format-Tamanho $livre))
    if ($livre -gt $Bytes) { return $true }
    Write-Registro 'Not enough free space at the destination.' 'AVISO'
    return (Read-SimNao 'Try anyway?' 'N')
}

function Select-Destino {
    <# Escolhe um disco (sem a letra do Windows e sem X: no WinPE) ou caminho digitado.
       -Bloquear: pastas de origem; destino dentro delas e recusado e pergunta de novo. #>
    param([string]$Titulo = 'Copy destination:', [string]$PastaLog = '', [string[]]$Bloquear = @())
    for ($volta = 0; $volta -lt 5; $volta++) {
        $alvos = @(); $descs = @()
        if ($PastaLog) { $alvos += $PastaLog; $descs += ('Log folder of this run (' + $PastaLog + ')') }
        if ($script:EhWindows) {
            foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
                try {
                    if (-not $d.IsReady) { continue }
                    $l = $d.Name.Substring(0, 1).ToUpperInvariant()
                    if ($script:WinLetra -and $l -eq $script:WinLetra) { continue }
                    if ($l -eq 'X' -and $script:EmWinPE) { continue }
                    if ([string]$d.DriveType -eq 'CDRom') { continue }
                    $extra = ''
                    if (Test-Path -LiteralPath (Join-Path $d.RootDirectory.FullName 'ReparoBoot')) { $extra = '  (REPAIR USB DRIVE)' }
                    $alvos += $d.RootDirectory.FullName
                    $descs += ('{0}  [{1}] label "{2}"  free {3} of {4}{5}' -f $d.Name, $d.DriveType, $d.VolumeLabel, (Format-Tamanho $d.AvailableFreeSpace), (Format-Tamanho $d.TotalSize), $extra)
                } catch { $null = $_ }
            }
        }
        $alvos += '*DIGITAR*'; $descs += 'Type a path (e.g. E:\Backup)'
        $i = Select-Item $Titulo $descs
        if ($i -lt 0) { return $null }
        $dest = $alvos[$i]
        if ($dest -eq '*DIGITAR*') {
            $dest = Read-Linha 'Path (ENTER cancels)'
            $dest = $dest.Trim('"')
            if (-not $dest) { return $null }
            if ($dest -match '^[A-Za-z]:$') { $dest += '\' }
            if ($script:EhWindows -and $dest -notmatch '^([A-Za-z]:\\|\\\\)') { Write-Registro 'Use a full path, e.g. E:\Backup' 'AVISO'; continue }
            if (-not $script:EhWindows -and -not [System.IO.Path]::IsPathRooted($dest)) { Write-Registro 'Use a full path.' 'AVISO'; continue }
            if ($dest.Length -gt 3) { $dest = $dest.TrimEnd('\') }
        }
        $dentro = Test-Dentro $dest $Bloquear
        if ($dentro) {
            Write-Registro ('The destination is INSIDE ' + $dentro + ' (the copy would copy itself). Choose another disk or folder.') 'AVISO'
            continue
        }
        $raizDest = $null
        try { $raizDest = [System.IO.Path]::GetPathRoot($dest) } catch { $null = $_ }
        if (-not $raizDest -or -not (Test-Path -LiteralPath $raizDest)) { Write-Registro ('The drive of ' + $dest + ' does not exist.') 'ERRO'; continue }
        if ($script:EmWinPE -and $dest -like 'X:*') { Write-Registro 'X: is the WinPE RAM disk: everything is lost on reboot.' 'AVISO' }
        if ($script:WinLetra -and $dest -like ($script:WinLetra + ':*')) { Write-Registro 'The destination is on the SAME disk as Windows.' 'AVISO' }
        if (-not (New-Pasta $dest)) { Write-Registro ('Could not create/use ' + $dest) 'ERRO'; continue }
        Write-Registro ('Destination: ' + $dest) 'OK'
        return $dest
    }
    return $null
}

function Get-TamanhoPasta {
    <# Soma os arquivos sem seguir juncoes/links (evita laco em perfis). #>
    param([string]$Caminho)
    $total = [int64]0
    $pilha = New-Object 'System.Collections.Generic.Stack[string]'
    $pilha.Push($Caminho)
    while ($pilha.Count -gt 0) {
        $atual = $pilha.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $atual
            foreach ($it in $di.EnumerateFileSystemInfos()) {
                if ($it -is [System.IO.DirectoryInfo]) {
                    if (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $pilha.Push($it.FullName) }
                } else { $total += $it.Length }
            }
        } catch { $null = $_ }
    }
    return $total
}

function Test-PastaVazia {
    param([string]$Caminho)
    try {
        $di = New-Object System.IO.DirectoryInfo $Caminho
        $en = $di.EnumerateFileSystemInfos().GetEnumerator()
        return (-not $en.MoveNext())
    } catch { return $false }
}

function Select-PastaDrivers {
    <# Pasta padrao com .inf ou outra digitada. $null = pular. #>
    param([string]$Padrao)
    $pasta = $Padrao
    $infs = @()
    if (Test-Path -LiteralPath $pasta) { $infs = @(Get-ChildItem -LiteralPath $pasta -Recurse -Filter '*.inf' -File -Force -ErrorAction SilentlyContinue) }
    if ($infs.Count -eq 0) {
        Write-Registro ('No .inf drivers in ' + $Padrao) 'AVISO'
        $pasta = (Read-Linha 'Another folder with .inf files (e.g. E:\drivers ; ENTER skips)').Trim('"')
        if (-not $pasta) { return $null }
        if (-not (Test-Path -LiteralPath $pasta)) { Write-Registro 'Folder does not exist.' 'ERRO'; return $null }
        $infs = @(Get-ChildItem -LiteralPath $pasta -Recurse -Filter '*.inf' -File -Force -ErrorAction SilentlyContinue)
        if ($infs.Count -eq 0) { Write-Registro 'No .inf in that folder.' 'ERRO'; return $null }
    }
    if ($pasta.Length -gt 3) { $pasta = $pasta.TrimEnd('\') }
    Write-Registro ('Drivers: ' + $pasta + ' (' + $infs.Count + ' .inf)')
    foreach ($f in ($infs | Select-Object -First 15)) { Write-Host ('  ' + $f.FullName) }
    return $pasta
}

# ================================================================== registro
function Mount-Hive {
    param([string]$Nome, [string]$Arquivo)
    if (-not (Test-Exe 'reg.exe')) { Write-Registro 'reg.exe does not exist in this environment.' 'ERRO'; return $false }
    if (-not (Test-Path -LiteralPath $Arquivo)) { Write-Registro ('Hive not found: ' + $Arquivo) 'ERRO'; return $false }
    $null = Invoke-Nativo 'reg.exe' @('unload', ('HKLM\' + $Nome)) -Silencioso
    $r = Invoke-Nativo 'reg.exe' @('load', ('HKLM\' + $Nome), $Arquivo) -Silencioso
    if ($r.Codigo -ne 0) { Write-Registro ('reg load HKLM\' + $Nome + ' failed (hive in use? no admin?): ' + $r.Texto.Trim()) 'ERRO'; return $false }
    $script:Hives.Add($Nome)
    Write-Registro ('Hive loaded (read): HKLM\' + $Nome + ' <- ' + $Arquivo)
    return $true
}

function Dismount-Hive {
    param([string]$Nome)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    for ($t = 0; $t -lt 3; $t++) {
        $r = Invoke-Nativo 'reg.exe' @('unload', ('HKLM\' + $Nome)) -Silencioso
        if ($r.Codigo -eq 0) { [void]$script:Hives.Remove($Nome); Write-Registro ('Hive unloaded: HKLM\' + $Nome); return }
        Start-Sleep -Seconds 1
    }
    Write-Registro ('reg unload HKLM\' + $Nome + ' failed. Run later: reg unload HKLM\' + $Nome) 'AVISO'
}

function Get-RegValor {
    param([string]$Chave, [string]$Nome)
    $r = Invoke-Nativo 'reg.exe' @('query', $Chave, '/v', $Nome) -Silencioso
    if ($r.Codigo -ne 0) { return $null }
    foreach ($l in $r.Saida) {
        if ($l -match ('^\s+' + [regex]::Escape($Nome) + '\s+REG_\w+\s*(.*)$')) { return $Matches[1].Trim() }
    }
    return $null
}

function Test-RegChave {
    param([string]$Chave)
    $r = Invoke-Nativo 'reg.exe' @('query', $Chave) -Silencioso
    return ($r.Codigo -eq 0)
}

function Get-RegSubchaves {
    param([string]$Chave)
    $r = Invoke-Nativo 'reg.exe' @('query', $Chave) -Silencioso
    if ($r.Codigo -ne 0) { return @() }
    $nomes = @()
    foreach ($l in $r.Saida) {
        $s = $l.Trim()
        if ($s -match '^HKEY_' -and $s.Length -gt 0) {
            $folha = $s.Substring($s.LastIndexOf('\') + 1)
            if ($s.TrimEnd('\') -ne ($Chave -replace '^HKLM', 'HKEY_LOCAL_MACHINE').TrimEnd('\')) { $nomes += $folha }
        }
    }
    return $nomes
}

function Get-ControlSet {
    param([string]$RaizSystem)
    $v = Get-RegValor ($RaizSystem + '\Select') 'Current'
    $n = 1
    if ($v -match '^0x([0-9a-fA-F]+)$') { $n = [Convert]::ToInt32($Matches[1], 16) }
    elseif ($v -match '^\d+$') { $n = [int]$v }
    return ('ControlSet{0:D3}' -f $n)
}

function Set-StartZero {
    <# Start=0 nos servicos (offline via reg load, online direto). #>
    param([string[]]$Servicos)
    if (-not (Test-Requisitos @('reg.exe'))) { return }
    $carregou = $false
    $raiz = 'HKLM\SYSTEM'; $cs = 'CurrentControlSet'
    try {
        if (-not $script:WinOnline) {
            if (-not (Mount-Hive 'RB_SYS' (Get-Caminho $script:WinDir 'System32\config\SYSTEM'))) {
                if ($script:Sim) {
                    foreach ($s in $Servicos) { Write-Registro ('[SIMULATION] reg add HKLM\RB_SYS\ControlSet001\Services\' + $s + ' /v Start /t REG_DWORD /d 0 /f') 'SIM' }
                }
                return
            }
            $carregou = $true; $raiz = 'HKLM\RB_SYS'; $cs = Get-ControlSet $raiz
        }
        foreach ($s in $Servicos) {
            $k = $raiz + '\' + $cs + '\Services\' + $s
            $v = Get-RegValor $k 'Start'
            if ($null -eq $v) { Write-Registro ('  ' + $s + ' does not exist in this Windows: skipped.'); continue }
            Write-Registro ('  ' + $s + ': current Start=' + $v + ' -> 0')
            $null = Invoke-Destrutivo 'reg.exe' @('add', $k, '/v', 'Start', '/t', 'REG_DWORD', '/d', '0', '/f')
            if (Test-RegChave ($k + '\StartOverride')) {
                $null = Invoke-Destrutivo 'reg.exe' @('add', ($k + '\StartOverride'), '/v', '0', '/t', 'REG_DWORD', '/d', '0', '/f')
            }
        }
    } finally {
        if ($carregou) { Dismount-Hive 'RB_SYS' }
    }
}

function Get-VersaoWindows {
    $res = @{ Versao = ''; Produto = ''; Build = '' }
    $carregou = $false; $raiz = 'HKLM\SOFTWARE'
    try {
        if (-not $script:WinOnline) {
            if (-not (Mount-Hive 'RB_SOFT' (Get-Caminho $script:WinDir 'System32\config\SOFTWARE'))) { return $res }
            $carregou = $true; $raiz = 'HKLM\RB_SOFT'
        }
        $k = $raiz + '\Microsoft\Windows NT\CurrentVersion'
        $v = Get-RegValor $k 'CurrentVersion'; if ($v) { $res.Versao = $v }
        $v = Get-RegValor $k 'ProductName'; if ($v) { $res.Produto = $v }
        $v = Get-RegValor $k 'CurrentBuild'; if ($v) { $res.Build = $v }
    } finally {
        if ($carregou) { Dismount-Hive 'RB_SOFT' }
    }
    return $res
}

function Backup-Registro {
    <# Copia SYSTEM, SOFTWARE, SAM, SECURITY, DEFAULT e NTUSER.DAT/UsrClass.dat + SHA256SUMS. #>
    param([string]$Destino)
    $dest = Get-Caminho $Destino ('registry-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Registro 'WARNING: SAM and SECURITY contain the local PASSWORD HASHES. Keep the backup somewhere safe and delete it when no longer needed.' 'AVISO'
    if (-not (New-Pasta (Get-Caminho $dest 'config'))) { return $false }
    $config = Get-Caminho $dest 'config'
    $hivesBase = @('SYSTEM', 'SOFTWARE')
    if (Read-SimNao 'Include SAM and SECURITY (local password hashes)? Only answer Y if really needed' 'N') {
        $hivesBase += @('SAM', 'SECURITY')
        Write-Registro 'SAM and SECURITY INCLUDED: delete the backup as soon as you no longer need it.' 'AVISO'
    } else { Write-Registro 'SAM and SECURITY will NOT be copied (safe default).' }
    if ($script:WinOnline) {
        if (-not (Test-Requisitos @('reg.exe'))) { return $false }
        foreach ($h in $hivesBase) {
            $r = Invoke-Destrutivo 'reg.exe' @('save', ('HKLM\' + $h), (Get-Caminho $config $h), '/y')
            if ($r.Codigo -eq 0) { Write-Registro ('  ' + $h + ' (reg save)') } else { Write-Registro ('  ' + $h + ' failed (needs administrator)') 'AVISO' }
        }
        $null = Invoke-Destrutivo 'reg.exe' @('save', 'HKU\.DEFAULT', (Get-Caminho $config 'DEFAULT'), '/y')
        if (New-Pasta (Get-Caminho $dest 'Users')) {
            $null = Invoke-Destrutivo 'reg.exe' @('save', 'HKCU', (Get-Caminho $dest 'Users\NTUSER-usuario-atual.DAT'), '/y')
        }
    } else {
        $origConfig = Get-Caminho $script:WinDir 'System32\config'
        foreach ($h in @($hivesBase + 'DEFAULT')) {
            foreach ($ext in '', '.LOG1', '.LOG2') {
                $f = Get-Caminho $origConfig ($h + $ext)
                if (-not (Test-Path -LiteralPath $f)) { if (-not $ext) { Write-Registro ('  ' + $h + ' does not exist') 'AVISO' }; continue }
                if (Copy-Arquivo $f $config) { if (-not $ext) { Write-Registro ('  ' + $h) } }
                else { Write-Registro ('  ' + $h + $ext + ' not copied (no access?)') 'AVISO' }
            }
        }
    }
    $users = Get-Caminho $script:WinRaiz 'Users'
    if (Test-Path -LiteralPath $users) {
        foreach ($u in @(Get-ChildItem -LiteralPath $users -Directory -Force -ErrorAction SilentlyContinue)) {
            if (($u.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            foreach ($rel in 'NTUSER.DAT', 'AppData\Local\Microsoft\Windows\UsrClass.dat') {
                $f = Get-Caminho $u.FullName $rel
                if (-not (Test-Path -LiteralPath $f)) { continue }
                if (Copy-Arquivo $f (Get-Caminho $dest ('Users\' + $u.Name))) { Write-Registro ('  Users\' + $u.Name + '\' + (Split-Path -Leaf $f)) }
                else { Write-Registro ('  Users\' + $u.Name + '\' + (Split-Path -Leaf $f) + ' in use/no access (normal for the logged-on user)') 'AVISO' }
            }
        }
    }
    if ($script:Sim) { Write-Registro ('[SIMULATION] create SHA256SUMS.txt in ' + $dest) 'SIM'; return $true }
    try {
        $linhas = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)) {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $linhas += ('{0} *{1}' -f $hash, $f.FullName.Substring($dest.Length).TrimStart('\', '/'))
        }
        Set-Content -LiteralPath (Get-Caminho $dest 'SHA256SUMS.txt') -Value $linhas -Encoding Ascii
    } catch { Write-Registro ('Could not create SHA256SUMS: ' + $_.Exception.Message) 'AVISO' }
    Write-Registro ('Registry backup: ' + $dest + ' (with SHA256SUMS.txt)') 'OK'
    Write-Host '  Restore: with Windows shut down, copy back to Windows\System32\config.'
    return $true
}

function Request-BackupRegistro {
    <# Oferece o backup (padrao N: nunca grava hives sem a pessoa pedir). #>
    if (Read-SimNao 'Back up the registry first (tool 9; may include SAM/SECURITY with password hashes)?' 'N') {
        $d = Select-Destino 'Registry backup destination:' $script:LogDir
        if ($d) { $null = Backup-Registro $d } else { Write-Registro 'Registry backup skipped.' }
    }
}

# ================================================================== 2. RST
function Get-ModoStorage {
    <# Lista controladoras de disco e define ModoStorage: VMD, RAID, NVME, AHCI ou DESCONHECIDO. #>
    $script:ModoStorage = 'AHCI'
    $vmd = 'VEN_8086&DEV_(9A0B|467F|A77F|7D0B|AD0B|0B25|28C0|201D)'
    $clsScsi = '{4d36e97b-e325-11ce-bfc1-08002be10318}'
    $clsHdc = '{4d36e96a-e325-11ce-bfc1-08002be10318}'
    $devs = @()
    try { $devs = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop) }
    catch {
        Write-Registro ('Could not list devices (WMI): ' + $_.Exception.Message) 'AVISO'
        $script:ModoStorage = 'UNKNOWN'
        return
    }
    $intelRaid = $false; $achou = 0
    Write-Registro 'Disk controllers:'
    foreach ($d in $devs) {
        $id = [string](Get-Prop $d 'DeviceID')
        $nome = [string](Get-Prop $d 'Name')
        $cls = [string](Get-Prop $d 'PNPClass')
        $guid = [string](Get-Prop $d 'ClassGuid')
        $ids = ((@(Get-Prop $d 'CompatibleID') + @(Get-Prop $d 'HardwareID')) | Where-Object { $_ }) -join ' '
        $cm = Get-Prop $d 'ConfigManagerErrorCode'
        $ehStorage = ($cls -eq 'SCSIAdapter' -or $cls -eq 'HDC' -or $guid -eq $clsScsi -or $guid -eq $clsHdc -or
            $ids -match 'CC_010[45678]' -or $id -match $vmd)
        if (-not $ehStorage) { continue }
        $achou++
        $estado = 'ok'
        if ($null -ne $cm -and [int]$cm -ne 0) { $estado = ('NO DRIVER/ERROR (code ' + $cm + ')') }
        if (-not $nome) { $nome = '(no name)' }
        Write-Registro ('  ' + $nome + ' | ' + $id + ' | ' + $estado)
        if ($id -match $vmd -or $nome -match 'VMD') { $script:ModoStorage = 'VMD'; if ($id -match 'VEN_8086') { $intelRaid = $true } }
        elseif ($ids -match 'CC_0104' -or $nome -match 'RAID|Rapid Storage|iaStor') {
            if ($script:ModoStorage -ne 'VMD') { $script:ModoStorage = 'RAID' }
            if ($id -match 'VEN_8086' -or $nome -match 'Intel') { $intelRaid = $true }
        }
        elseif (($ids -match 'CC_0108' -or $nome -match 'NVM') -and $script:ModoStorage -eq 'AHCI') { $script:ModoStorage = 'NVME' }
    }
    if ($achou -eq 0) { Write-Registro '  (no controller listed)' 'AVISO'; $script:ModoStorage = 'UNKNOWN' }
    if (($script:ModoStorage -eq 'RAID' -or $script:ModoStorage -eq 'VMD') -and -not $intelRaid) {
        Write-Registro 'RAID that does not look like Intel (e.g. AMD RAID): use the motherboard vendor driver.' 'AVISO'
    }
}

function Invoke-InjetarRst {
    Write-Registro '2. Intel RST driver injection (automatic detection)' 'PASSO'
    Get-ModoStorage
    if ($script:ModoStorage -eq 'VMD' -or $script:ModoStorage -eq 'RAID') {
        Write-Registro ('Controller in mode ' + $script:ModoStorage + ' (Intel RST): Windows needs iaStorAVC/iaStorVD.') 'AVISO'
    } elseif ($script:ModoStorage -eq 'UNKNOWN') {
        Write-Registro 'Could not determine the controller mode. If WinPE does not see the disk, it probably needs RST.' 'AVISO'
    } else {
        Write-Registro ('Controller in mode ' + $script:ModoStorage + ': the Intel RST driver is usually NOT needed.') 'OK'
    }
    Write-Host '  Alternative: switch SATA/VMD to AHCI in the BIOS (with storahci enabled in the registry).'
    $drv = $null
    if (Read-SimNao 'Inject/load RST drivers now?' $(if ($script:ModoStorage -eq 'VMD' -or $script:ModoStorage -eq 'RAID') { 'S' } else { 'N' })) {
        $drv = Select-PastaDrivers (Get-Caminho $script:RB 'drivers\rst')
    }
    if ($drv) {
        if ($script:EmWinPE -and (Test-Exe 'drvload.exe')) {
            if (Read-SimNao 'Load the driver into WinPE ITSELF (drvload) to see the disk now?' 'N') {
                foreach ($inf in @(Get-ChildItem -LiteralPath $drv -Recurse -Filter '*.inf' -File -Force -ErrorAction SilentlyContinue)) {
                    $null = Invoke-Destrutivo 'drvload.exe' @($inf.FullName)
                }
                Write-Registro 'If the disk appeared now, Windows will be searched for next.'
            }
        }
        if (-not (Select-Windows)) { return }
        Request-BackupRegistro
        if ($script:WinOnline) {
            if (-not (Test-Requisitos @('pnputil.exe'))) { return }
            if (Confirm-Sim ('Install the drivers from ' + $drv + ' on THIS Windows (pnputil)?')) {
                $null = Invoke-Destrutivo 'pnputil.exe' @('/add-driver', (Get-Caminho $drv '*.inf'), '/subdirs', '/install')
            }
        } else {
            if (-not (Test-Requisitos @('dism.exe'))) { return }
            if (Confirm-Sim ('Inject the drivers from ' + $drv + ' into Windows ' + (Get-RaizImagem) + ' (offline DISM)?')) {
                $r = Invoke-Destrutivo 'dism.exe' @(('/Image:' + (Get-RaizImagem)), '/Add-Driver', ('/Driver:' + $drv), '/Recurse', ('/LogPath:' + (Join-Path $script:LogDir 'dism-add-driver.log')))
                if (-not $r.Simulado) {
                    if ($r.Codigo -eq 0) { Write-Registro 'Drivers injected.' 'OK' } else { Write-Registro ('DISM finished with code ' + $r.Codigo + '. See dism-add-driver.log') 'ERRO' }
                }
            }
        }
    } else { Write-Registro 'Driver injection skipped.' }
    if (Read-SimNao 'Enable storahci/iaStorAVC/iaStorAC/iaStorVD/iaStorV (Start=0) in the registry (to switch the BIOS mode)?' 'N') {
        if (-not (Select-Windows)) { return }
        if (Confirm-Sim 'Write Start=0 to these services (those that exist)?') { Set-StartZero @('storahci', 'iaStorAVC', 'iaStorAC', 'iaStorVD', 'iaStorV') }
    }
}

# ================================================================== 3. BCD
function Find-EspWindows {
    if (-not $script:WinLetra) { return $null }
    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) { return $null }
    try {
        $pw = Get-Partition -DriveLetter $script:WinLetra -ErrorAction Stop | Select-Object -First 1
        $esps = @(Get-Partition -DiskNumber $pw.DiskNumber -ErrorAction Stop | Where-Object { [string]$_.GptType -eq $script:EspGuid })
        if ($esps.Count -eq 0) { return $null }
        if ($esps.Count -eq 1) { return $esps[0] }
        $i = Select-Item ('More than one EFI partition on disk ' + $pw.DiskNumber + ':') ($esps | ForEach-Object { 'Partition {0}: {1:N0} MB' -f $_.PartitionNumber, ($_.Size / 1MB) })
        if ($i -lt 0) { return $null }
        return $esps[$i]
    } catch { return $null }
}

function Mount-Esp {
    <# Devolve a letra da EFI (atribui uma temporaria se preciso; em simulacao nao atribui). #>
    param($Esp)
    $dl = Get-Prop $Esp 'DriveLetter'
    if ($dl -and [int][char]$dl -ne 0) { return ([string]$dl).ToUpperInvariant() }
    $l = Get-FreeLetter
    if (-not $l) { Write-Registro 'No free letter to mount the EFI.' 'ERRO'; return $null }
    if ($script:Sim) { Write-Registro ('[SIMULATION] assign letter ' + $l + ': to the EFI (disk ' + $Esp.DiskNumber + ', partition ' + $Esp.PartitionNumber + ')') 'SIM'; return $null }
    try {
        Add-PartitionAccessPath -DiskNumber $Esp.DiskNumber -PartitionNumber $Esp.PartitionNumber -AccessPath ($l + ':\') -ErrorAction Stop
        $script:EspTemp = $l
        Write-Registro ('EFI temporarily mounted on ' + $l + ':')
        return $l
    } catch {
        Write-Registro ('Could not mount the EFI: ' + $_.Exception.Message) 'AVISO'
        return $null
    }
}

function Dismount-Esp {
    if ($script:EspTemp -and (Test-Exe 'mountvol.exe')) {
        $null = Invoke-Nativo 'mountvol.exe' @(($script:EspTemp + ':'), '/D') -Silencioso
        Write-Registro ('Temporary letter ' + $script:EspTemp + ': removed.')
    }
    $script:EspTemp = $null
}

function Invoke-Bcdboot {
    param([string]$LetraEsp, [bool]$TemEsp)
    $a = @($script:WinDir, '/f', 'ALL')
    if ($LetraEsp) { $a += @('/s', ($LetraEsp + ':')) }
    elseif ($TemEsp) {
        if (-not $script:Sim) { Write-Registro 'The EFI exists but was not mounted: bcdboot without /s could write to the USB drive. Use menu option 1 (UEFI boot).' 'ERRO'; return }
        $a += @('/s', '<letra-da-EFI>:')
    }
    $r = Invoke-Destrutivo 'bcdboot.exe' ($a + @('/l', 'pt-BR'))
    if (-not $r.Simulado -and $r.Codigo -ne 0) {
        Write-Registro 'bcdboot failed with /l pt-BR; trying without the locale...' 'AVISO'
        $r = Invoke-Destrutivo 'bcdboot.exe' $a
    }
    if (-not $r.Simulado) {
        if ($r.Codigo -eq 0) { Write-Registro 'bcdboot finished.' 'OK' } else { Write-Registro ('bcdboot failed (code ' + $r.Codigo + ').') 'ERRO' }
    }
}

function Invoke-ReconstruirBcd {
    Write-Registro '3. BCD rebuild (automated bootrec)' 'PASSO'
    if (-not (Test-Requisitos @('bcdedit.exe'))) { return }
    if (-not (Select-Windows)) { return }
    Request-BackupRegistro
    $esp = Find-EspWindows
    $letra = $null; $bcdEsp = $null; $store = $null
    try {
        if ($esp) {
            Write-Registro ('EFI partition of the Windows disk: disk ' + $esp.DiskNumber + ', partition ' + $esp.PartitionNumber + (' ({0:N0} MB)' -f ($esp.Size / 1MB)))
            $letra = Mount-Esp $esp
            if ($letra) {
                $bcdEsp = $letra + ':\EFI\Microsoft\Boot\BCD'
                if (Test-Path -LiteralPath $bcdEsp) { $store = $bcdEsp } else { Write-Registro ('No BCD at ' + $bcdEsp) 'AVISO' }
            }
        } else {
            Write-Registro 'EFI partition not identified (MBR/BIOS disk, or no storage cmdlets): using the system BCD.' 'AVISO'
        }
        Write-Registro 'Backup of the current BCD (bcdedit /export) and listing:'
        $bkp = Join-Path $script:LogDir 'BCD-backup'
        $pre = @(); if ($store) { $pre = @('/store', $store) }
        $r = Invoke-Nativo 'bcdedit.exe' ($pre + @('/export', $bkp))
        if ($r.Codigo -eq 0) { Write-Registro ('Backup: ' + $bkp) 'OK' } else { Write-Registro 'bcdedit /export failed (BCD missing/corrupt?).' 'AVISO' }
        $r = Invoke-Nativo 'bcdedit.exe' ($pre + @('/enum', 'all'))
        $lista = Join-Path $script:LogDir 'bcdedit-enum.txt'
        try { Set-Content -LiteralPath $lista -Value $r.Saida -Encoding UTF8 } catch { $null = $_ }
        foreach ($l in $r.Saida) { if ($l -match '^(identifier|identificador|device|dispositivo|path|caminho|description|descri)') { Write-Host ('  ' + $l) } }
        Write-Registro ('Full listing: ' + $lista)

        Write-Host ''
        Write-Host '  [1] Rebuild: bootrec /scanos + /rebuildbcd (if present) and bcdboot'
        Write-Host '  [2] Restore a BCD from backup'
        Write-Host '  [3] Use BCD-Template as a base (no entries) and then bcdboot'
        $op = Read-Linha 'Option (ENTER cancels)'
        switch ($op) {
            '1' {
                if (-not (Confirm-Sim 'Rebuild the BCD (bootrec /scanos, /rebuildbcd and, if needed, bcdboot)?')) { return }
                $ok = $false
                if (Test-Exe 'bootrec.exe') {
                    $null = Invoke-Destrutivo 'bootrec.exe' @('/scanos')
                    Write-Host '  bootrec /rebuildbcd will ask whether to add the installation:'
                    Write-Host '  answer Y (Yes) or A (All) on English Windows; S/T on Portuguese Windows.'
                    Write-Host '  "Total identified Windows installations: 0" = the BCD already knows Windows or is unreadable.'
                    $r = Invoke-Destrutivo 'bootrec.exe' @('/rebuildbcd') -Interativo
                    if ($r.Codigo -eq 0) { $ok = $true }
                    Write-Host '  /fixboot is not run: on UEFI it usually gives "Access is denied" and is not needed.'
                } else {
                    Write-Registro 'bootrec does not exist here (only in WinRE, not in plain WinPE or online Windows). Using bcdboot.' 'AVISO'
                }
                if (-not $ok -or (Read-SimNao ('Also run bcdboot ' + $script:WinDir + ' /f ALL (recreates the boot files)?') 'N')) {
                    if (Test-Requisitos @('bcdboot.exe')) { Invoke-Bcdboot $letra ([bool]$esp) }
                }
            }
            '2' {
                $raizLogs = Get-Caminho $script:RB 'logs'
                $bks = @()
                if (Test-Path -LiteralPath $raizLogs) {
                    $bks = @(Get-ChildItem -LiteralPath $raizLogs -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
                            ($_.Name -eq 'BCD-backup' -or $_.Name -eq 'BCD-export' -or $_.Name -eq 'BCD-original' -or
                            ($_.Name -eq 'BCD' -and $_.FullName -match 'EFI-backup')) -and $_.FullName -ne $bkp
                        } | Sort-Object LastWriteTime -Descending)
                }
                $descs = @($bks | ForEach-Object { '{0}  ({1:yyyy-MM-dd HH:mm})' -f $_.FullName, $_.LastWriteTime })
                $descs += 'Type the path of a BCD file'
                $i = Select-Item 'BCD backups (newest first):' $descs
                if ($i -lt 0) { Write-Registro 'No backup selected.'; return }
                if ($i -lt $bks.Count) { $arq = $bks[$i].FullName } else { $arq = (Read-Linha 'BCD file (ENTER cancels)').Trim('"') }
                if (-not $arq -or -not (Test-Path -LiteralPath $arq)) { Write-Registro 'File does not exist.' 'ERRO'; return }
                if ($bcdEsp) {
                    if (-not (Confirm-Sim ('Replace ' + $bcdEsp + ' with ' + $arq + '? (the current one is already in BCD-backup)'))) { return }
                    $null = New-Pasta (Split-Path -Parent $bcdEsp)
                    $null = Invoke-Escrita ('copy ' + $arq + ' -> ' + $bcdEsp) {
                        if (Test-Path -LiteralPath $bcdEsp) { (Get-Item -LiteralPath $bcdEsp -Force).Attributes = 'Normal' }
                        Copy-Item -LiteralPath $arq -Destination $bcdEsp -Force -ErrorAction Stop
                    }
                } else {
                    if ($esp -and -not $script:Sim) { Write-Registro 'The EFI exists but was not mounted; will not import into the wrong BCD.' 'ERRO'; return }
                    if (-not (Confirm-Sim ('Import ' + $arq + ' into the system BCD (bcdedit /import)?'))) { return }
                    $null = Invoke-Destrutivo 'bcdedit.exe' @('/import', $arq)
                }
            }
            '3' {
                $tpl = Get-Caminho $script:WinDir 'System32\config\BCD-Template'
                if (-not (Test-Path -LiteralPath $tpl)) { Write-Registro ('BCD-Template does not exist: ' + $tpl) 'ERRO'; return }
                Write-Registro 'BCD-Template has NO Windows entry: on its own it does NOT boot (bcdboot creates the entry afterwards).' 'AVISO'
                if (-not $bcdEsp) {
                    if ($script:Sim) { Write-Registro '[SIMULATION] copy BCD-Template -> <EFI>:\EFI\Microsoft\Boot\BCD' 'SIM' }
                    else { Write-Registro 'Needs the EFI mounted (GPT disk). On an MBR disk use option [1].' 'ERRO'; return }
                } else {
                    if (-not (Confirm-Sim ('Write BCD-Template as ' + $bcdEsp + '?'))) { return }
                    $null = New-Pasta (Split-Path -Parent $bcdEsp)
                    $null = Invoke-Escrita ('copy ' + $tpl + ' -> ' + $bcdEsp) {
                        if (Test-Path -LiteralPath $bcdEsp) { (Get-Item -LiteralPath $bcdEsp -Force).Attributes = 'Normal' }
                        Copy-Item -LiteralPath $tpl -Destination $bcdEsp -Force -ErrorAction Stop
                    }
                }
                if ((Read-SimNao 'Run bcdboot now to create the Windows entry?' 'S') -and (Test-Requisitos @('bcdboot.exe'))) { Invoke-Bcdboot $letra ([bool]$esp) }
            }
            default { Write-Registro 'Cancelled.'; return }
        }
        Write-Registro ('Done. BCD backup in ' + $bkp + ' (restore: option [2] or bcdedit /import <file>).') 'OK'
    } finally {
        Dismount-Esp
    }
}

# ================================================================== 4. SFC + DISM
function Show-Resumo {
    param([string]$Nome, $Resultado, [string]$Padrao)
    if ($Resultado.Simulado) { return }
    $linhas = @($Resultado.Saida | Where-Object { $_ -match $Padrao } | Select-Object -Last 6)
    Write-Registro ('Summary ' + $Nome + ' (code ' + $Resultado.Codigo + '):')
    foreach ($l in $linhas) { Write-Registro ('  ' + $l.Trim()) }
}

function Copy-LogsCbs {
    if ($script:Sim) { return }
    $fontes = @()
    if ($script:WinDir) { $fontes += (Get-Caminho $script:WinDir 'Logs\CBS\CBS.log') }
    if ($env:SystemRoot) { $fontes += (Get-Caminho $env:SystemRoot 'Logs\CBS\CBS.log') }
    $n = 0
    foreach ($f in ($fontes | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $f) {
            $n++
            try { Copy-Item -LiteralPath $f -Destination (Join-Path $script:LogDir ('CBS-' + $n + '.log')) -Force -ErrorAction Stop } catch { $null = $_ }
        }
    }
}

$script:PadraoSfc = 'integrity|integridade|violat|violac|corrupt|corromp|repair|repar|could not|nao pode|Prote|Verification|Verifica'
$script:PadraoDism = 'component store|reposit|corrupt|corromp|repairable|repar|restore operation|operation completed|opera..o|Error|Erro'

function Invoke-SfcDism {
    Write-Registro '4. SFC and DISM in sequence (with log)' 'PASSO'
    if (-not (Test-Requisitos @('dism.exe', 'sfc.exe'))) { return }
    if (-not (Select-Windows)) { return }
    $dismLog = Join-Path $script:LogDir 'dism.log'
    if ($script:WinOnline) {
        Write-Registro 'ONLINE Windows: DISM /Online /RestoreHealth and then SFC /scannow.'
        if (-not (Confirm-Sim 'Run DISM /RestoreHealth and SFC now (may take 30+ min)?')) { return }
        $r = Invoke-Destrutivo 'dism.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth', ('/LogPath:' + $dismLog))
        Show-Resumo 'DISM' $r $script:PadraoDism
        $r = Invoke-Destrutivo 'sfc.exe' @('/scannow')
        Show-Resumo 'SFC' $r $script:PadraoSfc
    } else {
        $fonte = (Read-Linha 'Optional source (e.g. E:\sources\install.wim:1 ; ENTER = no source)').Trim('"')
        $a = @(('/Image:' + (Get-RaizImagem)), '/Cleanup-Image', '/RestoreHealth', ('/LogPath:' + $dismLog))
        if ($fonte) {
            $arqFonte = $fonte; $indice = ''
            if ($fonte -match '^(.+\.(wim|esd|swm))(:(\d+))?$') { $arqFonte = $Matches[1]; if ($Matches[4]) { $indice = $Matches[4] } }
            if (-not (Test-Path -LiteralPath $arqFonte)) { Write-Registro ('Source not found: ' + $arqFonte + ' (DISM will fail).') 'AVISO' }
            if ($arqFonte -match '\.(wim|esd|swm)$') {
                if (-not $indice) { $indice = '1'; Write-Registro 'No index in the source: using :1 (check with dism /Get-WimInfo /WimFile:<file>).' 'AVISO' }
                $tipo = 'WIM'; if ($arqFonte -match '\.esd$') { $tipo = 'ESD' }
                $a += ('/Source:' + $tipo + ':' + $arqFonte + ':' + $indice)
            } else { $a += ('/Source:' + $arqFonte) }
            $a += '/LimitAccess'
        }
        if ($script:EmWinPE) {
            $scratch = Get-Caminho $script:WinRaiz 'Scratch'
            $null = New-Pasta $scratch
            $a += ('/ScratchDir:' + $scratch)
        }
        if (-not (Confirm-Sim ('Run offline DISM on ' + (Get-RaizImagem) + ' and then offline SFC (may take 30+ min)?'))) { return }
        $r = Invoke-Destrutivo 'dism.exe' $a
        Show-Resumo 'DISM' $r $script:PadraoDism
        $r = Invoke-Destrutivo 'sfc.exe' @('/scannow', ('/offbootdir=' + (Get-RaizImagem)), ('/offwindir=' + $script:WinDir))
        Show-Resumo 'SFC' $r $script:PadraoSfc
    }
    Copy-LogsCbs
    Write-Registro ('Logs: ' + $script:LogFile + ', ' + $dismLog + ', CBS-*.log in ' + $script:LogDir)
}

# ================================================================== 5. PERFIL
$script:Favoritos = @(
    'Favorites',
    'AppData\Local\Microsoft\Edge\User Data\*\Bookmarks',
    'AppData\Local\Google\Chrome\User Data\*\Bookmarks',
    'AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Bookmarks',
    'AppData\Roaming\Opera Software\Opera Stable\Bookmarks',
    'AppData\Roaming\Opera Software\Opera GX Stable\Bookmarks',
    'AppData\Roaming\Mozilla\Firefox\Profiles\*\places.sqlite',
    'AppData\Roaming\Mozilla\Firefox\Profiles\*\bookmarkbackups'
)

function Resolve-Padrao {
    <# 'a\b\*\c' dentro de Base -> caminhos existentes (o * vale para uma pasta). #>
    param([string]$Base, [string]$Padrao)
    $idx = $Padrao.IndexOf('*')
    if ($idx -lt 0) {
        $p = Get-Caminho $Base $Padrao
        if (Test-Path -LiteralPath $p) { return @($p) }
        return @()
    }
    $antes = $Padrao.Substring(0, $idx).TrimEnd('\')
    $depois = $Padrao.Substring($idx + 1).TrimStart('\')
    $dirBase = Get-Caminho $Base $antes
    $res = @()
    if (Test-Path -LiteralPath $dirBase) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $dirBase -Directory -Force -ErrorAction SilentlyContinue)) {
            $c = Get-Caminho $sub.FullName $depois
            if (Test-Path -LiteralPath $c) { $res += $c }
        }
    }
    return $res
}

function Get-Favoritos {
    param([string]$Perfil, [string]$Destino)
    $rel = New-Object 'System.Collections.Generic.List[string]'
    $rel.Add('Favorites searched in ' + $Perfil + ' (paths inside the profile):')
    $null = New-Pasta $Destino
    foreach ($pad in $script:Favoritos) {
        $achados = @(Resolve-Padrao $Perfil $pad)
        if ($achados.Count -eq 0) { $rel.Add('  does not exist: ' + $pad); continue }
        foreach ($f in $achados) {
            $r = $f.Substring($Perfil.Length).TrimStart('\', '/')
            $extra = ''
            if ((Split-Path -Leaf $f) -eq 'Bookmarks') {
                try { $extra = ('  (' + ([regex]::Matches([IO.File]::ReadAllText($f), '"type"\s*:\s*"url"')).Count + ' links)') } catch { $null = $_ }
            }
            $rel.Add('  FOUND: ' + $r + $extra)
            $nomeDest = ($r -replace '[\\/ ]', '_')
            $origemFav = $f; $alvoFav = Get-Caminho $Destino $nomeDest
            $null = Invoke-Escrita ('copy ' + $origemFav + ' -> ' + $alvoFav) { Copy-Item -LiteralPath $origemFav -Destination $alvoFav -Recurse -Force -ErrorAction Stop }
        }
    }
    foreach ($l in $rel) { Write-Registro $l }
    $arqRel = Get-Caminho $Destino 'favorites.txt'
    if ($script:Sim) { $arqRel = Join-Path $script:LogDir ('favorites-' + (Split-Path -Leaf $Perfil) + '.txt') }
    try { Set-Content -LiteralPath $arqRel -Value $rel.ToArray() -Encoding UTF8 -ErrorAction Stop; Write-Registro ('Report: ' + $arqRel) } catch { $null = $_ }
}

function Invoke-ExtrairPerfil {
    Write-Registro '5. Profile extraction (AppData and favorites)' 'PASSO'
    if (-not (Select-Windows)) { return }
    $users = Get-Caminho $script:WinRaiz 'Users'
    if (-not (Test-Path -LiteralPath $users)) { Write-Registro ('Users folder not found in ' + $script:WinRaiz) 'ERRO'; return }
    $ignorar = @('default', 'public', 'all users', 'default user', 'defaultapppool', 'desktop.ini')
    $perfis = @(Get-ChildItem -LiteralPath $users -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
            ($ignorar -notcontains $_.Name.ToLowerInvariant()) -and (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
        } | ForEach-Object { $_.Name })
    if ($perfis.Count -eq 0) { Write-Registro 'No user profile.' 'ERRO'; return }
    $i = Select-Item 'Profiles:' ($perfis + @('ALL'))
    if ($i -lt 0) { Write-Registro 'Cancelled.'; return }
    if ($i -eq $perfis.Count) { $sel = $perfis } else { $sel = @($perfis[$i]) }
    $origens = @($sel | ForEach-Object { Get-Caminho $users $_ })
    $dest = Select-Destino 'Copy destination:' '' $origens
    if (-not $dest) { Write-Registro 'Cancelled.'; return }
    $exc = @()
    if (Read-SimNao 'Exclude junk (Temp, INetCache, CrashDumps, browser cache)?' 'S') {
        foreach ($o in $origens) {
            foreach ($r in 'AppData\Local\Temp', 'AppData\Local\Microsoft\Windows\INetCache', 'AppData\Local\CrashDumps') { $exc += (Get-Caminho $o $r) }
            foreach ($pad in 'AppData\Local\Google\Chrome\User Data\*\Cache', 'AppData\Local\Google\Chrome\User Data\*\Code Cache',
                'AppData\Local\Microsoft\Edge\User Data\*\Cache', 'AppData\Local\Microsoft\Edge\User Data\*\Code Cache',
                'AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Cache', 'AppData\Local\Mozilla\Firefox\Profiles\*\cache2') {
                $exc += @(Resolve-Padrao $o $pad)
            }
        }
        Write-Registro ('Folders excluded from the copy: ' + $exc.Count)
    }
    if ($script:WinOnline) { Write-Registro 'Online Windows: files in use (NTUSER.DAT, open Outlook) may fail. Close the programs.' 'AVISO' }
    Write-Registro 'Calculating size...'
    $bytes = [int64]0
    foreach ($o in $origens) { $bytes += (Get-TamanhoPasta $o) }
    if (-not (Test-EspacoOk $dest $bytes)) { return }
    $alvo = Get-Caminho $dest ('profiles-' + $script:Stamp)
    if (-not (New-Pasta $alvo)) { return }
    foreach ($nome in $sel) {
        Write-Registro ('Copying profile ' + $nome + ' (with AppData) ...') 'PASSO'
        $origemPerfil = Get-Caminho $users $nome
        $excPerfil = @($exc | Where-Object { Test-Dentro $_ @($origemPerfil) })
        if (-not (Copy-Robocopy $origemPerfil (Get-Caminho $alvo $nome) $excPerfil)) { Write-Registro ('Copy of ' + $nome + ' had errors (see the log).') 'AVISO' }
        Write-Registro ('Favorites of ' + $nome) 'PASSO'
        Get-Favoritos (Get-Caminho $users $nome) (Get-Caminho $alvo ('favorites-' + $nome))
    }
    Write-Registro ('Done: ' + $alvo + '  (printers: tool 6)') 'OK'
}

# ================================================================== 6. IMPRESSORAS
function Invoke-ExportarImpressoras {
    Write-Registro '6. Printer export' 'PASSO'
    if (-not (Select-Windows)) { return }
    $dest = Select-Destino 'Export destination:'
    if (-not $dest) { Write-Registro 'Cancelled.'; return }
    $d = Get-Caminho $dest ('printers-' + $script:Stamp)
    if (-not (New-Pasta $d)) { return }
    $sp = Get-Caminho $script:WinDir 'System32\spool\drivers'
    if (Test-Path -LiteralPath $sp) {
        Write-Registro 'Copying spool\drivers ...'
        $null = Copy-Robocopy $sp (Get-Caminho $d 'spool-drivers')
    } else { Write-Registro ('Missing: ' + $sp) 'AVISO' }
    if (-not (Test-Requisitos @('reg.exe'))) { return }
    $carregados = @()
    $exportados = @()
    $cs = 'CurrentControlSet'
    try {
        if ($script:WinOnline) { $rs = 'HKLM\SYSTEM'; $rso = 'HKLM\SOFTWARE' }
        else {
            $rs = 'HKLM\RB_SYS'; $rso = 'HKLM\RB_SOFT'
            if (Mount-Hive 'RB_SYS' (Get-Caminho $script:WinDir 'System32\config\SYSTEM')) { $carregados += 'RB_SYS'; $cs = Get-ControlSet $rs }
            elseif (-not $script:Sim) { return }
            else { $cs = 'ControlSet001' }
            if (Mount-Hive 'RB_SOFT' (Get-Caminho $script:WinDir 'System32\config\SOFTWARE')) { $carregados += 'RB_SOFT' }
            elseif (-not $script:Sim) { return }
        }
        $imps = @(Get-RegSubchaves ($rs + '\' + $cs + '\Control\Print\Printers'))
        if ($imps.Count -gt 0) { Write-Registro ('Printers in the registry: ' + ($imps -join ', ')) } else { Write-Registro 'No printer listed in the registry (or hive not read).' }
        foreach ($k in 'Printers', 'Environments', 'Monitors', 'Forms') {
            $arq = Get-Caminho $d ('print-' + $k + '.reg')
            $r = Invoke-Destrutivo 'reg.exe' @('export', ($rs + '\' + $cs + '\Control\Print\' + $k), $arq, '/y')
            if ($r.Codigo -eq 0) { $exportados += $arq; if (-not $r.Simulado) { Write-Registro ('  print-' + $k + '.reg') 'OK' } } else { Write-Registro ('  (no Print\ key ' + $k + ')') 'AVISO' }
        }
        $arq = Get-Caminho $d 'software-print.reg'
        $r = Invoke-Destrutivo 'reg.exe' @('export', ($rso + '\Microsoft\Windows NT\CurrentVersion\Print'), $arq, '/y')
        if ($r.Codigo -eq 0) { $exportados += $arq; if (-not $r.Simulado) { Write-Registro '  software-print.reg' 'OK' } }
        if ($script:WinOnline) { $null = Invoke-Destrutivo 'reg.exe' @('export', 'HKCU\Printers', (Get-Caminho $d 'usuario-atual-printers.reg'), '/y') }
    } finally {
        foreach ($h in $carregados) { Dismount-Hive $h }
    }
    if (-not $script:WinOnline -and -not $script:Sim) {
        foreach ($f in $exportados) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try {
                $t = [IO.File]::ReadAllText($f, [Text.Encoding]::Unicode)
                $t = $t -replace ([regex]::Escape('HKEY_LOCAL_MACHINE\RB_SYS\' + $cs)), 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet'
                $t = $t -replace ([regex]::Escape('HKEY_LOCAL_MACHINE\RB_SOFT')), 'HKEY_LOCAL_MACHINE\SOFTWARE'
                [IO.File]::WriteAllText(($f -replace '\.reg$', '-import.reg'), $t, [Text.Encoding]::Unicode)
            } catch { Write-Registro ('Could not create the importable version of ' + $f) 'AVISO' }
        }
    }
    $notas = @(
        'Restore printers exported by ReparoBoot (tool 6):',
        '1. Install the printer driver (from the vendor; the spool-drivers folder helps find the model).',
        '2. Import the *-import.reg (offline) or *.reg (online) files with: reg import <file>',
        '   (as administrator) and restart the spooler: net stop spooler & net start spooler',
        '3. Most reliable: reinstall the printer with the vendor installer, or use PrintBrm.exe.'
    )
    $arqNotas = Get-Caminho $d 'README-RESTORE.txt'
    $null = Invoke-Escrita ('write ' + $arqNotas) { Set-Content -LiteralPath $arqNotas -Value $notas -Encoding Ascii -ErrorAction Stop }
    Write-Registro ('Exported to ' + $d) 'OK'
    foreach ($n in $notas) { Write-Host ('  ' + $n) }
}

# ================================================================== 7. RAIZ DO C
$script:PastasSistema = @('windows', 'program files', 'program files (x86)', 'programdata', 'users', '$recycle.bin',
    'system volume information', 'recovery', 'perflogs', 'boot', '$winreagent', 'config.msi', 'msocache', 'intel', 'amd',
    'nvidia', 'onedrivetemp', '$windows.~bt', '$windows.~ws', '$getcurrent', '$sysreset', 'windows.old',
    'documents and settings', 'hiberfil.sys', 'pagefile.sys', 'swapfile.sys', 'dumpstack.log', 'dumpstack.log.tmp',
    'bootmgr', 'bootnxt', 'bootsect.bak', 'scratch', 'reparoboot')
$script:Marcadores = @('.gamingroot', 'desktop.ini', 'thumbs.db', 'ehthumbs.db', 'ehthumbs_vista.db', '.ds_store')

function Invoke-VarrerRaiz {
    Write-Registro '7. C: root scan (non-standard folders)' 'PASSO'
    if (-not (Select-Windows)) { return }
    $itens = @()
    foreach ($e in @(Get-ChildItem -LiteralPath $script:WinRaiz -Force -ErrorAction SilentlyContinue)) {
        $n = $e.Name.ToLowerInvariant()
        if ($script:PastasSistema -contains $n) { continue }
        if (($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($n -like '*.marker' -or $script:Marcadores -contains $n) { continue }
        if ($e -is [System.IO.FileInfo]) { if ($e.Length -eq 0) { continue } }
        elseif (Test-PastaVazia $e.FullName) { continue }
        $itens += $e
    }
    if ($itens.Count -eq 0) { Write-Registro 'Nothing outside the system folders in the root.' 'OK'; return }
    Write-Host 'Items outside the system (e.g. "Arquivos de Programas RFB" from IRPF, ERP/accounting, databases):'
    $tams = @()
    for ($i = 0; $i -lt $itens.Count; $i++) {
        $e = $itens[$i]
        if ($e -is [System.IO.FileInfo]) { $t = [int64]$e.Length; $suf = '' } else { $t = Get-TamanhoPasta $e.FullName; $suf = '\' }
        $tams += $t
        Write-Registro ('  [{0}] {1,10}  {2}{3}' -f ($i + 1), (Format-Tamanho $t), $e.Name, $suf)
    }
    $sel = @()
    for ($t = 0; $t -lt 5; $t++) {
        $r = Read-Linha 'Select the numbers (e.g. 1 3 5), "all", or ENTER/C cancels'
        if (-not $r -or $r.ToUpperInvariant() -eq 'C') { Write-Registro 'Cancelled.'; return }
        if (@('all', 'todos') -contains $r.ToLowerInvariant()) { $sel = @(0..($itens.Count - 1)); break }
        $ok = $true; $sel = @()
        foreach ($tok in ($r -split '[\s,;]+' | Where-Object { $_ })) {
            $k = 0
            if ([int]::TryParse($tok, [ref]$k) -and $k -ge 1 -and $k -le $itens.Count) { if ($sel -notcontains ($k - 1)) { $sel += ($k - 1) } } else { $ok = $false }
        }
        if ($ok -and $sel.Count -gt 0) { break }
        Write-Host 'Invalid input.'; $sel = @()
    }
    if ($sel.Count -eq 0) { Write-Registro 'Cancelled.'; return }
    $origens = @($sel | Where-Object { $itens[$_] -is [System.IO.DirectoryInfo] } | ForEach-Object { $itens[$_].FullName })
    $dest = Select-Destino 'Copy destination:' '' $origens
    if (-not $dest) { Write-Registro 'Cancelled.'; return }
    $bytes = [int64]0
    foreach ($k in $sel) { $bytes += $tams[$k] }
    if (-not (Test-EspacoOk $dest $bytes)) { return }
    $alvo = Get-Caminho $dest ('c-root-' + $script:Stamp)
    if (-not (New-Pasta $alvo)) { return }
    foreach ($k in $sel) {
        $e = $itens[$k]
        Write-Registro ('Copying ' + $e.Name + ' ...')
        if ($e -is [System.IO.DirectoryInfo]) { $ok = Copy-Robocopy $e.FullName (Get-Caminho $alvo $e.Name) }
        else { $ok = Copy-Robocopy $e.DirectoryName $alvo @() $e.Name }
        if (-not $ok) { Write-Registro ('Errors in ' + $e.Name) 'AVISO' }
    }
    Write-Registro ('Done: ' + $alvo) 'OK'
}

# ================================================================== 8. EVENT LOG
function Write-ErrosEvento {
    <# Lista erros/criticos de um .evtx (-Caminho) ou de um log vivo (-NomeLog) em um .txt. #>
    param([string]$Caminho = '', [string]$NomeLog = '', [string]$Arquivo, [int]$Max = 200)
    $linhas = New-Object 'System.Collections.Generic.List[string]'
    $ok = $false
    if (Get-Command Get-WinEvent -ErrorAction SilentlyContinue) {
        try {
            if ($Caminho) { $ev = @(Get-WinEvent -Path $Caminho -FilterXPath $script:Consulta -MaxEvents $Max -ErrorAction Stop) }
            else { $ev = @(Get-WinEvent -LogName $NomeLog -FilterXPath $script:Consulta -MaxEvents $Max -ErrorAction Stop) }
            foreach ($e in $ev) {
                $m = ''
                try { $m = [string]$e.Message } catch { $m = '' }
                if (-not $m) { try { $m = '(no provider text; data: ' + ((@($e.Properties) | ForEach-Object { [string]$_.Value }) -join ' | ') + ')' } catch { $m = '(no text)' } }
                $m = ($m -replace '\s+', ' ').Trim()
                if ($m.Length -gt 400) { $m = $m.Substring(0, 400) + '...' }
                $nv = 'ERROR'; if ($e.Level -eq 1) { $nv = 'CRITICAL' }
                $linhas.Add(('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2} id={3}: {4}' -f $e.TimeCreated, $nv, $e.ProviderName, $e.Id, $m))
            }
            $ok = $true
        } catch {
            if ([string]$_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { $ok = $true }
            else { Write-Registro ('Get-WinEvent failed: ' + $_.Exception.Message) 'AVISO' }
        }
    }
    if (-not $ok -and (Test-Exe 'wevtutil.exe')) {
        if ($Caminho) { $a = @('qe', $Caminho, '/lf:true') } else { $a = @('qe', $NomeLog) }
        $r = Invoke-Nativo 'wevtutil.exe' ($a + @(('/q:' + $script:Consulta), ('/c:' + $Max), '/rd:true', '/f:text')) -Silencioso -SemSaidaNoLog
        if ($r.Codigo -eq 0) { foreach ($l in $r.Saida) { $linhas.Add($l) }; $ok = $true }
    }
    if (-not $ok) { Write-Registro ('Could not read the events of ' + $Caminho + $NomeLog) 'AVISO'; return }
    if ($linhas.Count -eq 0) { $linhas.Add('No error or critical event found.') }
    try { Set-Content -LiteralPath $Arquivo -Value $linhas.ToArray() -Encoding UTF8 -ErrorAction Stop } catch { Write-Registro ('Could not write ' + $Arquivo) 'AVISO'; return }
    Write-Registro ('  ' + (Split-Path -Leaf $Arquivo) + ': ' + $linhas.Count + ' line(s) (last ' + $Max + ' errors/critical)')
}

function Invoke-EventLog {
    Write-Registro '8. Event Log (optional)' 'PASSO'
    if (-not (Select-Windows)) { return }
    $dest = Join-Path $script:LogDir 'eventlog'
    $dirErros = $dest
    if ($script:Sim) { $dirErros = $script:LogDir } else { $null = New-Pasta $dest }
    if ($script:WinOnline) {
        foreach ($n in 'System', 'Application', 'Setup') {
            $r = Invoke-Destrutivo 'wevtutil.exe' @('epl', $n, (Join-Path $dest ($n + '.evtx')), '/ow:true')
            if (-not $r.Simulado -and $r.Codigo -eq 0) { Write-Registro ('  ' + $n + '.evtx exported') }
            Write-ErrosEvento -NomeLog $n -Arquivo (Join-Path $dirErros ($n + '-erros.txt'))
        }
    } else {
        $dirLog = Get-Caminho $script:WinDir 'System32\winevt\Logs'
        if (-not (Test-Path -LiteralPath $dirLog)) { Write-Registro ('winevt\Logs not found: ' + $dirLog) 'ERRO'; return }
        $arqs = @(Get-ChildItem -LiteralPath $dirLog -Filter '*.evtx' -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.ToLowerInvariant() -match $script:EvtxRe })
        Write-Registro ('Selected .evtx logs: ' + $arqs.Count)
        foreach ($f in $arqs) { if (Copy-Arquivo $f.FullName $dest) { if (-not $script:Sim) { Write-Registro ('  ' + $f.Name) } } else { Write-Registro ('  ' + $f.Name + ' not copied') 'AVISO' } }
        foreach ($n in 'System', 'Application', 'Setup') {
            $orig = Get-Caminho $dirLog ($n + '.evtx')
            $copia = Join-Path $dest ($n + '.evtx')
            $fonte = $orig
            if (-not $script:Sim -and (Test-Path -LiteralPath $copia)) { $fonte = $copia }
            if (-not (Test-Path -LiteralPath $fonte)) { Write-Registro ('  ' + $n + '.evtx does not exist') 'AVISO'; continue }
            Write-ErrosEvento -Caminho $fonte -Arquivo (Join-Path $dirErros ($n + '-erros.txt'))
        }
    }
    Write-Registro ('Event Logs in ' + $dest + ' (error lists in ' + $dirErros + ')') 'OK'
}

# ================================================================== 9. BACKUP REGISTRO
function Invoke-BackupRegistro {
    Write-Registro '9. Registry hive backup' 'PASSO'
    if (-not (Select-Windows)) { return }
    Write-Registro 'The backup can include SAM and SECURITY, which hold the local PASSWORD HASHES.' 'AVISO'
    if (-not (Read-SimNao 'Continue with the registry backup?' 'N')) { Write-Registro 'Cancelled.'; return }
    $d = Select-Destino 'Registry backup destination:' $script:LogDir
    if (-not $d) { Write-Registro 'Cancelled.'; return }
    $null = Backup-Registro $d
}

# ================================================================== 10. INTEGRIDADE
function Test-Criticos {
    $lista = @('ntoskrnl.exe', 'hal.dll', 'winload.efi', 'winload.exe', 'ci.dll', 'ntdll.dll', 'kernel32.dll', 'kernelbase.dll',
        'smss.exe', 'csrss.exe', 'wininit.exe', 'winlogon.exe', 'services.exe', 'lsass.exe', 'userinit.exe',
        'drivers\ntfs.sys', 'drivers\disk.sys', 'drivers\volmgr.sys', 'drivers\partmgr.sys', 'drivers\classpnp.sys',
        'drivers\acpi.sys', 'drivers\pci.sys', 'drivers\storahci.sys', 'drivers\stornvme.sys',
        'config\SYSTEM', 'config\SOFTWARE', 'config\SAM', 'config\SECURITY', 'config\DEFAULT')
    $problemas = 0
    Write-Registro 'Critical files (missing or 0 bytes = problem):'
    $s32 = Get-Caminho $script:WinDir 'System32'
    foreach ($f in $lista) {
        $p = Get-Caminho $s32 $f
        if (-not (Test-Path -LiteralPath $p)) { Write-Registro ('  MISSING: System32\' + $f) 'AVISO'; $problemas++; continue }
        try { if ((Get-Item -LiteralPath $p -Force).Length -eq 0) { Write-Registro ('  EMPTY  : System32\' + $f) 'AVISO'; $problemas++ } } catch { $null = $_ }
    }
    if (-not (Test-Path -LiteralPath (Get-Caminho $script:WinDir 'explorer.exe'))) { Write-Registro '  MISSING: Windows\explorer.exe' 'AVISO'; $problemas++ }
    if ($problemas -eq 0) { Write-Registro '  No problem in the checked files.' 'OK' } else { Write-Registro ('  ' + $problemas + ' problem(s).') 'AVISO' }
}

function Show-ResumoCbs {
    param([string]$Desde)
    if ($script:Sim) { return }
    $fontes = @()
    if ($env:SystemRoot) { $fontes += (Get-Caminho $env:SystemRoot 'Logs\CBS\CBS.log') }
    if ($script:WinDir) { $fontes += (Get-Caminho $script:WinDir 'Logs\CBS\CBS.log') }
    foreach ($f in ($fontes | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $sr = 0; $naoRep = 0; $rep = 0; $ult = New-Object 'System.Collections.Generic.List[string]'
        try {
            $fs = New-Object System.IO.FileStream($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr2 = New-Object System.IO.StreamReader($fs)
            try {
                while ($null -ne ($l = $sr2.ReadLine())) {
                    if ($l.Length -lt 19 -or $l.Substring(0, 19) -lt $Desde) { continue }
                    if ($l -notmatch '\[SR\]') { continue }
                    $sr++
                    if ($l -match 'Cannot repair') { $naoRep++; $ult.Add($l) }
                    elseif ($l -match 'Repair|corrupt') { $rep++; $ult.Add($l) }
                }
            } finally { $sr2.Close(); $fs.Close() }
        } catch { Write-Registro ('Could not read ' + $f) 'AVISO'; continue }
        Write-Registro ('CBS.log (' + $f + '): ' + $sr + ' [SR] line(s) in this run; not repairable: ' + $naoRep + '; corrupt/repairs: ' + $rep)
        foreach ($l in ($ult | Select-Object -Last 10)) { Write-Registro ('  ' + $l) }
    }
}

function Invoke-Integridade {
    Write-Registro '10. File integrity checker (offline)' 'PASSO'
    if (-not (Select-Windows)) { return }
    Test-Criticos
    if (-not (Test-Requisitos @('sfc.exe', 'dism.exe'))) { return }
    if (-not (Read-SimNao 'Run SFC /verifyonly and DISM /CheckHealth + /ScanHealth now (check only, no fixes)?' 'S')) { return }
    $desde = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $dl = Join-Path $script:LogDir 'dism-scan.log'
    if ($script:WinOnline) {
        $r = Invoke-Destrutivo 'sfc.exe' @('/verifyonly'); Show-Resumo 'SFC' $r $script:PadraoSfc
        $r = Invoke-Destrutivo 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth', ('/LogPath:' + $dl)); Show-Resumo 'DISM CheckHealth' $r $script:PadraoDism
        $r = Invoke-Destrutivo 'dism.exe' @('/Online', '/Cleanup-Image', '/ScanHealth', ('/LogPath:' + $dl)); Show-Resumo 'DISM ScanHealth' $r $script:PadraoDism
    } else {
        $r = Invoke-Destrutivo 'sfc.exe' @('/verifyonly', ('/offbootdir=' + (Get-RaizImagem)), ('/offwindir=' + $script:WinDir)); Show-Resumo 'SFC' $r $script:PadraoSfc
        $extra = @()
        if ($script:EmWinPE) { $scratch = Get-Caminho $script:WinRaiz 'Scratch'; $null = New-Pasta $scratch; $extra = @('/ScratchDir:' + $scratch) }
        $r = Invoke-Destrutivo 'dism.exe' (@(('/Image:' + (Get-RaizImagem)), '/Cleanup-Image', '/CheckHealth', ('/LogPath:' + $dl)) + $extra); Show-Resumo 'DISM CheckHealth' $r $script:PadraoDism
        $r = Invoke-Destrutivo 'dism.exe' (@(('/Image:' + (Get-RaizImagem)), '/Cleanup-Image', '/ScanHealth', ('/LogPath:' + $dl)) + $extra); Show-Resumo 'DISM ScanHealth' $r $script:PadraoDism
    }
    Show-ResumoCbs $desde
    Copy-LogsCbs
    Write-Registro 'To repair the image use tool 4 (RestoreHealth + SFC /scannow).'
}

# ================================================================== 11. SMART
function ConvertTo-Nome {
    param($Valor, [hashtable]$Mapa)
    if ($null -eq $Valor) { return '?' }
    $s = [string]$Valor
    $n = 0
    if ([int]::TryParse($s, [ref]$n) -and $Mapa.ContainsKey($n)) { return $Mapa[$n] }
    return $s
}

$script:MapaBus = @{ 0 = 'Unknown'; 1 = 'SCSI'; 2 = 'ATAPI'; 3 = 'ATA'; 4 = '1394'; 5 = 'SSA'; 6 = 'FibreChannel'; 7 = 'USB'; 8 = 'RAID'; 9 = 'iSCSI'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 15 = 'Virtual'; 16 = 'StorageSpaces'; 17 = 'NVMe' }
$script:MapaMidia = @{ 0 = 'Unspecified'; 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
$script:MapaSaude = @{ 0 = 'Healthy'; 1 = 'Warning'; 2 = 'Unhealthy'; 5 = 'Unknown' }
$script:MapaOper = @{ 0 = 'Unknown'; 1 = 'Other'; 2 = 'OK'; 3 = 'Degraded'; 5 = 'Predictive Failure'; 6 = 'Error'; 10 = 'Stopped'; 11 = 'In Service'; 13 = 'Lost Communication'; 53264 = 'Online'; 53265 = 'Not Ready'; 53266 = 'No Media'; 53270 = 'Failed' }

function Find-Smartctl {
    $cands = @((Get-Caminho $script:RB 'tools\smartctl.exe'), (Get-Caminho $script:RB 'tools\smartmontools\bin\smartctl.exe'), (Get-Caminho $script:RB 'tools\bin\smartctl.exe'))
    if ($env:ProgramFiles) { $cands += (Get-Caminho $env:ProgramFiles 'smartmontools\bin\smartctl.exe') }
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    $g = Get-Command 'smartctl.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
    return $null
}

function Get-AvaliacaoSmartctl {
    param([string]$Texto, [bool]$Nvme)
    $nivel = 'OK'; $mot = @()
    $ml = [System.Text.RegularExpressions.RegexOptions]::Multiline
    function Get-Atr([string]$t, [string]$nome) {
        $m = [regex]::Match($t, ('^\s*\d+\s+' + $nome + '\s+(?:\S+\s+){7}(\d+)'), [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($m.Success) { return [int64]$m.Groups[1].Value }
        return $null
    }
    function Get-Nv([string]$t, [string]$nome) {
        $m = [regex]::Match($t, ('^' + $nome + ':\s+([0-9xXa-fA-F,\.]+)'), [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($m.Success) { return ($m.Groups[1].Value -replace '[,\.]', '') }
        return $null
    }
    if ($Texto -match 'FAILED|FAILING') { $nivel = 'BAD'; $mot += 'health=FAILED' }
    if ($Nvme) {
        $v = Get-Nv $Texto 'Critical Warning'
        if ($v -and $v -ne '0x00' -and $v -ne '0') { $nivel = 'BAD'; $mot += ('CriticalWarning=' + $v) }
        $sp = Get-Nv $Texto 'Available Spare'; $spt = Get-Nv $Texto 'Available Spare Threshold'
        if ($sp -match '^\d+$' -and $spt -match '^\d+$' -and [int]$sp -le [int]$spt) { $nivel = 'BAD'; $mot += ('spare=' + $sp + '%') }
        $v = Get-Nv $Texto 'Percentage Used'
        if ($v -match '^\d+$') { if ([int]$v -ge 100) { $nivel = 'BAD' } elseif ([int]$v -ge 90 -and $nivel -eq 'OK') { $nivel = 'ATTENTION' }; $mot += ('used=' + $v + '%') }
        $v = Get-Nv $Texto 'Media and Data Integrity Errors'
        if ($v -match '^\d+$' -and [int64]$v -gt 0) { if ($nivel -eq 'OK') { $nivel = 'ATTENTION' }; $mot += ('media_errors=' + $v) }
    } else {
        $v = Get-Atr $Texto 'Reallocated_Sector_Ct'
        if ($null -ne $v -and $v -gt 0) { if ($nivel -eq 'OK') { $nivel = 'ATTENTION' }; if ($v -gt 100) { $nivel = 'BAD' }; $mot += ('reallocated=' + $v) }
        $v = Get-Atr $Texto 'Current_Pending_Sector'
        if ($null -ne $v -and $v -gt 0) { $nivel = 'BAD'; $mot += ('pending=' + $v) }
        $v = Get-Atr $Texto 'Offline_Uncorrectable'
        if ($null -ne $v -and $v -gt 0) { $nivel = 'BAD'; $mot += ('uncorrectable=' + $v) }
        $v = Get-Atr $Texto 'UDMA_CRC_Error_Count'
        if ($null -ne $v -and $v -gt 0) { if ($nivel -eq 'OK') { $nivel = 'ATTENTION' }; $mot += ('CRC=' + $v + '(cable?)') }
    }
    if ($Texto -match 'SMART support is:\s+Unavailable|Unable to detect device type') { $nivel = 'NO SMART' }
    $null = $ml
    return @{ Nivel = $nivel; Motivos = ($mot -join ' ') }
}

function Test-TempConfiavel {
    <# Temperatura do contador de confiabilidade: nao confiavel se <=0, >100, ou >=85 com max 0/ausente. #>
    param($Temp, $Max)
    if ($null -eq $Temp) { return $false }
    $t = 0; $m = 0
    if (-not [int]::TryParse([string]$Temp, [ref]$t)) { return $false }
    $temMax = ($null -ne $Max -and [int]::TryParse([string]$Max, [ref]$m))
    if ($t -le 0 -or $t -gt 100) { return $false }
    if ($t -ge 85 -and (-not $temMax -or $m -eq 0)) { return $false }
    if ($temMax -and $m -gt 0 -and $t -gt $m + 5) { return $false }
    return $true
}

function Get-ChaveDisco {
    <# Chave para nao listar o mesmo disco duas vezes: serial; senao DeviceId; senao nome+tamanho. #>
    param($Disco)
    $sn = ([string](Get-Prop $Disco 'SerialNumber')).Trim() -replace '[\s_\.]+$', ''
    if ($sn -and $sn -notmatch '^0+$') { return ('SN:' + $sn.ToUpperInvariant()) }
    $id = [string](Get-Prop $Disco 'DeviceId')
    if ($id) { return ('ID:' + $id) }
    return ('NM:' + ([string](Get-Prop $Disco 'FriendlyName')).ToUpperInvariant() + '|' + [string](Get-Prop $Disco 'Size'))
}

function Invoke-Smart {
    Write-Registro '11. S.M.A.R.T. checker (optional)' 'PASSO'
    if (-not (Read-SimNao 'Read SMART of all disks now (read-only)?' 'S')) { return }
    $piores = @()
    $brutos = @()
    $viaCim = $false
    try { $brutos = @(Get-PhysicalDisk -ErrorAction Stop) }
    catch {
        try { $brutos = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_PhysicalDisk -ErrorAction Stop); $viaCim = $true }
        catch { Write-Registro 'Get-PhysicalDisk/MSFT_PhysicalDisk unavailable (WinPE-StorageWMI missing?).' 'AVISO' }
    }
    $vistos = @{}
    $discos = @()
    foreach ($d in $brutos) {
        $k = Get-ChaveDisco $d
        if ($vistos.ContainsKey($k)) { Add-Log ('Duplicate disk ignored: ' + (Get-Prop $d 'FriendlyName') + ' (' + $k + ')'); continue }
        $vistos[$k] = $true
        $discos += $d
    }
    if ($brutos.Count -ne $discos.Count) { Write-Registro (($brutos.Count - $discos.Count).ToString() + ' duplicate entry(ies) of the same disk ignored.') }
    foreach ($d in $discos) {
        $rel = $null
        if (-not $viaCim) { try { $rel = Get-StorageReliabilityCounter -PhysicalDisk $d -ErrorAction Stop } catch { $rel = $null } }
        if ($null -eq $rel) { try { $rel = Get-CimAssociatedInstance -InputObject $d -ResultClassName MSFT_StorageReliabilityCounter -ErrorAction Stop | Select-Object -First 1 } catch { $rel = $null } }
        $nome = [string](Get-Prop $d 'FriendlyName'); if (-not $nome) { $nome = [string](Get-Prop $d 'Model') }
        $bus = ConvertTo-Nome (Get-Prop $d 'BusType') $script:MapaBus
        $midia = ConvertTo-Nome (Get-Prop $d 'MediaType') $script:MapaMidia
        $saude = ConvertTo-Nome (Get-Prop $d 'HealthStatus') $script:MapaSaude
        $oper = (@(Get-Prop $d 'OperationalStatus') | ForEach-Object { ConvertTo-Nome $_ $script:MapaOper }) -join ','
        $tam = Get-Prop $d 'Size'
        $temp = Get-Prop $rel 'Temperature'; $tmax = Get-Prop $rel 'TemperatureMax'
        $wear = Get-Prop $rel 'Wear'
        $rerr = Get-Prop $rel 'ReadErrorsUncorrected'; $werr = Get-Prop $rel 'WriteErrorsUncorrected'
        $rtot = Get-Prop $rel 'ReadErrorsTotal'; $horas = Get-Prop $rel 'PowerOnHours'
        $nivel = 'OK'; $mot = @()
        if ($saude -eq 'Warning') { $nivel = 'ATTENTION'; $mot += 'health=Warning' }
        elseif ($saude -ne 'Healthy') { $nivel = 'BAD'; $mot += ('health=' + $saude) }
        if ($oper -match 'Predictive|Error|Failed|Degraded|Lost') { $nivel = 'BAD'; $mot += ('state=' + $oper) }
        if ($null -ne $wear -and [int]$wear -ge 100) { $nivel = 'BAD'; $mot += ('wear=' + $wear + '%') }
        elseif ($null -ne $wear -and [int]$wear -ge 90) { if ($nivel -eq 'OK') { $nivel = 'ATTENTION' }; $mot += ('wear=' + $wear + '%') }
        if (($null -ne $rerr -and [int64]$rerr -gt 0) -or ($null -ne $werr -and [int64]$werr -gt 0)) { $nivel = 'BAD'; $mot += 'uncorrected_errors' }
        $lim = 55; if ($bus -eq 'NVMe') { $lim = 70 }
        $tempOk = Test-TempConfiavel $temp $tmax
        if ($null -eq $temp) { $txtTemp = '?' }
        elseif ($tempOk) { $txtTemp = [string]$temp + 'C (max ' + $(if ($null -ne $tmax) { $tmax } else { '?' }) + ')' }
        else { $txtTemp = [string]$temp + 'C (max ' + $(if ($null -ne $tmax) { $tmax } else { '?' }) + ') temperature unreliable' }
        if ($tempOk -and [int]$temp -ge $lim) { if ($nivel -eq 'OK') { $nivel = 'ATTENTION' }; $mot += ('temperature=' + $temp + 'C') }
        Write-Registro ('Disk: ' + $nome + ' | ' + $bus + ' ' + $midia + ' | ' + $(if ($tam) { Format-Tamanho ([double]$tam) } else { '?' }))
        Write-Registro ('  health=' + $saude + '  state=' + $oper + '  temperature=' + $txtTemp +
            '  wear=' + $(if ($null -ne $wear) { [string]$wear + '%' } else { '?' }) + '  power_on_hours=' + $(if ($null -ne $horas) { $horas } else { '?' }))
        Write-Registro ('  uncorrected read errors=' + $(if ($null -ne $rerr) { $rerr } else { '?' }) + ' (total ' + $(if ($null -ne $rtot) { $rtot } else { '?' }) + ')  uncorrected write errors=' + $(if ($null -ne $werr) { $werr } else { '?' }))
        if ($null -eq $rel) { Write-Registro '  (no reliability counters for this disk: common on USB and RAID)' }
        if ($null -ne $temp -and -not $tempOk) { Write-Registro '  (temperature sensor reading is implausible: ignored in the evaluation; check with smartctl)' }
        Write-Registro ('  RESULT: ' + $nivel + $(if ($mot.Count) { ' -> ' + ($mot -join ' ') } else { '' })) $(if ($nivel -eq 'OK') { 'OK' } else { 'AVISO' })
        if ($nivel -ne 'OK') { $piores += ($nome + ': ' + $nivel) }
    }
    try {
        foreach ($p in @(Get-CimInstance -Namespace 'root/wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
            if ([bool](Get-Prop $p 'PredictFailure')) {
                Write-Registro ('SMART PREDICTS FAILURE: ' + (Get-Prop $p 'InstanceName') + ' (reason ' + (Get-Prop $p 'Reason') + ')') 'ERRO'
                $piores += ([string](Get-Prop $p 'InstanceName') + ': BAD (PredictFailure)')
            }
        }
    } catch { $null = $_ }
    $sm = Find-Smartctl
    if ($sm) {
        Write-Registro ('Using smartctl: ' + $sm)
        $scan = Invoke-Nativo $sm @('--scan') -Silencioso
        foreach ($l in $scan.Saida) {
            if ($l -notmatch '^(\S+)') { continue }
            $dev = $Matches[1]
            if ($dev -notmatch '^/dev/') { continue }
            $tipo = @()
            if ($l -match '-d\s+([a-z0-9,\-]+)') { $tipo = @('-d', $Matches[1]) }
            $r = Invoke-Nativo $sm ($tipo + @('-a', $dev)) -Silencioso -SemSaidaNoLog
            $arq = Join-Path $script:LogDir ('smart-' + ($dev -replace '[^A-Za-z0-9]', '_') + '.txt')
            try { Set-Content -LiteralPath $arq -Value $r.Saida -Encoding UTF8 } catch { $null = $_ }
            $nvme = ($l -match 'nvme' -or $r.Texto -match 'NVMe')
            $av = Get-AvaliacaoSmartctl $r.Texto $nvme
            Write-Registro ('  smartctl ' + $dev + ': ' + $av.Nivel + $(if ($av.Motivos) { ' -> ' + $av.Motivos } else { '' })) $(if ($av.Nivel -eq 'OK') { 'OK' } else { 'AVISO' })
            if ($av.Nivel -ne 'OK') { $piores += ($dev + ': ' + $av.Nivel) }
        }
    } else {
        Write-Registro 'smartctl not found (optional: put smartctl.exe in ReparoBoot\tools for details).'
    }
    Write-Host ''
    if ($piores.Count -gt 0) {
        Write-Registro ('Disks with problems: ' + ($piores -join '; ')) 'AVISO'
        Write-Registro 'Do not run heavy repairs or cloning on a BAD disk: save the data first (tools 5 and 7).' 'AVISO'
    } elseif ($discos.Count -gt 0) { Write-Registro 'No disk with an apparent problem.' 'OK' }
    Write-Registro ('Details in ' + $script:LogDir)
}

# ================================================================== 12. WIN7
function Invoke-DriversWin7 {
    Write-Registro '12. Storage drivers for Windows 7' 'PASSO'
    if (-not (Select-Windows)) { return }
    if ($script:WinOnline) {
        Write-Registro 'This is for an OFFLINE Windows 7 (one that does not boot). Run it from WinPE, with Win7 on another letter:' 'AVISO'
        Write-Host '  dism /Image:C:\ /Add-Driver /Driver:E:\drivers\win7 /Recurse'
        return
    }
    $ver = Get-VersaoWindows
    Write-Registro ('Windows: ' + $(if ($ver.Produto) { $ver.Produto } else { '?' }) + ' (version ' + $(if ($ver.Versao) { $ver.Versao } else { '?' }) + ', build ' + $(if ($ver.Build) { $ver.Build } else { '?' }) + ')')
    if ($ver.Versao -ne '6.1') {
        Write-Registro 'Not Windows 7 (or the version could not be read). For Win 8/10/11 use tool 2.' 'AVISO'
        if (-not (Read-SimNao 'Continue anyway?' 'N')) { return }
    }
    Get-ModoStorage
    switch ($script:ModoStorage) {
        'NVME' { Write-Registro 'NVMe: Win7 has no native driver; it needs KB2990941 (+KB3087873) or the vendor NVMe driver.' 'AVISO' }
        'RAID' { Write-Registro 'RAID mode: Win7 needs the old RST (iaStorV/iaStorA). Prefer AHCI in the BIOS.' 'AVISO' }
        'VMD' { Write-Registro 'VMD mode: Win7 needs the old RST (iaStorV/iaStorA). Prefer AHCI in the BIOS.' 'AVISO' }
        default { Write-Registro 'AHCI: Win7 has msahci, but it may be disabled if it was installed in IDE mode.' }
    }
    Write-Host '  Win7 also has no native USB 3.0: include the chipset xHCI driver in the folder.'
    $drv = Select-PastaDrivers (Get-Caminho $script:RB 'drivers\win7')
    if ($drv) {
        Request-BackupRegistro
        if (Test-Requisitos @('dism.exe')) {
            $fu = @()
            if (Read-SimNao 'Force unsigned drivers (/ForceUnsigned)?' 'N') { $fu = @('/ForceUnsigned') }
            if (Confirm-Sim ('Inject the drivers from ' + $drv + ' into Windows 7 on ' + (Get-RaizImagem) + ' (DISM)?')) {
                $r = Invoke-Destrutivo 'dism.exe' (@(('/Image:' + (Get-RaizImagem)), '/Add-Driver', ('/Driver:' + $drv), '/Recurse') + $fu + @(('/LogPath:' + (Join-Path $script:LogDir 'dism-win7.log'))))
                if (-not $r.Simulado) { if ($r.Codigo -eq 0) { Write-Registro 'Drivers injected.' 'OK' } else { Write-Registro ('DISM finished with code ' + $r.Codigo) 'ERRO' } }
            }
        }
    } else { Write-Registro 'Injection skipped.' }
    if (Read-SimNao 'Enable msahci/pciide/iaStorV/storahci (Start=0) in the registry?' 'S') {
        if (Confirm-Sim 'Write Start=0 to msahci, pciide, iaStorV, storahci (those that exist)?') { Set-StartZero @('msahci', 'pciide', 'iaStorV', 'storahci') }
    }
    $cmds = @(
        'REAL injection from WinPE 10/11 (it handles Win7 images):',
        '  dism /Image:C:\ /Add-Driver /Driver:C:\Drivers\Win7 /Recurse   [/ForceUnsigned]',
        'NVMe hotfix KB2990941/KB3087873 (extract the .msu and add the .cab):',
        '  expand -F:* Windows6.1-KB2990941-x64.msu C:\kb',
        '  dism /Image:C:\ /Add-Package /PackagePath:C:\kb\Windows6.1-KB2990941-x64.cab'
    )
    $arqCmd = Join-Path $script:LogDir 'commands-win7.txt'
    try { Set-Content -LiteralPath $arqCmd -Value $cmds -Encoding Ascii; Write-Registro ('Commands saved in ' + $arqCmd) } catch { $null = $_ }
    foreach ($c in $cmds) { Write-Host $c }
}

# ================================================================== 1. BOOT UEFI
# Porta do Reparar-BootUEFI.ps1 (deteccao GPT por 4 fontes). Em simulacao so detecta:
# nenhum diskpart que grava, nenhum bcdboot, nenhuma letra atribuida.
$script:TempLetter = $null
$script:LetterAssignedByUs = $false

function Stop-Reparo {
    <# Interrompe a ferramenta 1 (o menu continua). Codigo 0 = cancelado sem erro. #>
    param([string]$Mensagem, [int]$Codigo = 1)
    if ($Codigo -eq 0) { Write-Registro $Mensagem 'AVISO' } else { Write-Registro $Mensagem 'ERRO' }
    Remove-TempLetter
    throw 'REPARO_INTERROMPIDO'
}

function Read-Opcao {
    param([string]$Pergunta, [string[]]$Validas, [string]$Padrao)
    for ($t = 0; $t -lt 5; $t++) {
        $r = Read-Linha $Pergunta
        if (-not $r -and $Padrao) { return $Padrao }
        $r = $r.ToUpperInvariant()
        if ($Validas -contains $r) { return $r }
        Write-Host ('Invalid option. Use: ' + ($Validas -join ', ')) -ForegroundColor Yellow
    }
    if ($Padrao) { return $Padrao }
    Stop-Reparo 'No valid answer. Nothing was changed.' 0
}

function Invoke-DiskPart {
    <# Gera um script diskpart, salva no log e executa com diskpart /s (em simulacao nao executa). #>
    param([Parameter(Mandatory = $true)][string[]]$Linhas, [Parameter(Mandatory = $true)][string]$Nome)
    $arquivo = Join-Path $script:LogDir ($Nome + '.txt')
    try { Set-Content -LiteralPath $arquivo -Value $Linhas -Encoding Ascii -ErrorAction Stop } catch { $null = $_ }
    Write-Registro ('diskpart script (' + $arquivo + '):')
    foreach ($l in $Linhas) { Write-Registro ('    ' + $l) }
    if ($script:Sim) {
        Write-Registro '[SIMULATION] diskpart NOT run.' 'SIM'
        return [pscustomobject]@{ Codigo = 0; Saida = '' }
    }
    $saida = & diskpart.exe /s $arquivo 2>&1 | Out-String
    $codigo = $LASTEXITCODE
    if ($null -eq $codigo) { $codigo = 0 }
    Add-Log $saida
    Write-Host $saida
    return [pscustomobject]@{ Codigo = $codigo; Saida = $saida }
}

function Get-UsedLetters {
    $usadas = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) { [void]$usadas.Add($d.Name.Substring(0, 1).ToUpperInvariant()) }
    try { foreach ($v in Get-Volume -ErrorAction Stop) { if ($v.DriveLetter) { [void]$usadas.Add(([string]$v.DriveLetter).ToUpperInvariant()) } } } catch { $null = $_ }
    try { foreach ($p in Get-Partition -ErrorAction Stop) { if ($p.DriveLetter -and [int][char]$p.DriveLetter -ne 0) { [void]$usadas.Add(([string]$p.DriveLetter).ToUpperInvariant()) } } } catch { $null = $_ }
    return $usadas
}

function Get-FreeLetterBoot {
    $usadas = Get-UsedLetters
    foreach ($l in 'S', 'T', 'U', 'V', 'W', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K') {
        if (-not $usadas.Contains($l)) { return $l }
    }
    return $null
}

function Remove-TempLetter {
    if ($script:LetterAssignedByUs -and $script:TempLetter -and -not $script:Sim) {
        Write-Registro ('Removing temporary letter ' + $script:TempLetter + ':')
        & mountvol.exe ($script:TempLetter + ':') /D 2>&1 | Out-Null
    }
    $script:LetterAssignedByUs = $false
}

function Get-LockedBitLockerVolumes {
    <# Letras de volumes BitLocker bloqueados (WMI se houver, senao manage-bde). $null = nao deu para verificar. #>
    $bloqueados = @()
    try {
        $vols = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop
        foreach ($v in $vols) {
            $st = Invoke-CimMethod -InputObject $v -MethodName GetLockStatus -ErrorAction Stop
            if ($st.LockStatus -eq 1) { $bloqueados += [string]$v.DriveLetter }
        }
        return , $bloqueados
    } catch { $null = $_ }
    if (-not (Test-Exe 'manage-bde.exe')) { return $null }
    return , @(Get-BitLockerBloqueados)
}

function Get-EstiloParticao {
    <# GPT/MBR por 4 fontes: Get-Disk, MSFT_Disk, GptType das particoes, asterisco do diskpart.
       So devolve MBR quando alguma fonte confirma MBR e nenhuma indica GPT. #>
    param([int]$Num, $DiskObj)
    $gpt = @(); $mbr = @()
    $traduz = {
        param($v)
        $t = ([string]$v).Trim().ToUpperInvariant()
        if ($t -eq 'GPT' -or $t -eq '2') { return 'GPT' }
        if ($t -eq 'MBR' -or $t -eq '1') { return 'MBR' }
        return ''
    }
    $r = & $traduz (Get-Prop $DiskObj 'PartitionStyle')
    if ($r -eq 'GPT') { $gpt += 'Get-Disk' } elseif ($r -eq 'MBR') { $mbr += 'Get-Disk' }
    try {
        $cim = Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_Disk -Filter ('Number=' + $Num) -ErrorAction Stop | Select-Object -First 1
        $r = & $traduz (Get-Prop $cim 'PartitionStyle')
        if ($r -eq 'GPT') { $gpt += 'MSFT_Disk' } elseif ($r -eq 'MBR') { $mbr += 'MSFT_Disk' }
    } catch { $null = $_ }
    try {
        $tipos = @(Get-Partition -DiskNumber $Num -ErrorAction Stop | Where-Object { (Get-Prop $_ 'GptType') -and ([string](Get-Prop $_ 'GptType')) -match '^\{?[0-9a-fA-F-]{36}\}?$' })
        if ($tipos.Count -gt 0) { $gpt += 'partition GptType' }
    } catch { $null = $_ }
    try {
        if (Test-Exe 'diskpart.exe') {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'dp_listdisk.txt'
            Set-Content -LiteralPath $tmp -Value 'list disk' -Encoding Ascii -ErrorAction Stop
            $saida = & diskpart.exe /s $tmp 2>$null
            foreach ($l in @($saida)) {
                $s = [string]$l
                if ($s -match ('^\s*(Disk|Disco)\s+' + $Num + '\s')) {
                    if ($s.TrimEnd() -match '\*$') { $gpt += 'diskpart list disk' } else { $mbr += 'diskpart list disk' }
                }
            }
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    } catch { $null = $_ }
    if ($gpt.Count -gt 0) { return @{ Estilo = 'GPT'; Fonte = ($gpt -join ', ') } }
    if ($mbr.Count -gt 0) { return @{ Estilo = 'MBR'; Fonte = ($mbr -join ', ') } }
    return @{ Estilo = 'UNKNOWN'; Fonte = 'none' }
}

function Invoke-ReparoBootUefi {
    Write-Registro '1. UEFI boot repair' 'PASSO'
    try {
        Invoke-ReparoBootUefiInterno
    } catch {
        if ([string]$_.Exception.Message -ne 'REPARO_INTERROMPIDO') { throw }
    } finally {
        Remove-TempLetter
    }
}

function Invoke-ReparoBootUefiInterno {
    $script:TempLetter = $null
    $script:LetterAssignedByUs = $false
    if ($script:Sim) { Write-Registro 'SIMULATION MODE: detection only, nothing will be changed.' 'SIM' }
    if (-not $script:EmWinPE) {
        if (-not $script:Sim) { Stop-Reparo 'This option only changes disks when running in WinPE/WinRE (drive X:). Outside it use simulation (T).' }
        Write-Registro 'Outside WinPE: running detection only (simulation).' 'AVISO'
    }
    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        Stop-Reparo 'Storage cmdlets missing (WinPE-StorageWMI not present). Use option B (CMD version).'
    }

    Write-Registro '1.1 Checking firmware' 'PASSO'
    $fw = $null
    try { $fw = (Get-ItemProperty -LiteralPath 'HKLM:\System\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType } catch { $null = $_ }
    if ($fw -eq 2) { Write-Registro 'UEFI firmware (PEFirmwareType = 2).' 'OK' }
    elseif ($fw -eq 1) {
        Stop-Reparo 'The PC booted in BIOS/Legacy mode (PEFirmwareType = 1). This method is UEFI only. Boot the USB drive from its "UEFI:" entry.'
    } elseif ($script:EmWinPE) {
        Stop-Reparo 'Could not confirm the firmware type (PEFirmwareType missing). Aborting for safety.'
    } else {
        Write-Registro 'PEFirmwareType only exists in WinPE; ignored in simulation.' 'AVISO'
    }

    Write-Registro '1.2 Checking BitLocker' 'PASSO'
    $bloq = Get-LockedBitLockerVolumes
    if ($null -eq $bloq) {
        Write-Registro 'Could not check BitLocker (no manage-bde/WMI in this environment).' 'AVISO'
        Write-Registro 'If Windows is not found, the disk may be encrypted.' 'AVISO'
    } elseif (@($bloq).Count -gt 0) {
        Write-Registro ('LOCKED BitLocker volume(s): ' + (@($bloq) -join ', ')) 'AVISO'
        Write-Registro 'Get the recovery key (48 digits) at https://aka.ms/myrecoverykey and run:' 'AVISO'
        foreach ($b in @($bloq)) { Write-Registro ('    manage-bde -unlock ' + $b + ' -RecoveryPassword <48-digit key>') 'AVISO' }
        $r = Read-Opcao 'Continue anyway? (Y/N) [N]' @('Y', 'N') 'N'
        if ($r -ne 'Y') { Stop-Reparo 'Aborted so you can unlock BitLocker.' 0 }
    } else {
        Write-Registro 'No locked BitLocker volume.' 'OK'
    }

    Write-Registro '1.3 Looking for the Windows installation' 'PASSO'
    $candidatos = @()
    foreach ($c in [char[]]'CDEFGHIJKLMNOPQRSTUVWYZ') {
        $l = [string]$c
        if (Test-Path -LiteralPath ($l + ':\Windows\System32\winload.efi')) {
            $info = ''
            try { $v = Get-Volume -DriveLetter $l -ErrorAction Stop; $info = ('{0} | {1:N1} GB | label "{2}"' -f $v.FileSystem, ($v.Size / 1GB), $v.FileSystemLabel) } catch { $null = $_ }
            $candidatos += [pscustomobject]@{ Letra = $l; Info = $info }
            Write-Registro ('Found: ' + $l + ':\Windows  ' + $info)
        }
    }
    if ($candidatos.Count -eq 0) {
        Stop-Reparo 'No Windows found (\Windows\System32\winload.efi). Causes: BitLocker locked, disk without a driver (Intel RST/RAID: use L or option 2), or wrong disk.'
    }
    if ($candidatos.Count -eq 1) { $win = $candidatos[0].Letra }
    else {
        Write-Registro 'More than one Windows found:' 'AVISO'
        for ($i = 0; $i -lt $candidatos.Count; $i++) { Write-Host ('  [{0}] {1}:  {2}' -f ($i + 1), $candidatos[$i].Letra, $candidatos[$i].Info) }
        $nums = @(1..$candidatos.Count | ForEach-Object { [string]$_ })
        $escolha = Read-Opcao 'Number of the Windows to repair' $nums $null
        $win = $candidatos[[int]$escolha - 1].Letra
    }
    Write-Registro ('Selected Windows: ' + $win + ':') 'OK'

    Write-Registro '1.4 Identifying disk and EFI partition' 'PASSO'
    try {
        $partWin = Get-Partition -DriveLetter $win -ErrorAction Stop | Select-Object -First 1
        $disk = Get-Disk -Number $partWin.DiskNumber -ErrorAction Stop
    } catch {
        Stop-Reparo ('Could not identify the disk of volume ' + $win + ': (' + $_.Exception.Message + ')')
    }
    $discoNum = [int]$disk.Number
    $setor = [int]$disk.LogicalSectorSize
    $minEsp = 100
    if ($setor -eq 4096) { $minEsp = 260 }
    Write-Registro ('Disk {0}: {1} | {2:N1} GB | {3} | sector {4} bytes' -f $discoNum, $disk.FriendlyName, ($disk.Size / 1GB), $disk.PartitionStyle, $setor)

    $estilo = Get-EstiloParticao $discoNum $disk
    Write-Registro ('Partition table of disk ' + $discoNum + ': ' + $estilo.Estilo + ' (source: ' + $estilo.Fonte + ')')
    if ($estilo.Estilo -eq 'UNKNOWN') {
        Stop-Reparo ('Could not confirm whether disk ' + $discoNum + ' is GPT or MBR. Check with "diskpart" > "list disk" (asterisk in the Gpt column). Nothing was changed.')
    }
    if ($estilo.Estilo -eq 'MBR') {
        Stop-Reparo ('Disk ' + $discoNum + ' is MBR, not GPT. UEFI boot needs GPT. Option: "mbr2gpt /validate /disk:' + $discoNum + '" and then "mbr2gpt /convert /disk:' + $discoNum + '" (back up first). It was not done automatically.')
    }

    $esps = @(Get-Partition -DiskNumber $discoNum -ErrorAction SilentlyContinue | Where-Object { [string](Get-Prop $_ 'GptType') -eq $script:EspGuid })
    $outrasEsp = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { [string](Get-Prop $_ 'GptType') -eq $script:EspGuid -and $_.DiskNumber -ne $discoNum })
    foreach ($o in $outrasEsp) { Write-Registro ('Note: there is another EFI on disk ' + $o.DiskNumber + ' (partition ' + $o.PartitionNumber + '). It will NOT be touched.') 'AVISO' }

    $esp = $null
    $criarEsp = $false
    if ($esps.Count -eq 1) { $esp = $esps[0] }
    elseif ($esps.Count -gt 1) {
        Write-Registro 'More than one EFI partition on this disk:' 'AVISO'
        foreach ($e in $esps) { Write-Host ('  Partition {0}: {1:N0} MB' -f $e.PartitionNumber, ($e.Size / 1MB)) }
        $nums = @($esps | ForEach-Object { [string]$_.PartitionNumber })
        $escolha = Read-Opcao 'Number of the EFI partition to use' $nums $null
        $esp = $esps | Where-Object { [string]$_.PartitionNumber -eq $escolha } | Select-Object -First 1
    } else {
        Write-Registro ('No EFI partition on disk ' + $discoNum + '.') 'AVISO'
        $criarEsp = $true
    }

    $livreMB = 0
    try {
        $usado = (Get-Partition -DiskNumber $discoNum -ErrorAction Stop | Measure-Object -Property Size -Sum).Sum
        $livreMB = [math]::Floor(($disk.Size - $usado) / 1MB) - 2
    } catch { $null = $_ }

    $letra = Get-FreeLetterBoot
    if (-not $letra) { Stop-Reparo 'No free letter to mount the EFI.' }
    $script:TempLetter = $letra
    $encolher = $false
    $modoExec = ''
    $jaTemLetra = $false
    $espMB = 0; $espOffKB = 0

    if ($criarEsp) {
        $modoExec = 'C'
        $tamNovo = $minEsp
        Write-Registro ('It will be necessary to CREATE an EFI of ' + $tamNovo + ' MB. Estimated unallocated space: ' + $livreMB + ' MB.')
        if ($livreMB -ge ($tamNovo + 1)) {
            Write-Registro 'There is enough free space: the EFI will be created there.' 'OK'
        } else {
            Write-Registro ('No free space. Option: shrink volume ' + $win + ': by ' + ($tamNovo + 50) + ' MB and create the EFI in the freed space.') 'AVISO'
            Write-Registro 'Shrinking NTFS is safe in most cases, but have a backup. Disk with errors: run chkdsk first.' 'AVISO'
            $r = Read-Opcao 'Shrink Windows to create the EFI? (Y/N) [N]' @('Y', 'N') 'N'
            if ($r -ne 'Y') { Stop-Reparo 'Aborted: no space to create the EFI.' 0 }
            $encolher = $true
        }
    } else {
        $espMB = [math]::Floor($esp.Size / 1MB)
        $espOffKB = [math]::Floor($esp.Offset / 1KB)
        $tamNovo = $espMB
        Write-Host ''
        Write-Host '  A = SAFE     : reformats the existing EFI as FAT32 and recreates the boot files.' -ForegroundColor White
        Write-Host '  B = FULL     : deletes the EFI partition (override), creates an identical one, formats it and recreates boot.' -ForegroundColor White
        Write-Host '                 Use B only if A fails or the partition is damaged.' -ForegroundColor White
        $modoExec = Read-Opcao 'Mode (A/B) [A]' @('A', 'B') 'A'
        if ($modoExec -eq 'B' -and $espMB -lt $minEsp) {
            Stop-Reparo ('The current EFI has ' + $espMB + ' MB, less than the minimum ' + $minEsp + ' MB for this disk. Mode B would not fit in the same place. Use mode A.')
        }
    }

    Write-Registro '1.5 SUMMARY - check carefully' 'PASSO'
    Write-Registro ('  Disk .........: {0}  ({1}, {2:N1} GB, {3}, sector {4})' -f $discoNum, $disk.FriendlyName, ($disk.Size / 1GB), $estilo.Estilo, $setor)
    Write-Registro ('  Windows ......: {0}:\Windows' -f $win)
    if ($criarEsp) {
        Write-Registro ('  EFI ..........: DOES NOT EXIST -> create a new one of {0} MB{1}' -f $tamNovo, $(if ($encolher) { ' (shrinking ' + $win + ':)' } else { ' in free space' }))
    } else {
        Write-Registro ('  EFI ..........: partition {0}, {1} MB, offset {2} KB' -f $esp.PartitionNumber, $espMB, $espOffKB)
    }
    $descModo = switch ($modoExec) { 'A' { 'A - reformat existing EFI' } 'B' { 'B - delete and recreate EFI' } default { 'create new EFI' } }
    Write-Registro ('  Mode .........: ' + $descModo)
    Write-Registro ('  Temp letter ..: ' + $letra + ':')
    Write-Registro ('  Boot command .: bcdboot ' + $win + ':\Windows /f UEFI /s ' + $letra + ': /l pt-BR')
    Write-Registro ('  Backup/log ...: ' + $script:LogDir)
    Write-Host 'WARNING: the EFI partition above will be FORMATTED. Other systems (e.g. Linux) on this EFI lose their boot entry.' -ForegroundColor Yellow
    if (-not (Confirm-Sim 'Recreate UEFI boot with the data above?')) { Stop-Reparo 'Cancelled by the user. Nothing was changed.' 0 }

    if (-not $criarEsp) {
        Write-Registro '1.6 Backup of the BCD and EFI files' 'PASSO'
        $jaTemLetra = ((Get-Prop $esp 'DriveLetter') -and [int][char]$esp.DriveLetter -ne 0)
        if ($jaTemLetra) {
            $letra = [string]$esp.DriveLetter
            $script:TempLetter = $letra
            Write-Registro ('The EFI already has letter ' + $letra + ':, it will be used.')
        } else {
            $r = Invoke-DiskPart -Nome 'dp-01-montar-efi' -Linhas @("select disk $discoNum", "select partition $($esp.PartitionNumber)", "assign letter=$letra")
            if ($r.Codigo -ne 0) { Write-Registro 'Could not mount the EFI for backup (continuing without a file backup).' 'AVISO' }
            elseif (-not $script:Sim) { $script:LetterAssignedByUs = $true }
        }
        if (-not $script:Sim) {
            $bcdOut = & bcdedit.exe /export (Join-Path $script:LogDir 'BCD-export') 2>&1 | Out-String
            Write-Registro ('bcdedit /export: ' + $bcdOut.Trim())
            if (Test-Path -LiteralPath ($letra + ':\')) {
                $dest = Join-Path $script:LogDir 'EFI-backup'
                $xc = & xcopy.exe ($letra + ':\*') ($dest + '\') /E /H /C /I /Y /Q 2>&1 | Out-String
                Write-Registro ('EFI copy to ' + $dest + ': ' + $xc.Trim())
            } else { Write-Registro 'EFI unreadable (probably corrupt); no file copy.' 'AVISO' }
        } else { Write-Registro '[SIMULATION] bcdedit /export and EFI copy not run.' 'SIM' }
    }

    Write-Registro '1.7 Preparing the EFI partition' 'PASSO'
    if ($modoExec -eq 'A') {
        $r = Invoke-DiskPart -Nome 'dp-02-formatar-efi' -Linhas @("select disk $discoNum", "select partition $($esp.PartitionNumber)", 'format quick fs=fat32 label=System override')
        if ($r.Codigo -ne 0) {
            Write-Registro 'diskpart format failed; trying format.com...' 'AVISO'
            $null = & cmd.exe /c ('format ' + $letra + ': /FS:FAT32 /Q /V:System /Y') 2>&1
            if ($LASTEXITCODE -ne 0) { Stop-Reparo 'Failed to format the EFI. Try mode B.' }
        }
        if (-not $script:LetterAssignedByUs -and -not $jaTemLetra -and -not $script:Sim) {
            $r = Invoke-DiskPart -Nome 'dp-03-montar-efi' -Linhas @("select disk $discoNum", "select partition $($esp.PartitionNumber)", "assign letter=$letra")
            if ($r.Codigo -ne 0) { Stop-Reparo 'Could not assign a letter to the EFI.' }
            $script:LetterAssignedByUs = $true
        }
    } elseif ($modoExec -eq 'B') {
        if ($script:LetterAssignedByUs) { Remove-TempLetter }
        $linhas = @("select disk $discoNum", "select partition $($esp.PartitionNumber)", 'delete partition override',
            "create partition efi size=$tamNovo offset=$espOffKB", 'format quick fs=fat32 label=System', "assign letter=$letra")
        $r = Invoke-DiskPart -Nome 'dp-02-recriar-efi' -Linhas $linhas
        if ($r.Codigo -ne 0) {
            Write-Registro 'Failed. Trying to create it 1 MB smaller (rounding)...' 'AVISO'
            $r = Invoke-DiskPart -Nome 'dp-03-criar-efi-retry' -Linhas @("select disk $discoNum", "create partition efi size=$($tamNovo - 1) offset=$espOffKB", 'format quick fs=fat32 label=System', "assign letter=$letra")
            if ($r.Codigo -ne 0) {
                Stop-Reparo ('The EFI was DELETED and was not recreated. Do it manually in diskpart: select disk ' + $discoNum + ' / create partition efi size=' + $minEsp + ' / format quick fs=fat32 label=System / assign letter=' + $letra + ' and then run bcdboot.')
            }
        }
        if (-not $script:Sim) { $script:LetterAssignedByUs = $true }
    } else {
        $linhas = @()
        if ($encolher) { $linhas += "select volume $win"; $linhas += ('shrink desired={0} minimum={0}' -f ($tamNovo + 50)) }
        $linhas += "select disk $discoNum"
        $linhas += "create partition efi size=$tamNovo"
        $linhas += 'format quick fs=fat32 label=System'
        $linhas += "assign letter=$letra"
        $r = Invoke-DiskPart -Nome 'dp-02-criar-efi' -Linhas $linhas
        if ($r.Codigo -ne 0) { Stop-Reparo 'Failed to create the EFI partition. See the log.' }
        if (-not $script:Sim) { $script:LetterAssignedByUs = $true }
    }
    if (-not $script:Sim -and -not (Test-Path -LiteralPath ($letra + ':\'))) { Stop-Reparo ('The EFI is not accessible at ' + $letra + ':') }

    Write-Registro '1.8 Generating the boot files (bcdboot)' 'PASSO'
    $argsBcd = @(($win + ':\Windows'), '/f', 'UEFI', '/s', ($letra + ':'), '/l', 'pt-BR')
    if ($script:Sim) {
        Write-Registro ('[SIMULATION] bcdboot ' + ($argsBcd -join ' ')) 'SIM'
    } else {
        Write-Registro ('> bcdboot ' + ($argsBcd -join ' '))
        $o = & bcdboot.exe @argsBcd 2>&1 | Out-String
        Write-Registro $o.Trim()
        if ($LASTEXITCODE -ne 0) {
            Write-Registro 'Failed with /l pt-BR; trying without the locale...' 'AVISO'
            $o = & bcdboot.exe ($win + ':\Windows') /f UEFI /s ($letra + ':') 2>&1 | Out-String
            Write-Registro $o.Trim()
            if ($LASTEXITCODE -ne 0) { Stop-Reparo 'bcdboot failed. See the log.' }
        }
        $ok1 = Test-Path -LiteralPath ($letra + ':\EFI\Microsoft\Boot\bootmgfw.efi')
        $ok2 = Test-Path -LiteralPath ($letra + ':\EFI\Microsoft\Boot\BCD')
        Write-Registro ('Check: bootmgfw.efi=' + $ok1 + '  BCD=' + $ok2) $(if ($ok1 -and $ok2) { 'OK' } else { 'ERRO' })
        if (-not ($ok1 -and $ok2)) { Stop-Reparo 'Boot files not found after bcdboot.' }
        if (Test-Exe 'bootrec.exe') {
            if ((Read-Opcao 'Also run bootrec /rebuildbcd (optional, redundant)? (Y/N) [N]' @('Y', 'N') 'N') -eq 'Y') {
                $o = & cmd.exe /c 'echo n| bootrec /rebuildbcd' 2>&1 | Out-String
                Write-Registro ('bootrec: ' + $o.Trim())
            }
        } else { Write-Registro 'bootrec does not exist in this environment (normal in plain WinPE): bcdboot is enough.' }
    }
    Remove-TempLetter
    if ($script:Sim) { Write-Registro 'SIMULATION finished. Nothing was changed.' 'OK' }
    else { Write-Registro 'UEFI boot recreated. Remove the USB drive and reboot (menu option R).' 'OK' }
    Write-Registro ('Log and backup in: ' + $script:LogDir)
}

# ================================================================== MENU
function Invoke-Ferramenta {
    param([int]$Numero)
    try {
        switch ($Numero) {
            1 { Invoke-ReparoBootUefi }
            2 { Invoke-InjetarRst }
            3 { Invoke-ReconstruirBcd }
            4 { Invoke-SfcDism }
            5 { Invoke-ExtrairPerfil }
            6 { Invoke-ExportarImpressoras }
            7 { Invoke-VarrerRaiz }
            8 { Invoke-EventLog }
            9 { Invoke-BackupRegistro }
            10 { Invoke-Integridade }
            11 { Invoke-Smart }
            12 { Invoke-DriversWin7 }
            default { Write-Host 'Invalid option.' }
        }
    } catch {
        $linha = ''
        try { $linha = ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')' } catch { $null = $_ }
        Write-Registro ('Unexpected error in tool ' + $Numero + ': ' + $_.Exception.Message + $linha) 'ERRO'
    } finally {
        foreach ($h in @($script:Hives.ToArray())) { Dismount-Hive $h }
        Dismount-Esp
    }
}

function Find-ReparoCmd {
    foreach ($c in @((Get-Caminho $script:RB 'scripts\repair-boot-uefi-en.cmd'), (Get-Caminho $script:Aqui 'repair-boot-uefi-en.cmd'), (Get-Caminho $script:RB 'scripts\reparar-boot-uefi.cmd'), (Get-Caminho $script:Aqui 'reparar-boot-uefi.cmd'))) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Invoke-ReparoCmd {
    Write-Registro 'B. UEFI boot repair using the CMD version' 'PASSO'
    $c = Find-ReparoCmd
    if (-not $c) { Write-Registro ('repair-boot-uefi-en.cmd / reparar-boot-uefi.cmd not found in ' + (Get-Caminho $script:RB 'scripts')) 'ERRO'; return }
    if ((Split-Path -Leaf $c) -eq 'reparar-boot-uefi.cmd') { Write-Registro 'English CMD script (repair-boot-uefi-en.cmd) not found: using the Portuguese version.' 'AVISO' }
    $a = @('/c', $c); if ($script:Sim) { $a += '/simular' }
    Add-Log ('EXEC: cmd.exe ' + ($a -join ' '))
    & cmd.exe @a
}

function Invoke-Drvload {
    Write-Registro 'L. Load a disk driver now (drvload .inf)' 'PASSO'
    $pasta = Get-Caminho $script:RB 'drivers'
    if (Test-Path -LiteralPath $pasta) {
        $infs = @(Get-ChildItem -LiteralPath $pasta -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
        if ($infs.Count -gt 0) { Write-Host ('Drivers found in ' + $pasta + ':'); foreach ($i in $infs) { Write-Host ('  ' + $i.FullName) } }
    }
    $inf = (Read-Linha 'Full path of the .inf (ENTER cancels)').Trim('"')
    if (-not $inf) { return }
    if (-not (Test-Path -LiteralPath $inf)) { Write-Registro ('File not found: ' + $inf) 'ERRO'; return }
    $r = Invoke-Destrutivo 'drvload.exe' @($inf)
    if (-not $r.Simulado) { if ($r.Codigo -eq 0) { Write-Registro 'Driver loaded. New disks should appear now.' 'OK' } else { Write-Registro ('drvload finished with code ' + $r.Codigo) 'ERRO' } }
}

function Invoke-Avancado {
    Write-Registro 'A. Advanced mode (interactive shell)' 'PASSO'
    $env:REPARO_RB = $script:RB
    $env:REPARO_SIMULAR = $(if ($script:Sim) { '1' } else { '0' })
    Write-Host '--------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ' ADVANCED MODE - careful: here NOTHING asks for YES or respects simulation' -ForegroundColor Yellow
    Write-Host (' Kit folder: ' + $script:RB + '   variables: REPARO_RB, REPARO_SIMULAR')
    Write-Host ' Type exit to return to the menu.'
    Write-Host '--------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host '   1 - Command prompt (default)'
    Write-Host '   2 - PowerShell'
    $av = Read-Linha 'Choose [1]'
    if ($av -eq '2') {
        $ps = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }
        & $ps -NoProfile -ExecutionPolicy Bypass -NoExit
    } else {
        & cmd.exe /k
    }
}

function Invoke-Wpeutil {
    param([string]$Acao)
    $txt = $(if ($Acao -eq 'reboot') { 'REBOOT' } else { 'SHUT DOWN' })
    if (-not (Read-SimNao ($txt + ' the computer now?') 'N')) { return }
    if (Test-Exe 'wpeutil.exe') { & wpeutil.exe $Acao; return }
    if ($script:EhWindows -and -not $script:EmWinPE) {
        Write-Registro 'wpeutil only exists in WinPE. On this Windows use: shutdown /r /t 0 (reboot) or shutdown /s /t 0 (shut down).' 'AVISO'
        return
    }
    Write-Registro 'wpeutil not found.' 'ERRO'
}

function Show-Cabecalho {
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor Cyan
    Write-Host '              WINDOWS REPAIR - WinPE MENU (PowerShell)' -ForegroundColor Cyan
    Write-Host ('  environment: ' + (Get-DescAmbiente)) -ForegroundColor Cyan
    Write-Host ('  simulation: ' + $(if ($script:Sim) { 'ON - nothing will be changed' } else { 'off' })) -ForegroundColor $(if ($script:Sim) { 'Magenta' } else { 'Cyan' })
    Write-Host ('  log: ' + $script:LogDir) -ForegroundColor Cyan
    Write-Host '==============================================================' -ForegroundColor Cyan
}

function Show-Menu {
    for ($voltas = 0; $voltas -lt 1000; $voltas++) {
        Show-Cabecalho
        Write-Host '   1  UEFI boot repair'
        Write-Host '   2  Intel RST driver injection (automatic detection)'
        Write-Host '   3  BCD rebuild (automated bootrec)'
        Write-Host '   4  SFC and DISM in sequence with log'
        Write-Host '   5  Profile extraction (AppData and favorites)'
        Write-Host '   6  Printer export'
        Write-Host '   7  C: root scan (non-standard folders)'
        Write-Host '   8  Event Log (optional)'
        Write-Host '   9  Registry hive backup'
        Write-Host '  10  File integrity checker (offline)'
        Write-Host '  11  S.M.A.R.T. checker (optional)'
        Write-Host '  12  Storage drivers for Windows 7'
        Write-Host '   B  UEFI boot repair using the CMD version'
        Write-Host '   L  Load a disk driver now (drvload .inf)'
        Write-Host '   A  Advanced mode (command prompt or PowerShell)'
        Write-Host '   T  Toggle simulation on/off'
        Write-Host '   R  Reboot'
        Write-Host '   D  Shut down'
        Write-Host '   0  Exit to the prompt (Q also exits)'
        Write-Host '==============================================================' -ForegroundColor Cyan
        $op = ((Read-Linha 'Option') -replace '[\s"]', '').ToUpperInvariant()
        if (-not $op) {
            if ([Console]::IsInputRedirected) { return }
            continue
        }
        if ($op -eq '0' -or $op -eq 'Q' -or $op -eq 'S') { Write-Host 'Leaving the menu. To come back, type: winpe_reparo_en'; return }
        $n = 0
        if ([int]::TryParse($op, [ref]$n) -and $n -ge 1 -and $n -le 12) { Invoke-Ferramenta $n; Wait-Enter; continue }
        switch ($op) {
            'T' { $script:Sim = -not $script:Sim; Write-Registro ('Simulation now: ' + $(if ($script:Sim) { 'ON' } else { 'off' })) }
            'B' { try { Invoke-ReparoCmd } catch { Write-Registro $_.Exception.Message 'ERRO' }; Wait-Enter }
            'L' { try { Invoke-Drvload } catch { Write-Registro $_.Exception.Message 'ERRO' }; Wait-Enter }
            'A' { try { Invoke-Avancado } catch { Write-Registro $_.Exception.Message 'ERRO' } }
            'R' { Invoke-Wpeutil 'reboot' }
            'D' { Invoke-Wpeutil 'shutdown' }
            default { Write-Host 'Invalid option: type 0 to 12, B, L, A, T, R or D.' }
        }
    }
}

# ================================================================== INICIO
Initialize-Ambiente
try {
    Initialize-Log
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
Write-Registro ('Start. environment=' + (Get-DescAmbiente) + ' Simulate=' + $script:Sim + ' Tool=' + $Ferramenta + ' RB=' + $script:RB)
if ($script:EhWindows -and -not $script:EmWinPE -and -not (Test-Admin)) {
    Write-Registro 'No ADMINISTRATOR privilege: dism/sfc/reg load/bcdedit will fail. Open PowerShell as administrator.' 'AVISO'
}
try {
    if ($Ferramenta -gt 0) {
        Show-Cabecalho
        Invoke-Ferramenta $Ferramenta
        Write-Registro ('Log: ' + $script:LogDir)
        if (-not [Console]::IsInputRedirected) { $null = Read-Linha 'Press ENTER to exit' }
    } else {
        Show-Menu
    }
} finally {
    foreach ($h in @($script:Hives.ToArray())) { Dismount-Hive $h }
    Dismount-Esp
    Write-Registro ('End. Logs in ' + $script:LogDir)
    if ($script:Transcricao) { try { Stop-Transcript | Out-Null } catch { $null = $_ } }
}
exit 0
