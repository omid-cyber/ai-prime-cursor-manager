param(
    [ValidateSet('Start')][string]$Mode = 'Start',
    [int]$Port = 8787,
    [string]$AppDataDir = (Join-Path $env:LOCALAPPDATA 'AIPrimeCursorBridge')
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$tools = Join-Path $AppDataDir 'tools'
$exe = Join-Path $tools 'cloudflared.exe'
$statePath = Join-Path $AppDataDir 'tunnel-state.json'
$stdoutPath = Join-Path $AppDataDir 'cloudflared.stdout.log'
$stderrPath = Join-Path $AppDataDir 'cloudflared.stderr.log'
New-Item -ItemType Directory -Force -Path $AppDataDir, $tools | Out-Null

function Write-State(
    [string]$Status,
    [int]$ProcessId = 0,
    [string]$Url = '',
    [string]$ErrorText = '',
    [int]$Progress = -1,
    [long]$BytesDownloaded = 0,
    [long]$BytesTotal = 0
) {
    $state = [ordered]@{
        status = $Status
        processId = $ProcessId
        publicUrl = $Url
        port = $Port
        error = $ErrorText
        progress = $Progress
        bytesDownloaded = $BytesDownloaded
        bytesTotal = $BytesTotal
        updatedAt = (Get-Date).ToString('o')
    }
    $tmp = "$statePath.tmp"
    [System.IO.File]::WriteAllText($tmp, ($state | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $statePath -Force
}

function Download-CloudflaredWithProgress([string]$Uri, [string]$Destination) {
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'AIPrimeCursorManager/1.7'
    $request.Timeout = 180000
    $request.ReadWriteTimeout = 30000
    $response = $null
    $inputStream = $null
    $outputStream = $null
    $received = [long]0
    $total = [long]0
    $lastUpdate = Get-Date
    try {
        $response = $request.GetResponse()
        $total = [long]$response.ContentLength
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] (64 * 1024)
        if ($total -gt 0) {
            Write-State 'Downloading' 0 '' 'Downloading official Cloudflare Tunnel binary: 0%.' 0 0 $total
        } else {
            Write-State 'Downloading' 0 '' 'Downloading official Cloudflare Tunnel binary; server has not supplied a content length.' -1 0 0
        }
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $received += $read
            $now = Get-Date
            if (($now - $lastUpdate).TotalMilliseconds -ge 300) {
                $pct = -1
                $message = "Downloaded $([Math]::Round($received / 1MB, 1)) MB."
                if ($total -gt 0) {
                    $pct = [int][Math]::Min(99, [Math]::Floor(($received * 100.0) / $total))
                    $message = "Downloading cloudflared: $pct% ($([Math]::Round($received / 1MB, 1)) / $([Math]::Round($total / 1MB, 1)) MB)."
                }
                Write-State 'Downloading' 0 '' $message $pct $received $total
                $lastUpdate = $now
            }
        }
        $outputStream.Flush()
        if ($total -gt 0 -and $received -ne $total) {
            throw "Download ended early: received $received bytes of $total bytes."
        }
        Write-State 'Downloading' 0 '' 'Download complete; validating Windows executable.' 100 $received $total
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

$proc = $null
try {
    Write-State 'Preparing' 0 '' ''
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-State 'Downloading' 0 '' 'Downloading official Cloudflare Tunnel binary.'
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $download = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'
        # Keep the temporary filename ending in .exe. Windows will not execute a file
        # whose name ends with .download, which caused the previous "document in pipeline" failure.
        $tempExe = Join-Path $tools 'cloudflared.download.exe'
        if (Test-Path -LiteralPath $tempExe) { Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue }
        Download-CloudflaredWithProgress -Uri $download -Destination $tempExe
        $file = Get-Item -LiteralPath $tempExe
        if ($file.Length -lt 10000000) { throw "Downloaded cloudflared binary is unexpectedly small ($($file.Length) bytes). Download rejected." }
        $fs = [System.IO.File]::OpenRead($tempExe)
        try {
            $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte()
            if ($b1 -ne 0x4D -or $b2 -ne 0x5A) { throw 'Downloaded file is not a Windows executable (MZ header missing).' }
        } finally { $fs.Dispose() }
        $versionText = (& $tempExe --version 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $versionText -notmatch 'cloudflared') { throw 'Downloaded executable did not pass the cloudflared --version check.' }
        Move-Item -LiteralPath $tempExe -Destination $exe -Force
    }

    # Avoid silently creating a second quick tunnel when a previous tunnel is recorded and alive.
    if (Test-Path $statePath) {
        try {
            $old = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($old.status -eq 'Running' -and [int]$old.processId -gt 0) {
                $alive = Get-Process -Id ([int]$old.processId) -ErrorAction SilentlyContinue
                if ($alive -and $old.publicUrl) { return }
            }
        } catch { }
    }

    Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    Write-State 'Connecting' 0 '' 'Starting Cloudflare Quick Tunnel and waiting for its temporary HTTPS URL.'
    $proc = Start-Process -FilePath $exe -ArgumentList @('tunnel', '--url', "http://127.0.0.1:$Port") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Write-State 'Connecting' $proc.Id '' 'Cloudflared started; waiting for trycloudflare.com URL.'

    $url = ''
    for ($i = 0; $i -lt 120; $i++) {
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if (-not $p) { break }
        $all = ''
        foreach ($f in @($stdoutPath,$stderrPath)) {
            if (Test-Path $f) {
                try { $all += "`n" + ((Get-Content -LiteralPath $f -Tail 100 -ErrorAction SilentlyContinue) -join "`n") } catch { }
            }
        }
        $m = [regex]::Match($all, 'https://[a-zA-Z0-9-]+\.trycloudflare\.com')
        if ($m.Success) { $url = $m.Value.TrimEnd('.'); break }
        Start-Sleep -Seconds 1
    }
    if ($url) {
        Write-State 'Running' $proc.Id $url 'Quick Tunnel active. URL is temporary and public; Bridge API endpoints still require the local Bearer key.'
        exit 0
    }
    $tail = ''
    foreach ($f in @($stdoutPath,$stderrPath)) {
        if (Test-Path $f) { try { $tail += ((Get-Content -LiteralPath $f -Tail 35 -ErrorAction SilentlyContinue) -join "`n") + "`n" } catch { } }
    }
    if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
        throw "cloudflared exited before producing a URL. Details: $tail"
    }
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    throw "Timed out waiting for Cloudflare Quick Tunnel URL. Details: $tail"
 } catch {
    try {
        $tempCandidate = Join-Path $tools 'cloudflared.download.exe'
        if (Test-Path -LiteralPath $tempCandidate) { Remove-Item -LiteralPath $tempCandidate -Force -ErrorAction SilentlyContinue }
    } catch { }
    Write-State 'Failed' $(if ($proc) { $proc.Id } else { 0 }) '' ([string]$_.Exception.Message) -1 0 0
    exit 1
}