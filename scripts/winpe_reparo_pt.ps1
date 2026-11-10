<#
.SYNOPSIS
    winpe_reparo_pt.ps1 - kit de reparo do Windows para o WinPE (substitui o bash_reparo.sh).

.DESCRIPTION
    Um unico arquivo PowerShell 5.1 com o menu e as 12 ferramentas + modo avancado:
      1  Reparo de boot UEFI (deteccao GPT por 4 fontes)
      2  Injecao de drivers Intel RST (deteccao automatica)
      3  Reconstrucao do BCD (bootrec se existir, senao bcdboot/bcdedit) / restaurar backup
      4  SFC e DISM em sequencia com log
      5  Extracao de perfil (AppData e favoritos; destino dentro do perfil e recusado)
      6  Exportacao de impressoras
      7  Varredura da raiz do C (esconde desktop.ini, thumbs.db, *.marker, .GamingRoot, vazios)
      8  Event Log (opcional)
      9  Backup dos hives do registro (SAM/SECURITY so se confirmar; padrao N)
     10  Verificador de integridade de arquivos (offline)
     11  Verificador S.M.A.R.T. (opcional; temperatura implausivel ignorada, discos sem repeticao)
     12  Drivers de storage para Windows 7
      B  Reparo de boot pela versao CMD   L  drvload   A  modo avancado (cmd/PowerShell)
      T  simulacao   R  reiniciar   D  desligar   0/S  sair
    Nao usa findstr, where, bash nem bootrec obrigatorio (nao existem no WinPE).
    Nada destrutivo sem digitar SIM. Em simulacao nenhum comando que grava roda.
    Textos sem acento de proposito (console do WinPE).

.PARAMETER Ferramenta
    Numero da ferramenta (1 a 12). Alias: -Tool. Roda so ela e sai. Sem ele abre o menu.

.PARAMETER Simular
    Alias: -Simulate. Liga a simulacao: comandos que gravam aparecem como [SIMULACAO] e nao rodam.

.EXAMPLE
    winpe_reparo_pt
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File winpe_reparo_pt.ps1 -Ferramenta 11 -Simular
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
$script:ModoStorage = 'DESCONHECIDO'
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
    elseif ($Nivel -eq 'AVISO') { Write-Host ('AVISO: ' + $Mensagem) -ForegroundColor $cor }
    elseif ($Nivel -eq 'ERRO') { Write-Host ('ERRO: ' + $Mensagem) -ForegroundColor $cor }
    else { Write-Host $Mensagem -ForegroundColor $cor }
    Add-Log ('[' + $Nivel + '] ' + $Mensagem)
}

function Read-Linha {
    <# Read-Host seguro: fim da entrada (EOF) ou erro vira texto vazio. #>
    param([string]$Pergunta)
    $r = $null
    try { $r = Read-Host $Pergunta } catch { $r = $null }
    if ($null -eq $r) { Write-Host ''; Add-Log ('Entrada [' + $Pergunta + ']: (fim da entrada)'); return '' }
    $r = ([string]$r).Trim()
    Add-Log ('Entrada [' + $Pergunta + ']: [' + $r + ']')
    return $r
}

function Read-SimNao {
    param([string]$Pergunta, [ValidateSet('S', 'N')][string]$Padrao = 'N')
    for ($t = 0; $t -lt 5; $t++) {
        $r = (Read-Linha ('{0} (S/N) [{1}]' -f $Pergunta, $Padrao)).ToUpperInvariant()
        if (-not $r) { $r = $Padrao }
        if ($r -eq 'S' -or $r -eq 'SIM') { return $true }
        if ($r -eq 'N' -or $r -eq 'NAO') { return $false }
        Write-Host 'Responda S ou N.'
    }
    return $false
}

function Confirm-Sim {
    param([string]$Pergunta)
    Write-Host ''
    Write-Host $Pergunta -ForegroundColor Yellow
    if ($script:Sim) { Write-Host '(SIMULACAO ligada: mesmo com SIM nada que grava sera executado)' -ForegroundColor Magenta }
    $r = Read-Linha 'Digite SIM (maiusculo) para continuar, qualquer outra coisa cancela'
    $ok = ($r -ceq 'SIM')
    Add-Log ('Confirmacao [' + $Pergunta + ']: ' + $ok)
    if (-not $ok) { Write-Registro 'Cancelado. Nada foi feito nesta etapa.' }
    return $ok
}

function Wait-Enter { $null = Read-Linha 'Pressione ENTER para continuar' }

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
        Write-Registro ('Nao existe(m) neste ambiente: ' + ($falta -join ', ') + ' (a simulacao continua so para mostrar o plano).') 'AVISO'
        return $true
    }
    Write-Registro ('Comando(s) do Windows ausente(s) neste ambiente: ' + ($falta -join ', ')) 'ERRO'
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
        if (-not $Silencioso) { Write-Registro ($Exe + ' nao existe neste ambiente.') 'ERRO' }
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
    Add-Log ('CODIGO: ' + $codigo)
    return (New-Resultado ([int]$codigo) $saida.ToArray() $false)
}

function Invoke-Destrutivo {
    <# Comando que grava/altera algo: em simulacao so imprime [SIMULACAO]. #>
    param([string]$Exe, [string[]]$Argumentos = @(), [switch]$Interativo, [switch]$SemSaidaNoLog)
    $linha = Format-Comando $Exe $Argumentos
    if ($script:Sim) {
        Write-Registro ('[SIMULACAO] ' + $linha) 'SIM'
        return (New-Resultado 0 @() $true)
    }
    Write-Registro ('> ' + $linha)
    if ($Interativo) {
        if (-not (Test-Exe $Exe)) { Write-Registro ($Exe + ' nao existe neste ambiente.') 'ERRO'; return (New-Resultado 9009 @() $false) }
        $c = 0
        try { & $Exe @Argumentos; $c = $LASTEXITCODE } catch { Write-Registro $_.Exception.Message 'ERRO'; $c = 1 }
        if ($null -eq $c) { $c = 0 }
        Add-Log ('CODIGO: ' + $c)
        return (New-Resultado ([int]$c) @() $false)
    }
    return (Invoke-Nativo -Exe $Exe -Argumentos $Argumentos -Mostrar -SemSaidaNoLog:$SemSaidaNoLog)
}

function Invoke-Escrita {
    <# Acao PowerShell que grava (copia, cria pasta, arquivo): em simulacao so imprime. #>
    param([string]$Descricao, [scriptblock]$Acao)
    if ($script:Sim) { Write-Registro ('[SIMULACAO] ' + $Descricao) 'SIM'; return $true }
    Add-Log ('ESCRITA: ' + $Descricao)
    try { $null = & $Acao; return $true }
    catch { Write-Registro ('Falhou: ' + $Descricao + ' (' + $_.Exception.Message + ')') 'ERRO'; return $false }
}

function New-Pasta {
    param([string]$Caminho)
    if (Test-Path -LiteralPath $Caminho) { return $true }
    $pastaNova = $Caminho
    return (Invoke-Escrita ('criar pasta ' + $pastaNova) { New-Item -ItemType Directory -Path $pastaNova -Force -ErrorAction Stop | Out-Null })
}

function Copy-Arquivo {
    <# Copia um arquivo para dentro de uma pasta (robocopy /B se o Copy-Item falhar). #>
    param([string]$Origem, [string]$Pasta, [string]$NomeDestino = '')
    if (-not $NomeDestino) { $NomeDestino = Split-Path -Leaf $Origem }
    $alvoArq = Get-Caminho $Pasta $NomeDestino
    $origArq = $Origem
    if ($script:Sim) { Write-Registro ('[SIMULACAO] copiar ' + $origArq + ' -> ' + $alvoArq) 'SIM'; return $true }
    try {
        if (-not (Test-Path -LiteralPath $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force -ErrorAction Stop | Out-Null }
        Copy-Item -LiteralPath $origArq -Destination $alvoArq -Force -ErrorAction Stop
        Add-Log ('COPIA: ' + $origArq + ' -> ' + $alvoArq)
        return $true
    } catch {
        Add-Log ('Copy-Item falhou: ' + $_.Exception.Message)
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
    if (-not $script:Sim -and -not (Test-Exe 'robocopy.exe')) { Write-Registro 'robocopy.exe nao existe neste ambiente.' 'ERRO'; return $false }
    $r = Invoke-Destrutivo 'robocopy.exe' $a -SemSaidaNoLog
    if ($r.Simulado) { return $true }
    if ($r.Codigo -lt 8) { Write-Registro ('robocopy terminou com codigo ' + $r.Codigo + ' (0 a 7 = sucesso).') 'OK'; return $true }
    Write-Registro ('robocopy terminou com codigo ' + $r.Codigo + ' (8 ou mais = falha). Veja ' + $log) 'ERRO'
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
    if (-not $script:EhWindows) { return 'NAO-WINDOWS (so teste/simulacao)' }
    if ($script:EmWinPE) { return ('WinPE (sistema em ' + $script:SysDrive + ', Windows offline)') }
    return ('Windows online (sistema em ' + $script:SysDrive + ')')
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
    $sufixo = $script:Stamp + '-winpe-reparo'
    if ($Ferramenta -gt 0) { $sufixo = $script:Stamp + '-ferramenta' + $Ferramenta }
    foreach ($c in $candidatas) {
        try {
            $dir = Join-Path (Join-Path $c 'logs') $sufixo
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            $teste = Join-Path $dir 'teste.tmp'
            Set-Content -LiteralPath $teste -Value 'ok' -Encoding Ascii -ErrorAction Stop
            Remove-Item -LiteralPath $teste -Force -ErrorAction Stop
            $script:LogDir = $dir
            $script:LogFile = Join-Path $dir 'winpe-reparo.log'
            try {
                Start-Transcript -Path (Join-Path $dir 'transcricao.txt') -Append -ErrorAction Stop | Out-Null
                $script:Transcricao = $true
            } catch { $null = $_ }
            if ($dir -like 'X:*') { Write-Registro 'Log gravado em X: (RAM). Ele SOME ao reiniciar. Copie antes se precisar.' 'AVISO' }
            return
        } catch { $null = $_ }
    }
    throw 'Nao foi possivel criar a pasta de log.'
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
    if ($Itens.Count -eq 1) { Write-Registro ($Titulo.TrimEnd(':') + ': ' + $Itens[0] + ' (unico, escolhido)'); return 0 }
    Write-Host $Titulo
    for ($i = 0; $i -lt $Itens.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i + 1), $Itens[$i]) }
    for ($t = 0; $t -lt 5; $t++) {
        $r = Read-Linha 'Numero (ENTER ou C cancela)'
        if (-not $r -or $r.ToUpperInvariant() -eq 'C') { return -1 }
        $n = 0
        if ([int]::TryParse($r, [ref]$n) -and $n -ge 1 -and $n -le $Itens.Count) { return ($n - 1) }
        Write-Host 'Opcao invalida.'
    }
    return -1
}

function Select-Windows {
    <# Define WinRaiz (D:\), WinDir (D:\Windows), WinLetra e WinOnline. #>
    if ($script:WinRaiz) {
        Write-Registro ('Windows: ' + $script:WinDir + $(if ($script:WinOnline) { ' (ONLINE)' } else { ' (offline)' }))
        return $true
    }
    Write-Registro 'Procurando o Windows (C: a Z:, sem X:)' 'PASSO'
    $cands = @(); $descs = @()
    if ($env:REPARO_RAIZ_WIN) {
        $cands += $env:REPARO_RAIZ_WIN
        $descs += ($env:REPARO_RAIZ_WIN + '  (definido em REPARO_RAIZ_WIN)')
    } else {
        foreach ($c in [char[]]'CDEFGHIJKLMNOPQRSTUVWYZ') {
            $raiz = ([string]$c) + ':\'
            $sys = Get-Caminho $raiz 'Windows\System32\config\SYSTEM'
            if (-not (Test-Path -LiteralPath $sys)) { continue }
            $info = ''
            try { $v = Get-Volume -DriveLetter ([string]$c) -ErrorAction Stop; $info = ('{0}, {1:N1} GB, rotulo "{2}"' -f $v.FileSystem, ($v.Size / 1GB), $v.FileSystemLabel) } catch { $null = $_ }
            try { $info += (', SYSTEM alterado em ' + (Get-Item -LiteralPath $sys -Force).LastWriteTime.ToString('yyyy-MM-dd HH:mm')) } catch { $null = $_ }
            $estado = '(offline)'
            if (-not $script:EmWinPE -and (([string]$c) + ':') -eq $script:SysDrive) { $estado = '(ESTE Windows, online)' }
            $cands += $raiz
            $descs += ('{0}Windows  {1}  {2}' -f $raiz, $estado, $info)
        }
    }
    if ($cands.Count -eq 0) {
        Write-Registro 'Nenhum Windows encontrado (\Windows\System32\config\SYSTEM).' 'ERRO'
        $bl = @(Get-BitLockerBloqueados)
        if ($bl.Count -gt 0) {
            Write-Registro ('Volume(s) BitLocker BLOQUEADO(s): ' + ($bl -join ', ')) 'AVISO'
            Write-Host '  Desbloqueie com a chave de recuperacao (48 digitos, https://aka.ms/myrecoverykey):'
            Write-Host '    manage-bde -unlock C: -RecoveryPassword <chave>'
        }
        Write-Host '  Causas comuns: BitLocker bloqueado, disco sem driver no WinPE (Intel RST/VMD:'
        Write-Host '  ferramenta 2 ou drvload <driver>.inf) ou volume sem letra (diskpart > assign).'
        return $false
    }
    $i = Select-Item 'Windows encontrados:' $descs
    if ($i -lt 0) { Write-Registro 'Nenhum Windows escolhido.'; return $false }
    $raizEsc = $cands[$i]
    $script:WinRaiz = $raizEsc
    $script:WinDir = Get-Caminho $raizEsc 'Windows'
    $script:WinLetra = $null
    if ($raizEsc -match '^([A-Za-z]):') { $script:WinLetra = $Matches[1].ToUpperInvariant() }
    $script:WinOnline = ((-not $script:EmWinPE) -and $script:WinLetra -and (($script:WinLetra + ':') -eq $script:SysDrive))
    if ($script:WinOnline) { Write-Registro 'Este e o Windows EM EXECUCAO: modo ONLINE (dism /Online, reg save, wevtutil epl).' 'AVISO' }
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
    if ($livre -lt 0) { Write-Registro 'Nao consegui medir o espaco livre; confira voce.' 'AVISO'; return $true }
    Write-Registro ('Necessario ~' + (Format-Tamanho $Bytes) + ' | livre ' + (Format-Tamanho $livre))
    if ($livre -gt $Bytes) { return $true }
    Write-Registro 'Espaco livre insuficiente no destino.' 'AVISO'
    return (Read-SimNao 'Tentar mesmo assim?' 'N')
}

