#Requires -Version 5.1
<#
    Espelhar Celular - espelhamento da tela do Android no PC com baixa latencia.
    Portatil: nao precisa de administrador nem de instalacao.
    Motor: scrcpy (https://github.com/Genymobile/scrcpy), baixado automaticamente
    para a pasta .\scrcpy ao lado deste script.
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$script:Root          = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ToolsDir      = Join-Path $script:Root 'scrcpy'
$script:LogsDir       = Join-Path $script:Root 'logs'
$script:ConfigPath    = Join-Path $script:Root 'config.json'
$script:FallbackVer   = 'v3.3.1'
$script:Scrcpy        = $null
$script:Adb           = $null
$script:LogFile       = $null
$script:LogPos        = 0
$script:MirrorProc    = $null

# ---------------------------------------------------------------- utilidades

class DeviceItem {
    [string]$Serial; [string]$State; [string]$Label
    DeviceItem([string]$s, [string]$st, [string]$l) { $this.Serial = $s; $this.State = $st; $this.Label = $l }
    [string] ToString() { return $this.Label }
}

function Write-Log([string]$Text) {
    if (-not $script:TxtLog) { return }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim().Length -eq 0) { continue }
        $script:TxtLog.AppendText("[$stamp] $line`r`n")
    }
}

function Wait-UI([int]$Ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
}

function Find-Tools {
    $exe = Get-ChildItem -Path $script:ToolsDir -Recurse -Filter 'scrcpy.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) {
        $script:Scrcpy = $exe.FullName
        $script:Adb    = Join-Path $exe.DirectoryName 'adb.exe'
        return (Test-Path $script:Adb)
    }
    return $false
}

function Install-Scrcpy {
    Write-Log 'Baixando o scrcpy (so na primeira vez)...'
    $url = $null
    try {
        $rel = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/Genymobile/scrcpy/releases/latest' -Headers @{ 'User-Agent' = 'EspelharCelular' }
        $asset = $rel.assets | Where-Object { $_.name -like 'scrcpy-win64-*.zip' } | Select-Object -First 1
        if ($asset) { $url = $asset.browser_download_url; Write-Log "Versao encontrada: $($rel.tag_name)" }
    } catch {
        Write-Log "Nao consegui consultar a ultima versao, usando $($script:FallbackVer)."
    }
    if (-not $url) {
        $v = $script:FallbackVer
        $url = "https://github.com/Genymobile/scrcpy/releases/download/$v/scrcpy-win64-$v.zip"
    }
    $zip = Join-Path $env:TEMP ('scrcpy-win64-' + [Guid]::NewGuid().ToString('N') + '.zip')
    Write-Log "Download: $url"
    Wait-UI 50
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    if (Test-Path $script:ToolsDir) { Remove-Item $script:ToolsDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $script:ToolsDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $script:ToolsDir -Recurse | Unblock-File -ErrorAction SilentlyContinue
    if (-not (Find-Tools)) { throw 'O pacote baixado nao contem scrcpy.exe/adb.exe.' }
    Write-Log 'scrcpy pronto.'
}

# Executa o adb sem travar (o servidor do adb herda os pipes, por isso o timeout nas leituras).
function Invoke-Adb([string]$Arguments, [int]$TimeoutMs = 15000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $script:Adb
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    if (-not $p.HasExited) {
        try { $p.Kill() } catch { }
        return "(tempo esgotado: adb $Arguments)"
    }
    $text = ''
    if ($tOut.Wait(1500)) { $text += $tOut.Result }
    if ($tErr.Wait(500))  { $text += $tErr.Result }
    return $text.Trim()
}

function Start-AdbServer {
    $p = Start-Process -FilePath $script:Adb -ArgumentList 'start-server' -WindowStyle Hidden -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.ElapsedMilliseconds -lt 15000) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}

function Get-SelectedSerial {
    $item = $script:CmbDevice.SelectedItem
    if ($item -and $item.Serial) { return $item.Serial }
    return $null
}

function Update-Devices {
    $previous = Get-SelectedSerial
    $script:CmbDevice.Items.Clear()
    $out = Invoke-Adb 'devices'
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline)\s*$') {
            $serial = $Matches[1]; $state = $Matches[2]
            $label = $serial
            if ($state -eq 'device') {
                $model = Invoke-Adb "-s $serial shell getprop ro.product.model" 5000
                if ($model -and $model -notmatch 'error|tempo') { $label = "$model  ($serial)" }
            } elseif ($state -eq 'unauthorized') {
                $label = "$serial  - aceite a autorizacao no celular!"
            } else {
                $label = "$serial  - offline"
            }
            [void]$script:CmbDevice.Items.Add([DeviceItem]::new($serial, $state, $label))
        }
    }
    if ($script:CmbDevice.Items.Count -eq 0) {
        Write-Log 'Nenhum celular encontrado. Ligue a Depuracao USB e conecte o cabo (ou use o Wi-Fi).'
        return
    }
    $idx = 0
    for ($i = 0; $i -lt $script:CmbDevice.Items.Count; $i++) {
        if ($script:CmbDevice.Items[$i].Serial -eq $previous) { $idx = $i }
    }
    $script:CmbDevice.SelectedIndex = $idx
    Write-Log "$($script:CmbDevice.Items.Count) dispositivo(s) encontrado(s)."
}

function Get-PhoneIp([string]$Serial) {
    $route = Invoke-Adb "-s $Serial shell ip route" 5000
    foreach ($line in ($route -split "`r?`n")) {
        if ($line -match 'wlan' -and $line -match 'src\s+(\d{1,3}(\.\d{1,3}){3})') { return $Matches[1] }
    }
    $addr = Invoke-Adb "-s $Serial shell ip -f inet addr show wlan0" 5000
    if ($addr -match 'inet\s+(\d{1,3}(\.\d{1,3}){3})') { return $Matches[1] }
    return $null
}

# ---------------------------------------------------------------- configuracao

$script:Defaults = [ordered]@{
    Preset = 'Latencia minima'; MaxSize = '1280'; BitRate = 8; MaxFps = 60; Codec = 'h264'
    Audio = $false; StayAwake = $true; ScreenOff = $false; OnTop = $false; Touches = $false
    NoControl = $false; Record = $false; Fullscreen = $false; WifiAddr = ''; PairAddr = ''
}

function Load-Config {
    $cfg = [ordered]@{}
    foreach ($k in $script:Defaults.Keys) { $cfg[$k] = $script:Defaults[$k] }
    if (Test-Path $script:ConfigPath) {
        try {
            $j = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) { if ($null -ne $j.$k) { $cfg[$k] = $j.$k } }
        } catch { }
    }
    return $cfg
}