function Select-Destino {
    <# Escolhe um disco (sem a letra do Windows e sem X: no WinPE) ou caminho digitado.
       -Bloquear: pastas de origem; destino dentro delas e recusado e pergunta de novo. #>
    param([string]$Titulo = 'Destino da copia:', [string]$PastaLog = '', [string[]]$Bloquear = @())
    for ($volta = 0; $volta -lt 5; $volta++) {
        $alvos = @(); $descs = @()
        if ($PastaLog) { $alvos += $PastaLog; $descs += ('Pasta de log desta execucao (' + $PastaLog + ')') }
        if ($script:EhWindows) {
            foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
                try {
                    if (-not $d.IsReady) { continue }
                    $l = $d.Name.Substring(0, 1).ToUpperInvariant()
                    if ($script:WinLetra -and $l -eq $script:WinLetra) { continue }
                    if ($l -eq 'X' -and $script:EmWinPE) { continue }
                    if ([string]$d.DriveType -eq 'CDRom') { continue }
                    $extra = ''
                    if (Test-Path -LiteralPath (Join-Path $d.RootDirectory.FullName 'ReparoBoot')) { $extra = '  (PENDRIVE DO REPARO)' }
                    $alvos += $d.RootDirectory.FullName
                    $descs += ('{0}  [{1}] rotulo "{2}"  livre {3} de {4}{5}' -f $d.Name, $d.DriveType, $d.VolumeLabel, (Format-Tamanho $d.AvailableFreeSpace), (Format-Tamanho $d.TotalSize), $extra)
                } catch { $null = $_ }
            }
        }
        $alvos += '*DIGITAR*'; $descs += 'Digitar um caminho (ex.: E:\Backup)'
        $i = Select-Item $Titulo $descs
        if ($i -lt 0) { return $null }
        $dest = $alvos[$i]
        if ($dest -eq '*DIGITAR*') {
            $dest = Read-Linha 'Caminho (ENTER cancela)'
            $dest = $dest.Trim('"')
            if (-not $dest) { return $null }
            if ($dest -match '^[A-Za-z]:$') { $dest += '\' }
            if ($script:EhWindows -and $dest -notmatch '^([A-Za-z]:\\|\\\\)') { Write-Registro 'Use um caminho completo, ex.: E:\Backup' 'AVISO'; continue }
            if (-not $script:EhWindows -and -not [System.IO.Path]::IsPathRooted($dest)) { Write-Registro 'Use um caminho completo.' 'AVISO'; continue }
            if ($dest.Length -gt 3) { $dest = $dest.TrimEnd('\') }
        }
        $dentro = Test-Dentro $dest $Bloquear
        if ($dentro) {
            Write-Registro ('O destino fica DENTRO de ' + $dentro + ' (a copia copiaria a si mesma). Escolha outro disco ou pasta.') 'AVISO'
            continue
        }
        $raizDest = $null
        try { $raizDest = [System.IO.Path]::GetPathRoot($dest) } catch { $null = $_ }
        if (-not $raizDest -or -not (Test-Path -LiteralPath $raizDest)) { Write-Registro ('A unidade de ' + $dest + ' nao existe.') 'ERRO'; continue }
        if ($script:EmWinPE -and $dest -like 'X:*') { Write-Registro 'X: e a RAM do WinPE: tudo some ao reiniciar.' 'AVISO' }
        if ($script:WinLetra -and $dest -like ($script:WinLetra + ':*')) { Write-Registro 'O destino esta no MESMO disco do Windows.' 'AVISO' }
        if (-not (New-Pasta $dest)) { Write-Registro ('Nao consegui criar/usar ' + $dest) 'ERRO'; continue }
        Write-Registro ('Destino: ' + $dest) 'OK'
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
        Write-Registro ('Sem drivers .inf em ' + $Padrao) 'AVISO'
        $pasta = (Read-Linha 'Outra pasta com .inf (ex.: E:\drivers ; ENTER pula)').Trim('"')
        if (-not $pasta) { return $null }
        if (-not (Test-Path -LiteralPath $pasta)) { Write-Registro 'Pasta nao existe.' 'ERRO'; return $null }
        $infs = @(Get-ChildItem -LiteralPath $pasta -Recurse -Filter '*.inf' -File -Force -ErrorAction SilentlyContinue)
        if ($infs.Count -eq 0) { Write-Registro 'Nenhum .inf nessa pasta.' 'ERRO'; return $null }
    }
    if ($pasta.Length -gt 3) { $pasta = $pasta.TrimEnd('\') }
    Write-Registro ('Drivers: ' + $pasta + ' (' + $infs.Count + ' .inf)')
    foreach ($f in ($infs | Select-Object -First 15)) { Write-Host ('  ' + $f.FullName) }
    return $pasta
}

# ================================================================== registro
function Mount-Hive {
    param([string]$Nome, [string]$Arquivo)
    if (-not (Test-Exe 'reg.exe')) { Write-Registro 'reg.exe nao existe neste ambiente.' 'ERRO'; return $false }
    if (-not (Test-Path -LiteralPath $Arquivo)) { Write-Registro ('Hive nao encontrado: ' + $Arquivo) 'ERRO'; return $false }
    $null = Invoke-Nativo 'reg.exe' @('unload', ('HKLM\' + $Nome)) -Silencioso
    $r = Invoke-Nativo 'reg.exe' @('load', ('HKLM\' + $Nome), $Arquivo) -Silencioso
    if ($r.Codigo -ne 0) { Write-Registro ('reg load HKLM\' + $Nome + ' falhou (hive em uso? sem admin?): ' + $r.Texto.Trim()) 'ERRO'; return $false }
    $script:Hives.Add($Nome)
    Write-Registro ('Hive carregado (leitura): HKLM\' + $Nome + ' <- ' + $Arquivo)
    return $true
}

function Dismount-Hive {
    param([string]$Nome)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    for ($t = 0; $t -lt 3; $t++) {
        $r = Invoke-Nativo 'reg.exe' @('unload', ('HKLM\' + $Nome)) -Silencioso
        if ($r.Codigo -eq 0) { [void]$script:Hives.Remove($Nome); Write-Registro ('Hive descarregado: HKLM\' + $Nome); return }
        Start-Sleep -Seconds 1
    }
    Write-Registro ('reg unload HKLM\' + $Nome + ' falhou. Rode depois: reg unload HKLM\' + $Nome) 'AVISO'
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
                    foreach ($s in $Servicos) { Write-Registro ('[SIMULACAO] reg add HKLM\RB_SYS\ControlSet001\Services\' + $s + ' /v Start /t REG_DWORD /d 0 /f') 'SIM' }
                }
                return
            }
            $carregou = $true; $raiz = 'HKLM\RB_SYS'; $cs = Get-ControlSet $raiz
        }
        foreach ($s in $Servicos) {
            $k = $raiz + '\' + $cs + '\Services\' + $s
            $v = Get-RegValor $k 'Start'
            if ($null -eq $v) { Write-Registro ('  ' + $s + ' nao existe neste Windows: pulado.'); continue }
            Write-Registro ('  ' + $s + ': Start atual=' + $v + ' -> 0')
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
    $dest = Get-Caminho $Destino ('backup-registro-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Registro 'ATENCAO: SAM e SECURITY contem os HASHES DAS SENHAS locais. Guarde o backup em local seguro e apague quando nao precisar.' 'AVISO'
    if (-not (New-Pasta (Get-Caminho $dest 'config'))) { return $false }
    $config = Get-Caminho $dest 'config'
    $hivesBase = @('SYSTEM', 'SOFTWARE')
    if (Read-SimNao 'Incluir SAM e SECURITY (hashes das senhas locais)? So responda S se for realmente preciso' 'N') {
        $hivesBase += @('SAM', 'SECURITY')
        Write-Registro 'SAM e SECURITY INCLUIDOS: apague o backup assim que nao precisar mais.' 'AVISO'
    } else { Write-Registro 'SAM e SECURITY NAO serao copiados (padrao seguro).' }
    if ($script:WinOnline) {
        if (-not (Test-Requisitos @('reg.exe'))) { return $false }
        foreach ($h in $hivesBase) {
            $r = Invoke-Destrutivo 'reg.exe' @('save', ('HKLM\' + $h), (Get-Caminho $config $h), '/y')
            if ($r.Codigo -eq 0) { Write-Registro ('  ' + $h + ' (reg save)') } else { Write-Registro ('  ' + $h + ' falhou (precisa de administrador)') 'AVISO' }
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
                if (-not (Test-Path -LiteralPath $f)) { if (-not $ext) { Write-Registro ('  ' + $h + ' nao existe') 'AVISO' }; continue }
                if (Copy-Arquivo $f $config) { if (-not $ext) { Write-Registro ('  ' + $h) } }
                else { Write-Registro ('  ' + $h + $ext + ' nao copiado (sem acesso?)') 'AVISO' }
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
                else { Write-Registro ('  Users\' + $u.Name + '\' + (Split-Path -Leaf $f) + ' em uso/sem acesso (normal para o usuario logado)') 'AVISO' }
            }
        }
    }
    if ($script:Sim) { Write-Registro ('[SIMULACAO] gerar SHA256SUMS.txt em ' + $dest) 'SIM'; return $true }
    try {
        $linhas = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)) {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $linhas += ('{0} *{1}' -f $hash, $f.FullName.Substring($dest.Length).TrimStart('\', '/'))
        }
        Set-Content -LiteralPath (Get-Caminho $dest 'SHA256SUMS.txt') -Value $linhas -Encoding Ascii
    } catch { Write-Registro ('Nao consegui gerar SHA256SUMS: ' + $_.Exception.Message) 'AVISO' }
    Write-Registro ('Backup do registro: ' + $dest + ' (com SHA256SUMS.txt)') 'OK'
    Write-Host '  Restaurar: com o Windows desligado, copie de volta para Windows\System32\config.'
    return $true
}

function Request-BackupRegistro {
    <# Oferece o backup (padrao N: nunca grava hives sem a pessoa pedir). #>
    if (Read-SimNao 'Fazer backup do registro (ferramenta 9; inclui SAM/SECURITY com hashes de senha) antes?' 'N') {
        $d = Select-Destino 'Destino do backup do registro:' $script:LogDir
        if ($d) { $null = Backup-Registro $d } else { Write-Registro 'Backup do registro pulado.' }
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
        Write-Registro ('Nao consegui listar os dispositivos (WMI): ' + $_.Exception.Message) 'AVISO'
        $script:ModoStorage = 'DESCONHECIDO'
        return
    }
    $intelRaid = $false; $achou = 0
    Write-Registro 'Controladoras de disco:'
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
        if ($null -ne $cm -and [int]$cm -ne 0) { $estado = ('SEM DRIVER/ERRO (codigo ' + $cm + ')') }
        if (-not $nome) { $nome = '(sem nome)' }
        Write-Registro ('  ' + $nome + ' | ' + $id + ' | ' + $estado)
        if ($id -match $vmd -or $nome -match 'VMD') { $script:ModoStorage = 'VMD'; if ($id -match 'VEN_8086') { $intelRaid = $true } }
        elseif ($ids -match 'CC_0104' -or $nome -match 'RAID|Rapid Storage|iaStor') {
            if ($script:ModoStorage -ne 'VMD') { $script:ModoStorage = 'RAID' }
            if ($id -match 'VEN_8086' -or $nome -match 'Intel') { $intelRaid = $true }
        }
        elseif (($ids -match 'CC_0108' -or $nome -match 'NVM') -and $script:ModoStorage -eq 'AHCI') { $script:ModoStorage = 'NVME' }
    }
    if ($achou -eq 0) { Write-Registro '  (nenhuma controladora listada)' 'AVISO'; $script:ModoStorage = 'DESCONHECIDO' }
    if (($script:ModoStorage -eq 'RAID' -or $script:ModoStorage -eq 'VMD') -and -not $intelRaid) {
        Write-Registro 'RAID que nao parece Intel (ex.: AMD RAID): use o driver do fabricante da placa.' 'AVISO'
    }
}

function Invoke-InjetarRst {
    Write-Registro '2. Injecao de drivers Intel RST (deteccao automatica)' 'PASSO'
    Get-ModoStorage
    if ($script:ModoStorage -eq 'VMD' -or $script:ModoStorage -eq 'RAID') {
        Write-Registro ('Controladora em modo ' + $script:ModoStorage + ' (Intel RST): o Windows precisa do iaStorAVC/iaStorVD.') 'AVISO'
    } elseif ($script:ModoStorage -eq 'DESCONHECIDO') {
        Write-Registro 'Nao consegui determinar o modo da controladora. Se o WinPE nao enxerga o disco, provavelmente precisa do RST.' 'AVISO'
    } else {
        Write-Registro ('Controladora em modo ' + $script:ModoStorage + ': o driver Intel RST geralmente NAO e necessario.') 'OK'
    }
    Write-Host '  Alternativa: mudar no BIOS SATA/VMD para AHCI (com storahci ligado no registro).'
    $drv = $null
    if (Read-SimNao 'Injetar/carregar drivers RST agora?' $(if ($script:ModoStorage -eq 'VMD' -or $script:ModoStorage -eq 'RAID') { 'S' } else { 'N' })) {
        $drv = Select-PastaDrivers (Get-Caminho $script:RB 'drivers\rst')
    }
    if ($drv) {
        if ($script:EmWinPE -and (Test-Exe 'drvload.exe')) {
            if (Read-SimNao 'Carregar o driver no PROPRIO WinPE (drvload) para enxergar o disco agora?' 'N') {
                foreach ($inf in @(Get-ChildItem -LiteralPath $drv -Recurse -Filter '*.inf' -File -Force -ErrorAction SilentlyContinue)) {
                    $null = Invoke-Destrutivo 'drvload.exe' @($inf.FullName)
                }
                Write-Registro 'Se o disco apareceu agora, o Windows sera procurado a seguir.'
            }
        }
        if (-not (Select-Windows)) { return }
        Request-BackupRegistro
        if ($script:WinOnline) {
            if (-not (Test-Requisitos @('pnputil.exe'))) { return }
            if (Confirm-Sim ('Instalar os drivers de ' + $drv + ' NESTE Windows (pnputil)?')) {
                $null = Invoke-Destrutivo 'pnputil.exe' @('/add-driver', (Get-Caminho $drv '*.inf'), '/subdirs', '/install')
            }
        } else {
            if (-not (Test-Requisitos @('dism.exe'))) { return }
            if (Confirm-Sim ('Injetar os drivers de ' + $drv + ' no Windows ' + (Get-RaizImagem) + ' (DISM offline)?')) {
                $r = Invoke-Destrutivo 'dism.exe' @(('/Image:' + (Get-RaizImagem)), '/Add-Driver', ('/Driver:' + $drv), '/Recurse', ('/LogPath:' + (Join-Path $script:LogDir 'dism-add-driver.log')))
                if (-not $r.Simulado) {
                    if ($r.Codigo -eq 0) { Write-Registro 'Drivers injetados.' 'OK' } else { Write-Registro ('DISM terminou com codigo ' + $r.Codigo + '. Veja dism-add-driver.log') 'ERRO' }
                }
            }
        }
    } else { Write-Registro 'Injecao de driver pulada.' }
    if (Read-SimNao 'Ligar storahci/iaStorAVC/iaStorAC/iaStorVD/iaStorV (Start=0) no registro (para trocar o modo no BIOS)?' 'N') {
        if (-not (Select-Windows)) { return }
        if (Confirm-Sim 'Gravar Start=0 nesses servicos (os que existirem)?') { Set-StartZero @('storahci', 'iaStorAVC', 'iaStorAC', 'iaStorVD', 'iaStorV') }
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
        $i = Select-Item ('Mais de uma particao EFI no disco ' + $pw.DiskNumber + ':') ($esps | ForEach-Object { 'Particao {0}: {1:N0} MB' -f $_.PartitionNumber, ($_.Size / 1MB) })
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
    if (-not $l) { Write-Registro 'Nenhuma letra livre para montar a EFI.' 'ERRO'; return $null }
    if ($script:Sim) { Write-Registro ('[SIMULACAO] atribuir a letra ' + $l + ': a EFI (disco ' + $Esp.DiskNumber + ', particao ' + $Esp.PartitionNumber + ')') 'SIM'; return $null }
    try {
        Add-PartitionAccessPath -DiskNumber $Esp.DiskNumber -PartitionNumber $Esp.PartitionNumber -AccessPath ($l + ':\') -ErrorAction Stop
        $script:EspTemp = $l
        Write-Registro ('EFI montada temporariamente em ' + $l + ':')
        return $l
    } catch {
        Write-Registro ('Nao consegui montar a EFI: ' + $_.Exception.Message) 'AVISO'
        return $null
    }
}

function Dismount-Esp {
    if ($script:EspTemp -and (Test-Exe 'mountvol.exe')) {
        $null = Invoke-Nativo 'mountvol.exe' @(($script:EspTemp + ':'), '/D') -Silencioso
        Write-Registro ('Letra temporaria ' + $script:EspTemp + ': removida.')
    }
    $script:EspTemp = $null
}

function Invoke-Bcdboot {
    param([string]$LetraEsp, [bool]$TemEsp)
    $a = @($script:WinDir, '/f', 'ALL')
    if ($LetraEsp) { $a += @('/s', ($LetraEsp + ':')) }
    elseif ($TemEsp) {
        if (-not $script:Sim) { Write-Registro 'A EFI existe mas nao foi montada: bcdboot sem /s poderia gravar no pendrive. Use a opcao 1 do menu (boot UEFI).' 'ERRO'; return }
        $a += @('/s', '<letra-da-EFI>:')
    }
    $r = Invoke-Destrutivo 'bcdboot.exe' ($a + @('/l', 'pt-BR'))
    if (-not $r.Simulado -and $r.Codigo -ne 0) {
        Write-Registro 'bcdboot falhou com /l pt-BR; tentando sem o idioma...' 'AVISO'
        $r = Invoke-Destrutivo 'bcdboot.exe' $a
    }
    if (-not $r.Simulado) {
        if ($r.Codigo -eq 0) { Write-Registro 'bcdboot concluido.' 'OK' } else { Write-Registro ('bcdboot falhou (codigo ' + $r.Codigo + ').') 'ERRO' }
    }
}

function Invoke-ReconstruirBcd {
    Write-Registro '3. Reconstrucao do BCD (bootrec automatizado)' 'PASSO'
    if (-not (Test-Requisitos @('bcdedit.exe'))) { return }
    if (-not (Select-Windows)) { return }
    Request-BackupRegistro
    $esp = Find-EspWindows
    $letra = $null; $bcdEsp = $null; $store = $null
    try {
        if ($esp) {
            Write-Registro ('Particao EFI do disco do Windows: disco ' + $esp.DiskNumber + ', particao ' + $esp.PartitionNumber + (' ({0:N0} MB)' -f ($esp.Size / 1MB)))
            $letra = Mount-Esp $esp
            if ($letra) {
                $bcdEsp = $letra + ':\EFI\Microsoft\Boot\BCD'
                if (Test-Path -LiteralPath $bcdEsp) { $store = $bcdEsp } else { Write-Registro ('Nao existe BCD em ' + $bcdEsp) 'AVISO' }
            }
        } else {
            Write-Registro 'Particao EFI nao identificada (disco MBR/BIOS, ou sem os cmdlets de armazenamento): usando o BCD do sistema.' 'AVISO'
        }
        Write-Registro 'Backup do BCD atual (bcdedit /export) e listagem:'
        $bkp = Join-Path $script:LogDir 'BCD-backup'
        $pre = @(); if ($store) { $pre = @('/store', $store) }
        $r = Invoke-Nativo 'bcdedit.exe' ($pre + @('/export', $bkp))
        if ($r.Codigo -eq 0) { Write-Registro ('Backup: ' + $bkp) 'OK' } else { Write-Registro 'bcdedit /export falhou (BCD ausente/corrompido?).' 'AVISO' }
        $r = Invoke-Nativo 'bcdedit.exe' ($pre + @('/enum', 'all'))
        $lista = Join-Path $script:LogDir 'bcdedit-enum.txt'
        try { Set-Content -LiteralPath $lista -Value $r.Saida -Encoding UTF8 } catch { $null = $_ }
        foreach ($l in $r.Saida) { if ($l -match '^(identifier|identificador|device|dispositivo|path|caminho|description|descri)') { Write-Host ('  ' + $l) } }
        Write-Registro ('Listagem completa: ' + $lista)

        Write-Host ''
        Write-Host '  [1] Reconstruir: bootrec /scanos + /rebuildbcd (se existir) e bcdboot'
        Write-Host '  [2] Restaurar um BCD de backup'
        Write-Host '  [3] Usar o BCD-Template como base (sem entradas) e depois bcdboot'
        $op = Read-Linha 'Opcao (ENTER cancela)'
        switch ($op) {
            '1' {
                if (-not (Confirm-Sim 'Reconstruir o BCD (bootrec /scanos, /rebuildbcd e, se preciso, bcdboot)?')) { return }
                $ok = $false
                if (Test-Exe 'bootrec.exe') {
                    $null = Invoke-Destrutivo 'bootrec.exe' @('/scanos')
                    Write-Host '  bootrec /rebuildbcd vai perguntar se adiciona a instalacao:'
                    Write-Host '  responda S (Sim) ou T (Todos) no Windows em portugues; Y/A em ingles.'
                    Write-Host '  "Total de instalacoes identificadas: 0" = o BCD ja conhece o Windows ou esta ilegivel.'
                    $r = Invoke-Destrutivo 'bootrec.exe' @('/rebuildbcd') -Interativo
                    if ($r.Codigo -eq 0) { $ok = $true }
                    Write-Host '  /fixboot nao e rodado: em UEFI costuma dar "Acesso negado" e nao e necessario.'
                } else {
                    Write-Registro 'bootrec nao existe aqui (so existe no WinRE, nao no WinPE puro nem no Windows online). Usando bcdboot.' 'AVISO'
                }
                if (-not $ok -or (Read-SimNao ('Rodar tambem bcdboot ' + $script:WinDir + ' /f ALL (recria os arquivos de boot)?') 'N')) {
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
                $descs += 'Digitar o caminho de um arquivo BCD'
                $i = Select-Item 'Backups de BCD (mais novo primeiro):' $descs
                if ($i -lt 0) { Write-Registro 'Nenhum backup escolhido.'; return }
                if ($i -lt $bks.Count) { $arq = $bks[$i].FullName } else { $arq = (Read-Linha 'Arquivo BCD (ENTER cancela)').Trim('"') }
                if (-not $arq -or -not (Test-Path -LiteralPath $arq)) { Write-Registro 'Arquivo nao existe.' 'ERRO'; return }
                if ($bcdEsp) {
                    if (-not (Confirm-Sim ('Substituir ' + $bcdEsp + ' por ' + $arq + '? (o atual ja esta em BCD-backup)'))) { return }
                    $null = New-Pasta (Split-Path -Parent $bcdEsp)
                    $null = Invoke-Escrita ('copiar ' + $arq + ' -> ' + $bcdEsp) {
                        if (Test-Path -LiteralPath $bcdEsp) { (Get-Item -LiteralPath $bcdEsp -Force).Attributes = 'Normal' }
                        Copy-Item -LiteralPath $arq -Destination $bcdEsp -Force -ErrorAction Stop
                    }
                } else {
                    if ($esp -and -not $script:Sim) { Write-Registro 'A EFI existe mas nao foi montada; nao vou importar no BCD errado.' 'ERRO'; return }
                    if (-not (Confirm-Sim ('Importar ' + $arq + ' no BCD do sistema (bcdedit /import)?'))) { return }
                    $null = Invoke-Destrutivo 'bcdedit.exe' @('/import', $arq)
                }
            }
            '3' {
                $tpl = Get-Caminho $script:WinDir 'System32\config\BCD-Template'
                if (-not (Test-Path -LiteralPath $tpl)) { Write-Registro ('BCD-Template nao existe: ' + $tpl) 'ERRO'; return }
                Write-Registro 'O BCD-Template NAO tem entrada do Windows: sozinho NAO da boot (o bcdboot cria a entrada depois).' 'AVISO'
                if (-not $bcdEsp) {
                    if ($script:Sim) { Write-Registro '[SIMULACAO] copiar BCD-Template -> <EFI>:\EFI\Microsoft\Boot\BCD' 'SIM' }
                    else { Write-Registro 'Precisa da EFI montada (disco GPT). Em disco MBR use a opcao [1].' 'ERRO'; return }
                } else {
                    if (-not (Confirm-Sim ('Gravar o BCD-Template como ' + $bcdEsp + '?'))) { return }
                    $null = New-Pasta (Split-Path -Parent $bcdEsp)
                    $null = Invoke-Escrita ('copiar ' + $tpl + ' -> ' + $bcdEsp) {
                        if (Test-Path -LiteralPath $bcdEsp) { (Get-Item -LiteralPath $bcdEsp -Force).Attributes = 'Normal' }
                        Copy-Item -LiteralPath $tpl -Destination $bcdEsp -Force -ErrorAction Stop
                    }
                }
                if ((Read-SimNao 'Rodar bcdboot agora para criar a entrada do Windows?' 'S') -and (Test-Requisitos @('bcdboot.exe'))) { Invoke-Bcdboot $letra ([bool]$esp) }
            }
            default { Write-Registro 'Cancelado.'; return }
        }
        Write-Registro ('Concluido. Backup do BCD em ' + $bkp + ' (restaurar: opcao [2] ou bcdedit /import <arquivo>).') 'OK'
    } finally {
        Dismount-Esp
    }
}

# ================================================================== 4. SFC + DISM
function Show-Resumo {
    param([string]$Nome, $Resultado, [string]$Padrao)
    if ($Resultado.Simulado) { return }
    $linhas = @($Resultado.Saida | Where-Object { $_ -match $Padrao } | Select-Object -Last 6)
    Write-Registro ('Resumo ' + $Nome + ' (codigo ' + $Resultado.Codigo + '):')
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
    Write-Registro '4. SFC e DISM em sequencia (com log)' 'PASSO'
    if (-not (Test-Requisitos @('dism.exe', 'sfc.exe'))) { return }
    if (-not (Select-Windows)) { return }
    $dismLog = Join-Path $script:LogDir 'dism.log'
    if ($script:WinOnline) {
        Write-Registro 'Windows ONLINE: DISM /Online /RestoreHealth e depois SFC /scannow.'
        if (-not (Confirm-Sim 'Rodar DISM /RestoreHealth e SFC agora (pode levar 30+ min)?')) { return }
        $r = Invoke-Destrutivo 'dism.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth', ('/LogPath:' + $dismLog))
        Show-Resumo 'DISM' $r $script:PadraoDism
        $r = Invoke-Destrutivo 'sfc.exe' @('/scannow')
        Show-Resumo 'SFC' $r $script:PadraoSfc
    } else {
        $fonte = (Read-Linha 'Fonte opcional (ex.: E:\sources\install.wim:1 ; ENTER = sem fonte)').Trim('"')
        $a = @(('/Image:' + (Get-RaizImagem)), '/Cleanup-Image', '/RestoreHealth', ('/LogPath:' + $dismLog))
        if ($fonte) {
            $arqFonte = $fonte; $indice = ''
            if ($fonte -match '^(.+\.(wim|esd|swm))(:(\d+))?$') { $arqFonte = $Matches[1]; if ($Matches[4]) { $indice = $Matches[4] } }
            if (-not (Test-Path -LiteralPath $arqFonte)) { Write-Registro ('Fonte nao encontrada: ' + $arqFonte + ' (o DISM vai falhar).') 'AVISO' }
            if ($arqFonte -match '\.(wim|esd|swm)$') {
                if (-not $indice) { $indice = '1'; Write-Registro 'Sem indice na fonte: usando :1 (confira com dism /Get-WimInfo /WimFile:<arquivo>).' 'AVISO' }
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
        if (-not (Confirm-Sim ('Rodar DISM offline em ' + (Get-RaizImagem) + ' e depois SFC offline (pode levar 30+ min)?'))) { return }
        $r = Invoke-Destrutivo 'dism.exe' $a
        Show-Resumo 'DISM' $r $script:PadraoDism
        $r = Invoke-Destrutivo 'sfc.exe' @('/scannow', ('/offbootdir=' + (Get-RaizImagem)), ('/offwindir=' + $script:WinDir))
        Show-Resumo 'SFC' $r $script:PadraoSfc
    }
    Copy-LogsCbs
    Write-Registro ('Logs: ' + $script:LogFile + ', ' + $dismLog + ', CBS-*.log em ' + $script:LogDir)
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
    $rel.Add('Favoritos procurados em ' + $Perfil + ' (caminhos dentro do perfil):')
    $null = New-Pasta $Destino
    foreach ($pad in $script:Favoritos) {
        $achados = @(Resolve-Padrao $Perfil $pad)
        if ($achados.Count -eq 0) { $rel.Add('  nao existe: ' + $pad); continue }
        foreach ($f in $achados) {
            $r = $f.Substring($Perfil.Length).TrimStart('\', '/')
            $extra = ''
            if ((Split-Path -Leaf $f) -eq 'Bookmarks') {
                try { $extra = ('  (' + ([regex]::Matches([IO.File]::ReadAllText($f), '"type"\s*:\s*"url"')).Count + ' links)') } catch { $null = $_ }
            }
            $rel.Add('  ENCONTRADO: ' + $r + $extra)
            $nomeDest = ($r -replace '[\\/ ]', '_')
            $origemFav = $f; $alvoFav = Get-Caminho $Destino $nomeDest
            $null = Invoke-Escrita ('copiar ' + $origemFav + ' -> ' + $alvoFav) { Copy-Item -LiteralPath $origemFav -Destination $alvoFav -Recurse -Force -ErrorAction Stop }
        }
    }
    foreach ($l in $rel) { Write-Registro $l }
    $arqRel = Get-Caminho $Destino 'favoritos.txt'
    if ($script:Sim) { $arqRel = Join-Path $script:LogDir ('favoritos-' + (Split-Path -Leaf $Perfil) + '.txt') }
    try { Set-Content -LiteralPath $arqRel -Value $rel.ToArray() -Encoding UTF8 -ErrorAction Stop; Write-Registro ('Relatorio: ' + $arqRel) } catch { $null = $_ }
}

function Invoke-ExtrairPerfil {
    Write-Registro '5. Extracao de perfil (AppData e favoritos)' 'PASSO'
    if (-not (Select-Windows)) { return }
    $users = Get-Caminho $script:WinRaiz 'Users'
    if (-not (Test-Path -LiteralPath $users)) { Write-Registro ('Pasta Users nao encontrada em ' + $script:WinRaiz) 'ERRO'; return }
    $ignorar = @('default', 'public', 'all users', 'default user', 'defaultapppool', 'desktop.ini')
    $perfis = @(Get-ChildItem -LiteralPath $users -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
            ($ignorar -notcontains $_.Name.ToLowerInvariant()) -and (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
        } | ForEach-Object { $_.Name })
    if ($perfis.Count -eq 0) { Write-Registro 'Nenhum perfil de usuario.' 'ERRO'; return }
    $i = Select-Item 'Perfis:' ($perfis + @('TODOS'))
    if ($i -lt 0) { Write-Registro 'Cancelado.'; return }
    if ($i -eq $perfis.Count) { $sel = $perfis } else { $sel = @($perfis[$i]) }
    $origens = @($sel | ForEach-Object { Get-Caminho $users $_ })
    $dest = Select-Destino 'Destino da copia:' '' $origens
    if (-not $dest) { Write-Registro 'Cancelado.'; return }
    $exc = @()
    if (Read-SimNao 'Excluir lixo (Temp, INetCache, CrashDumps, cache de navegador)?' 'S') {
        foreach ($o in $origens) {
            foreach ($r in 'AppData\Local\Temp', 'AppData\Local\Microsoft\Windows\INetCache', 'AppData\Local\CrashDumps') { $exc += (Get-Caminho $o $r) }
            foreach ($pad in 'AppData\Local\Google\Chrome\User Data\*\Cache', 'AppData\Local\Google\Chrome\User Data\*\Code Cache',
                'AppData\Local\Microsoft\Edge\User Data\*\Cache', 'AppData\Local\Microsoft\Edge\User Data\*\Code Cache',
                'AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Cache', 'AppData\Local\Mozilla\Firefox\Profiles\*\cache2') {
                $exc += @(Resolve-Padrao $o $pad)
            }
        }
        Write-Registro ('Pastas excluidas da copia: ' + $exc.Count)
    }
    if ($script:WinOnline) { Write-Registro 'Windows online: arquivos em uso (NTUSER.DAT, Outlook aberto) podem falhar. Feche os programas.' 'AVISO' }
    Write-Registro 'Calculando tamanho...'
    $bytes = [int64]0
    foreach ($o in $origens) { $bytes += (Get-TamanhoPasta $o) }
    if (-not (Test-EspacoOk $dest $bytes)) { return }
    $alvo = Get-Caminho $dest ('perfis-' + $script:Stamp)
    if (-not (New-Pasta $alvo)) { return }
    foreach ($nome in $sel) {
        Write-Registro ('Copiando perfil ' + $nome + ' (com AppData) ...') 'PASSO'
        $origemPerfil = Get-Caminho $users $nome
        $excPerfil = @($exc | Where-Object { Test-Dentro $_ @($origemPerfil) })
        if (-not (Copy-Robocopy $origemPerfil (Get-Caminho $alvo $nome) $excPerfil)) { Write-Registro ('Copia de ' + $nome + ' com erros (veja o log).') 'AVISO' }
        Write-Registro ('Favoritos de ' + $nome) 'PASSO'
        Get-Favoritos (Get-Caminho $users $nome) (Get-Caminho $alvo ('favoritos-' + $nome))
    }
    Write-Registro ('Concluido: ' + $alvo + '  (impressoras: ferramenta 6)') 'OK'
}

# ================================================================== 6. IMPRESSORAS
function Invoke-ExportarImpressoras {
    Write-Registro '6. Exportacao de impressoras' 'PASSO'
    if (-not (Select-Windows)) { return }
    $dest = Select-Destino 'Destino da exportacao:'
    if (-not $dest) { Write-Registro 'Cancelado.'; return }
    $d = Get-Caminho $dest ('impressoras-' + $script:Stamp)
    if (-not (New-Pasta $d)) { return }
    $sp = Get-Caminho $script:WinDir 'System32\spool\drivers'
    if (Test-Path -LiteralPath $sp) {
        Write-Registro 'Copiando spool\drivers ...'
        $null = Copy-Robocopy $sp (Get-Caminho $d 'spool-drivers')
    } else { Write-Registro ('Sem ' + $sp) 'AVISO' }
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
        if ($imps.Count -gt 0) { Write-Registro ('Impressoras no registro: ' + ($imps -join ', ')) } else { Write-Registro 'Nenhuma impressora listada no registro (ou hive nao lido).' }
        foreach ($k in 'Printers', 'Environments', 'Monitors', 'Forms') {
            $arq = Get-Caminho $d ('print-' + $k + '.reg')
            $r = Invoke-Destrutivo 'reg.exe' @('export', ($rs + '\' + $cs + '\Control\Print\' + $k), $arq, '/y')
            if ($r.Codigo -eq 0) { $exportados += $arq; if (-not $r.Simulado) { Write-Registro ('  print-' + $k + '.reg') 'OK' } } else { Write-Registro ('  (sem a chave Print\' + $k + ')') 'AVISO' }
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
                [IO.File]::WriteAllText(($f -replace '\.reg$', '-importar.reg'), $t, [Text.Encoding]::Unicode)
            } catch { Write-Registro ('Nao consegui gerar a versao para importar de ' + $f) 'AVISO' }
        }
    }
    $notas = @(
        'Restaurar impressoras exportadas pelo ReparoBoot (ferramenta 6):',
        '1. Instale o driver da impressora (pelo fabricante; a pasta spool-drivers ajuda a achar o modelo).',
        '2. Importe os arquivos *-importar.reg (offline) ou *.reg (online) com: reg import <arquivo>',
        '   (como administrador) e reinicie o spooler: net stop spooler & net start spooler',
        '3. Mais garantido: reinstalar a impressora pelo instalador do fabricante, ou usar PrintBrm.exe.'
    )
    $arqNotas = Get-Caminho $d 'LEIA-RESTAURAR.txt'
    $null = Invoke-Escrita ('gravar ' + $arqNotas) { Set-Content -LiteralPath $arqNotas -Value $notas -Encoding Ascii -ErrorAction Stop }
    Write-Registro ('Exportado em ' + $d) 'OK'
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
    Write-Registro '7. Varredura da raiz do C (pastas nao padrao)' 'PASSO'
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
    if ($itens.Count -eq 0) { Write-Registro 'Nada fora das pastas de sistema na raiz.' 'OK'; return }
    Write-Host 'Itens fora do sistema (ex.: "Arquivos de Programas RFB" do IRPF, ERP/contabilidade, bancos de dados):'
    $tams = @()
    for ($i = 0; $i -lt $itens.Count; $i++) {
        $e = $itens[$i]
        if ($e -is [System.IO.FileInfo]) { $t = [int64]$e.Length; $suf = '' } else { $t = Get-TamanhoPasta $e.FullName; $suf = '\' }
        $tams += $t
        Write-Registro ('  [{0}] {1,10}  {2}{3}' -f ($i + 1), (Format-Tamanho $t), $e.Name, $suf)
    }
    $sel = @()
    for ($t = 0; $t -lt 5; $t++) {
        $r = Read-Linha 'Marque os numeros (ex.: 1 3 5), "todos", ou ENTER/C cancela'
        if (-not $r -or $r.ToUpperInvariant() -eq 'C') { Write-Registro 'Cancelado.'; return }
        if ($r.ToLowerInvariant() -eq 'todos') { $sel = @(0..($itens.Count - 1)); break }
        $ok = $true; $sel = @()
        foreach ($tok in ($r -split '[\s,;]+' | Where-Object { $_ })) {
            $k = 0
            if ([int]::TryParse($tok, [ref]$k) -and $k -ge 1 -and $k -le $itens.Count) { if ($sel -notcontains ($k - 1)) { $sel += ($k - 1) } } else { $ok = $false }
        }
        if ($ok -and $sel.Count -gt 0) { break }
        Write-Host 'Entrada invalida.'; $sel = @()
    }
    if ($sel.Count -eq 0) { Write-Registro 'Cancelado.'; return }
    $origens = @($sel | Where-Object { $itens[$_] -is [System.IO.DirectoryInfo] } | ForEach-Object { $itens[$_].FullName })
    $dest = Select-Destino 'Destino da copia:' '' $origens
    if (-not $dest) { Write-Registro 'Cancelado.'; return }
    $bytes = [int64]0
    foreach ($k in $sel) { $bytes += $tams[$k] }
    if (-not (Test-EspacoOk $dest $bytes)) { return }
    $alvo = Get-Caminho $dest ('raiz-c-' + $script:Stamp)
    if (-not (New-Pasta $alvo)) { return }
    foreach ($k in $sel) {
        $e = $itens[$k]
        Write-Registro ('Copiando ' + $e.Name + ' ...')
        if ($e -is [System.IO.DirectoryInfo]) { $ok = Copy-Robocopy $e.FullName (Get-Caminho $alvo $e.Name) }
        else { $ok = Copy-Robocopy $e.DirectoryName $alvo @() $e.Name }
        if (-not $ok) { Write-Registro ('Erros em ' + $e.Name) 'AVISO' }
    }
    Write-Registro ('Concluido: ' + $alvo) 'OK'
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
                if (-not $m) { try { $m = '(sem texto do provedor; dados: ' + ((@($e.Properties) | ForEach-Object { [string]$_.Value }) -join ' | ') + ')' } catch { $m = '(sem texto)' } }
                $m = ($m -replace '\s+', ' ').Trim()
                if ($m.Length -gt 400) { $m = $m.Substring(0, 400) + '...' }
                $nv = 'ERRO'; if ($e.Level -eq 1) { $nv = 'CRITICO' }
                $linhas.Add(('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2} id={3}: {4}' -f $e.TimeCreated, $nv, $e.ProviderName, $e.Id, $m))
            }
            $ok = $true
        } catch {
            if ([string]$_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { $ok = $true }
            else { Write-Registro ('Get-WinEvent falhou: ' + $_.Exception.Message) 'AVISO' }
        }
    }
    if (-not $ok -and (Test-Exe 'wevtutil.exe')) {
        if ($Caminho) { $a = @('qe', $Caminho, '/lf:true') } else { $a = @('qe', $NomeLog) }
        $r = Invoke-Nativo 'wevtutil.exe' ($a + @(('/q:' + $script:Consulta), ('/c:' + $Max), '/rd:true', '/f:text')) -Silencioso -SemSaidaNoLog
        if ($r.Codigo -eq 0) { foreach ($l in $r.Saida) { $linhas.Add($l) }; $ok = $true }
    }
    if (-not $ok) { Write-Registro ('Nao consegui ler os eventos de ' + $Caminho + $NomeLog) 'AVISO'; return }
    if ($linhas.Count -eq 0) { $linhas.Add('Nenhum erro ou critico encontrado.') }
    try { Set-Content -LiteralPath $Arquivo -Value $linhas.ToArray() -Encoding UTF8 -ErrorAction Stop } catch { Write-Registro ('Nao consegui gravar ' + $Arquivo) 'AVISO'; return }
    Write-Registro ('  ' + (Split-Path -Leaf $Arquivo) + ': ' + $linhas.Count + ' linha(s) (ultimos ' + $Max + ' erros/criticos)')
}

function Invoke-EventLog {
    Write-Registro '8. Event Log (opcional)' 'PASSO'
    if (-not (Select-Windows)) { return }
    $dest = Join-Path $script:LogDir 'eventlog'
    $dirErros = $dest
    if ($script:Sim) { $dirErros = $script:LogDir } else { $null = New-Pasta $dest }
    if ($script:WinOnline) {
        foreach ($n in 'System', 'Application', 'Setup') {
            $r = Invoke-Destrutivo 'wevtutil.exe' @('epl', $n, (Join-Path $dest ($n + '.evtx')), '/ow:true')
            if (-not $r.Simulado -and $r.Codigo -eq 0) { Write-Registro ('  ' + $n + '.evtx exportado') }
            Write-ErrosEvento -NomeLog $n -Arquivo (Join-Path $dirErros ($n + '-erros.txt'))
        }
    } else {
        $dirLog = Get-Caminho $script:WinDir 'System32\winevt\Logs'
        if (-not (Test-Path -LiteralPath $dirLog)) { Write-Registro ('winevt\Logs nao encontrado: ' + $dirLog) 'ERRO'; return }
        $arqs = @(Get-ChildItem -LiteralPath $dirLog -Filter '*.evtx' -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.ToLowerInvariant() -match $script:EvtxRe })
        Write-Registro ('Logs .evtx selecionados: ' + $arqs.Count)
        foreach ($f in $arqs) { if (Copy-Arquivo $f.FullName $dest) { if (-not $script:Sim) { Write-Registro ('  ' + $f.Name) } } else { Write-Registro ('  ' + $f.Name + ' nao copiado') 'AVISO' } }
        foreach ($n in 'System', 'Application', 'Setup') {
            $orig = Get-Caminho $dirLog ($n + '.evtx')
            $copia = Join-Path $dest ($n + '.evtx')
            $fonte = $orig
            if (-not $script:Sim -and (Test-Path -LiteralPath $copia)) { $fonte = $copia }
            if (-not (Test-Path -LiteralPath $fonte)) { Write-Registro ('  ' + $n + '.evtx nao existe') 'AVISO'; continue }
            Write-ErrosEvento -Caminho $fonte -Arquivo (Join-Path $dirErros ($n + '-erros.txt'))
        }
    }
    Write-Registro ('Event Logs em ' + $dest + ' (listas de erros em ' + $dirErros + ')') 'OK'
}

# ================================================================== 9. BACKUP REGISTRO
function Invoke-BackupRegistro {
    Write-Registro '9. Backup dos hives do registro' 'PASSO'
    if (-not (Select-Windows)) { return }
    Write-Registro 'O backup inclui SAM e SECURITY, que guardam os HASHES DAS SENHAS locais.' 'AVISO'
    if (-not (Read-SimNao 'Continuar com o backup do registro?' 'N')) { Write-Registro 'Cancelado.'; return }
    $d = Select-Destino 'Destino do backup do registro:' $script:LogDir
    if (-not $d) { Write-Registro 'Cancelado.'; return }
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
    Write-Registro 'Arquivos criticos (ausente ou 0 byte = problema):'
    $s32 = Get-Caminho $script:WinDir 'System32'
    foreach ($f in $lista) {
        $p = Get-Caminho $s32 $f
        if (-not (Test-Path -LiteralPath $p)) { Write-Registro ('  AUSENTE: System32\' + $f) 'AVISO'; $problemas++; continue }
        try { if ((Get-Item -LiteralPath $p -Force).Length -eq 0) { Write-Registro ('  ZERADO : System32\' + $f) 'AVISO'; $problemas++ } } catch { $null = $_ }
    }
    if (-not (Test-Path -LiteralPath (Get-Caminho $script:WinDir 'explorer.exe'))) { Write-Registro '  AUSENTE: Windows\explorer.exe' 'AVISO'; $problemas++ }
    if ($problemas -eq 0) { Write-Registro '  Nenhum problema nos arquivos verificados.' 'OK' } else { Write-Registro ('  ' + $problemas + ' problema(s).') 'AVISO' }
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
        } catch { Write-Registro ('Nao consegui ler ' + $f) 'AVISO'; continue }
        Write-Registro ('CBS.log (' + $f + '): ' + $sr + ' linha(s) [SR] nesta execucao; nao reparaveis: ' + $naoRep + '; corrompidos/reparos: ' + $rep)
        foreach ($l in ($ult | Select-Object -Last 10)) { Write-Registro ('  ' + $l) }
    }
}

function Invoke-Integridade {
    Write-Registro '10. Verificador de integridade de arquivos (offline)' 'PASSO'
    if (-not (Select-Windows)) { return }
    Test-Criticos
    if (-not (Test-Requisitos @('sfc.exe', 'dism.exe'))) { return }
    if (-not (Read-SimNao 'Rodar SFC /verifyonly e DISM /CheckHealth + /ScanHealth agora (so verificam, nao corrigem)?' 'S')) { return }
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
    Write-Registro 'Para reparar a imagem use a ferramenta 4 (RestoreHealth + SFC /scannow).'
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

$script:MapaBus = @{ 0 = 'Desconhecido'; 1 = 'SCSI'; 2 = 'ATAPI'; 3 = 'ATA'; 4 = '1394'; 5 = 'SSA'; 6 = 'FibreChannel'; 7 = 'USB'; 8 = 'RAID'; 9 = 'iSCSI'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 15 = 'Virtual'; 16 = 'StorageSpaces'; 17 = 'NVMe' }
$script:MapaMidia = @{ 0 = 'Nao especificado'; 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
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
    if ($Texto -match 'FAILED|FAILING') { $nivel = 'RUIM'; $mot += 'saude=FALHOU' }
    if ($Nvme) {
        $v = Get-Nv $Texto 'Critical Warning'
        if ($v -and $v -ne '0x00' -and $v -ne '0') { $nivel = 'RUIM'; $mot += ('CriticalWarning=' + $v) }
        $sp = Get-Nv $Texto 'Available Spare'; $spt = Get-Nv $Texto 'Available Spare Threshold'
        if ($sp -match '^\d+$' -and $spt -match '^\d+$' -and [int]$sp -le [int]$spt) { $nivel = 'RUIM'; $mot += ('spare=' + $sp + '%') }
        $v = Get-Nv $Texto 'Percentage Used'
        if ($v -match '^\d+$') { if ([int]$v -ge 100) { $nivel = 'RUIM' } elseif ([int]$v -ge 90 -and $nivel -eq 'OK') { $nivel = 'ATENCAO' }; $mot += ('uso=' + $v + '%') }
        $v = Get-Nv $Texto 'Media and Data Integrity Errors'
        if ($v -match '^\d+$' -and [int64]$v -gt 0) { if ($nivel -eq 'OK') { $nivel = 'ATENCAO' }; $mot += ('erros_midia=' + $v) }
    } else {
        $v = Get-Atr $Texto 'Reallocated_Sector_Ct'
        if ($null -ne $v -and $v -gt 0) { if ($nivel -eq 'OK') { $nivel = 'ATENCAO' }; if ($v -gt 100) { $nivel = 'RUIM' }; $mot += ('realocados=' + $v) }
        $v = Get-Atr $Texto 'Current_Pending_Sector'
        if ($null -ne $v -and $v -gt 0) { $nivel = 'RUIM'; $mot += ('pendentes=' + $v) }
        $v = Get-Atr $Texto 'Offline_Uncorrectable'
        if ($null -ne $v -and $v -gt 0) { $nivel = 'RUIM'; $mot += ('incorrigiveis=' + $v) }
        $v = Get-Atr $Texto 'UDMA_CRC_Error_Count'
        if ($null -ne $v -and $v -gt 0) { if ($nivel -eq 'OK') { $nivel = 'ATENCAO' }; $mot += ('CRC=' + $v + '(cabo?)') }
    }
    if ($Texto -match 'SMART support is:\s+Unavailable|Unable to detect device type') { $nivel = 'SEM SMART' }
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
    Write-Registro '11. Verificador S.M.A.R.T. (opcional)' 'PASSO'
    if (-not (Read-SimNao 'Ler o SMART de todos os discos agora (so leitura)?' 'S')) { return }
    $piores = @()
    $brutos = @()
    $viaCim = $false
    try { $brutos = @(Get-PhysicalDisk -ErrorAction Stop) }
    catch {
        try { $brutos = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_PhysicalDisk -ErrorAction Stop); $viaCim = $true }
        catch { Write-Registro 'Get-PhysicalDisk/MSFT_PhysicalDisk indisponivel (falta WinPE-StorageWMI?).' 'AVISO' }
    }
    $vistos = @{}
    $discos = @()
    foreach ($d in $brutos) {
        $k = Get-ChaveDisco $d
        if ($vistos.ContainsKey($k)) { Add-Log ('Disco repetido ignorado: ' + (Get-Prop $d 'FriendlyName') + ' (' + $k + ')'); continue }
        $vistos[$k] = $true
        $discos += $d
    }
    if ($brutos.Count -ne $discos.Count) { Write-Registro (($brutos.Count - $discos.Count).ToString() + ' entrada(s) repetida(s) do mesmo disco ignorada(s).') }
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
        if ($saude -eq 'Warning') { $nivel = 'ATENCAO'; $mot += 'saude=Warning' }
        elseif ($saude -ne 'Healthy') { $nivel = 'RUIM'; $mot += ('saude=' + $saude) }
        if ($oper -match 'Predictive|Error|Failed|Degraded|Lost') { $nivel = 'RUIM'; $mot += ('estado=' + $oper) }
        if ($null -ne $wear -and [int]$wear -ge 100) { $nivel = 'RUIM'; $mot += ('desgaste=' + $wear + '%') }
        elseif ($null -ne $wear -and [int]$wear -ge 90) { if ($nivel -eq 'OK') { $nivel = 'ATENCAO' }; $mot += ('desgaste=' + $wear + '%') }
        if (($null -ne $rerr -and [int64]$rerr -gt 0) -or ($null -ne $werr -and [int64]$werr -gt 0)) { $nivel = 'RUIM'; $mot += 'erros_nao_corrigidos' }
        $lim = 55; if ($bus -eq 'NVMe') { $lim = 70 }
        $tempOk = Test-TempConfiavel $temp $tmax
        if ($null -eq $temp) { $txtTemp = '?' }
        elseif ($tempOk) { $txtTemp = [string]$temp + 'C (max ' + $(if ($null -ne $tmax) { $tmax } else { '?' }) + ')' }
        else { $txtTemp = [string]$temp + 'C (max ' + $(if ($null -ne $tmax) { $tmax } else { '?' }) + ') temperatura nao confiavel' }
        if ($tempOk -and [int]$temp -ge $lim) { if ($nivel -eq 'OK') { $nivel = 'ATENCAO' }; $mot += ('temperatura=' + $temp + 'C') }
        Write-Registro ('Disco: ' + $nome + ' | ' + $bus + ' ' + $midia + ' | ' + $(if ($tam) { Format-Tamanho ([double]$tam) } else { '?' }))
        Write-Registro ('  saude=' + $saude + '  estado=' + $oper + '  temperatura=' + $txtTemp +
            '  desgaste=' + $(if ($null -ne $wear) { [string]$wear + '%' } else { '?' }) + '  horas_ligado=' + $(if ($null -ne $horas) { $horas } else { '?' }))
        Write-Registro ('  erros leitura nao corrigidos=' + $(if ($null -ne $rerr) { $rerr } else { '?' }) + ' (total ' + $(if ($null -ne $rtot) { $rtot } else { '?' }) + ')  erros escrita nao corrigidos=' + $(if ($null -ne $werr) { $werr } else { '?' }))
        if ($null -eq $rel) { Write-Registro '  (sem contadores de confiabilidade para este disco: comum em USB e RAID)' }
        if ($null -ne $temp -and -not $tempOk) { Write-Registro '  (sensor de temperatura com leitura implausivel: ignorado na avaliacao; confira com smartctl)' }
        Write-Registro ('  RESULTADO: ' + $nivel + $(if ($mot.Count) { ' -> ' + ($mot -join ' ') } else { '' })) $(if ($nivel -eq 'OK') { 'OK' } else { 'AVISO' })
        if ($nivel -ne 'OK') { $piores += ($nome + ': ' + $nivel) }
    }
    try {
        foreach ($p in @(Get-CimInstance -Namespace 'root/wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
            if ([bool](Get-Prop $p 'PredictFailure')) {
                Write-Registro ('SMART PREVE FALHA: ' + (Get-Prop $p 'InstanceName') + ' (motivo ' + (Get-Prop $p 'Reason') + ')') 'ERRO'
                $piores += ([string](Get-Prop $p 'InstanceName') + ': RUIM (PredictFailure)')
            }
        }
    } catch { $null = $_ }
    $sm = Find-Smartctl
    if ($sm) {
        Write-Registro ('Usando smartctl: ' + $sm)
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
        Write-Registro 'smartctl nao encontrado (opcional: coloque smartctl.exe em ReparoBoot\tools para detalhes).'
    }
    Write-Host ''
    if ($piores.Count -gt 0) {
        Write-Registro ('Discos com problema: ' + ($piores -join '; ')) 'AVISO'
        Write-Registro 'Nao faca reparos pesados nem clonagem com disco RUIM: priorize salvar os dados (ferramentas 5 e 7).' 'AVISO'
    } elseif ($discos.Count -gt 0) { Write-Registro 'Nenhum disco com problema aparente.' 'OK' }
    Write-Registro ('Detalhes em ' + $script:LogDir)
}

# ================================================================== 12. WIN7
function Invoke-DriversWin7 {
    Write-Registro '12. Drivers de storage para Windows 7' 'PASSO'
    if (-not (Select-Windows)) { return }
    if ($script:WinOnline) {
        Write-Registro 'Isto e para um Windows 7 OFFLINE (que nao liga). Rode do WinPE, com o Win7 em outra letra:' 'AVISO'
        Write-Host '  dism /Image:C:\ /Add-Driver /Driver:E:\drivers\win7 /Recurse'
        return
    }
    $ver = Get-VersaoWindows
    Write-Registro ('Windows: ' + $(if ($ver.Produto) { $ver.Produto } else { '?' }) + ' (versao ' + $(if ($ver.Versao) { $ver.Versao } else { '?' }) + ', build ' + $(if ($ver.Build) { $ver.Build } else { '?' }) + ')')
    if ($ver.Versao -ne '6.1') {
        Write-Registro 'Nao e Windows 7 (ou a versao nao foi lida). Para Win 8/10/11 use a ferramenta 2.' 'AVISO'
        if (-not (Read-SimNao 'Continuar mesmo assim?' 'N')) { return }
    }
    Get-ModoStorage
    switch ($script:ModoStorage) {
        'NVME' { Write-Registro 'NVMe: o Win7 nao tem driver nativo; precisa do KB2990941 (+KB3087873) ou driver NVMe do fabricante.' 'AVISO' }
        'RAID' { Write-Registro 'Modo RAID: o Win7 precisa do RST antigo (iaStorV/iaStorA). Prefira AHCI no BIOS.' 'AVISO' }
        'VMD' { Write-Registro 'Modo VMD: o Win7 precisa do RST antigo (iaStorV/iaStorA). Prefira AHCI no BIOS.' 'AVISO' }
        default { Write-Registro 'AHCI: o Win7 tem o msahci, mas ele pode estar desligado se foi instalado em IDE.' }
    }
    Write-Host '  O Win7 tambem nao tem USB 3.0 nativo: inclua o driver xHCI do chipset na pasta.'
    $drv = Select-PastaDrivers (Get-Caminho $script:RB 'drivers\win7')
    if ($drv) {
        Request-BackupRegistro
        if (Test-Requisitos @('dism.exe')) {
            $fu = @()
            if (Read-SimNao 'Forcar drivers sem assinatura (/ForceUnsigned)?' 'N') { $fu = @('/ForceUnsigned') }
            if (Confirm-Sim ('Injetar os drivers de ' + $drv + ' no Windows 7 em ' + (Get-RaizImagem) + ' (DISM)?')) {
                $r = Invoke-Destrutivo 'dism.exe' (@(('/Image:' + (Get-RaizImagem)), '/Add-Driver', ('/Driver:' + $drv), '/Recurse') + $fu + @(('/LogPath:' + (Join-Path $script:LogDir 'dism-win7.log'))))
                if (-not $r.Simulado) { if ($r.Codigo -eq 0) { Write-Registro 'Drivers injetados.' 'OK' } else { Write-Registro ('DISM terminou com codigo ' + $r.Codigo) 'ERRO' } }
            }
        }
    } else { Write-Registro 'Injecao pulada.' }
    if (Read-SimNao 'Ligar msahci/pciide/iaStorV/storahci (Start=0) no registro?' 'S') {
        if (Confirm-Sim 'Gravar Start=0 em msahci, pciide, iaStorV, storahci (os que existirem)?') { Set-StartZero @('msahci', 'pciide', 'iaStorV', 'storahci') }
    }
    $cmds = @(
        'Injecao REAL no WinPE 10/11 (entende imagens do Win7):',
        '  dism /Image:C:\ /Add-Driver /Driver:C:\Drivers\Win7 /Recurse   [/ForceUnsigned]',
        'Hotfix NVMe KB2990941/KB3087873 (extrair o .msu e adicionar o .cab):',
        '  expand -F:* Windows6.1-KB2990941-x64.msu C:\kb',
        '  dism /Image:C:\ /Add-Package /PackagePath:C:\kb\Windows6.1-KB2990941-x64.cab'
    )
    $arqCmd = Join-Path $script:LogDir 'comandos-win7.txt'
    try { Set-Content -LiteralPath $arqCmd -Value $cmds -Encoding Ascii; Write-Registro ('Comandos salvos em ' + $arqCmd) } catch { $null = $_ }
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
        Write-Host ('Opcao invalida. Use: ' + ($Validas -join ', ')) -ForegroundColor Yellow
    }
    if ($Padrao) { return $Padrao }
    Stop-Reparo 'Sem resposta valida. Nada foi alterado.' 0
}

function Invoke-DiskPart {
    <# Gera um script diskpart, salva no log e executa com diskpart /s (em simulacao nao executa). #>
    param([Parameter(Mandatory = $true)][string[]]$Linhas, [Parameter(Mandatory = $true)][string]$Nome)
    $arquivo = Join-Path $script:LogDir ($Nome + '.txt')
    try { Set-Content -LiteralPath $arquivo -Value $Linhas -Encoding Ascii -ErrorAction Stop } catch { $null = $_ }
    Write-Registro ('Script diskpart (' + $arquivo + '):')
    foreach ($l in $Linhas) { Write-Registro ('    ' + $l) }
    if ($script:Sim) {
        Write-Registro '[SIMULACAO] diskpart NAO executado.' 'SIM'
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
        Write-Registro ('Removendo letra temporaria ' + $script:TempLetter + ':')
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
        if ($tipos.Count -gt 0) { $gpt += 'GptType das particoes' }
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
    return @{ Estilo = 'DESCONHECIDO'; Fonte = 'nenhuma' }
}

function Invoke-ReparoBootUefi {
    Write-Registro '1. Reparo de boot UEFI' 'PASSO'
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
    if ($script:Sim) { Write-Registro 'MODO SIMULACAO: so deteccao, nada sera alterado.' 'SIM' }
    if (-not $script:EmWinPE) {
        if (-not $script:Sim) { Stop-Reparo 'Esta opcao so altera discos rodando no WinPE/WinRE (unidade X:). Fora dele use a simulacao (T).' }
        Write-Registro 'Fora do WinPE: rodando so a deteccao (simulacao).' 'AVISO'
    }
    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        Stop-Reparo 'Cmdlets de armazenamento ausentes (falta WinPE-StorageWMI). Use a opcao B (versao CMD).'
    }

    Write-Registro '1.1 Verificando firmware' 'PASSO'
    $fw = $null
    try { $fw = (Get-ItemProperty -LiteralPath 'HKLM:\System\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType } catch { $null = $_ }
    if ($fw -eq 2) { Write-Registro 'Firmware UEFI (PEFirmwareType = 2).' 'OK' }
    elseif ($fw -eq 1) {
        Stop-Reparo 'O PC iniciou em modo BIOS/Legacy (PEFirmwareType = 1). Este metodo e so para UEFI. Inicie o pendrive pela entrada "UEFI:".'
    } elseif ($script:EmWinPE) {
        Stop-Reparo 'Nao foi possivel confirmar o tipo de firmware (PEFirmwareType ausente). Abortando por seguranca.'
    } else {
        Write-Registro 'PEFirmwareType so existe no WinPE; ignorado na simulacao.' 'AVISO'
    }

    Write-Registro '1.2 Verificando BitLocker' 'PASSO'
    $bloq = Get-LockedBitLockerVolumes
    if ($null -eq $bloq) {
        Write-Registro 'Nao deu para verificar o BitLocker (sem manage-bde/WMI neste ambiente).' 'AVISO'
        Write-Registro 'Se o Windows nao for encontrado, o disco pode estar criptografado.' 'AVISO'
    } elseif (@($bloq).Count -gt 0) {
        Write-Registro ('Volume(s) BitLocker BLOQUEADO(s): ' + (@($bloq) -join ', ')) 'AVISO'
        Write-Registro 'Pegue a chave de recuperacao (48 digitos) em https://aka.ms/myrecoverykey e rode:' 'AVISO'
        foreach ($b in @($bloq)) { Write-Registro ('    manage-bde -unlock ' + $b + ' -RecoveryPassword <chave de 48 digitos>') 'AVISO' }
        $r = Read-Opcao 'Continuar mesmo assim? (S/N) [N]' @('S', 'N') 'N'
        if ($r -ne 'S') { Stop-Reparo 'Abortado para desbloquear o BitLocker.' 0 }
    } else {
        Write-Registro 'Nenhum volume BitLocker bloqueado.' 'OK'
    }

    Write-Registro '1.3 Procurando a instalacao do Windows' 'PASSO'
    $candidatos = @()
    foreach ($c in [char[]]'CDEFGHIJKLMNOPQRSTUVWYZ') {
        $l = [string]$c
        if (Test-Path -LiteralPath ($l + ':\Windows\System32\winload.efi')) {
            $info = ''
            try { $v = Get-Volume -DriveLetter $l -ErrorAction Stop; $info = ('{0} | {1:N1} GB | rotulo "{2}"' -f $v.FileSystem, ($v.Size / 1GB), $v.FileSystemLabel) } catch { $null = $_ }
            $candidatos += [pscustomobject]@{ Letra = $l; Info = $info }
            Write-Registro ('Encontrado: ' + $l + ':\Windows  ' + $info)
        }
    }
    if ($candidatos.Count -eq 0) {
        Stop-Reparo 'Nenhum Windows encontrado (\Windows\System32\winload.efi). Causas: BitLocker bloqueado, disco sem driver (Intel RST/RAID: use L ou a opcao 2), ou disco errado.'
    }
    if ($candidatos.Count -eq 1) { $win = $candidatos[0].Letra }
    else {
        Write-Registro 'Mais de um Windows encontrado:' 'AVISO'
        for ($i = 0; $i -lt $candidatos.Count; $i++) { Write-Host ('  [{0}] {1}:  {2}' -f ($i + 1), $candidatos[$i].Letra, $candidatos[$i].Info) }
        $nums = @(1..$candidatos.Count | ForEach-Object { [string]$_ })
        $escolha = Read-Opcao 'Numero do Windows a reparar' $nums $null
        $win = $candidatos[[int]$escolha - 1].Letra
    }
    Write-Registro ('Windows escolhido: ' + $win + ':') 'OK'

    Write-Registro '1.4 Identificando disco e particao EFI' 'PASSO'
    try {
        $partWin = Get-Partition -DriveLetter $win -ErrorAction Stop | Select-Object -First 1
        $disk = Get-Disk -Number $partWin.DiskNumber -ErrorAction Stop
    } catch {
        Stop-Reparo ('Nao consegui identificar o disco do volume ' + $win + ': (' + $_.Exception.Message + ')')
    }
    $discoNum = [int]$disk.Number
    $setor = [int]$disk.LogicalSectorSize
    $minEsp = 100
    if ($setor -eq 4096) { $minEsp = 260 }
    Write-Registro ('Disco {0}: {1} | {2:N1} GB | {3} | setor {4} bytes' -f $discoNum, $disk.FriendlyName, ($disk.Size / 1GB), $disk.PartitionStyle, $setor)

    $estilo = Get-EstiloParticao $discoNum $disk
    Write-Registro ('Tabela de particao do disco ' + $discoNum + ': ' + $estilo.Estilo + ' (fonte: ' + $estilo.Fonte + ')')
    if ($estilo.Estilo -eq 'DESCONHECIDO') {
        Stop-Reparo ('Nao consegui confirmar se o disco ' + $discoNum + ' e GPT ou MBR. Confira com "diskpart" > "list disk" (asterisco na coluna Gpt). Nada foi alterado.')
    }
    if ($estilo.Estilo -eq 'MBR') {
        Stop-Reparo ('O disco ' + $discoNum + ' e MBR, nao GPT. Boot UEFI precisa de GPT. Opcao: "mbr2gpt /validate /disk:' + $discoNum + '" e depois "mbr2gpt /convert /disk:' + $discoNum + '" (faca backup antes). Nao foi feito automaticamente.')
    }

    $esps = @(Get-Partition -DiskNumber $discoNum -ErrorAction SilentlyContinue | Where-Object { [string](Get-Prop $_ 'GptType') -eq $script:EspGuid })
    $outrasEsp = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { [string](Get-Prop $_ 'GptType') -eq $script:EspGuid -and $_.DiskNumber -ne $discoNum })
    foreach ($o in $outrasEsp) { Write-Registro ('Obs: existe outra EFI no disco ' + $o.DiskNumber + ' (particao ' + $o.PartitionNumber + '). Ela NAO sera mexida.') 'AVISO' }

    $esp = $null
    $criarEsp = $false
    if ($esps.Count -eq 1) { $esp = $esps[0] }
    elseif ($esps.Count -gt 1) {
        Write-Registro 'Mais de uma particao EFI neste disco:' 'AVISO'
        foreach ($e in $esps) { Write-Host ('  Particao {0}: {1:N0} MB' -f $e.PartitionNumber, ($e.Size / 1MB)) }
        $nums = @($esps | ForEach-Object { [string]$_.PartitionNumber })
        $escolha = Read-Opcao 'Numero da particao EFI a usar' $nums $null
        $esp = $esps | Where-Object { [string]$_.PartitionNumber -eq $escolha } | Select-Object -First 1
    } else {
        Write-Registro ('Nenhuma particao EFI no disco ' + $discoNum + '.') 'AVISO'
        $criarEsp = $true
    }

    $livreMB = 0
    try {
        $usado = (Get-Partition -DiskNumber $discoNum -ErrorAction Stop | Measure-Object -Property Size -Sum).Sum
        $livreMB = [math]::Floor(($disk.Size - $usado) / 1MB) - 2
    } catch { $null = $_ }

    $letra = Get-FreeLetterBoot
    if (-not $letra) { Stop-Reparo 'Nenhuma letra livre para montar a EFI.' }
    $script:TempLetter = $letra
    $encolher = $false
    $modoExec = ''
    $jaTemLetra = $false
    $espMB = 0; $espOffKB = 0

    if ($criarEsp) {
        $modoExec = 'C'
        $tamNovo = $minEsp
        Write-Registro ('Sera preciso CRIAR uma EFI de ' + $tamNovo + ' MB. Espaco nao alocado estimado: ' + $livreMB + ' MB.')
        if ($livreMB -ge ($tamNovo + 1)) {
            Write-Registro 'Ha espaco livre suficiente: a EFI sera criada nele.' 'OK'
        } else {
            Write-Registro ('Sem espaco livre. Opcao: encolher o volume ' + $win + ': em ' + ($tamNovo + 50) + ' MB e criar a EFI no espaco liberado.') 'AVISO'
            Write-Registro 'Encolher NTFS e seguro na maioria dos casos, mas tenha backup. Disco com erros: rode chkdsk antes.' 'AVISO'
            $r = Read-Opcao 'Encolher o Windows para criar a EFI? (S/N) [N]' @('S', 'N') 'N'
            if ($r -ne 'S') { Stop-Reparo 'Abortado: sem espaco para criar a EFI.' 0 }
            $encolher = $true
        }
    } else {
        $espMB = [math]::Floor($esp.Size / 1MB)
        $espOffKB = [math]::Floor($esp.Offset / 1KB)
        $tamNovo = $espMB
        Write-Host ''
        Write-Host '  A = SEGURO   : reformata a EFI existente em FAT32 e recria os arquivos de boot.' -ForegroundColor White
        Write-Host '  B = COMPLETO : apaga a particao EFI (override), cria outra igual, formata e recria o boot.' -ForegroundColor White
        Write-Host '                 Use B so se o A falhar ou a particao estiver danificada.' -ForegroundColor White
        $modoExec = Read-Opcao 'Modo (A/B) [A]' @('A', 'B') 'A'
        if ($modoExec -eq 'B' -and $espMB -lt $minEsp) {
            Stop-Reparo ('A EFI atual tem ' + $espMB + ' MB, menos que o minimo ' + $minEsp + ' MB para este disco. O modo B nao caberia no mesmo lugar. Use o modo A.')
        }
    }

    Write-Registro '1.5 RESUMO - confira com atencao' 'PASSO'
    Write-Registro ('  Disco ........: {0}  ({1}, {2:N1} GB, {3}, setor {4})' -f $discoNum, $disk.FriendlyName, ($disk.Size / 1GB), $estilo.Estilo, $setor)
    Write-Registro ('  Windows ......: {0}:\Windows' -f $win)
    if ($criarEsp) {
        Write-Registro ('  EFI ..........: NAO EXISTE -> criar nova de {0} MB{1}' -f $tamNovo, $(if ($encolher) { ' (encolhendo ' + $win + ':)' } else { ' no espaco livre' }))
    } else {
        Write-Registro ('  EFI ..........: particao {0}, {1} MB, offset {2} KB' -f $esp.PartitionNumber, $espMB, $espOffKB)
    }
    $descModo = switch ($modoExec) { 'A' { 'A - reformatar EFI existente' } 'B' { 'B - apagar e recriar EFI' } default { 'criar EFI nova' } }
    Write-Registro ('  Modo .........: ' + $descModo)
    Write-Registro ('  Letra temp. ..: ' + $letra + ':')
    Write-Registro ('  Comando boot .: bcdboot ' + $win + ':\Windows /f UEFI /s ' + $letra + ': /l pt-BR')
    Write-Registro ('  Backup/log ...: ' + $script:LogDir)
    Write-Host 'ATENCAO: a particao EFI acima sera FORMATADA. Outros sistemas (ex.: Linux) nessa EFI perdem a entrada de boot.' -ForegroundColor Yellow
    if (-not (Confirm-Sim 'Recriar o boot UEFI com os dados acima?')) { Stop-Reparo 'Cancelado pelo usuario. Nada foi alterado.' 0 }

    if (-not $criarEsp) {
        Write-Registro '1.6 Backup do BCD e dos arquivos da EFI' 'PASSO'
        $jaTemLetra = ((Get-Prop $esp 'DriveLetter') -and [int][char]$esp.DriveLetter -ne 0)
        if ($jaTemLetra) {
            $letra = [string]$esp.DriveLetter
            $script:TempLetter = $letra
            Write-Registro ('A EFI ja tem a letra ' + $letra + ':, sera usada.')
        } else {
            $r = Invoke-DiskPart -Nome 'dp-01-montar-efi' -Linhas @("select disk $discoNum", "select partition $($esp.PartitionNumber)", "assign letter=$letra")
            if ($r.Codigo -ne 0) { Write-Registro 'Nao foi possivel montar a EFI para backup (seguindo sem backup dos arquivos).' 'AVISO' }
            elseif (-not $script:Sim) { $script:LetterAssignedByUs = $true }
        }
        if (-not $script:Sim) {
            $bcdOut = & bcdedit.exe /export (Join-Path $script:LogDir 'BCD-export') 2>&1 | Out-String
            Write-Registro ('bcdedit /export: ' + $bcdOut.Trim())
            if (Test-Path -LiteralPath ($letra + ':\')) {
                $dest = Join-Path $script:LogDir 'EFI-backup'
                $xc = & xcopy.exe ($letra + ':\*') ($dest + '\') /E /H /C /I /Y /Q 2>&1 | Out-String
                Write-Registro ('Copia da EFI para ' + $dest + ': ' + $xc.Trim())
            } else { Write-Registro 'EFI ilegivel (provavelmente corrompida); sem copia de arquivos.' 'AVISO' }
        } else { Write-Registro '[SIMULACAO] bcdedit /export e copia da EFI nao executados.' 'SIM' }
    }

    Write-Registro '1.7 Preparando a particao EFI' 'PASSO'
    if ($modoExec -eq 'A') {
        $r = Invoke-DiskPart -Nome 'dp-02-formatar-efi' -Linhas @("select disk $discoNum", "select partition $($esp.PartitionNumber)", 'format quick fs=fat32 label=System override')
        if ($r.Codigo -ne 0) {
            Write-Registro 'diskpart format falhou; tentando format.com...' 'AVISO'
            $null = & cmd.exe /c ('format ' + $letra + ': /FS:FAT32 /Q /V:System /Y') 2>&1
            if ($LASTEXITCODE -ne 0) { Stop-Reparo 'Falha ao formatar a EFI. Tente o modo B.' }
        }
        if (-not $script:LetterAssignedByUs -and -not $jaTemLetra -and -not $script:Sim) {
            $r = Invoke-DiskPart -Nome 'dp-03-montar-efi' -Linhas @("select disk $discoNum", "select partition $($esp.PartitionNumber)", "assign letter=$letra")
            if ($r.Codigo -ne 0) { Stop-Reparo 'Nao foi possivel atribuir letra a EFI.' }
            $script:LetterAssignedByUs = $true
        }
    } elseif ($modoExec -eq 'B') {
        if ($script:LetterAssignedByUs) { Remove-TempLetter }
        $linhas = @("select disk $discoNum", "select partition $($esp.PartitionNumber)", 'delete partition override',
            "create partition efi size=$tamNovo offset=$espOffKB", 'format quick fs=fat32 label=System', "assign letter=$letra")
        $r = Invoke-DiskPart -Nome 'dp-02-recriar-efi' -Linhas $linhas
        if ($r.Codigo -ne 0) {
            Write-Registro 'Falhou. Tentando criar com 1 MB a menos (arredondamento)...' 'AVISO'
            $r = Invoke-DiskPart -Nome 'dp-03-criar-efi-retry' -Linhas @("select disk $discoNum", "create partition efi size=$($tamNovo - 1) offset=$espOffKB", 'format quick fs=fat32 label=System', "assign letter=$letra")
            if ($r.Codigo -ne 0) {
                Stop-Reparo ('A EFI foi APAGADA e nao foi recriada. Faca manualmente no diskpart: select disk ' + $discoNum + ' / create partition efi size=' + $minEsp + ' / format quick fs=fat32 label=System / assign letter=' + $letra + ' e depois rode bcdboot.')
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
        if ($r.Codigo -ne 0) { Stop-Reparo 'Falha ao criar a particao EFI. Veja o log.' }
        if (-not $script:Sim) { $script:LetterAssignedByUs = $true }
    }
    if (-not $script:Sim -and -not (Test-Path -LiteralPath ($letra + ':\'))) { Stop-Reparo ('A EFI nao ficou acessivel em ' + $letra + ':') }

    Write-Registro '1.8 Gerando os arquivos de boot (bcdboot)' 'PASSO'
    $argsBcd = @(($win + ':\Windows'), '/f', 'UEFI', '/s', ($letra + ':'), '/l', 'pt-BR')
    if ($script:Sim) {
        Write-Registro ('[SIMULACAO] bcdboot ' + ($argsBcd -join ' ')) 'SIM'
    } else {
        Write-Registro ('> bcdboot ' + ($argsBcd -join ' '))
        $o = & bcdboot.exe @argsBcd 2>&1 | Out-String
        Write-Registro $o.Trim()
        if ($LASTEXITCODE -ne 0) {
            Write-Registro 'Falhou com /l pt-BR; tentando sem o idioma...' 'AVISO'
            $o = & bcdboot.exe ($win + ':\Windows') /f UEFI /s ($letra + ':') 2>&1 | Out-String
            Write-Registro $o.Trim()
            if ($LASTEXITCODE -ne 0) { Stop-Reparo 'bcdboot falhou. Veja o log.' }
        }
        $ok1 = Test-Path -LiteralPath ($letra + ':\EFI\Microsoft\Boot\bootmgfw.efi')
        $ok2 = Test-Path -LiteralPath ($letra + ':\EFI\Microsoft\Boot\BCD')
        Write-Registro ('Verificacao: bootmgfw.efi=' + $ok1 + '  BCD=' + $ok2) $(if ($ok1 -and $ok2) { 'OK' } else { 'ERRO' })
        if (-not ($ok1 -and $ok2)) { Stop-Reparo 'Arquivos de boot nao encontrados apos o bcdboot.' }
        if (Test-Exe 'bootrec.exe') {
            if ((Read-Opcao 'Rodar bootrec /rebuildbcd tambem (opcional, redundante)? (S/N) [N]' @('S', 'N') 'N') -eq 'S') {
                $o = & cmd.exe /c 'echo n| bootrec /rebuildbcd' 2>&1 | Out-String
                Write-Registro ('bootrec: ' + $o.Trim())
            }
        } else { Write-Registro 'bootrec nao existe neste ambiente (normal no WinPE puro): bcdboot ja basta.' }
    }
    Remove-TempLetter
    if ($script:Sim) { Write-Registro 'SIMULACAO concluida. Nada foi alterado.' 'OK' }
    else { Write-Registro 'Boot UEFI recriado. Remova o pendrive e reinicie (opcao R do menu).' 'OK' }
    Write-Registro ('Log e backup em: ' + $script:LogDir)
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
            default { Write-Host 'Opcao invalida.' }
        }
    } catch {
        $linha = ''
        try { $linha = ' (linha ' + $_.InvocationInfo.ScriptLineNumber + ')' } catch { $null = $_ }
        Write-Registro ('Erro inesperado na ferramenta ' + $Numero + ': ' + $_.Exception.Message + $linha) 'ERRO'
    } finally {
        foreach ($h in @($script:Hives.ToArray())) { Dismount-Hive $h }
        Dismount-Esp
    }
}

function Find-ReparoCmd {
    foreach ($c in @((Get-Caminho $script:RB 'scripts\reparar-boot-uefi.cmd'), (Get-Caminho $script:Aqui 'reparar-boot-uefi.cmd'))) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Invoke-ReparoCmd {
    Write-Registro 'B. Reparo de boot UEFI usando a versao CMD' 'PASSO'
    $c = Find-ReparoCmd
    if (-not $c) { Write-Registro ('reparar-boot-uefi.cmd nao encontrado em ' + (Get-Caminho $script:RB 'scripts')) 'ERRO'; return }
    $a = @('/c', $c); if ($script:Sim) { $a += '/simular' }
    Add-Log ('EXEC: cmd.exe ' + ($a -join ' '))
    & cmd.exe @a
}

function Invoke-Drvload {
    Write-Registro 'L. Carregar driver de disco na hora (drvload .inf)' 'PASSO'
    $pasta = Get-Caminho $script:RB 'drivers'
    if (Test-Path -LiteralPath $pasta) {
        $infs = @(Get-ChildItem -LiteralPath $pasta -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
        if ($infs.Count -gt 0) { Write-Host ('Drivers encontrados em ' + $pasta + ':'); foreach ($i in $infs) { Write-Host ('  ' + $i.FullName) } }
    }
    $inf = (Read-Linha 'Caminho completo do .inf (ENTER cancela)').Trim('"')
    if (-not $inf) { return }
    if (-not (Test-Path -LiteralPath $inf)) { Write-Registro ('Arquivo nao encontrado: ' + $inf) 'ERRO'; return }
    $r = Invoke-Destrutivo 'drvload.exe' @($inf)
    if (-not $r.Simulado) { if ($r.Codigo -eq 0) { Write-Registro 'Driver carregado. Os discos novos ja devem aparecer.' 'OK' } else { Write-Registro ('drvload terminou com codigo ' + $r.Codigo) 'ERRO' } }
}

function Invoke-Avancado {
    Write-Registro 'A. Modo avancado (shell interativo)' 'PASSO'
    $env:REPARO_RB = $script:RB
    $env:REPARO_SIMULAR = $(if ($script:Sim) { '1' } else { '0' })
    Write-Host '--------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ' MODO AVANCADO - cuidado: aqui NADA pede SIM nem respeita simulacao' -ForegroundColor Yellow
    Write-Host (' Pasta do kit: ' + $script:RB + '   variaveis: REPARO_RB, REPARO_SIMULAR')
    Write-Host ' Digite exit para voltar ao menu.'
    Write-Host '--------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host '   1 - Prompt de comando (padrao)'
    Write-Host '   2 - PowerShell'
    $av = Read-Linha 'Escolha [1]'
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
    $txt = $(if ($Acao -eq 'reboot') { 'REINICIAR' } else { 'DESLIGAR' })
    if (-not (Read-SimNao ($txt + ' o computador agora?') 'N')) { return }
    if (Test-Exe 'wpeutil.exe') { & wpeutil.exe $Acao; return }
    if ($script:EhWindows -and -not $script:EmWinPE) {
        Write-Registro 'wpeutil so existe no WinPE. Neste Windows use: shutdown /r /t 0 (reiniciar) ou shutdown /s /t 0 (desligar).' 'AVISO'
        return
    }
    Write-Registro 'wpeutil nao encontrado.' 'ERRO'
}

function Show-Cabecalho {
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor Cyan
    Write-Host '              REPARO DO WINDOWS - MENU DO WinPE (PowerShell)' -ForegroundColor Cyan
    Write-Host ('  ambiente: ' + (Get-DescAmbiente)) -ForegroundColor Cyan
    Write-Host ('  simulacao: ' + $(if ($script:Sim) { 'LIGADA - nada sera alterado' } else { 'desligada' })) -ForegroundColor $(if ($script:Sim) { 'Magenta' } else { 'Cyan' })
    Write-Host ('  log: ' + $script:LogDir) -ForegroundColor Cyan
    Write-Host '==============================================================' -ForegroundColor Cyan
}

function Show-Menu {
    for ($voltas = 0; $voltas -lt 1000; $voltas++) {
        Show-Cabecalho
        Write-Host '   1  Reparo de boot UEFI'
        Write-Host '   2  Injecao de drivers Intel RST (deteccao automatica)'
        Write-Host '   3  Reconstrucao do BCD (bootrec automatizado)'
        Write-Host '   4  SFC e DISM em sequencia com log'
        Write-Host '   5  Extracao de perfil (AppData e favoritos)'
        Write-Host '   6  Exportacao de impressoras'
        Write-Host '   7  Varredura da raiz do C (pastas nao padrao)'
        Write-Host '   8  Event Log (opcional)'
        Write-Host '   9  Backup dos hives do registro'
        Write-Host '  10  Verificador de integridade de arquivos (offline)'
        Write-Host '  11  Verificador S.M.A.R.T. (opcional)'
        Write-Host '  12  Drivers de storage para Windows 7'
        Write-Host '   B  Reparo de boot UEFI usando a versao CMD'
        Write-Host '   L  Carregar driver de disco na hora (drvload .inf)'
        Write-Host '   A  Modo avancado (prompt de comando ou PowerShell)'
        Write-Host '   T  Ligar/desligar simulacao'
        Write-Host '   R  Reiniciar'
        Write-Host '   D  Desligar'
        Write-Host '   0  Sair para o prompt (S tambem sai)'
        Write-Host '==============================================================' -ForegroundColor Cyan
        $op = ((Read-Linha 'Opcao') -replace '[\s"]', '').ToUpperInvariant()
        if (-not $op) {
            if ([Console]::IsInputRedirected) { return }
            continue
        }
        if ($op -eq '0' -or $op -eq 'S') { Write-Host 'Saindo do menu. Para voltar, digite: winpe_reparo_pt'; return }
        $n = 0
        if ([int]::TryParse($op, [ref]$n) -and $n -ge 1 -and $n -le 12) { Invoke-Ferramenta $n; Wait-Enter; continue }
        switch ($op) {
            'T' { $script:Sim = -not $script:Sim; Write-Registro ('Simulacao agora: ' + $(if ($script:Sim) { 'LIGADA' } else { 'desligada' })) }
            'B' { try { Invoke-ReparoCmd } catch { Write-Registro $_.Exception.Message 'ERRO' }; Wait-Enter }
            'L' { try { Invoke-Drvload } catch { Write-Registro $_.Exception.Message 'ERRO' }; Wait-Enter }
            'A' { try { Invoke-Avancado } catch { Write-Registro $_.Exception.Message 'ERRO' } }
            'R' { Invoke-Wpeutil 'reboot' }
            'D' { Invoke-Wpeutil 'shutdown' }
            default { Write-Host 'Opcao invalida: digite 0 a 12, B, L, A, T, R ou D.' }
        }
    }
}

# ================================================================== INICIO
Initialize-Ambiente
try {
    Initialize-Log
} catch {
    Write-Host ('ERRO: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
Write-Registro ('Inicio. ambiente=' + (Get-DescAmbiente) + ' Simular=' + $script:Sim + ' Ferramenta=' + $Ferramenta + ' RB=' + $script:RB)
if ($script:EhWindows -and -not $script:EmWinPE -and -not (Test-Admin)) {
    Write-Registro 'Sem privilegio de ADMINISTRADOR: dism/sfc/reg load/bcdedit vao falhar. Abra o PowerShell como administrador.' 'AVISO'
}
try {
    if ($Ferramenta -gt 0) {
        Show-Cabecalho
        Invoke-Ferramenta $Ferramenta
        Write-Registro ('Log: ' + $script:LogDir)
        if (-not [Console]::IsInputRedirected) { $null = Read-Linha 'Pressione ENTER para sair' }
    } else {
        Show-Menu
    }
} finally {
    foreach ($h in @($script:Hives.ToArray())) { Dismount-Hive $h }
    Dismount-Esp
    Write-Registro ('Fim. Logs em ' + $script:LogDir)
    if ($script:Transcricao) { try { Stop-Transcript | Out-Null } catch { $null = $_ } }
}
exit 0