function Save-Config {
    $cfg = [ordered]@{
        Preset = [string]$script:CmbPreset.SelectedItem; MaxSize = [string]$script:CmbSize.SelectedItem
        BitRate = [int]$script:NumBitRate.Value; MaxFps = [int]$script:NumFps.Value; Codec = [string]$script:CmbCodec.SelectedItem
        Audio = $script:ChkAudio.Checked; StayAwake = $script:ChkAwake.Checked; ScreenOff = $script:ChkScreenOff.Checked
        OnTop = $script:ChkOnTop.Checked; Touches = $script:ChkTouches.Checked; NoControl = $script:ChkNoControl.Checked
        Record = $script:ChkRecord.Checked; Fullscreen = $script:ChkFull.Checked
        WifiAddr = $script:TxtWifi.Text; PairAddr = $script:TxtPairAddr.Text
    }
    try { $cfg | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- espelhamento

function Build-ScrcpyArgs {
    $a = New-Object System.Collections.Generic.List[string]
    $serial = Get-SelectedSerial
    if ($serial) { $a.Add("--serial=$serial") }
    $size = [string]$script:CmbSize.SelectedItem
    if ($size -and $size -ne 'Original') { $a.Add("--max-size=$size") }
    $a.Add("--video-bit-rate=$([int]$script:NumBitRate.Value)M")
    if ([int]$script:NumFps.Value -gt 0) { $a.Add("--max-fps=$([int]$script:NumFps.Value)") }
    $a.Add("--video-codec=$($script:CmbCodec.SelectedItem)")
    $a.Add('--video-buffer=0')
    if ($script:ChkAudio.Checked) { $a.Add('--audio-buffer=40') } else { $a.Add('--no-audio') }
    if ($script:ChkAwake.Checked)     { $a.Add('--stay-awake') }
    if ($script:ChkScreenOff.Checked) { $a.Add('--turn-screen-off') }
    if ($script:ChkOnTop.Checked)     { $a.Add('--always-on-top') }
    if ($script:ChkTouches.Checked)   { $a.Add('--show-touches') }
    if ($script:ChkNoControl.Checked) { $a.Add('--no-control') }
    if ($script:ChkFull.Checked)      { $a.Add('--fullscreen') }
    if ($script:ChkRecord.Checked) {
        $videos = [Environment]::GetFolderPath('MyVideos')
        $file = Join-Path $videos ('Celular_' + (Get-Date).ToString('yyyyMMdd_HHmmss') + '.mp4')
        $a.Add("--record=`"$file`"")
        Write-Log "Gravando em: $file"
    }
    $a.Add('--window-title="Espelhar Celular"')
    return ($a -join ' ')
}

function Start-Mirror {
    $item = $script:CmbDevice.SelectedItem
    if (-not $item) {
        Update-Devices
        $item = $script:CmbDevice.SelectedItem
        if (-not $item) { return }
    }
    if ($item.State -ne 'device') {
        Write-Log 'O dispositivo selecionado nao esta pronto (autorize no celular e clique em Atualizar).'
        return
    }
    Save-Config
    $argLine = Build-ScrcpyArgs
    if (-not (Test-Path $script:LogsDir)) { New-Item -ItemType Directory -Path $script:LogsDir | Out-Null }
    $script:LogFile = Join-Path $script:LogsDir 'scrcpy.log'
    Set-Content -Path $script:LogFile -Value '' -Encoding ASCII
    $script:LogPos = 0

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName         = $env:ComSpec
    $psi.Arguments        = "/c `"`"$($script:Scrcpy)`" $argLine > `"$($script:LogFile)`" 2>&1`""
    $psi.WorkingDirectory = Split-Path $script:Scrcpy
    $psi.UseShellExecute  = $false
    $psi.CreateNoWindow   = $true
    Write-Log "scrcpy $argLine"
    $script:MirrorProc = [System.Diagnostics.Process]::Start($psi)
    $script:LogTimer.Start()
}

function Read-MirrorLog {
    if (-not $script:LogFile -or -not (Test-Path $script:LogFile)) { return }
    try {
        $fs = [System.IO.File]::Open($script:LogFile, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -gt $script:LogPos) {
                [void]$fs.Seek($script:LogPos, 'Begin')
                $buf = New-Object byte[] ($fs.Length - $script:LogPos)
                $n = $fs.Read($buf, 0, $buf.Length)
                $script:LogPos += $n
                Write-Log ([Text.Encoding]::UTF8.GetString($buf, 0, $n))
            }
        } finally { $fs.Close() }
    } catch { }
    if ($script:MirrorProc -and $script:MirrorProc.HasExited) {
        $script:MirrorProc = $null
        $script:LogTimer.Stop()
        Write-Log 'Espelhamento encerrado.'
    }
}

function Apply-Preset([string]$Name) {
    switch ($Name) {
        'Latencia minima'  { $script:CmbSize.SelectedItem = '1280'; $script:NumBitRate.Value = 8;  $script:NumFps.Value = 60; $script:CmbCodec.SelectedItem = 'h264' }
        'Equilibrado'      { $script:CmbSize.SelectedItem = '1600'; $script:NumBitRate.Value = 12; $script:NumFps.Value = 60; $script:CmbCodec.SelectedItem = 'h264' }
        'Qualidade maxima' { $script:CmbSize.SelectedItem = 'Original'; $script:NumBitRate.Value = 24; $script:NumFps.Value = 0; $script:CmbCodec.SelectedItem = 'h265' }
        'Wi-Fi fraco'      { $script:CmbSize.SelectedItem = '1024'; $script:NumBitRate.Value = 4;  $script:NumFps.Value = 30; $script:CmbCodec.SelectedItem = 'h264' }
    }
}

# ---------------------------------------------------------------- interface

$cfg = Load-Config
$font = New-Object System.Drawing.Font('Segoe UI', 9)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Espelhar Celular'
$form.ClientSize = New-Object System.Drawing.Size(560, 690)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $font

function New-Ctl($Type, $Parent, $X, $Y, $W, $H, $Text) {
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    if ($null -ne $Text) { $c.Text = $Text }
    $Parent.Controls.Add($c)
    return $c
}

# Dispositivo
$grpDev = New-Ctl GroupBox $form 10 8 540 60 'Celular'
$script:CmbDevice = New-Ctl ComboBox $grpDev 12 24 400 24 $null
$script:CmbDevice.DropDownStyle = 'DropDownList'
$btnRefresh = New-Ctl Button $grpDev 420 22 108 27 'Atualizar'

# Wi-Fi
$grpWifi = New-Ctl GroupBox $form 10 74 540 150 'Sem fio (Wi-Fi) - celular e PC na mesma rede'
$btnWifiUsb = New-Ctl Button $grpWifi 12 22 516 28 'Ativar Wi-Fi usando o cabo USB (depois pode tirar o cabo)'
[void](New-Ctl Label $grpWifi 12 62 80 20 'IP:porta')
$script:TxtWifi = New-Ctl TextBox $grpWifi 95 59 317 24 $cfg.WifiAddr
$btnWifiConnect = New-Ctl Button $grpWifi 420 57 108 27 'Conectar'
[void](New-Ctl Label $grpWifi 12 98 80 20 'Parear')
$script:TxtPairAddr = New-Ctl TextBox $grpWifi 95 95 180 24 $cfg.PairAddr
[void](New-Ctl Label $grpWifi 282 98 48 20 'Codigo')
$script:TxtPairCode = New-Ctl TextBox $grpWifi 332 95 80 24 ''
$btnPair = New-Ctl Button $grpWifi 420 93 108 27 'Parear'
$lblPair = New-Ctl Label $grpWifi 12 124 516 20 'Android 11+: Depuracao por Wi-Fi > Parear com codigo. Depois use o IP:porta da tela principal em "Conectar".'
$lblPair.ForeColor = [System.Drawing.Color]::DimGray

# Qualidade
$grpQ = New-Ctl GroupBox $form 10 230 540 200 'Imagem e opcoes'
[void](New-Ctl Label $grpQ 12 27 80 20 'Perfil')
$script:CmbPreset = New-Ctl ComboBox $grpQ 95 24 180 24 $null
$script:CmbPreset.DropDownStyle = 'DropDownList'
[void]$script:CmbPreset.Items.AddRange(@('Latencia minima', 'Equilibrado', 'Qualidade maxima', 'Wi-Fi fraco', 'Personalizado'))
[void](New-Ctl Label $grpQ 290 27 90 20 'Resolucao max.')
$script:CmbSize = New-Ctl ComboBox $grpQ 390 24 138 24 $null
$script:CmbSize.DropDownStyle = 'DropDownList'
[void]$script:CmbSize.Items.AddRange(@('Original', '1920', '1600', '1280', '1024', '800'))
[void](New-Ctl Label $grpQ 12 60 80 20 'Mbps')
$script:NumBitRate = New-Ctl NumericUpDown $grpQ 95 57 70 24 $null
$script:NumBitRate.Minimum = 1; $script:NumBitRate.Maximum = 100
[void](New-Ctl Label $grpQ 175 60 100 20 'FPS (0=livre)')
$script:NumFps = New-Ctl NumericUpDown $grpQ 280 57 60 24 $null
$script:NumFps.Minimum = 0; $script:NumFps.Maximum = 240
[void](New-Ctl Label $grpQ 350 60 40 20 'Codec')
$script:CmbCodec = New-Ctl ComboBox $grpQ 390 57 138 24 $null
$script:CmbCodec.DropDownStyle = 'DropDownList'
[void]$script:CmbCodec.Items.AddRange(@('h264', 'h265', 'av1'))

$script:ChkAudio     = New-Ctl CheckBox $grpQ 12  95 250 22 'Transmitir audio (Android 11+)'
$script:ChkAwake     = New-Ctl CheckBox $grpQ 280 95 250 22 'Manter celular acordado'
$script:ChkScreenOff = New-Ctl CheckBox $grpQ 12  120 250 22 'Apagar a tela do celular'
$script:ChkOnTop     = New-Ctl CheckBox $grpQ 280 120 250 22 'Janela sempre no topo'
$script:ChkTouches   = New-Ctl CheckBox $grpQ 12  145 250 22 'Mostrar toques'
$script:ChkNoControl = New-Ctl CheckBox $grpQ 280 145 250 22 'So visualizar (sem mouse/teclado)'
$script:ChkRecord    = New-Ctl CheckBox $grpQ 12  170 250 22 'Gravar video (pasta Videos)'
$script:ChkFull      = New-Ctl CheckBox $grpQ 280 170 250 22 'Tela cheia'

# Botao principal
$btnStart = New-Ctl Button $form 10 438 540 46 'ESPELHAR TELA'
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)

# Log
$script:TxtLog = New-Ctl TextBox $form 10 492 540 188 $null
$script:TxtLog.Multiline = $true
$script:TxtLog.ScrollBars = 'Vertical'
$script:TxtLog.ReadOnly = $true
$script:TxtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)

# Valores iniciais
$script:CmbSize.SelectedItem = [string]$cfg.MaxSize
if ($script:CmbSize.SelectedIndex -lt 0) { $script:CmbSize.SelectedItem = '1280' }
$script:NumBitRate.Value = [Math]::Max(1, [Math]::Min(100, [int]$cfg.BitRate))
$script:NumFps.Value     = [Math]::Max(0, [Math]::Min(240, [int]$cfg.MaxFps))
$script:CmbCodec.SelectedItem = [string]$cfg.Codec
if ($script:CmbCodec.SelectedIndex -lt 0) { $script:CmbCodec.SelectedItem = 'h264' }
$script:ChkAudio.Checked     = [bool]$cfg.Audio
$script:ChkAwake.Checked     = [bool]$cfg.StayAwake
$script:ChkScreenOff.Checked = [bool]$cfg.ScreenOff
$script:ChkOnTop.Checked     = [bool]$cfg.OnTop
$script:ChkTouches.Checked   = [bool]$cfg.Touches
$script:ChkNoControl.Checked = [bool]$cfg.NoControl
$script:ChkRecord.Checked    = [bool]$cfg.Record
$script:ChkFull.Checked      = [bool]$cfg.Fullscreen
$script:LoadingPreset = $true
$script:CmbPreset.SelectedItem = [string]$cfg.Preset
if ($script:CmbPreset.SelectedIndex -lt 0) { $script:CmbPreset.SelectedItem = 'Personalizado' }
$script:LoadingPreset = $false

# Timer que mostra a saida do scrcpy no log
$script:LogTimer = New-Object System.Windows.Forms.Timer
$script:LogTimer.Interval = 400
$script:LogTimer.Add_Tick({ Read-MirrorLog })

# ---------------------------------------------------------------- eventos

$script:CmbPreset.Add_SelectedIndexChanged({
    if ($script:LoadingPreset) { return }
    $script:LoadingPreset = $true
    Apply-Preset ([string]$script:CmbPreset.SelectedItem)
    $script:LoadingPreset = $false
})
$markCustom = {
    if ($script:LoadingPreset) { return }
    $script:LoadingPreset = $true
    $script:CmbPreset.SelectedItem = 'Personalizado'
    $script:LoadingPreset = $false
}
$script:CmbSize.Add_SelectedIndexChanged($markCustom)
$script:CmbCodec.Add_SelectedIndexChanged($markCustom)
$script:NumBitRate.Add_ValueChanged($markCustom)
$script:NumFps.Add_ValueChanged($markCustom)

$guard = {
    param([scriptblock]$Action)
    $form.UseWaitCursor = $true
    try { & $Action } catch { Write-Log "Erro: $($_.Exception.Message)" } finally { $form.UseWaitCursor = $false }
}

$btnRefresh.Add_Click({ & $guard { Update-Devices } })

$btnWifiUsb.Add_Click({ & $guard {
    $serial = Get-SelectedSerial
    if (-not $serial -or $serial -match ':') { Write-Log 'Selecione o celular conectado pelo CABO USB primeiro.'; return }
    $ip = Get-PhoneIp $serial
    if (-not $ip) { Write-Log 'Nao achei o IP do celular. O Wi-Fi do celular esta ligado?'; return }
    Write-Log "IP do celular: $ip"
    Write-Log (Invoke-Adb "-s $serial tcpip 5555")
    Wait-UI 2500
    Write-Log (Invoke-Adb "connect ${ip}:5555")
    $script:TxtWifi.Text = "${ip}:5555"
    Save-Config
    Update-Devices
    Write-Log 'Pronto! Ja pode tirar o cabo e escolher o dispositivo com IP na lista.'
} })

$btnWifiConnect.Add_Click({ & $guard {
    $addr = $script:TxtWifi.Text.Trim()
    if (-not $addr) { Write-Log 'Digite o IP:porta do celular (ex.: 192.168.0.15:5555).'; return }
    if ($addr -notmatch ':\d+$') { $addr = "${addr}:5555"; $script:TxtWifi.Text = $addr }
    Write-Log (Invoke-Adb "connect $addr" 12000)
    Save-Config
    Update-Devices
} })

$btnPair.Add_Click({ & $guard {
    $addr = $script:TxtPairAddr.Text.Trim(); $code = $script:TxtPairCode.Text.Trim()
    if (-not $addr -or -not $code) { Write-Log 'Preencha o IP:porta de pareamento e o codigo de 6 digitos mostrados no celular.'; return }
    Write-Log (Invoke-Adb "pair $addr $code" 20000)
    Write-Log 'Agora digite em IP:porta o endereco mostrado na tela "Depuracao por Wi-Fi" e clique em Conectar.'
    Save-Config
} })

$btnStart.Add_Click({ & $guard { Start-Mirror } })

$form.Add_FormClosing({ Save-Config })

$form.Add_Shown({ & $guard {
    if (-not (Find-Tools)) { Install-Scrcpy }
    Write-Log "Usando: $($script:Scrcpy)"
    Start-AdbServer
    Update-Devices
    if ($script:CmbDevice.Items.Count -eq 0 -and $script:TxtWifi.Text) {
        Write-Log "Tentando reconectar via Wi-Fi em $($script:TxtWifi.Text)..."
        Write-Log (Invoke-Adb "connect $($script:TxtWifi.Text)" 6000)
        Update-Devices
    }
} })

[void]$form.ShowDialog()
