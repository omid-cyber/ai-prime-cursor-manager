#requires -Version 5.1
# AI Prime Cursor Manager - Windows PowerShell/WPF, no third-party packages required.
# API keys are not written to logs. The upstream key is saved only when the user opts in,
# encrypted with Windows DPAPI for the current Windows account.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This application requires Windows and WPF.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Security

$script:AppDataDir = Join-Path $env:LOCALAPPDATA 'AIPrimeCursorBridge'
$script:SettingsPath = Join-Path $script:AppDataDir 'settings.json'
$script:ManagerLogPath = Join-Path $script:AppDataDir 'manager.log'
$script:BridgeLogPath = Join-Path $script:AppDataDir 'bridge.log'
$script:BridgeScriptPath = Join-Path $PSScriptRoot 'bridge\server.mjs'
$script:BridgeProcess = $null
$script:ApiKey = ''
$script:BridgeKey = ''
$script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:LastDisplayedLogs = ''
$script:CurrentSettings = $null
$script:LoadedModelIds = @()
$script:ActiveModel = ''
$script:ActiveBaseUrl = ''
$script:ActivePort = 0
$script:ApiOperation = $null
$script:ApiOperationTimer = $null
$script:ApiCooldownUntil = [datetime]::MinValue
$script:TunnelStatePath = Join-Path $script:AppDataDir 'tunnel-state.json'
$script:TunnelPublicUrl = ''
$script:TunnelHelperProcess = $null
$script:TunnelTimer = $null

New-Item -ItemType Directory -Force -Path $script:AppDataDir | Out-Null

function Protect-Text([string]$PlainText) {
    if ([string]::IsNullOrEmpty($PlainText)) { return '' }
    $secure = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secure
}

function Unprotect-Text([string]$CipherText) {
    if ([string]::IsNullOrEmpty($CipherText)) { return '' }
    $secure = ConvertTo-SecureString -String $CipherText
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
        $secure.Dispose()
    }
}

function New-RandomToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Write-AppLog([string]$Message) {
    $safe = [string]$Message
    $safe = $safe -replace '(?i)Bearer\s+\S+', 'Bearer [REDACTED]'
    $safe = $safe -replace '\bsk-[A-Za-z0-9_-]{16,}\b', '[REDACTED_API_KEY]'
    $line = ('{0} [APP] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $safe)
    try {
        if ((Test-Path $script:ManagerLogPath) -and (Get-Item $script:ManagerLogPath).Length -gt 1000000) {
            Set-Content -Path $script:ManagerLogPath -Value '--- Log rotated ---' -Encoding UTF8
        }
        Add-Content -Path $script:ManagerLogPath -Value $line -Encoding UTF8
    } catch { }
}

function Get-ErrorSummary($ErrorRecord) {
    $message = ''
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $message = [string]$ErrorRecord.ErrorDetails.Message
    } else {
        $message = [string]$ErrorRecord.Exception.Message
    }
    $message = $message -replace '(?i)Bearer\s+\S+', 'Bearer [REDACTED]'
    $message = $message -replace '\bsk-[A-Za-z0-9_-]{16,}\b', '[REDACTED_API_KEY]'
    if ($message.Length -gt 1200) { $message = $message.Substring(0, 1200) }
    return $message
}

function Get-DefaultSettings {
    return [pscustomobject]@{
        ApiBaseUrl = 'https://aiprimetech.io/v1'
        Model = 'claude-sonnet-4-6'
        Port = 8787
        RememberApiKey = $false
        EncryptedApiKey = ''
        EncryptedBridgeKey = ''
    }
}

function Load-Settings {
    $s = Get-DefaultSettings
    if (Test-Path $script:SettingsPath) {
        try {
            $saved = Get-Content -Path $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($name in @('ApiBaseUrl','Model','Port','RememberApiKey','EncryptedApiKey','EncryptedBridgeKey')) {
                if ($saved.PSObject.Properties.Name -contains $name) {
                    $s.$name = $saved.$name
                }
            }
        } catch {
            Write-AppLog "Settings file could not be read; defaults loaded."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$s.EncryptedBridgeKey)) {
        $s.EncryptedBridgeKey = Protect-Text (New-RandomToken)
    }
    $script:CurrentSettings = $s
    try { $script:BridgeKey = Unprotect-Text ([string]$s.EncryptedBridgeKey) } catch { $script:BridgeKey = New-RandomToken; $s.EncryptedBridgeKey = Protect-Text $script:BridgeKey }
    if ([string]::IsNullOrWhiteSpace($script:BridgeKey)) {
        $script:BridgeKey = New-RandomToken
        $s.EncryptedBridgeKey = Protect-Text $script:BridgeKey
    }
    if ([bool]$s.RememberApiKey -and -not [string]::IsNullOrWhiteSpace([string]$s.EncryptedApiKey)) {
        try { $script:ApiKey = Unprotect-Text ([string]$s.EncryptedApiKey) } catch { $script:ApiKey = '' }
    }
    Save-SettingsCore
}

function Save-SettingsCore {
    if (-not $script:CurrentSettings) { $script:CurrentSettings = Get-DefaultSettings }
    $obj = [ordered]@{
        ApiBaseUrl = [string]$script:CurrentSettings.ApiBaseUrl
        Model = [string]$script:CurrentSettings.Model
        Port = [int]$script:CurrentSettings.Port
        RememberApiKey = [bool]$script:CurrentSettings.RememberApiKey
        EncryptedApiKey = [string]$script:CurrentSettings.EncryptedApiKey
        EncryptedBridgeKey = [string]$script:CurrentSettings.EncryptedBridgeKey
    }
    $json = $obj | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($script:SettingsPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Save-SettingsFromUi {
    $base = $script:ApiBaseUrlBox.Text.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'https://aiprimetech.io/v1' }
    $model = $script:ModelCombo.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($model)) { $model = 'claude-sonnet-4-6' }
    $port = 8787
    if (-not [int]::TryParse($script:PortBox.Text.Trim(), [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
        throw 'Port must be a number from 1024 to 65535.'
    }
    $script:CurrentSettings.ApiBaseUrl = $base
    $script:CurrentSettings.Model = $model
    $script:CurrentSettings.Port = $port
    $script:CurrentSettings.RememberApiKey = [bool]$script:RememberKeyCheck.IsChecked
    $script:CurrentSettings.EncryptedBridgeKey = Protect-Text $script:BridgeKey
    $script:ApiKey = $script:ApiKeyBox.Password
    if ($script:CurrentSettings.RememberApiKey -and -not [string]::IsNullOrWhiteSpace($script:ApiKey)) {
        $script:CurrentSettings.EncryptedApiKey = Protect-Text $script:ApiKey
    } else {
        $script:CurrentSettings.EncryptedApiKey = ''
    }
    Save-SettingsCore
    Update-CursorValues
    Write-AppLog 'Settings saved.'
    Set-StatusText 'Settings saved' 'Green'
}

function Get-ApiBaseUrl {
    $base = $script:ApiBaseUrlBox.Text.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'Enter an API base URL.' }
    $uri = $null
    if (-not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$uri) -or @('http','https') -notcontains $uri.Scheme) {
        throw 'API base URL must be a valid HTTP or HTTPS URL.'
    }
    return $base
}

function Get-CurrentModel {
    $m = $script:ModelCombo.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($m)) { throw 'Select or enter a model ID.' }
    return $m
}

function Get-ModelAlias([string]$ModelId) {
    $slug = $ModelId.ToLowerInvariant()
    $slug = $slug -replace '^claude-', ''
    $slug = $slug -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'custom-model' }
    return "aiprimetech-$slug"
}

function Update-CursorValues {
    $port = 8787
    [void][int]::TryParse($script:PortBox.Text.Trim(), [ref]$port)
    if ($port -lt 1024 -or $port -gt 65535) { $port = 8787 }
    if (-not [string]::IsNullOrWhiteSpace($script:TunnelPublicUrl)) {
        $script:CursorBaseLabel.Text = "$($script:TunnelPublicUrl.TrimEnd('/'))/v1"
    } else {
        $script:CursorBaseLabel.Text = "http://127.0.0.1:$port/v1"
    }
    $script:CursorModelLabel.Text = Get-ModelAlias $script:ModelCombo.Text.Trim()
    if ($script:CursorKeyPassword) { $script:CursorKeyPassword.Password = $script:BridgeKey }
    if ($script:CursorKeyRevealBox) { $script:CursorKeyRevealBox.Text = $script:BridgeKey }
}

function Refresh-LogView {
    $parts = @()
    foreach ($item in @(@{Path=$script:ManagerLogPath; Title='MANAGER LOG'}, @{Path=$script:BridgeLogPath; Title='BRIDGE LOG'}, @{Path=(Join-Path $script:AppDataDir 'cloudflared.stdout.log'); Title='CLOUDFLARED STDOUT'}, @{Path=(Join-Path $script:AppDataDir 'cloudflared.stderr.log'); Title='CLOUDFLARED STDERR'})) {
        if (Test-Path $item.Path) {
            try {
                # Tail only the most recent lines; never reload megabytes on every UI tick.
                $lines = @(Get-Content -Path $item.Path -Tail 250 -Encoding UTF8 -ErrorAction Stop)
                $text = $lines -join "`r`n"
                $parts += "===== $($item.Title) =====`r`n$text"
            } catch { }
        }
    }
    $combined = $parts -join "`r`n`r`n"
    if ($combined -ne $script:LastDisplayedLogs) {
        $script:LogBox.Text = $combined
        $script:LogBox.CaretIndex = $script:LogBox.Text.Length
        $script:LogBox.ScrollToEnd()
        $script:LastDisplayedLogs = $combined
    }
}

function Set-StatusText([string]$Text, [string]$ColorName = 'LightGray') {
    if ($script:OverallStatus) {
        $script:OverallStatus.Text = $Text
        try { $script:OverallStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($ColorName) } catch { }
    }
}

function Test-ApiConnection {
    $script:ApiKey = $script:ApiKeyBox.Password
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) { throw 'Enter your AI Prime Tech API key first.' }
    $base = Get-ApiBaseUrl
    $model = Get-CurrentModel
    Set-StatusText 'Testing AI Prime Tech API…' 'Orange'
    Write-AppLog "Testing upstream API; model=$model, base=$base"
    $headers = @{ Authorization = "Bearer $script:ApiKey" }
    $modelsUri = "$base/models"
    $modelResult = Invoke-RestMethod -Method Get -Uri $modelsUri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    $ids = @($modelResult.data | ForEach-Object { [string]$_.id })
    Write-AppLog "Models endpoint succeeded; model count=$($ids.Count)."
    if ($ids.Count -gt 0) { Set-ModelItems $ids $model }
    $body = @{
        model = $model
        messages = @(@{ role = 'user'; content = 'Reply with exactly: API TEST SUCCESS' })
        max_tokens = 50
    } | ConvertTo-Json -Depth 6
    $response = Invoke-RestMethod -Method Post -Uri "$base/chat/completions" -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60 -ErrorAction Stop
    $text = $response.choices[0].message.content
    if ($text -is [array]) { $text = ($text | ForEach-Object { $_.text }) -join "`n" }
    Write-AppLog "API chat test succeeded; returned_model=$($response.model); response=$([string]$text)"
    Set-StatusText "API OK — $($response.model)" 'LightGreen'
    if ($script:ApiTestResultText) { $script:ApiTestResultText.Text = "SUCCESS · $($response.model) · $([string]$text)"; $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::LightGreen }
    $script:ApiStatusCard.Text = 'Connected'
    $script:ApiStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGreen
}

function Fetch-Models {
    $script:ApiKey = $script:ApiKeyBox.Password
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) { throw 'Enter your AI Prime Tech API key first.' }
    $base = Get-ApiBaseUrl
    Write-AppLog "Fetching available models from $base/models"
    Set-StatusText 'Fetching models…' 'Orange'
    $response = Invoke-RestMethod -Method Get -Uri "$base/models" -Headers @{ Authorization = "Bearer $script:ApiKey" } -TimeoutSec 30 -ErrorAction Stop
    $ids = @($response.data | ForEach-Object { [string]$_.id })
    if ($ids.Count -eq 0) { throw 'The API returned no model IDs.' }
    Set-ModelItems $ids $script:ModelCombo.Text
    Write-AppLog "Retrieved $($ids.Count) models."
    if ($script:ApiTestResultText) { $script:ApiTestResultText.Text = "Loaded $($ids.Count) model IDs from this API key. Choose one, then test it."; $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::LightGreen }
    Set-StatusText "Models loaded — $($ids.Count)" 'LightGreen'
}

function Get-ModelProfile([string]$ModelId) {
    $id = $ModelId.ToLowerInvariant()
    if ($id -match '\(1m\)') {
        return 'LONG-CONTEXT VARIANT · Choose this when a large context window matters; verify limits and price for your key group.'
    }
    if ($id -match 'thinking') {
        return 'EXTENDED THINKING VARIANT · Designed for deeper reasoning; latency and billing may be higher.'
    }
    if ($id -match 'fable-5-1') {
        return 'FLAGSHIP · AI Prime Tech positions Fable 5.1 as its strongest coding and long-horizon agent model. Highest-cost tier; test access before long jobs.'
    }
    if ($id -match 'opus-5-5') {
        return 'PREMIUM REASONING · Strong alternative for complex debugging, architecture decisions and multi-step coding.'
    }
    if ($id -match 'opus') {
        return 'PREMIUM REASONING · Choose for difficult code analysis and high-stakes debugging; typically costs more than Sonnet.'
    }
    if ($id -match 'fable') {
        return 'FLAGSHIP FAMILY · Intended for demanding coding and agentic work. Test against your task and budget.'
    }
    if ($id -match 'sonnet-5-5|sonnet-5|sonnet-4-6') {
        return 'BALANCED CODING · Strong everyday coding, edits and agent tasks with a quality/cost balance.'
    }
    if ($id -match 'haiku') {
        return 'FAST / ECONOMICAL · Best for quick questions, summaries and routine steps rather than the hardest reasoning.'
    }
    return 'Model supplied by your API key. Run Test API before using it for a long coding session.'
}

function Update-ModelAdvice {
    if ($script:ModelRecommendationText) {
        $id = $script:ModelCombo.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($id)) {
            $script:ModelRecommendationText.Text = 'Fetch models from your key, then choose a model from the list.'
        } else {
            $profile = Get-ModelProfile $id
            $script:ModelRecommendationText.Text = $profile
        }
    }
    if ($script:ModelCountLabel) {
        if ($script:LoadedModelIds.Count -gt 0) {
            $script:ModelCountLabel.Text = "KEY CATALOG · $($script:LoadedModelIds.Count) models loaded"
        } else {
            $script:ModelCountLabel.Text = 'KEY CATALOG · Not loaded yet'
        }
    }
    if ($script:AliasCard) { $script:AliasCard.Text = Get-ModelAlias $script:ModelCombo.Text.Trim() }
    Update-CursorValues
}

function Select-StrongestAvailableModel {
    if ($script:LoadedModelIds.Count -eq 0) {
        throw 'Click Fetch Models first so the app can choose from models returned for your API key.'
    }
    $ranked = @(
        'claude-fable-5-1',
        'claude-opus-5-5',
        'claude-fable-5',
        'claude-opus-5-thinking',
        'claude-opus-5',
        'claude-opus-4-8-thinking',
        'claude-opus-4-8',
        'claude-opus-4-7-thinking',
        'claude-opus-4-7',
        'claude-opus-4-6-thinking',
        'claude-opus-4-6',
        'claude-sonnet-5-5',
        'claude-sonnet-5',
        'claude-sonnet-4-6'
    )
    foreach ($candidate in $ranked) {
        if ($script:LoadedModelIds -contains $candidate) {
            $script:ModelCombo.SelectedItem = $candidate
            Update-ModelAdvice
            Write-AppLog "Strongest suggested model selected from API catalog: $candidate"
            Set-StatusText "Selected recommendation: $candidate" 'LightGreen'
            return
        }
    }
    throw 'No known recommended model was found in the model list returned by this API key. Choose a model manually.'
}

function Set-ModelItems([string[]]$Ids, [string]$Prefer) {
    $script:LoadedModelIds = @($Ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    $priority = @{
        'claude-fable-5-1' = 0
        'claude-opus-5-5' = 1
        'claude-fable-5' = 2
        'claude-opus-5-thinking' = 3
        'claude-opus-5' = 4
        'claude-opus-4-8-thinking' = 5
        'claude-opus-4-8' = 6
        'claude-opus-4-7-thinking' = 7
        'claude-opus-4-7' = 8
        'claude-opus-4-6-thinking' = 9
        'claude-opus-4-6' = 10
        'claude-sonnet-5-5' = 11
        'claude-sonnet-5' = 12
        'claude-sonnet-4-6' = 13
    }
    $Ids = @($script:LoadedModelIds | Sort-Object @{ Expression = { if ($priority.ContainsKey([string]$_)) { $priority[[string]$_] } else { 1000 } } }, @{ Expression = { [string]$_ } })
    $current = $Prefer
    $script:ModelCombo.Items.Clear()
    foreach ($id in $Ids) { [void]$script:ModelCombo.Items.Add($id) }
    if ($Ids -contains $current) { $script:ModelCombo.SelectedItem = $current }
    elseif ($Ids -contains 'claude-sonnet-4-6') { $script:ModelCombo.SelectedItem = 'claude-sonnet-4-6' }
    elseif ($Ids.Count -gt 0) { $script:ModelCombo.SelectedItem = $Ids[0] }
    Update-ModelAdvice
}

function Get-NodeExecutable {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $cmd2 = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd2 -and $cmd2.Source) { return $cmd2.Source }
    foreach ($p in @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe", "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Test-BridgeRunning {
    return ($script:BridgeProcess -and -not $script:BridgeProcess.HasExited)
}

function Start-Bridge {
    if (Test-BridgeRunning) {
        $requestedModel = $script:ModelCombo.Text.Trim()
        $requestedBase = $script:ApiBaseUrlBox.Text.Trim().TrimEnd('/')
        $requestedPort = 8787
        [void][int]::TryParse($script:PortBox.Text.Trim(), [ref]$requestedPort)
        $sameSettings = ($requestedModel -eq $script:ActiveModel)
        if ($sameSettings) { $sameSettings = ($requestedBase -eq $script:ActiveBaseUrl) }
        if ($sameSettings) { $sameSettings = ($requestedPort -eq $script:ActivePort) }
        if ($sameSettings) {
            Write-AppLog "Bridge is already running with the selected model and settings."
            $runningAlias = Get-ModelAlias $requestedModel
            Set-StatusText ("Bridge running - " + $runningAlias) "LightGreen"
            return
        }
        Write-AppLog "Bridge settings changed; restarting from model=$($script:ActiveModel) to model=$requestedModel."
        Stop-Bridge
    }
    if (-not (Test-Path $script:BridgeScriptPath)) { throw "Bridge script not found: $($script:BridgeScriptPath). Keep the bridge folder beside the manager script." }
    $script:ApiKey = $script:ApiKeyBox.Password
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) { throw 'Enter your AI Prime Tech API key before starting the bridge.' }
    $node = Get-NodeExecutable
    if (-not $node) { throw 'Node.js was not found. Install Node.js 20+ and reopen this manager.' }
    $base = Get-ApiBaseUrl
    $model = Get-CurrentModel
    $alias = Get-ModelAlias $model
    $port = 8787
    if (-not [int]::TryParse($script:PortBox.Text.Trim(), [ref]$port) -or $port -lt 1024 -or $port -gt 65535) { throw 'Port must be from 1024 to 65535.' }

    # A previous UI crash can leave the Node bridge alive. Detect and safely reattach to
    # our own bridge instead of spawning a duplicate listener (which would immediately exit).
    $listenerPid = $null
    try {
        $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($listener) { $listenerPid = [int]$listener.OwningProcess }
    } catch { }
    if ($listenerPid -and $listenerPid -ne $PID) {
        $listenerProcess = $null
        try { $listenerProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $listenerPid" -ErrorAction Stop } catch { }
        $commandLine = if ($listenerProcess) { [string]$listenerProcess.CommandLine } else { '' }
        $ownedBridge = ($commandLine -match '(?i)AIPrimeCursorManager(?:App)?[\\/].*bridge[\\/]server\.mjs')
        if (-not $ownedBridge) {
            throw "Port $port is already in use by PID $listenerPid. The manager did not stop it because it does not look like this app's Bridge. Stop that process or choose another port."
        }
        $existingHealth = $null
        try { $existingHealth = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 1 -ErrorAction Stop } catch { }
        if ($existingHealth -and $existingHealth.ok -and [string]$existingHealth.model -eq $model -and [string]$existingHealth.alias -eq $alias) {
            $script:BridgeProcess = [System.Diagnostics.Process]::GetProcessById($listenerPid)
            $script:ActiveModel = $model
            $script:ActiveBaseUrl = $base
            $script:ActivePort = $port
            Write-AppLog "Re-attached to previous bridge PID=$listenerPid, model=$model, port=$port."
            Update-CursorValues
            Set-StatusText "Bridge already running — $alias" 'LightGreen'
            if ($script:BridgeStatusCard) {
                $script:BridgeStatusCard.Text = 'Running — re-attached'
                $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGreen
            }
            Refresh-LogView
            return
        }
        try {
            Stop-Process -Id $listenerPid -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 250
            Write-AppLog "Stopped stale manager-owned bridge PID=$listenerPid before applying selected model."
        } catch {
            throw "A previous manager Bridge (PID $listenerPid) is using port $port and could not be stopped: $($_.Exception.Message)"
        }
    }

    if (-not $script:BridgeKey) { $script:BridgeKey = New-RandomToken }
    $script:CurrentSettings.ApiBaseUrl = $base
    $script:CurrentSettings.Model = $model
    $script:CurrentSettings.Port = $port
    $script:CurrentSettings.EncryptedBridgeKey = Protect-Text $script:BridgeKey
    $script:CurrentSettings.RememberApiKey = [bool]$script:RememberKeyCheck.IsChecked
    if ($script:CurrentSettings.RememberApiKey) { $script:CurrentSettings.EncryptedApiKey = Protect-Text $script:ApiKey } else { $script:CurrentSettings.EncryptedApiKey = '' }
    Save-SettingsCore

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = '"' + $script:BridgeScriptPath + '"'
    $psi.WorkingDirectory = Split-Path -Parent $script:BridgeScriptPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Do not redirect Node stdout/stderr into PowerShell event callbacks.
    # Those callbacks can execute on a non-UI thread and destabilize the WPF host.
    # The bridge writes diagnostics to its own log file, so no pipe is needed.
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.EnvironmentVariables['AIPRIMETECH_API_KEY'] = $script:ApiKey
    $psi.EnvironmentVariables['AIPRIMETECH_BASE_URL'] = $base
    $psi.EnvironmentVariables['AIPRIMETECH_MODEL'] = $model
    $psi.EnvironmentVariables['CURSOR_MODEL_ALIAS'] = $alias
    $psi.EnvironmentVariables['CURSOR_BRIDGE_KEY'] = $script:BridgeKey
    $psi.EnvironmentVariables['CURSOR_BRIDGE_PORT'] = [string]$port
    $psi.EnvironmentVariables['BRIDGE_LOG_PATH'] = $script:BridgeLogPath

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true
    if (-not $proc.Start()) { throw 'Node bridge process failed to start.' }

    $script:BridgeProcess = $proc
    $script:ActiveModel = $model
    $script:ActiveBaseUrl = $base
    $script:ActivePort = $port
    Write-AppLog "Bridge process launched; port=$port, alias=$alias, upstream model=$model."
    Update-CursorValues

    # Starting the child must not wait on a network health check on the WPF UI thread.
    # The Test Bridge action performs health/models/chat checks in a background runspace.
    Set-StatusText "Bridge process launched on port $port; verify with Test Bridge" 'LightGreen'
    if ($script:BridgeStatusCard) {
        $script:BridgeStatusCard.Text = 'Started — verify connection'
        $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::Orange
    }
    Refresh-LogView
}

function Stop-Bridge {
    if (Test-BridgeRunning) {
        try {
            $script:BridgeProcess.Kill()
            [void]$script:BridgeProcess.WaitForExit(5000)
            Write-AppLog 'Bridge process stopped.'
        } catch { Write-AppLog "Could not stop bridge cleanly: $($_.Exception.Message)" }
    } else {
        Write-AppLog 'Bridge is not running in this manager session.'
    }
    $script:BridgeProcess = $null
    $script:ActiveModel = ''
    $script:ActiveBaseUrl = ''
    $script:ActivePort = 0
    Set-StatusText 'Bridge stopped' 'LightGray'
    Refresh-LogView
}

function Test-BridgeConnection {
    $port = 8787
    if (-not [int]::TryParse($script:PortBox.Text.Trim(), [ref]$port)) { throw 'Invalid port.' }
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 5 -ErrorAction Stop
    $headers = @{ Authorization = "Bearer $script:BridgeKey" }
    $models = Invoke-RestMethod -Uri "http://127.0.0.1:$port/v1/models" -Headers $headers -TimeoutSec 5 -ErrorAction Stop
    if (@($models.data).Count -lt 1) { throw 'Bridge did not expose a model.' }
    $alias = [string]$models.data[0].id
    $body = @{
        model = $alias
        messages = @(@{ role = 'user'; content = 'Reply with exactly: LOCAL BRIDGE TEST SUCCESS' })
        max_tokens = 50
    } | ConvertTo-Json -Depth 6
    Write-AppLog "Testing bridge at port $port with alias=$alias."
    $response = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/v1/chat/completions" -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 90 -ErrorAction Stop
    $text = $response.choices[0].message.content
    if ($text -is [array]) { $text = ($text | ForEach-Object { $_.text }) -join "`n" }
    Write-AppLog "Bridge request succeeded; upstream model=$($response.model); response=$([string]$text)"
    Set-StatusText "Bridge OK — $($response.model)" 'LightGreen'
    [System.Windows.MessageBox]::Show("Local bridge request succeeded.`r`n`r`nUpstream model: $($response.model)`r`nResponse: $text", 'AI Prime Cursor Manager', 'OK', 'Information') | Out-Null
}

function Copy-Text([string]$Value, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "Nothing to copy for $Label." }
    [System.Windows.Clipboard]::SetText($Value)
    Write-AppLog "$Label copied to clipboard."
    Set-StatusText "$Label copied" 'LightGreen'
}

function Set-ApiOperationControls([bool]$Enabled) {
    foreach ($control in @(
        $script:TestApiButton, $script:FetchModelsButton, $script:TestBridgeButton,
        $script:StrongestModelButton, $script:SaveSettingsButton, $script:SaveSettingsButton2,
        $script:ForgetKeyButton, $script:StartBridgeButton, $script:StopBridgeButton,
        $script:ModelCombo, $script:ApiBaseUrlBox, $script:ApiKeyBox, $script:PortBox
    )) {
        if ($null -ne $control) { $control.IsEnabled = $Enabled }
    }
}

function Start-ApiOperation([string]$Kind) {
    if ($script:ApiOperation) {
        Set-StatusText 'A request is already running; please wait.' 'Orange'
        return
    }
    if ((Get-Date) -lt $script:ApiCooldownUntil) {
        $seconds = [int][Math]::Ceiling(($script:ApiCooldownUntil - (Get-Date)).TotalSeconds)
        $message = "AI Prime Tech reported a concurrency limit. Wait about $seconds more seconds and ensure no other long request is running. No automatic retry was sent."
        if ($script:ApiTestResultText) { $script:ApiTestResultText.Text = $message; $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::Orange }
        Set-StatusText 'Gateway busy — wait before retrying' 'Orange'
        return
    }

    $base = ''
    $key = ''
    $model = ''
    $port = 8787
    $localKey = ''
    if ($Kind -eq 'Bridge') {
        if (-not (Test-BridgeRunning)) { throw 'Start the local bridge before testing it.' }
        if (-not [int]::TryParse($script:PortBox.Text.Trim(), [ref]$port) -or $port -lt 1024 -or $port -gt 65535) { throw 'Invalid local bridge port.' }
        $localKey = $script:BridgeKey
        $model = Get-CurrentModel
    } else {
        Save-SettingsFromUi
        $key = $script:ApiKeyBox.Password
        if ([string]::IsNullOrWhiteSpace($key)) { throw 'Enter your AI Prime Tech API key first.' }
        $base = Get-ApiBaseUrl
        $model = Get-CurrentModel
    }

    $worker = @'
param($Kind, $BaseUrl, $ApiKey, $ModelId, $Port, $LocalKey)
$ErrorActionPreference = 'Stop'
function Get-SafeWorkerError($record) {
    if ($record.ErrorDetails -and $record.ErrorDetails.Message) { $m = [string]$record.ErrorDetails.Message }
    else { $m = [string]$record.Exception.Message }
    $m = $m -replace '(?i)Bearer\s+\S+', 'Bearer [REDACTED]'
    $m = $m -replace '\bsk-[A-Za-z0-9_-]{16,}\b', '[REDACTED_API_KEY]'
    if ($m.Length -gt 1600) { $m = $m.Substring(0, 1600) }
    return $m
}
try {
    if ($Kind -eq 'Models') {
        $headers = @{ Authorization = "Bearer $ApiKey" }
        $catalog = Invoke-RestMethod -Method Get -Uri "$($BaseUrl.TrimEnd('/'))/models" -Headers $headers -TimeoutSec 25 -ErrorAction Stop
        $ids = @($catalog.data | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($ids.Count -eq 0) { throw 'The models endpoint returned no model IDs.' }
        [pscustomobject]@{ Success=$true; Kind=$Kind; ModelIds=$ids; Model=$ModelId; Response="Loaded $($ids.Count) models."; Error=''; Code=''; IsConcurrency=$false }
    } elseif ($Kind -eq 'Test') {
        $headers = @{ Authorization = "Bearer $ApiKey" }
        $body = @{ model=$ModelId; messages=@(@{ role='user'; content='Reply with exactly: API TEST SUCCESS' }); max_tokens=40 } | ConvertTo-Json -Depth 5
        # One request only: model catalog fetching is a separate button.
        $reply = Invoke-RestMethod -Method Post -Uri "$($BaseUrl.TrimEnd('/'))/chat/completions" -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 35 -ErrorAction Stop
        $content = $reply.choices[0].message.content
        if ($content -is [array]) { $content = ($content | ForEach-Object { $_.text }) -join "`n" }
        [pscustomobject]@{ Success=$true; Kind=$Kind; Model=[string]$reply.model; ModelIds=@(); Response=[string]$content; Error=''; Code=''; IsConcurrency=$false }
    } elseif ($Kind -eq 'Bridge') {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 4 -ErrorAction Stop
        $headers = @{ Authorization = "Bearer $LocalKey" }
        $models = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -Headers $headers -TimeoutSec 4 -ErrorAction Stop
        if (@($models.data).Count -lt 1) { throw 'Bridge did not expose a model.' }
        $alias = [string]$models.data[0].id
        $body = @{ model=$alias; messages=@(@{ role='user'; content='Reply with exactly: LOCAL BRIDGE TEST SUCCESS' }); max_tokens=40 } | ConvertTo-Json -Depth 5
        $reply = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 90 -ErrorAction Stop
        $content = $reply.choices[0].message.content
        if ($content -is [array]) { $content = ($content | ForEach-Object { $_.text }) -join "`n" }
        [pscustomobject]@{ Success=$true; Kind=$Kind; Model=[string]$reply.model; ModelIds=@(); Response=[string]$content; Error=''; Code=''; IsConcurrency=$false }
    } else { throw "Unsupported operation: $Kind" }
} catch {
    $message = Get-SafeWorkerError $_
    $code = ''
    if ($message -match '"code"\s*:\s*"(?<code>\w+)"') { $code = $Matches.code }
    $busy = ($message -match '(?i)gateway_concurrency_limit|concurren(?:cy|t).*limit|too many requests|HTTP\s*429|status code 429')
    [pscustomobject]@{ Success=$false; Kind=$Kind; Model=$ModelId; ModelIds=@(); Response=''; Error=$message; Code=$code; IsConcurrency=$busy }
}
'@

    $ps = [System.Management.Automation.PowerShell]::Create()
    try {
        [void]$ps.AddScript($worker)
        [void]$ps.AddArgument($Kind)
        [void]$ps.AddArgument($base)
        [void]$ps.AddArgument($key)
        [void]$ps.AddArgument($model)
        [void]$ps.AddArgument($port)
        [void]$ps.AddArgument($localKey)
        $handle = $ps.BeginInvoke()
        $script:ApiOperation = [pscustomobject]@{ PowerShell=$ps; Handle=$handle; Kind=$Kind; Started=(Get-Date) }
        Set-ApiOperationControls $false
        if ($Kind -eq 'Test') {
            Set-StatusText "Testing $model in background…" 'Orange'
            $script:ApiStatusCard.Text = 'Testing…'
            $script:ApiTestResultText.Text = 'Request running in the background. The window should remain responsive.'
            $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::LightBlue
        } elseif ($Kind -eq 'Models') {
            Set-StatusText 'Refreshing model catalog in background…' 'Orange'
            $script:ModelCountLabel.Text = 'KEY CATALOG · Loading…'
            $script:ApiTestResultText.Text = 'Loading models in the background…'
        } else {
            Set-StatusText 'Testing local bridge in background…' 'Orange'
            $script:BridgeStatusCard.Text = 'Testing…'
            $script:ApiTestResultText.Text = 'Bridge test running. The window should remain responsive.'
        }
        Write-AppLog "Started asynchronous operation: $Kind; model=$model."
        $script:ApiOperationTimer.Start()
    } catch {
        try { $ps.Dispose() } catch { }
        Set-ApiOperationControls $true
        throw
    }
}

function Complete-ApiOperation {
    $op = $script:ApiOperation
    if (-not $op) { return }
    $result = $null
    try {
        $output = $op.PowerShell.EndInvoke($op.Handle)
        if ($output -and $output.Count -gt 0) { $result = $output[0] }
        if (-not $result) {
            $streamErrors = @($op.PowerShell.Streams.Error | ForEach-Object { [string]$_.ToString() })
            throw $(if ($streamErrors.Count -gt 0) { $streamErrors -join '; ' } else { 'Background operation returned no result.' })
        }
    } catch {
        $result = [pscustomobject]@{ Success=$false; Kind=$op.Kind; Model=''; ModelIds=@(); Response=''; Error=(Get-ErrorSummary $_); Code=''; IsConcurrency=$false }
    } finally {
        try { $op.PowerShell.Dispose() } catch { }
        $script:ApiOperation = $null
        $script:ApiOperationTimer.Stop()
        Set-ApiOperationControls $true
    }

    if (-not $result.Success) {
        $message = [string]$result.Error
        Write-AppLog "$($op.Kind) failed: $message"
        if ($result.IsConcurrency) {
            $script:ApiCooldownUntil = (Get-Date).AddSeconds(20)
            $friendly = "AI Prime Tech is at its concurrent-request limit (gateway_concurrency_limit). This does not mean your key is invalid. Wait at least 20 seconds and make sure other requests have finished, then retry manually. No automatic retry was sent.`r`n`r`nDetails: $message"
            Set-StatusText 'Gateway busy — wait before retrying' 'Orange'
            $script:ApiStatusCard.Text = 'Busy — retry later'
            $script:ApiStatusCard.Foreground = [System.Windows.Media.Brushes]::Orange
            $script:ApiTestResultText.Text = $friendly
            $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::Orange
        } else {
            Set-StatusText "$($op.Kind) failed" 'Salmon'
            $script:ApiTestResultText.Text = $message
            $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::Salmon
            if ($op.Kind -eq 'Bridge') {
                $script:BridgeStatusCard.Text = 'Test failed'
                $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::Salmon
            } else {
                $script:ApiStatusCard.Text = 'Failed'
                $script:ApiStatusCard.Foreground = [System.Windows.Media.Brushes]::Salmon
            }
        }
        return
    }

    if ($op.Kind -eq 'Models') {
        Set-ModelItems ([string[]]$result.ModelIds) $script:ModelCombo.Text
        $script:ApiStatusCard.Text = 'Connected — models loaded'
        $script:ApiStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGreen
        $script:ApiTestResultText.Text = "Loaded $(@($result.ModelIds).Count) models. Choose one, then test only that model."
        $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::LightGreen
        Set-StatusText "Models loaded — $(@($result.ModelIds).Count)" 'LightGreen'
        Write-AppLog "Model catalog refreshed successfully; count=$(@($result.ModelIds).Count)."
    } elseif ($op.Kind -eq 'Test') {
        $script:ApiStatusCard.Text = 'Connected'
        $script:ApiStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGreen
        $script:ApiTestResultText.Text = "SUCCESS · $($result.Model) · $($result.Response)"
        $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::LightGreen
        Set-StatusText "API OK — $($result.Model)" 'LightGreen'
        Write-AppLog "API test succeeded; model=$($result.Model); response=$($result.Response)"
    } elseif ($op.Kind -eq 'Bridge') {
        $script:BridgeStatusCard.Text = 'Connected'
        $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGreen
        $script:ApiTestResultText.Text = "BRIDGE SUCCESS · $($result.Model) · $($result.Response)"
        $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::LightGreen
        Set-StatusText "Bridge OK — $($result.Model)" 'LightGreen'
        Write-AppLog "Bridge test succeeded; model=$($result.Model); response=$($result.Response)"
    }
    Refresh-LogView
}

# ---- WPF UI ----
function Ensure-TunnelHelper {
    $target = Join-Path $script:AppDataDir 'tunnel-manager.ps1'
    $bundled = Join-Path $PSScriptRoot 'cloudflare-tunnel-manager.ps1'
    if (Test-Path -LiteralPath $bundled) {
        Copy-Item -LiteralPath $bundled -Destination $target -Force
    } else {
        $encoded = '77u/cGFyYW0oCiAgICBbVmFsaWRhdGVTZXQoJ1N0YXJ0JyldW3N0cmluZ10kTW9kZSA9ICdTdGFydCcsCiAgICBbaW50XSRQb3J0ID0gODc4NywKICAgIFtzdHJpbmddJEFwcERhdGFEaXIgPSAoSm9pbi1QYXRoICRlbnY6TE9DQUxBUFBEQVRBICdBSVByaW1lQ3Vyc29yQnJpZGdlJykKKQokRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gJ1N0b3AnCiRQcm9ncmVzc1ByZWZlcmVuY2UgPSAnU2lsZW50bHlDb250aW51ZScKJHRvb2xzID0gSm9pbi1QYXRoICRBcHBEYXRhRGlyICd0b29scycKJGV4ZSA9IEpvaW4tUGF0aCAkdG9vbHMgJ2Nsb3VkZmxhcmVkLmV4ZScKJHN0YXRlUGF0aCA9IEpvaW4tUGF0aCAkQXBwRGF0YURpciAndHVubmVsLXN0YXRlLmpzb24nCiRzdGRvdXRQYXRoID0gSm9pbi1QYXRoICRBcHBEYXRhRGlyICdjbG91ZGZsYXJlZC5zdGRvdXQubG9nJwokc3RkZXJyUGF0aCA9IEpvaW4tUGF0aCAkQXBwRGF0YURpciAnY2xvdWRmbGFyZWQuc3RkZXJyLmxvZycKTmV3LUl0ZW0gLUl0ZW1UeXBlIERpcmVjdG9yeSAtRm9yY2UgLVBhdGggJEFwcERhdGFEaXIsICR0b29scyB8IE91dC1OdWxsCgpmdW5jdGlvbiBXcml0ZS1TdGF0ZSgKICAgIFtzdHJpbmddJFN0YXR1cywKICAgIFtpbnRdJFByb2Nlc3NJZCA9IDAsCiAgICBbc3RyaW5nXSRVcmwgPSAnJywKICAgIFtzdHJpbmddJEVycm9yVGV4dCA9ICcnLAogICAgW2ludF0kUHJvZ3Jlc3MgPSAtMSwKICAgIFtsb25nXSRCeXRlc0Rvd25sb2FkZWQgPSAwLAogICAgW2xvbmddJEJ5dGVzVG90YWwgPSAwCikgewogICAgJHN0YXRlID0gW29yZGVyZWRdQHsKICAgICAgICBzdGF0dXMgPSAkU3RhdHVzCiAgICAgICAgcHJvY2Vzc0lkID0gJFByb2Nlc3NJZAogICAgICAgIHB1YmxpY1VybCA9ICRVcmwKICAgICAgICBwb3J0ID0gJFBvcnQKICAgICAgICBlcnJvciA9ICRFcnJvclRleHQKICAgICAgICBwcm9ncmVzcyA9ICRQcm9ncmVzcwogICAgICAgIGJ5dGVzRG93bmxvYWRlZCA9ICRCeXRlc0Rvd25sb2FkZWQKICAgICAgICBieXRlc1RvdGFsID0gJEJ5dGVzVG90YWwKICAgICAgICB1cGRhdGVkQXQgPSAoR2V0LURhdGUpLlRvU3RyaW5nKCdvJykKICAgIH0KICAgICR0bXAgPSAiJHN0YXRlUGF0aC50bXAiCiAgICBbU3lzdGVtLklPLkZpbGVdOjpXcml0ZUFsbFRleHQoJHRtcCwgKCRzdGF0ZSB8IENvbnZlcnRUby1Kc29uIC1EZXB0aCA0KSwgKE5ldy1PYmplY3QgU3lzdGVtLlRleHQuVVRGOEVuY29kaW5nKCRmYWxzZSkpKQogICAgTW92ZS1JdGVtIC1MaXRlcmFsUGF0aCAkdG1wIC1EZXN0aW5hdGlvbiAkc3RhdGVQYXRoIC1Gb3JjZQp9CgpmdW5jdGlvbiBEb3dubG9hZC1DbG91ZGZsYXJlZFdpdGhQcm9ncmVzcyhbc3RyaW5nXSRVcmksIFtzdHJpbmddJERlc3RpbmF0aW9uKSB7CiAgICAkcmVxdWVzdCA9IFtTeXN0ZW0uTmV0Lkh0dHBXZWJSZXF1ZXN0XTo6Q3JlYXRlKCRVcmkpCiAgICAkcmVxdWVzdC5NZXRob2QgPSAnR0VUJwogICAgJHJlcXVlc3QuQWxsb3dBdXRvUmVkaXJlY3QgPSAkdHJ1ZQogICAgJHJlcXVlc3QuVXNlckFnZW50ID0gJ0FJUHJpbWVDdXJzb3JNYW5hZ2VyLzEuNycKICAgICRyZXF1ZXN0LlRpbWVvdXQgPSAxODAwMDAKICAgICRyZXF1ZXN0LlJlYWRXcml0ZVRpbWVvdXQgPSAzMDAwMAogICAgJHJlc3BvbnNlID0gJG51bGwKICAgICRpbnB1dFN0cmVhbSA9ICRudWxsCiAgICAkb3V0cHV0U3RyZWFtID0gJG51bGwKICAgICRyZWNlaXZlZCA9IFtsb25nXTAKICAgICR0b3RhbCA9IFtsb25nXTAKICAgICRsYXN0VXBkYXRlID0gR2V0LURhdGUKICAgIHRyeSB7CiAgICAgICAgJHJlc3BvbnNlID0gJHJlcXVlc3QuR2V0UmVzcG9uc2UoKQogICAgICAgICR0b3RhbCA9IFtsb25nXSRyZXNwb25zZS5Db250ZW50TGVuZ3RoCiAgICAgICAgJGlucHV0U3RyZWFtID0gJHJlc3BvbnNlLkdldFJlc3BvbnNlU3RyZWFtKCkKICAgICAgICAkb3V0cHV0U3RyZWFtID0gW1N5c3RlbS5JTy5GaWxlXTo6T3BlbigkRGVzdGluYXRpb24sIFtTeXN0ZW0uSU8uRmlsZU1vZGVdOjpDcmVhdGVOZXcsIFtTeXN0ZW0uSU8uRmlsZUFjY2Vzc106OldyaXRlLCBbU3lzdGVtLklPLkZpbGVTaGFyZV06Ok5vbmUpCiAgICAgICAgJGJ1ZmZlciA9IE5ldy1PYmplY3QgYnl0ZVtdICg2NCAqIDEwMjQpCiAgICAgICAgaWYgKCR0b3RhbCAtZ3QgMCkgewogICAgICAgICAgICBXcml0ZS1TdGF0ZSAnRG93bmxvYWRpbmcnIDAgJycgJ0Rvd25sb2FkaW5nIG9mZmljaWFsIENsb3VkZmxhcmUgVHVubmVsIGJpbmFyeTogMCUuJyAwIDAgJHRvdGFsCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgV3JpdGUtU3RhdGUgJ0Rvd25sb2FkaW5nJyAwICcnICdEb3dubG9hZGluZyBvZmZpY2lhbCBDbG91ZGZsYXJlIFR1bm5lbCBiaW5hcnk7IHNlcnZlciBoYXMgbm90IHN1cHBsaWVkIGEgY29udGVudCBsZW5ndGguJyAtMSAwIDAKICAgICAgICB9CiAgICAgICAgd2hpbGUgKCgkcmVhZCA9ICRpbnB1dFN0cmVhbS5SZWFkKCRidWZmZXIsIDAsICRidWZmZXIuTGVuZ3RoKSkgLWd0IDApIHsKICAgICAgICAgICAgJG91dHB1dFN0cmVhbS5Xcml0ZSgkYnVmZmVyLCAwLCAkcmVhZCkKICAgICAgICAgICAgJHJlY2VpdmVkICs9ICRyZWFkCiAgICAgICAgICAgICRub3cgPSBHZXQtRGF0ZQogICAgICAgICAgICBpZiAoKCRub3cgLSAkbGFzdFVwZGF0ZSkuVG90YWxNaWxsaXNlY29uZHMgLWdlIDMwMCkgewogICAgICAgICAgICAgICAgJHBjdCA9IC0xCiAgICAgICAgICAgICAgICAkbWVzc2FnZSA9ICJEb3dubG9hZGVkICQoW01hdGhdOjpSb3VuZCgkcmVjZWl2ZWQgLyAxTUIsIDEpKSBNQi4iCiAgICAgICAgICAgICAgICBpZiAoJHRvdGFsIC1ndCAwKSB7CiAgICAgICAgICAgICAgICAgICAgJHBjdCA9IFtpbnRdW01hdGhdOjpNaW4oOTksIFtNYXRoXTo6Rmxvb3IoKCRyZWNlaXZlZCAqIDEwMC4wKSAvICR0b3RhbCkpCiAgICAgICAgICAgICAgICAgICAgJG1lc3NhZ2UgPSAiRG93bmxvYWRpbmcgY2xvdWRmbGFyZWQ6ICRwY3QlICgkKFtNYXRoXTo6Um91bmQoJHJlY2VpdmVkIC8gMU1CLCAxKSkgLyAkKFtNYXRoXTo6Um91bmQoJHRvdGFsIC8gMU1CLCAxKSkgTUIpLiIKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIFdyaXRlLVN0YXRlICdEb3dubG9hZGluZycgMCAnJyAkbWVzc2FnZSAkcGN0ICRyZWNlaXZlZCAkdG90YWwKICAgICAgICAgICAgICAgICRsYXN0VXBkYXRlID0gJG5vdwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgICRvdXRwdXRTdHJlYW0uRmx1c2goKQogICAgICAgIGlmICgkdG90YWwgLWd0IDAgLWFuZCAkcmVjZWl2ZWQgLW5lICR0b3RhbCkgewogICAgICAgICAgICB0aHJvdyAiRG93bmxvYWQgZW5kZWQgZWFybHk6IHJlY2VpdmVkICRyZWNlaXZlZCBieXRlcyBvZiAkdG90YWwgYnl0ZXMuIgogICAgICAgIH0KICAgICAgICBXcml0ZS1TdGF0ZSAnRG93bmxvYWRpbmcnIDAgJycgJ0Rvd25sb2FkIGNvbXBsZXRlOyB2YWxpZGF0aW5nIFdpbmRvd3MgZXhlY3V0YWJsZS4nIDEwMCAkcmVjZWl2ZWQgJHRvdGFsCiAgICB9CiAgICBmaW5hbGx5IHsKICAgICAgICBpZiAoJG91dHB1dFN0cmVhbSkgeyAkb3V0cHV0U3RyZWFtLkRpc3Bvc2UoKSB9CiAgICAgICAgaWYgKCRpbnB1dFN0cmVhbSkgeyAkaW5wdXRTdHJlYW0uRGlzcG9zZSgpIH0KICAgICAgICBpZiAoJHJlc3BvbnNlKSB7ICRyZXNwb25zZS5EaXNwb3NlKCkgfQogICAgfQp9CgokcHJvYyA9ICRudWxsCnRyeSB7CiAgICBXcml0ZS1TdGF0ZSAnUHJlcGFyaW5nJyAwICcnICcnCiAgICBpZiAoLW5vdCAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkZXhlKSkgewogICAgICAgIFdyaXRlLVN0YXRlICdEb3dubG9hZGluZycgMCAnJyAnRG93bmxvYWRpbmcgb2ZmaWNpYWwgQ2xvdWRmbGFyZSBUdW5uZWwgYmluYXJ5LicKICAgICAgICB0cnkgeyBbTmV0LlNlcnZpY2VQb2ludE1hbmFnZXJdOjpTZWN1cml0eVByb3RvY29sID0gW05ldC5TZWN1cml0eVByb3RvY29sVHlwZV06OlRsczEyIH0gY2F0Y2ggeyB9CiAgICAgICAgJGRvd25sb2FkID0gJ2h0dHBzOi8vZ2l0aHViLmNvbS9jbG91ZGZsYXJlL2Nsb3VkZmxhcmVkL3JlbGVhc2VzL2xhdGVzdC9kb3dubG9hZC9jbG91ZGZsYXJlZC13aW5kb3dzLWFtZDY0LmV4ZScKICAgICAgICAjIEtlZXAgdGhlIHRlbXBvcmFyeSBmaWxlbmFtZSBlbmRpbmcgaW4gLmV4ZS4gV2luZG93cyB3aWxsIG5vdCBleGVjdXRlIGEgZmlsZQogICAgICAgICMgd2hvc2UgbmFtZSBlbmRzIHdpdGggLmRvd25sb2FkLCB3aGljaCBjYXVzZWQgdGhlIHByZXZpb3VzICJkb2N1bWVudCBpbiBwaXBlbGluZSIgZmFpbHVyZS4KICAgICAgICAkdGVtcEV4ZSA9IEpvaW4tUGF0aCAkdG9vbHMgJ2Nsb3VkZmxhcmVkLmRvd25sb2FkLmV4ZScKICAgICAgICBpZiAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkdGVtcEV4ZSkgeyBSZW1vdmUtSXRlbSAtTGl0ZXJhbFBhdGggJHRlbXBFeGUgLUZvcmNlIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlIH0KICAgICAgICBEb3dubG9hZC1DbG91ZGZsYXJlZFdpdGhQcm9ncmVzcyAtVXJpICRkb3dubG9hZCAtRGVzdGluYXRpb24gJHRlbXBFeGUKICAgICAgICAkZmlsZSA9IEdldC1JdGVtIC1MaXRlcmFsUGF0aCAkdGVtcEV4ZQogICAgICAgIGlmICgkZmlsZS5MZW5ndGggLWx0IDEwMDAwMDAwKSB7IHRocm93ICJEb3dubG9hZGVkIGNsb3VkZmxhcmVkIGJpbmFyeSBpcyB1bmV4cGVjdGVkbHkgc21hbGwgKCQoJGZpbGUuTGVuZ3RoKSBieXRlcykuIERvd25sb2FkIHJlamVjdGVkLiIgfQogICAgICAgICRmcyA9IFtTeXN0ZW0uSU8uRmlsZV06Ok9wZW5SZWFkKCR0ZW1wRXhlKQogICAgICAgIHRyeSB7CiAgICAgICAgICAgICRiMSA9ICRmcy5SZWFkQnl0ZSgpOyAkYjIgPSAkZnMuUmVhZEJ5dGUoKQogICAgICAgICAgICBpZiAoJGIxIC1uZSAweDREIC1vciAkYjIgLW5lIDB4NUEpIHsgdGhyb3cgJ0Rvd25sb2FkZWQgZmlsZSBpcyBub3QgYSBXaW5kb3dzIGV4ZWN1dGFibGUgKE1aIGhlYWRlciBtaXNzaW5nKS4nIH0KICAgICAgICB9IGZpbmFsbHkgeyAkZnMuRGlzcG9zZSgpIH0KICAgICAgICAkdmVyc2lvblRleHQgPSAoJiAkdGVtcEV4ZSAtLXZlcnNpb24gMj4mMSB8IE91dC1TdHJpbmcpCiAgICAgICAgaWYgKCRMQVNURVhJVENPREUgLW5lIDAgLW9yICR2ZXJzaW9uVGV4dCAtbm90bWF0Y2ggJ2Nsb3VkZmxhcmVkJykgeyB0aHJvdyAnRG93bmxvYWRlZCBleGVjdXRhYmxlIGRpZCBub3QgcGFzcyB0aGUgY2xvdWRmbGFyZWQgLS12ZXJzaW9uIGNoZWNrLicgfQogICAgICAgIE1vdmUtSXRlbSAtTGl0ZXJhbFBhdGggJHRlbXBFeGUgLURlc3RpbmF0aW9uICRleGUgLUZvcmNlCiAgICB9CgogICAgIyBBdm9pZCBzaWxlbnRseSBjcmVhdGluZyBhIHNlY29uZCBxdWljayB0dW5uZWwgd2hlbiBhIHByZXZpb3VzIHR1bm5lbCBpcyByZWNvcmRlZCBhbmQgYWxpdmUuCiAgICBpZiAoVGVzdC1QYXRoICRzdGF0ZVBhdGgpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICAkb2xkID0gR2V0LUNvbnRlbnQgLUxpdGVyYWxQYXRoICRzdGF0ZVBhdGggLVJhdyB8IENvbnZlcnRGcm9tLUpzb24KICAgICAgICAgICAgaWYgKCRvbGQuc3RhdHVzIC1lcSAnUnVubmluZycgLWFuZCBbaW50XSRvbGQucHJvY2Vzc0lkIC1ndCAwKSB7CiAgICAgICAgICAgICAgICAkYWxpdmUgPSBHZXQtUHJvY2VzcyAtSWQgKFtpbnRdJG9sZC5wcm9jZXNzSWQpIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlCiAgICAgICAgICAgICAgICBpZiAoJGFsaXZlIC1hbmQgJG9sZC5wdWJsaWNVcmwpIHsgcmV0dXJuIH0KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2ggeyB9CiAgICB9CgogICAgUmVtb3ZlLUl0ZW0gLUxpdGVyYWxQYXRoICRzdGRvdXRQYXRoLCRzdGRlcnJQYXRoIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZQogICAgV3JpdGUtU3RhdGUgJ0Nvbm5lY3RpbmcnIDAgJycgJ1N0YXJ0aW5nIENsb3VkZmxhcmUgUXVpY2sgVHVubmVsIGFuZCB3YWl0aW5nIGZvciBpdHMgdGVtcG9yYXJ5IEhUVFBTIFVSTC4nCiAgICAkcHJvYyA9IFN0YXJ0LVByb2Nlc3MgLUZpbGVQYXRoICRleGUgLUFyZ3VtZW50TGlzdCBAKCd0dW5uZWwnLCAnLS11cmwnLCAiaHR0cDovLzEyNy4wLjAuMTokUG9ydCIpIGAKICAgICAgICAtUGFzc1RocnUgLVdpbmRvd1N0eWxlIEhpZGRlbiAtUmVkaXJlY3RTdGFuZGFyZE91dHB1dCAkc3Rkb3V0UGF0aCAtUmVkaXJlY3RTdGFuZGFyZEVycm9yICRzdGRlcnJQYXRoCiAgICBXcml0ZS1TdGF0ZSAnQ29ubmVjdGluZycgJHByb2MuSWQgJycgJ0Nsb3VkZmxhcmVkIHN0YXJ0ZWQ7IHdhaXRpbmcgZm9yIHRyeWNsb3VkZmxhcmUuY29tIFVSTC4nCgogICAgJHVybCA9ICcnCiAgICBmb3IgKCRpID0gMDsgJGkgLWx0IDEyMDsgJGkrKykgewogICAgICAgICRwID0gR2V0LVByb2Nlc3MgLUlkICRwcm9jLklkIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlCiAgICAgICAgaWYgKC1ub3QgJHApIHsgYnJlYWsgfQogICAgICAgICRhbGwgPSAnJwogICAgICAgIGZvcmVhY2ggKCRmIGluIEAoJHN0ZG91dFBhdGgsJHN0ZGVyclBhdGgpKSB7CiAgICAgICAgICAgIGlmIChUZXN0LVBhdGggJGYpIHsKICAgICAgICAgICAgICAgIHRyeSB7ICRhbGwgKz0gImBuIiArICgoR2V0LUNvbnRlbnQgLUxpdGVyYWxQYXRoICRmIC1UYWlsIDEwMCAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSkgLWpvaW4gImBuIikgfSBjYXRjaCB7IH0KICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICAkbSA9IFtyZWdleF06Ok1hdGNoKCRhbGwsICdodHRwczovL1thLXpBLVowLTktXStcLnRyeWNsb3VkZmxhcmVcLmNvbScpCiAgICAgICAgaWYgKCRtLlN1Y2Nlc3MpIHsgJHVybCA9ICRtLlZhbHVlLlRyaW1FbmQoJy4nKTsgYnJlYWsgfQogICAgICAgIFN0YXJ0LVNsZWVwIC1TZWNvbmRzIDEKICAgIH0KICAgIGlmICgkdXJsKSB7CiAgICAgICAgV3JpdGUtU3RhdGUgJ1J1bm5pbmcnICRwcm9jLklkICR1cmwgJ1F1aWNrIFR1bm5lbCBhY3RpdmUuIFVSTCBpcyB0ZW1wb3JhcnkgYW5kIHB1YmxpYzsgQnJpZGdlIEFQSSBlbmRwb2ludHMgc3RpbGwgcmVxdWlyZSB0aGUgbG9jYWwgQmVhcmVyIGtleS4nCiAgICAgICAgZXhpdCAwCiAgICB9CiAgICAkdGFpbCA9ICcnCiAgICBmb3JlYWNoICgkZiBpbiBAKCRzdGRvdXRQYXRoLCRzdGRlcnJQYXRoKSkgewogICAgICAgIGlmIChUZXN0LVBhdGggJGYpIHsgdHJ5IHsgJHRhaWwgKz0gKChHZXQtQ29udGVudCAtTGl0ZXJhbFBhdGggJGYgLVRhaWwgMzUgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUpIC1qb2luICJgbiIpICsgImBuIiB9IGNhdGNoIHsgfSB9CiAgICB9CiAgICBpZiAoLW5vdCAoR2V0LVByb2Nlc3MgLUlkICRwcm9jLklkIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlKSkgewogICAgICAgIHRocm93ICJjbG91ZGZsYXJlZCBleGl0ZWQgYmVmb3JlIHByb2R1Y2luZyBhIFVSTC4gRGV0YWlsczogJHRhaWwiCiAgICB9CiAgICB0cnkgeyBTdG9wLVByb2Nlc3MgLUlkICRwcm9jLklkIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSB9IGNhdGNoIHsgfQogICAgdGhyb3cgIlRpbWVkIG91dCB3YWl0aW5nIGZvciBDbG91ZGZsYXJlIFF1aWNrIFR1bm5lbCBVUkwuIERldGFpbHM6ICR0YWlsIgogfSBjYXRjaCB7CiAgICB0cnkgewogICAgICAgICR0ZW1wQ2FuZGlkYXRlID0gSm9pbi1QYXRoICR0b29scyAnY2xvdWRmbGFyZWQuZG93bmxvYWQuZXhlJwogICAgICAgIGlmIChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICR0ZW1wQ2FuZGlkYXRlKSB7IFJlbW92ZS1JdGVtIC1MaXRlcmFsUGF0aCAkdGVtcENhbmRpZGF0ZSAtRm9yY2UgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUgfQogICAgfSBjYXRjaCB7IH0KICAgIFdyaXRlLVN0YXRlICdGYWlsZWQnICQoaWYgKCRwcm9jKSB7ICRwcm9jLklkIH0gZWxzZSB7IDAgfSkgJycgKFtzdHJpbmddJF8uRXhjZXB0aW9uLk1lc3NhZ2UpIC0xIDAgMAogICAgZXhpdCAxCn0K'
        $bytes = [Convert]::FromBase64String($encoded)
        [System.IO.File]::WriteAllBytes($target, $bytes)
    }
    return $target
}

function Read-TunnelState {
    if (-not (Test-Path -LiteralPath $script:TunnelStatePath)) { return $null }
    try {
        $state = Get-Content -LiteralPath $script:TunnelStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $state) { return $null }

        # Backward compatibility: tunnel-state.json may come from older releases,
        # before progress and byte-count fields were introduced. StrictMode throws
        # if code directly accesses a missing PSCustomObject property, so migrate
        # the in-memory object before the UI reads it.
        $defaults = [ordered]@{
            status = 'Stopped'
            processId = 0
            publicUrl = ''
            port = 8787
            error = ''
            progress = -1
            bytesDownloaded = 0
            bytesTotal = 0
            updatedAt = ''
        }
        foreach ($name in $defaults.Keys) {
            if ($null -eq $state.PSObject.Properties[$name]) {
                $state | Add-Member -MemberType NoteProperty -Name $name -Value $defaults[$name] -Force
            }
        }
        return $state
    } catch {
        Write-AppLog "Tunnel state could not be read or migrated: $($_.Exception.Message)"
        return $null
    }
}

function Write-TunnelStateLocal([string]$Status, [int]$ProcessId = 0, [string]$Url = '', [string]$ErrorText = '') {
    $state = [ordered]@{ status=$Status; processId=$ProcessId; publicUrl=$Url; port=[int]$script:CurrentSettings.Port; error=$ErrorText; progress=-1; bytesDownloaded=0; bytesTotal=0; updatedAt=(Get-Date).ToString('o') }
    $temp = "$($script:TunnelStatePath).tmp"
    [System.IO.File]::WriteAllText($temp, ($state | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $script:TunnelStatePath -Force
}

function Update-TunnelUi {
    $state = Read-TunnelState
    $status = 'Stopped'
    $url = ''
    $errorText = ''
    if ($state) {
        $status = [string]$state.status
        $url = [string]$state.publicUrl
        $errorText = [string]$state.error
        if ($status -eq 'Running') {
            $pidValue = 0
            [void][int]::TryParse([string]$state.processId, [ref]$pidValue)
            $alive = $false
            if ($pidValue -gt 0) {
                try {
                    $p = Get-Process -Id $pidValue -ErrorAction Stop
                    $alive = ($p.ProcessName -eq 'cloudflared')
                } catch { }
            }
            if (-not $alive) {
                $status = 'Stopped'
                $url = ''
                Write-TunnelStateLocal 'Stopped' 0 '' 'Tunnel process is no longer running.'
            }
        }
    }
    if ($status -eq 'Running' -and $url -match '^https://[a-zA-Z0-9-]+\.trycloudflare\.com$') {
        $script:TunnelPublicUrl = $url.TrimEnd('/')
        if ($script:TunnelStatusCard) { $script:TunnelStatusCard.Text = 'Running · Public HTTPS URL active'; $script:TunnelStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGreen }
        if ($script:TunnelUrlBox) { $script:TunnelUrlBox.Text = $script:TunnelPublicUrl }
        if ($script:TunnelBaseUrlBox) { $script:TunnelBaseUrlBox.Text = "$($script:TunnelPublicUrl)/v1" }
    } else {
        $script:TunnelPublicUrl = ''
        if ($script:TunnelStatusCard) {
            if ($status -eq 'Failed') {
                $script:TunnelStatusCard.Text = "Failed · $errorText"
                $script:TunnelStatusCard.Foreground = [System.Windows.Media.Brushes]::Salmon
            } elseif ($status -in @('Preparing','Downloading','Connecting')) {
                $script:TunnelStatusCard.Text = "$status · waiting for Cloudflare URL"
                $script:TunnelStatusCard.Foreground = [System.Windows.Media.Brushes]::Orange
            } else {
                $script:TunnelStatusCard.Text = 'Stopped · No public URL'
                $script:TunnelStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGray
            }
        }
        if ($script:TunnelUrlBox) { $script:TunnelUrlBox.Text = '' }
        if ($script:TunnelBaseUrlBox) { $script:TunnelBaseUrlBox.Text = '' }
    }
    # Reflect helper progress state in UI. Download percentage is based on actual bytes written.
    if ($script:TunnelProgressBar) {
        $progress = -1
        if ($state -and $null -ne $state.progress) { try { $progress = [int]$state.progress } catch { $progress = -1 } }
        if ($status -eq 'Downloading' -and $progress -lt 0) {
            $script:TunnelProgressBar.IsIndeterminate = $true
            $script:TunnelProgressBar.Value = 0
        } else {
            $script:TunnelProgressBar.IsIndeterminate = $false
            $script:TunnelProgressBar.Value = [Math]::Max(0, [Math]::Min(100, $progress))
        }
    }
    if ($script:TunnelProgressText) {
        if ($status -eq 'Downloading' -and $state) {
            $progress = -1
            if ($null -ne $state.progress) { try { $progress = [int]$state.progress } catch { $progress = -1 } }
            $bytesDone = 0L; $bytesTotal = 0L
            try { $bytesDone = [long]$state.bytesDownloaded } catch { }
            try { $bytesTotal = [long]$state.bytesTotal } catch { }
            if ($progress -ge 0) {
                $script:TunnelProgressText.Text = "Download progress: $progress% · $([Math]::Round($bytesDone / 1MB, 1)) / $([Math]::Round($bytesTotal / 1MB, 1)) MB"
            } else {
                $script:TunnelProgressText.Text = [string]$state.error
            }
        } elseif ($status -eq 'Connecting') {
            $script:TunnelProgressText.Text = 'Download finished. Waiting for Cloudflare to assign the HTTPS URL…'
        } elseif ($status -eq 'Running') {
            $script:TunnelProgressText.Text = 'Tunnel is active.'
        } elseif ($status -eq 'Failed') {
            $script:TunnelProgressText.Text = "Tunnel failed: $errorText"
        } else {
            $script:TunnelProgressText.Text = 'Idle. Start Quick Tunnel to begin.'
        }
    }
    Update-CursorValues
}

function Start-QuickTunnel {
    Save-SettingsFromUi
    if ($script:TunnelPublicUrl) {
        Set-StatusText 'Quick Tunnel already running' 'LightGreen'
        return
    }
    $answer = [System.Windows.MessageBox]::Show(
        "This creates a temporary PUBLIC HTTPS URL using Cloudflare Quick Tunnel. No DNS or Cloudflare account is needed; the URL changes after restart. Anyone with the URL can reach the Bridge, although model/chat endpoints require the separate Bridge Bearer key. Use for testing only. Start tunnel now?",
        'Cloudflare Quick Tunnel - Public Access Warning', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    $port = [int]$script:CurrentSettings.Port
    if (-not [int]::TryParse($script:PortBox.Text.Trim(), [ref]$port)) { throw 'Invalid Bridge port.' }
    # Ensure the local origin responds before publishing it.
    $ready = $false
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 -ErrorAction Stop
        $ready = [bool]$health.ok
    } catch { }
    if (-not $ready) {
        $answerBridge = [System.Windows.MessageBox]::Show('The local Bridge is not responding. Start / Apply Bridge first, then retry the tunnel.', 'Bridge required', 'OKCancel', 'Warning')
        Set-StatusText 'Start Bridge before starting the tunnel' 'Orange'
        return
    }

    $helper = Ensure-TunnelHelper
    Write-TunnelStateLocal 'Preparing' 0 '' 'Preparing Cloudflare Quick Tunnel.'
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Start -Port {1} -AppDataDir "{2}"' -f $helper, $port, $script:AppDataDir
    $script:TunnelHelperProcess = Start-Process -FilePath $psExe -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
    Write-AppLog "Started Cloudflare Quick Tunnel helper; port=$port; helperPid=$($script:TunnelHelperProcess.Id)."
    if ($script:TunnelStatusCard) { $script:TunnelStatusCard.Text = 'Starting · downloading/checking cloudflared if needed'; $script:TunnelStatusCard.Foreground = [System.Windows.Media.Brushes]::Orange }
    Set-StatusText 'Starting public Quick Tunnel…' 'Orange'
    Update-TunnelUi
}

function Stop-QuickTunnel {
    $state = Read-TunnelState
    if ($script:TunnelHelperProcess) {
        try { if (-not $script:TunnelHelperProcess.HasExited) { $script:TunnelHelperProcess.Kill() } } catch { }
        $script:TunnelHelperProcess = $null
    }
    if ($state -and [int]$state.processId -gt 0) {
        $pidValue = [int]$state.processId
        try {
            $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction Stop
            $cloudflared = Join-Path (Join-Path $script:AppDataDir 'tools') 'cloudflared.exe'
            if ($procInfo -and [string]$procInfo.ExecutablePath -eq $cloudflared) {
                Stop-Process -Id $pidValue -Force -ErrorAction Stop
                Write-AppLog "Stopped Cloudflare Quick Tunnel process PID=$pidValue."
            }
        } catch { Write-AppLog "Tunnel stop note: $($_.Exception.Message)" }
    }
    try { Write-TunnelStateLocal 'Stopped' 0 '' '' } catch { }
    $script:TunnelPublicUrl = ''
    Update-CursorValues
    if ($script:TunnelStatusCard) { $script:TunnelStatusCard.Text = 'Stopped · No public URL'; $script:TunnelStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGray }
    Set-StatusText 'Quick Tunnel stopped' 'LightGray'
    Refresh-LogView
}

function Copy-TunnelPublicUrl {
    if ([string]::IsNullOrWhiteSpace($script:TunnelPublicUrl)) { throw 'Start the Quick Tunnel and wait for its HTTPS URL first.' }
    Copy-Text $script:TunnelPublicUrl 'Cloudflare public tunnel URL'
}
function Copy-TunnelBaseUrl {
    if ([string]::IsNullOrWhiteSpace($script:TunnelPublicUrl)) { throw 'Start the Quick Tunnel and wait for its HTTPS URL first.' }
    Copy-Text "$($script:TunnelPublicUrl)/v1" 'Cursor public Bridge Base URL'
}

$xamlBase64 = 'PFdpbmRvdyB4bWxucz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS93aW5meC8yMDA2L3hhbWwvcHJlc2VudGF0aW9uIgogICAgICAgIHhtbG5zOng9Imh0dHA6Ly9zY2hlbWFzLm1pY3Jvc29mdC5jb20vd2luZngvMjAwNi94YW1sIgogICAgICAgIFRpdGxlPSJBSSBQcmltZSBDdXJzb3IgTWFuYWdlciIgSGVpZ2h0PSI4NTAiIFdpZHRoPSIxMTgwIgogICAgICAgIE1pbkhlaWdodD0iNzIwIiBNaW5XaWR0aD0iMTAyMCIgV2luZG93U3RhcnR1cExvY2F0aW9uPSJDZW50ZXJTY3JlZW4iCiAgICAgICAgQmFja2dyb3VuZD0iIzBCMTIyMCIgRm9yZWdyb3VuZD0iI0U1RTdFQiIgRm9udEZhbWlseT0iU2Vnb2UgVUkiPgogIDxXaW5kb3cuUmVzb3VyY2VzPgogICAgPFNvbGlkQ29sb3JCcnVzaCB4OktleT0iUGFuZWxCcnVzaCIgQ29sb3I9IiMxMTFCMkQiLz4KICAgIDxTb2xpZENvbG9yQnJ1c2ggeDpLZXk9IlBhbmVsMkJydXNoIiBDb2xvcj0iIzE3MjMzOCIvPgogICAgPFNvbGlkQ29sb3JCcnVzaCB4OktleT0iQWNjZW50QnJ1c2giIENvbG9yPSIjNUI4REVGIi8+CiAgICA8U29saWRDb2xvckJydXNoIHg6S2V5PSJNdXRlZEJydXNoIiBDb2xvcj0iIzk0QTNCOCIvPgogICAgPFN0eWxlIFRhcmdldFR5cGU9IlRleHRCbG9jayI+PFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IiNFNUU3RUIiLz48U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSIwLDIsMCwyIi8+PC9TdHlsZT4KICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJMYWJlbCI+PFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IiNCOEM0RDgiLz48U2V0dGVyIFByb3BlcnR5PSJQYWRkaW5nIiBWYWx1ZT0iMCwzLDAsNCIvPjwvU3R5bGU+CiAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iVGV4dEJveCI+PFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IiMwQjEyMjAiLz48U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0iI0U1RTdFQiIvPjxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0iIzMzNDE1NSIvPjxTZXR0ZXIgUHJvcGVydHk9IlBhZGRpbmciIFZhbHVlPSI5LDciLz48U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSIwLDQsMCw5Ii8+PFNldHRlciBQcm9wZXJ0eT0iQ2FyZXRCcnVzaCIgVmFsdWU9IldoaXRlIi8+PC9TdHlsZT4KICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJQYXNzd29yZEJveCI+PFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IiMwQjEyMjAiLz48U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0iI0U1RTdFQiIvPjxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0iIzMzNDE1NSIvPjxTZXR0ZXIgUHJvcGVydHk9IlBhZGRpbmciIFZhbHVlPSI5LDciLz48U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSIwLDQsMCw5Ii8+PC9TdHlsZT4KICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJDb21ib0JveCI+PFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IiMwQjEyMjAiLz48U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0iI0U1RTdFQiIvPjxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0iIzMzNDE1NSIvPjxTZXR0ZXIgUHJvcGVydHk9IlBhZGRpbmciIFZhbHVlPSI4Ii8+PFNldHRlciBQcm9wZXJ0eT0iTWluSGVpZ2h0IiBWYWx1ZT0iMzgiLz48U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSIwLDQsMCw4Ii8+PC9TdHlsZT4KICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJDb21ib0JveEl0ZW0iPjxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSIjMTExQjJEIi8+PFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IiNFNUU3RUIiLz48U2V0dGVyIFByb3BlcnR5PSJQYWRkaW5nIiBWYWx1ZT0iOSw3Ii8+PFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSIjMjQzNDRCIi8+PFN0eWxlLlRyaWdnZXJzPjxUcmlnZ2VyIFByb3BlcnR5PSJJc0hpZ2hsaWdodGVkIiBWYWx1ZT0iVHJ1ZSI+PFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IiMyNjNBNTkiLz48L1RyaWdnZXI+PFRyaWdnZXIgUHJvcGVydHk9IklzU2VsZWN0ZWQiIFZhbHVlPSJUcnVlIj48U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0iIzMxNUI5MSIvPjxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSIjRkZGRkZGIi8+PC9UcmlnZ2VyPjwvU3R5bGUuVHJpZ2dlcnM+PC9TdHlsZT4KICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJCdXR0b24iPjxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSIjMjYzQTU5Ii8+PFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IiNGOEZBRkMiLz48U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJCcnVzaCIgVmFsdWU9IiMzQjUyNkYiLz48U2V0dGVyIFByb3BlcnR5PSJQYWRkaW5nIiBWYWx1ZT0iMTQsOSIvPjxTZXR0ZXIgUHJvcGVydHk9Ik1pbkhlaWdodCIgVmFsdWU9IjM2Ii8+PFNldHRlciBQcm9wZXJ0eT0iTWFyZ2luIiBWYWx1ZT0iMCw0LDgsNCIvPjxTZXR0ZXIgUHJvcGVydHk9IkN1cnNvciIgVmFsdWU9IkhhbmQiLz48U2V0dGVyIFByb3BlcnR5PSJGb250V2VpZ2h0IiBWYWx1ZT0iU2VtaUJvbGQiLz48L1N0eWxlPgogICAgPFN0eWxlIFRhcmdldFR5cGU9IkNoZWNrQm94Ij48U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0iI0QxRDlFNiIvPjxTZXR0ZXIgUHJvcGVydHk9Ik1hcmdpbiIgVmFsdWU9IjAsNiwwLDkiLz48L1N0eWxlPgogICAgPFN0eWxlIFRhcmdldFR5cGU9IlRhYkl0ZW0iPjxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSIjQ0JENUUxIi8+PFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IiMxMTFCMkQiLz48U2V0dGVyIFByb3BlcnR5PSJQYWRkaW5nIiBWYWx1ZT0iMTgsMTAiLz48U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSIwLDAsNSwwIi8+PC9TdHlsZT4KICA8L1dpbmRvdy5SZXNvdXJjZXM+CiAgPEdyaWQgTWFyZ2luPSIyMiI+CiAgICA8R3JpZC5Sb3dEZWZpbml0aW9ucz48Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz48Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz48Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiLz48Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz48L0dyaWQuUm93RGVmaW5pdGlvbnM+CiAgICA8R3JpZCBHcmlkLlJvdz0iMCIgTWFyZ2luPSIwLDAsMCwxNCI+CiAgICAgIDxHcmlkLkNvbHVtbkRlZmluaXRpb25zPjxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+PENvbHVtbkRlZmluaXRpb24gV2lkdGg9IkF1dG8iLz48L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgIDxTdGFja1BhbmVsPgogICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iQUkgUHJpbWUgQ3Vyc29yIE1hbmFnZXIiIEZvbnRTaXplPSIyNiIgRm9udFdlaWdodD0iQm9sZCIgRm9yZWdyb3VuZD0iI0Y4RkFGQyIvPgogICAgICAgIDxUZXh0QmxvY2sgVGV4dD0idjEuNyDCtyBCYWNrd2FyZC1jb21wYXRpYmxlIHR1bm5lbCBzdGF0ZSDCtyBkb3dubG9hZCBwcm9ncmVzcyDCtyBDbG91ZGZsYXJlIHN0YXJ0dXAiIEZvcmVncm91bmQ9IiM5NEEzQjgiIEZvbnRTaXplPSIxMiIvPgogICAgICA8L1N0YWNrUGFuZWw+CiAgICAgIDxCb3JkZXIgR3JpZC5Db2x1bW49IjEiIEJhY2tncm91bmQ9IiMxNzIzMzgiIENvcm5lclJhZGl1cz0iOSIgUGFkZGluZz0iMTIsOCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciI+CiAgICAgICAgPFN0YWNrUGFuZWwgT3JpZW50YXRpb249Ikhvcml6b250YWwiPjxFbGxpcHNlIFdpZHRoPSI4IiBIZWlnaHQ9IjgiIEZpbGw9IiM2NDc0OEIiIE1hcmdpbj0iMCwwLDgsMCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIvPjxUZXh0QmxvY2sgeDpOYW1lPSJPdmVyYWxsU3RhdHVzIiBUZXh0PSJSZWFkeSIgRm9yZWdyb3VuZD0iI0NCRDVFMSIgRm9udFdlaWdodD0iU2VtaUJvbGQiLz48L1N0YWNrUGFuZWw+CiAgICAgIDwvQm9yZGVyPgogICAgPC9HcmlkPgogICAgPEJvcmRlciBHcmlkLlJvdz0iMSIgQmFja2dyb3VuZD0iIzE4MjY0MCIgQ29ybmVyUmFkaXVzPSI4IiBQYWRkaW5nPSIxMiIgTWFyZ2luPSIwLDAsMCwxNCI+CiAgICAgIDxUZXh0QmxvY2sgVGV4dFdyYXBwaW5nPSJXcmFwIiBGb250U2l6ZT0iMTIiIEZvcmVncm91bmQ9IiNDN0Q3RjIiIFRleHQ9IlNlY3VyaXR5OiB0aGUgQUkgUHJpbWUgVGVjaCBrZXkgc3RheXMgaW4gdGhpcyBXaW5kb3dzIGFwcCBhbmQgaXMgc2VudCBvbmx5IHRvIEFJIFByaW1lIFRlY2guIEN1cnNvciByZWNlaXZlcyBhIHNlcGFyYXRlIGxvY2FsIGJyaWRnZSBrZXkuIEtleXMgYXJlIG5ldmVyIHdyaXR0ZW4gdG8gbG9ncy4gVGhlIGxvY2FsIGJyaWRnZSBiaW5kcyB0byAxMjcuMC4wLjEgb25seS4iLz4KICAgIDwvQm9yZGVyPgogICAgPFRhYkNvbnRyb2wgeDpOYW1lPSJNYWluVGFicyIgR3JpZC5Sb3c9IjIiIEJhY2tncm91bmQ9IiMwQjEyMjAiIEJvcmRlckJydXNoPSIjMjUzNDRCIj4KICAgICAgPFRhYkl0ZW0gSGVhZGVyPSJEYXNoYm9hcmQiPgogICAgICAgIDxTY3JvbGxWaWV3ZXIgVmVydGljYWxTY3JvbGxCYXJWaXNpYmlsaXR5PSJBdXRvIj4KICAgICAgICAgIDxTdGFja1BhbmVsIE1hcmdpbj0iMTYiPgogICAgICAgICAgICA8R3JpZCBNYXJnaW49IjAsMCwwLDEyIj4KICAgICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz48Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iKiIvPjxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+PENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz48L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLkNvbHVtbj0iMCIgQmFja2dyb3VuZD0iIzExMUIyRCIgQ29ybmVyUmFkaXVzPSIxMCIgUGFkZGluZz0iMTQiIE1hcmdpbj0iMCwwLDEwLDAiPjxTdGFja1BhbmVsPjxUZXh0QmxvY2sgVGV4dD0iQUkgUFJJTUUgVEVDSCBBUEkiIEZvcmVncm91bmQ9IiM5NEEzQjgiIEZvbnRTaXplPSIxMSIgRm9udFdlaWdodD0iQm9sZCIvPjxUZXh0QmxvY2sgeDpOYW1lPSJBcGlTdGF0dXNDYXJkIiBUZXh0PSJOb3QgdGVzdGVkIiBGb250U2l6ZT0iMTgiIEZvbnRXZWlnaHQ9IlNlbWlCb2xkIiBNYXJnaW49IjAsNiwwLDAiLz48VGV4dEJsb2NrIFRleHQ9Ik1vZGVscyBhbmQgY2hhdCBjb21wbGV0aW9uIiBGb3JlZ3JvdW5kPSIjNjQ3NDhCIiBGb250U2l6ZT0iMTEiLz48L1N0YWNrUGFuZWw+PC9Cb3JkZXI+CiAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLkNvbHVtbj0iMSIgQmFja2dyb3VuZD0iIzExMUIyRCIgQ29ybmVyUmFkaXVzPSIxMCIgUGFkZGluZz0iMTQiIE1hcmdpbj0iMCwwLDEwLDAiPjxTdGFja1BhbmVsPjxUZXh0QmxvY2sgVGV4dD0iTE9DQUwgQlJJREdFIiBGb3JlZ3JvdW5kPSIjOTRBM0I4IiBGb250U2l6ZT0iMTEiIEZvbnRXZWlnaHQ9IkJvbGQiLz48VGV4dEJsb2NrIHg6TmFtZT0iQnJpZGdlU3RhdHVzQ2FyZCIgVGV4dD0iU3RvcHBlZCIgRm9udFNpemU9IjE4IiBGb250V2VpZ2h0PSJTZW1pQm9sZCIgTWFyZ2luPSIwLDYsMCwwIi8+PFRleHRCbG9jayB4Ok5hbWU9IkJyaWRnZVBvcnRDYXJkIiBUZXh0PSIxMjcuMC4wLjE6ODc4NyIgRm9yZWdyb3VuZD0iIzY0NzQ4QiIgRm9udFNpemU9IjExIi8+PC9TdGFja1BhbmVsPjwvQm9yZGVyPgogICAgICAgICAgICAgIDxCb3JkZXIgR3JpZC5Db2x1bW49IjIiIEJhY2tncm91bmQ9IiMxMTFCMkQiIENvcm5lclJhZGl1cz0iMTAiIFBhZGRpbmc9IjE0Ij48U3RhY2tQYW5lbD48VGV4dEJsb2NrIFRleHQ9IkNVUlNPUiBNT0RFTCBBTElBUyIgRm9yZWdyb3VuZD0iIzk0QTNCOCIgRm9udFNpemU9IjExIiBGb250V2VpZ2h0PSJCb2xkIi8+PFRleHRCbG9jayB4Ok5hbWU9IkFsaWFzQ2FyZCIgVGV4dD0iYWlwcmltZXRlY2gtc29ubmV0LTQtNiIgRm9udFNpemU9IjE1IiBGb250V2VpZ2h0PSJTZW1pQm9sZCIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsNiwwLDAiLz48VGV4dEJsb2NrIFRleHQ9IkZvcndhcmRlZCB0byBjaG9zZW4gdXBzdHJlYW0gbW9kZWwiIEZvcmVncm91bmQ9IiM2NDc0OEIiIEZvbnRTaXplPSIxMSIvPjwvU3RhY2tQYW5lbD48L0JvcmRlcj4KICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICA8Qm9yZGVyIEJhY2tncm91bmQ9IiMxMTFCMkQiIENvcm5lclJhZGl1cz0iMTAiIFBhZGRpbmc9IjE2IiBNYXJnaW49IjAsMCwwLDEyIj4KICAgICAgICAgICAgICA8U3RhY2tQYW5lbD4KICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iQUkgUHJpbWUgVGVjaCBjb25uZWN0aW9uIiBGb250U2l6ZT0iMTciIEZvbnRXZWlnaHQ9IlNlbWlCb2xkIiBNYXJnaW49IjAsMCwwLDEwIi8+CiAgICAgICAgICAgICAgICA8TGFiZWwgQ29udGVudD0iQVBJIEJhc2UgVVJMIi8+PFRleHRCb3ggeDpOYW1lPSJBcGlCYXNlVXJsQm94IiBUZXh0PSJodHRwczovL2FpcHJpbWV0ZWNoLmlvL3YxIi8+CiAgICAgICAgICAgICAgICA8TGFiZWwgQ29udGVudD0iQUkgUHJpbWUgVGVjaCBBUEkgS2V5Ii8+PFBhc3N3b3JkQm94IHg6TmFtZT0iQXBpS2V5Qm94Ii8+CiAgICAgICAgICAgICAgICA8Q2hlY2tCb3ggeDpOYW1lPSJSZW1lbWJlcktleUNoZWNrIiBDb250ZW50PSJSZW1lbWJlciBBUEkga2V5IGVuY3J5cHRlZCBmb3IgdGhpcyBXaW5kb3dzIGFjY291bnQgKG9wdGlvbmFsKSIgSXNDaGVja2VkPSJGYWxzZSIvPgogICAgICAgICAgICAgICAgPERvY2tQYW5lbCBNYXJnaW49IjAsNCwwLDAiIExhc3RDaGlsZEZpbGw9IkZhbHNlIj4KICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayB4Ok5hbWU9Ik1vZGVsQ291bnRMYWJlbCIgVGV4dD0iS0VZIENBVEFMT0cgwrcgTm90IGxvYWRlZCB5ZXQiIEZvcmVncm91bmQ9IiM3REE5RjciIEZvbnRTaXplPSIxMSIgRm9udFdlaWdodD0iQm9sZCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIvPgogICAgICAgICAgICAgICAgICA8QnV0dG9uIHg6TmFtZT0iU3Ryb25nZXN0TW9kZWxCdXR0b24iIENvbnRlbnQ9IuKcpiBTZWxlY3Qgc3Ryb25nZXN0IiBCYWNrZ3JvdW5kPSIjM0QyRDY0IiBCb3JkZXJCcnVzaD0iIzY1NTE5QiIgRG9ja1BhbmVsLkRvY2s9IlJpZ2h0IiBNYXJnaW49IjgsMCwwLDAiLz4KICAgICAgICAgICAgICAgIDwvRG9ja1BhbmVsPgogICAgICAgICAgICAgICAgPExhYmVsIENvbnRlbnQ9IkNob29zZSB0aGUgdXBzdHJlYW0gbW9kZWwgKGV4YWN0IElEIHJldHVybmVkIGJ5IHlvdXIga2V5KSIvPgogICAgICAgICAgICAgICAgPENvbWJvQm94IHg6TmFtZT0iTW9kZWxDb21ibyIgSXNFZGl0YWJsZT0iRmFsc2UiIElzVGV4dFNlYXJjaEVuYWJsZWQ9IlRydWUiIFN0YXlzT3Blbk9uRWRpdD0iRmFsc2UiIFRleHQ9ImNsYXVkZS1zb25uZXQtNC02IiBUb29sVGlwPSJGZXRjaCBNb2RlbHMgbG9hZHMgdGhlIG1vZGVscyBhdmFpbGFibGUgdG8gdGhpcyBBUEkga2V5LiBTZWxlY3Qgb25lIGhlcmU7IHRoZSBicmlkZ2Ugd2lsbCBmb3J3YXJkIHJlcXVlc3RzIHRvIHRoZSBzZWxlY3RlZCBJRC4iLz4KICAgICAgICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0iIzBCMTcyOCIgQm9yZGVyQnJ1c2g9IiMyNjNBNTkiIEJvcmRlclRoaWNrbmVzcz0iMSIgQ29ybmVyUmFkaXVzPSI4IiBQYWRkaW5nPSIxMSIgTWFyZ2luPSIwLDAsMCw3Ij4KICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJNT0RFTCBHVUlERSIgRm9yZWdyb3VuZD0iIzdEQTlGNyIgRm9udFNpemU9IjEwIiBGb250V2VpZ2h0PSJCb2xkIiBNYXJnaW49IjAsMCwwLDQiLz4KICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIHg6TmFtZT0iTW9kZWxSZWNvbW1lbmRhdGlvblRleHQiIFRleHQ9IkZldGNoIG1vZGVscyBmcm9tIHlvdXIga2V5LCB0aGVuIGNob29zZSBhIG1vZGVsIGZyb20gdGhlIGxpc3QuIiBGb3JlZ3JvdW5kPSIjQzREM0U4IiBUZXh0V3JhcHBpbmc9IldyYXAiIEZvbnRTaXplPSIxMiIvPgogICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgIDxXcmFwUGFuZWwgTWFyZ2luPSIwLDMsMCwwIj4KICAgICAgICAgICAgICAgICAgPEJ1dHRvbiB4Ok5hbWU9IlRlc3RBcGlCdXR0b24iIENvbnRlbnQ9IlRlc3Qgc2VsZWN0ZWQgbW9kZWwiIEJhY2tncm91bmQ9IiMyNTYzRUIiLz4KICAgICAgICAgICAgICAgICAgPEJ1dHRvbiB4Ok5hbWU9IkZldGNoTW9kZWxzQnV0dG9uIiBDb250ZW50PSJSZWZyZXNoIG1vZGVsIGNhdGFsb2ciLz4KICAgICAgICAgICAgICAgICAgPEJ1dHRvbiB4Ok5hbWU9IlNhdmVTZXR0aW5nc0J1dHRvbiIgQ29udGVudD0iU2F2ZSBzZXR0aW5ncyIvPgogICAgICAgICAgICAgICAgICA8QnV0dG9uIHg6TmFtZT0iRm9yZ2V0S2V5QnV0dG9uIiBDb250ZW50PSJGb3JnZXQga2V5IiBCYWNrZ3JvdW5kPSIjNTQyQjM4IiBCb3JkZXJCcnVzaD0iIzg0NDQ1NiIvPgogICAgICAgICAgICAgICAgPC9XcmFwUGFuZWw+CiAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9Ik1vZGVsIHNlbGVjdGlvbiBpcyB0YWtlbiBmcm9tIHRoZSBBUEkgY2F0YWxvZy4gQWZ0ZXIgY2hhbmdpbmcgYSBtb2RlbCwgY2xpY2sgU3RhcnQgLyBBcHBseSBCcmlkZ2UgdG8gcmVzdGFydCB0aGUgbG9jYWwgYnJpZGdlIHdpdGggdGhhdCBtb2RlbC4iIEZvcmVncm91bmQ9IiM5NEEzQjgiIEZvbnRTaXplPSIxMSIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsNiwwLDAiLz4KICAgICAgICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0iIzEwMjUxRiIgQm9yZGVyQnJ1c2g9IiMxRjVBNDMiIEJvcmRlclRoaWNrbmVzcz0iMSIgQ29ybmVyUmFkaXVzPSI3IiBQYWRkaW5nPSIxMCIgTWFyZ2luPSIwLDgsMCwwIj4KICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayB4Ok5hbWU9IkFwaVRlc3RSZXN1bHRUZXh0IiBUZXh0PSJSZWFkeSDCtyBGZXRjaCBtb2RlbHMgdG8gbG9hZCB0aGUgbW9kZWxzIGF2YWlsYWJsZSB0byB0aGlzIEFQSSBrZXkuIiBGb3JlZ3JvdW5kPSIjQTdDOEJDIiBGb250U2l6ZT0iMTIiIFRleHRXcmFwcGluZz0iV3JhcCIvPgogICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSIjMTExQjJEIiBDb3JuZXJSYWRpdXM9IjEwIiBQYWRkaW5nPSIxNiI+CiAgICAgICAgICAgICAgPFN0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IkxvY2FsIGJyaWRnZSBjb250cm9scyIgRm9udFNpemU9IjE3IiBGb250V2VpZ2h0PSJTZW1pQm9sZCIgTWFyZ2luPSIwLDAsMCwxMCIvPgogICAgICAgICAgICAgICAgPEdyaWQ+PEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+PENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz48Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iMTYwIi8+PC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPjxTdGFja1BhbmVsPjxMYWJlbCBDb250ZW50PSJMb2NhbCBwb3J0IChsb29wYmFjayBvbmx5KSIvPjxUZXh0Qm94IHg6TmFtZT0iUG9ydEJveCIgVGV4dD0iODc4NyIgV2lkdGg9IjEzMCIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIvPjxUZXh0QmxvY2sgVGV4dD0iVGhlIGxvY2FsIGJyaWRnZSBsaXN0ZW5zIG9uIDEyNy4wLjAuMS4gVXNlIHRoZSBDbG91ZGZsYXJlIFR1bm5lbCB0YWIgaWYgcmVtb3RlIEN1cnNvciBjYW5ub3QgcmVhY2ggbG9jYWxob3N0LiIgRm9yZWdyb3VuZD0iIzk0QTNCOCIgRm9udFNpemU9IjExIi8+PC9TdGFja1BhbmVsPjxTdGFja1BhbmVsIEdyaWQuQ29sdW1uPSIxIj48QnV0dG9uIHg6TmFtZT0iU3RhcnRCcmlkZ2VCdXR0b24iIENvbnRlbnQ9IuKWtiAgU3RhcnQgLyBBcHBseSBCcmlkZ2UiIEJhY2tncm91bmQ9IiMxNjgxNUYiIEJvcmRlckJydXNoPSIjMjE5ODc5IiBNYXJnaW49IjAsMTQsMCw4Ii8+PEJ1dHRvbiB4Ok5hbWU9IlN0b3BCcmlkZ2VCdXR0b24iIENvbnRlbnQ9IuKWoCAgU3RvcCBCcmlkZ2UiIEJhY2tncm91bmQ9IiM1NDJCMzgiIEJvcmRlckJydXNoPSIjODQ0NDU2Ii8+PC9TdGFja1BhbmVsPjwvR3JpZD4KICAgICAgICAgICAgICAgIDxXcmFwUGFuZWwgTWFyZ2luPSIwLDgsMCwwIj48QnV0dG9uIHg6TmFtZT0iVGVzdEJyaWRnZUJ1dHRvbiIgQ29udGVudD0iVGVzdCBCcmlkZ2UiLz48QnV0dG9uIHg6TmFtZT0iT3BlbkN1cnNvclNldHVwQnV0dG9uIiBDb250ZW50PSJDdXJzb3IgU2V0dXAg4oaSIiBCYWNrZ3JvdW5kPSIjMjU2M0VCIi8+PC9XcmFwUGFuZWw+CiAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICA8L1Njcm9sbFZpZXdlcj4KICAgICAgPC9UYWJJdGVtPgogICAgICA8VGFiSXRlbSBIZWFkZXI9IkN1cnNvciBTZXR1cCI+CiAgICAgICAgPFNjcm9sbFZpZXdlciBWZXJ0aWNhbFNjcm9sbEJhclZpc2liaWxpdHk9IkF1dG8iPjxTdGFja1BhbmVsIE1hcmdpbj0iMTgiPgogICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJVc2UgdGhlc2UgdmFsdWVzIGluIHlvdXIgc2VwYXJhdGUgQ3Vyc29yIHByb2ZpbGUiIEZvbnRTaXplPSIxOSIgRm9udFdlaWdodD0iU2VtaUJvbGQiIE1hcmdpbj0iMCwwLDAsNSIvPgogICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJJbiBDdXJzb3IgU2V0dGluZ3Mg4oaSIE1vZGVscywgZW5hYmxlIFVzZSBPcGVuQUkgQVBJIEtleSBhbmQgT3ZlcnJpZGUgT3BlbkFJIEJhc2UgVVJMLiBVc2UgdGhlIGxvY2FsIGJyaWRnZSBrZXkgYmVsb3csIG5vdCB5b3VyIEFJIFByaW1lIFRlY2gga2V5LiIgRm9yZWdyb3VuZD0iIzk0QTNCOCIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDE2Ii8+CiAgICAgICAgICA8Qm9yZGVyIEJhY2tncm91bmQ9IiMxMTFCMkQiIENvcm5lclJhZGl1cz0iMTAiIFBhZGRpbmc9IjE2IiBNYXJnaW49IjAsMCwwLDEyIj48U3RhY2tQYW5lbD4KICAgICAgICAgICAgPExhYmVsIENvbnRlbnQ9Ik9wZW5BSS1jb21wYXRpYmxlIEJhc2UgVVJMIi8+PERvY2tQYW5lbD48VGV4dEJveCB4Ok5hbWU9IkN1cnNvckJhc2VMYWJlbCIgSXNSZWFkT25seT0iVHJ1ZSIgVGV4dD0iaHR0cDovLzEyNy4wLjAuMTo4Nzg3L3YxIi8+PEJ1dHRvbiB4Ok5hbWU9IkNvcHlCYXNlQnV0dG9uIiBDb250ZW50PSJDb3B5IiBEb2NrUGFuZWwuRG9jaz0iUmlnaHQiLz48L0RvY2tQYW5lbD4KICAgICAgICAgICAgPExhYmVsIENvbnRlbnQ9IkFQSSBLZXkgZm9yIEN1cnNvciAobG9jYWwgYnJpZGdlIGtleSkiLz48RG9ja1BhbmVsPjxQYXNzd29yZEJveCB4Ok5hbWU9IkN1cnNvcktleVBhc3N3b3JkIi8+PFRleHRCb3ggeDpOYW1lPSJDdXJzb3JLZXlSZXZlYWxCb3giIFZpc2liaWxpdHk9IkNvbGxhcHNlZCIgSXNSZWFkT25seT0iVHJ1ZSIvPjxCdXR0b24geDpOYW1lPSJSZXZlYWxLZXlCdXR0b24iIENvbnRlbnQ9IlJldmVhbCIgRG9ja1BhbmVsLkRvY2s9IlJpZ2h0Ii8+PEJ1dHRvbiB4Ok5hbWU9IkNvcHlLZXlCdXR0b24iIENvbnRlbnQ9IkNvcHkgS2V5IiBEb2NrUGFuZWwuRG9jaz0iUmlnaHQiLz48L0RvY2tQYW5lbD4KICAgICAgICAgICAgPExhYmVsIENvbnRlbnQ9IkN1c3RvbSBtb2RlbCBJRCB0byBhZGQiLz48RG9ja1BhbmVsPjxUZXh0Qm94IHg6TmFtZT0iQ3Vyc29yTW9kZWxMYWJlbCIgSXNSZWFkT25seT0iVHJ1ZSIgVGV4dD0iYWlwcmltZXRlY2gtc29ubmV0LTQtNiIvPjxCdXR0b24geDpOYW1lPSJDb3B5TW9kZWxCdXR0b24iIENvbnRlbnQ9IkNvcHkiIERvY2tQYW5lbC5Eb2NrPSJSaWdodCIvPjwvRG9ja1BhbmVsPgogICAgICAgICAgICA8V3JhcFBhbmVsPjxCdXR0b24geDpOYW1lPSJDb3B5QWxsQnV0dG9uIiBDb250ZW50PSJDb3B5IFNldHVwIFN1bW1hcnkiIEJhY2tncm91bmQ9IiMyNTYzRUIiLz48QnV0dG9uIHg6TmFtZT0iQ29weUpzb25CdXR0b24iIENvbnRlbnQ9IkNvcHkgTUNQIEpTT04gKGluZm8gb25seSkiLz48L1dyYXBQYW5lbD4KICAgICAgICAgIDwvU3RhY2tQYW5lbD48L0JvcmRlcj4KICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0iIzE3MjMzOCIgQ29ybmVyUmFkaXVzPSIxMCIgUGFkZGluZz0iMTUiPjxTdGFja1BhbmVsPgogICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IlNldHVwIHN0ZXBzIiBGb250V2VpZ2h0PSJTZW1pQm9sZCIgRm9udFNpemU9IjE1IiBNYXJnaW49IjAsMCwwLDgiLz4KICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSIxLiBTdGFydCAvIEFwcGx5IEJyaWRnZSBmcm9tIERhc2hib2FyZC4iIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDIiLz4KICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSIyLiBJZiBDdXJzb3Igc2F5cyBwcml2YXRlIG5ldHdvcmtzIGFyZSBmb3JiaWRkZW4sIG9wZW4gdGhlIENsb3VkZmxhcmUgVHVubmVsIHRhYiBhbmQgY2xpY2sgU3RhcnQgUXVpY2sgVHVubmVsLiIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMiIvPgogICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IjMuIEluIEN1cnNvciBTZXR0aW5ncyDihpIgTW9kZWxzLCBlbmFibGUgVXNlIE9wZW5BSSBBUEkgS2V5IGFuZCBwYXN0ZSB0aGUgbG9jYWwgQnJpZGdlIGtleS4iIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDIiLz4KICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSI0LiBFbmFibGUgT3ZlcnJpZGUgT3BlbkFJIEJhc2UgVVJMIGFuZCBwYXN0ZSB0aGUgQmFzZSBVUkwgc2hvd24gaGVyZS4gV2hlbiBRdWljayBUdW5uZWwgaXMgYWN0aXZlLCB0aGlzIGlzIHRoZSBwdWJsaWMgSFRUUFMgVVJMLiIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMiIvPgogICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IjUuIEFkZCB0aGUgY3VzdG9tIG1vZGVsIElEIGFib3ZlIGFuZCB0cnkgaXQgaW4gQ3Vyc29yLiBUaGUgcHVibGljIFVSTCBjaGFuZ2VzIHdoZW5ldmVyIGEgUXVpY2sgVHVubmVsIGlzIHJlc3RhcnRlZC4iIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDIiLz4KICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJJbXBvcnRhbnQ6IEN1cnNvciBtYXkgc3RpbGwgcmVzdHJpY3Qgc2VsZWN0aW5nIGEgY3VzdG9tIEJZT0sgbW9kZWwgaW5kZXBlbmRlbnRseSBmb3IgdGhlIGJ1aWx0LWluIEV4cGxvcmUgU3ViYWdlbnQuIFRoaXMgbWFuYWdlciBkb2VzIG5vdCBieXBhc3MgQ3Vyc29yIHByb2R1Y3QgbGltaXRhdGlvbnMuIiBGb3JlZ3JvdW5kPSIjRkJCRjI0IiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCw4LDAsMCIvPgogICAgICAgICAgPC9TdGFja1BhbmVsPjwvQm9yZGVyPgogICAgICAgIDwvU3RhY2tQYW5lbD48L1Njcm9sbFZpZXdlcj4KICAgICAgPC9UYWJJdGVtPgogICAgICA8VGFiSXRlbSBIZWFkZXI9IkxvZ3MiPgogICAgICAgIDxHcmlkIE1hcmdpbj0iMTQiPjxHcmlkLlJvd0RlZmluaXRpb25zPjxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPjxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPjwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgIDxEb2NrUGFuZWwgR3JpZC5Sb3c9IjAiIE1hcmdpbj0iMCwwLDAsOCI+PFRleHRCbG9jayBUZXh0PSJSdW50aW1lIGFuZCBBUEkgYWN0aXZpdHkgKGNyZWRlbnRpYWxzIGFyZSBub3QgbG9nZ2VkKSIgRm9yZWdyb3VuZD0iIzk0QTNCOCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIvPjxTdGFja1BhbmVsIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBEb2NrUGFuZWwuRG9jaz0iUmlnaHQiPjxCdXR0b24geDpOYW1lPSJSZWZyZXNoTG9nc0J1dHRvbiIgQ29udGVudD0iUmVmcmVzaCIvPjxCdXR0b24geDpOYW1lPSJFeHBvcnRMb2dzQnV0dG9uIiBDb250ZW50PSJFeHBvcnTigKYiLz48QnV0dG9uIHg6TmFtZT0iQ2xlYXJMb2dzQnV0dG9uIiBDb250ZW50PSJDbGVhciIvPjwvU3RhY2tQYW5lbD48L0RvY2tQYW5lbD4KICAgICAgICAgIDxUZXh0Qm94IHg6TmFtZT0iTG9nQm94IiBHcmlkLlJvdz0iMSIgSXNSZWFkT25seT0iVHJ1ZSIgQWNjZXB0c1JldHVybj0iVHJ1ZSIgVGV4dFdyYXBwaW5nPSJOb1dyYXAiIFZlcnRpY2FsU2Nyb2xsQmFyVmlzaWJpbGl0eT0iQXV0byIgSG9yaXpvbnRhbFNjcm9sbEJhclZpc2liaWxpdHk9IkF1dG8iIEZvbnRGYW1pbHk9IkNvbnNvbGFzIiBGb250U2l6ZT0iMTEiIEJhY2tncm91bmQ9IiMwNzBEMTciLz4KICAgICAgICA8L0dyaWQ+CiAgICAgIDwvVGFiSXRlbT4KICAgICAgPFRhYkl0ZW0gSGVhZGVyPSJTZXR0aW5ncyI+CiAgICAgICAgPFN0YWNrUGFuZWwgTWFyZ2luPSIxOCI+CiAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9Ik1hbmFnZXIgc2V0dGluZ3MgYW5kIHNlY3VyaXR5IiBGb250U2l6ZT0iMTkiIEZvbnRXZWlnaHQ9IlNlbWlCb2xkIiBNYXJnaW49IjAsMCwwLDEyIi8+CiAgICAgICAgICA8Qm9yZGVyIEJhY2tncm91bmQ9IiMxMTFCMkQiIENvcm5lclJhZGl1cz0iMTAiIFBhZGRpbmc9IjE2IiBNYXJnaW49IjAsMCwwLDEyIj48U3RhY2tQYW5lbD4KICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJTdG9yYWdlIGxvY2F0aW9ucyIgRm9udFdlaWdodD0iU2VtaUJvbGQiIEZvbnRTaXplPSIxNSIgTWFyZ2luPSIwLDAsMCw4Ii8+CiAgICAgICAgICAgIDxUZXh0QmxvY2sgeDpOYW1lPSJTZXR0aW5nc1BhdGhMYWJlbCIgVGV4dFdyYXBwaW5nPSJXcmFwIiBGb3JlZ3JvdW5kPSIjOTRBM0I4Ii8+CiAgICAgICAgICAgIDxUZXh0QmxvY2sgeDpOYW1lPSJNYW5hZ2VyTG9nUGF0aExhYmVsIiBUZXh0V3JhcHBpbmc9IldyYXAiIEZvcmVncm91bmQ9IiM5NEEzQjgiIE1hcmdpbj0iMCw1LDAsMCIvPgogICAgICAgICAgICA8VGV4dEJsb2NrIHg6TmFtZT0iQnJpZGdlU2NyaXB0UGF0aExhYmVsIiBUZXh0V3JhcHBpbmc9IldyYXAiIEZvcmVncm91bmQ9IiM5NEEzQjgiIE1hcmdpbj0iMCw1LDAsMCIvPgogICAgICAgICAgPC9TdGFja1BhbmVsPjwvQm9yZGVyPgogICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSIjMTExQjJEIiBDb3JuZXJSYWRpdXM9IjEwIiBQYWRkaW5nPSIxNiIgTWFyZ2luPSIwLDAsMCwxMiI+PFN0YWNrUGFuZWw+CiAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iU2VjdXJpdHkgbm90ZXMiIEZvbnRXZWlnaHQ9IlNlbWlCb2xkIiBGb250U2l6ZT0iMTUiIE1hcmdpbj0iMCwwLDAsOCIvPgogICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IuKAoiBUaGUgQUkgUHJpbWUgVGVjaCBrZXkgaXMga2VwdCBpbiBhcHAgbWVtb3J5IHVubGVzcyB5b3Ugb3B0IGludG8gZW5jcnlwdGVkIHN0b3JhZ2UuIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwyIi8+CiAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0i4oCiIE9wdGlvbmFsIHNhdmVkIGtleSBhbmQgdGhlIGxvY2FsIEN1cnNvciBicmlkZ2Uga2V5IGFyZSBwcm90ZWN0ZWQgd2l0aCBXaW5kb3dzIERQQVBJIGZvciB0aGlzIFdpbmRvd3MgYWNjb3VudC4iIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDIiLz4KICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSLigKIgVGhlIGJyaWRnZSBiaW5kcyB0byAxMjcuMC4wLjEgYW5kIHNob3VsZCBub3QgYmUgZXhwb3NlZCB0byBhIExBTiBvciB0aGUgaW50ZXJuZXQuIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwyIi8+CiAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0i4oCiIENvZGUvcHJvbXB0IGNvbnRlbnRzIGFyZSBmb3J3YXJkZWQgdG8gQUkgUHJpbWUgVGVjaCB3aGVuIEN1cnNvciBjYWxscyB0aGUgYnJpZGdlLiIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMiIvPgogICAgICAgICAgPC9TdGFja1BhbmVsPjwvQm9yZGVyPgogICAgICAgICAgPFdyYXBQYW5lbD48QnV0dG9uIHg6TmFtZT0iU2F2ZVNldHRpbmdzQnV0dG9uMiIgQ29udGVudD0iU2F2ZSBTZXR0aW5ncyIgQmFja2dyb3VuZD0iIzI1NjNFQiIvPjxCdXR0b24geDpOYW1lPSJPcGVuRGF0YUZvbGRlckJ1dHRvbiIgQ29udGVudD0iT3BlbiBBcHAgRGF0YSBGb2xkZXIiLz48QnV0dG9uIHg6TmFtZT0iT3BlblNjcmlwdEZvbGRlckJ1dHRvbiIgQ29udGVudD0iT3BlbiBBcHAgRm9sZGVyIi8+PC9XcmFwUGFuZWw+CiAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICA8L1RhYkl0ZW0+CiAgICAgIDxUYWJJdGVtIEhlYWRlcj0iQ2xvdWRmbGFyZSBUdW5uZWwiPgogICAgICAgIDxTY3JvbGxWaWV3ZXIgVmVydGljYWxTY3JvbGxCYXJWaXNpYmlsaXR5PSJBdXRvIj48U3RhY2tQYW5lbCBNYXJnaW49IjE4Ij4KICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iUHVibGljIEhUVFBTIGVuZHBvaW50IGZvciBDdXJzb3IiIEZvbnRTaXplPSIxOSIgRm9udFdlaWdodD0iU2VtaUJvbGQiIE1hcmdpbj0iMCwwLDAsNSIvPgogICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJDcmVhdGUgYSB0ZW1wb3JhcnkgQ2xvdWRmbGFyZSBRdWljayBUdW5uZWwgYXV0b21hdGljYWxseS4gTm8gRE5TLCBkb21haW4gb3IgQ2xvdWRmbGFyZSBsb2dpbiBpcyByZXF1aXJlZC4gVGhlIHRyeWNsb3VkZmxhcmUuY29tIFVSTCBjaGFuZ2VzIHdoZW4gdGhlIHR1bm5lbCByZXN0YXJ0cy4iIEZvcmVncm91bmQ9IiM5NEEzQjgiIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCwxMiIvPgogICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSIjMkIyMTE1IiBCb3JkZXJCcnVzaD0iIzhBNUEyMCIgQm9yZGVyVGhpY2tuZXNzPSIxIiBDb3JuZXJSYWRpdXM9IjgiIFBhZGRpbmc9IjEyIiBNYXJnaW49IjAsMCwwLDEyIj4KICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0V3JhcHBpbmc9IldyYXAiIEZvcmVncm91bmQ9IiNGQ0Q5QTQiIFRleHQ9IlNlY3VyaXR5OiB0aGlzIHB1Ymxpc2hlcyB5b3VyIEJyaWRnZSB0byB0aGUgcHVibGljIGludGVybmV0LiBBUEkgZW5kcG9pbnRzIHJlcXVpcmUgdGhlIHJhbmRvbSBsb2NhbCBCcmlkZ2Uga2V5LCBidXQgdXNlIFF1aWNrIFR1bm5lbHMgZm9yIHRlc3Rpbmcgb25seS4gVGhlIGFwcCBzdG9wcyB0aGUgdHVubmVsIHdoZW4gaXQgY2xvc2VzLiBOZXZlciBzaGFyZSB0aGUgVVJMIG9yIEJyaWRnZSBrZXkuIi8+CiAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0iIzExMUIyRCIgQ29ybmVyUmFkaXVzPSIxMCIgUGFkZGluZz0iMTYiIE1hcmdpbj0iMCwwLDAsMTIiPgogICAgICAgICAgICA8U3RhY2tQYW5lbD4KICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IlR1bm5lbCBzdGF0dXMiIEZvbnRTaXplPSIxNSIgRm9udFdlaWdodD0iU2VtaUJvbGQiIE1hcmdpbj0iMCwwLDAsNiIvPgogICAgICAgICAgICAgIDxUZXh0QmxvY2sgeDpOYW1lPSJUdW5uZWxTdGF0dXNDYXJkIiBUZXh0PSJTdG9wcGVkIMK3IE5vIHB1YmxpYyBVUkwiIEZvcmVncm91bmQ9IiM5NEEzQjgiIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw2Ii8+CiAgICAgICAgICAgICAgPFByb2dyZXNzQmFyIHg6TmFtZT0iVHVubmVsUHJvZ3Jlc3NCYXIiIEhlaWdodD0iMTIiIE1pbmltdW09IjAiIE1heGltdW09IjEwMCIgVmFsdWU9IjAiIElzSW5kZXRlcm1pbmF0ZT0iRmFsc2UiIEJhY2tncm91bmQ9IiMwQjEyMjAiIEZvcmVncm91bmQ9IiMzOEJERjgiIEJvcmRlckJydXNoPSIjMzM0MTU1IiBNYXJnaW49IjAsMCwwLDMiLz4KICAgICAgICAgICAgICA8VGV4dEJsb2NrIHg6TmFtZT0iVHVubmVsUHJvZ3Jlc3NUZXh0IiBUZXh0PSJJZGxlLiBTdGFydCBRdWljayBUdW5uZWwgdG8gYmVnaW4uIiBGb3JlZ3JvdW5kPSIjOTRBM0I4IiBGb250U2l6ZT0iMTEiIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCwxMCIvPgogICAgICAgICAgICAgIDxMYWJlbCBDb250ZW50PSJHZW5lcmF0ZWQgcHVibGljIFVSTCIvPgogICAgICAgICAgICAgIDxUZXh0Qm94IHg6TmFtZT0iVHVubmVsVXJsQm94IiBJc1JlYWRPbmx5PSJUcnVlIiBUZXh0PSIiIFRvb2xUaXA9IkNsb3VkZmxhcmUtZ2VuZXJhdGVkIFVSTDsgYmVjb21lcyBhdmFpbGFibGUgYWZ0ZXIgdGhlIHR1bm5lbCBzdGFydHMuIi8+CiAgICAgICAgICAgICAgPFdyYXBQYW5lbCBNYXJnaW49IjAsOCwwLDAiPgogICAgICAgICAgICAgICAgPEJ1dHRvbiB4Ok5hbWU9IlN0YXJ0VHVubmVsQnV0dG9uIiBDb250ZW50PSJTdGFydCBRdWljayBUdW5uZWwiIEJhY2tncm91bmQ9IiMxNjgxNUYiIEJvcmRlckJydXNoPSIjMjE5ODc5Ii8+CiAgICAgICAgICAgICAgICA8QnV0dG9uIHg6TmFtZT0iU3RvcFR1bm5lbEJ1dHRvbiIgQ29udGVudD0iU3RvcCBUdW5uZWwiIEJhY2tncm91bmQ9IiM1NDJCMzgiIEJvcmRlckJydXNoPSIjODQ0NDU2Ii8+CiAgICAgICAgICAgICAgICA8QnV0dG9uIHg6TmFtZT0iQ29weVR1bm5lbFVybEJ1dHRvbiIgQ29udGVudD0iQ29weSBQdWJsaWMgVVJMIi8+CiAgICAgICAgICAgICAgPC9XcmFwUGFuZWw+CiAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSIjMTExQjJEIiBDb3JuZXJSYWRpdXM9IjEwIiBQYWRkaW5nPSIxNiI+CiAgICAgICAgICAgIDxTdGFja1BhbmVsPgogICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iQ3Vyc29yIGNvbm5lY3Rpb24gc2V0dGluZ3MiIEZvbnRTaXplPSIxNSIgRm9udFdlaWdodD0iU2VtaUJvbGQiIE1hcmdpbj0iMCwwLDAsNiIvPgogICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iV2hlbiB0aGUgVVJMIGlzIHJlYWR5LCB0aGUgQ3Vyc29yIFNldHVwIHRhYiBhdXRvbWF0aWNhbGx5IHN3aXRjaGVzIHRvIHRoaXMgcHVibGljIEhUVFBTIGJhc2UgVVJMLiBLZWVwIHRoZSBsb2NhbCBCcmlkZ2UgYW5kIHRoaXMgdHVubmVsIHJ1bm5pbmcgd2hpbGUgQ3Vyc29yIHVzZXMgaXQuIiBGb3JlZ3JvdW5kPSIjOTRBM0I4IiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsOCIvPgogICAgICAgICAgICAgIDxMYWJlbCBDb250ZW50PSJPcGVuQUktY29tcGF0aWJsZSBCYXNlIFVSTCBmb3IgQ3Vyc29yIi8+CiAgICAgICAgICAgICAgPERvY2tQYW5lbD48VGV4dEJveCB4Ok5hbWU9IlR1bm5lbEJhc2VVcmxCb3giIElzUmVhZE9ubHk9IlRydWUiIFRleHQ9IiIvPjxCdXR0b24geDpOYW1lPSJDb3B5VHVubmVsQmFzZUJ1dHRvbiIgQ29udGVudD0iQ29weSBCYXNlIFVSTCIgRG9ja1BhbmVsLkRvY2s9IlJpZ2h0Ii8+PC9Eb2NrUGFuZWw+CiAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJGb3IgYSBwZXJtYW5lbnQgY3VzdG9tIGhvc3RuYW1lLCB5b3UgbmVlZCBhIENsb3VkZmxhcmUgYWNjb3VudCBhbmQgYSBkb21haW4gY29uZmlndXJlZCBpbiBDbG91ZGZsYXJlLiBRdWljayBUdW5uZWwgYXV0b21hdGljYWxseSBjcmVhdGVzIGEgcmFuZG9tIEROUyBob3N0bmFtZSBhbmQgaXMgaW50ZW5kZWQgZm9yIHRlc3RpbmcvZGV2ZWxvcG1lbnQuIiBGb3JlZ3JvdW5kPSIjRkJCRjI0IiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwxMCwwLDAiLz4KICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgPC9TdGFja1BhbmVsPjwvU2Nyb2xsVmlld2VyPgogICAgICA8L1RhYkl0ZW0+CiAgICA8L1RhYkNvbnRyb2w+CiAgICA8RG9ja1BhbmVsIEdyaWQuUm93PSIzIiBNYXJnaW49IjAsMTIsMCwwIj4KICAgICAgPFRleHRCbG9jayBUZXh0PSJMb2NhbCBXaW5kb3dzIHV0aWxpdHkgwrcgTm9kZS5qcyAyMCsgwrcgUG93ZXJTaGVsbCA1LjErIiBGb3JlZ3JvdW5kPSIjNjQ3NDhCIiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIi8+CiAgICAgIDxUZXh0QmxvY2sgeDpOYW1lPSJGb290ZXJTdGF0dXMiIFRleHQ9IlJlYWR5IiBGb3JlZ3JvdW5kPSIjOTRBM0I4IiBEb2NrUGFuZWwuRG9jaz0iUmlnaHQiIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIi8+CiAgICA8L0RvY2tQYW5lbD4KICA8L0dyaWQ+CjwvV2luZG93Pg=='
$xaml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($xamlBase64))

$stringReader = New-Object System.IO.StringReader($xaml)
try {
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    try {
        $script:Window = [Windows.Markup.XamlReader]::Load($xmlReader)
    }
    finally {
        if ($xmlReader) { $xmlReader.Dispose() }
    }
}
finally {
    $stringReader.Dispose()
}

# Bind named controls to script scope for predictable event handlers.
$controlNamesText = "MainTabs|OverallStatus|ApiStatusCard|BridgeStatusCard|BridgePortCard|AliasCard|ApiBaseUrlBox|ApiKeyBox|RememberKeyCheck|ModelCombo|ModelCountLabel|ModelRecommendationText|ApiTestResultText|StrongestModelButton|TestApiButton|FetchModelsButton|SaveSettingsButton|ForgetKeyButton|PortBox|StartBridgeButton|StopBridgeButton|TestBridgeButton|OpenCursorSetupButton|CursorBaseLabel|CursorKeyPassword|CursorKeyRevealBox|RevealKeyButton|CopyKeyButton|CursorModelLabel|CopyBaseButton|CopyModelButton|CopyAllButton|CopyJsonButton|LogBox|RefreshLogsButton|ExportLogsButton|ClearLogsButton|SettingsPathLabel|ManagerLogPathLabel|BridgeScriptPathLabel|SaveSettingsButton2|OpenDataFolderButton|OpenScriptFolderButton|FooterStatus|TunnelStatusCard|TunnelProgressBar|TunnelProgressText|TunnelUrlBox|TunnelBaseUrlBox|StartTunnelButton|StopTunnelButton|CopyTunnelUrlButton|CopyTunnelBaseButton"
$controlNames = $controlNamesText -split '\|'
foreach ($name in $controlNames) { Set-Variable -Name $name -Value $script:Window.FindName($name) -Scope Script }

Load-Settings
$script:ApiBaseUrlBox.Text = [string]$script:CurrentSettings.ApiBaseUrl
$script:ModelCombo.Items.Clear()
[void]$script:ModelCombo.Items.Add([string]$script:CurrentSettings.Model)
$script:ModelCombo.SelectedItem = [string]$script:CurrentSettings.Model
$script:PortBox.Text = [string]$script:CurrentSettings.Port
$script:RememberKeyCheck.IsChecked = [bool]$script:CurrentSettings.RememberApiKey
$script:ApiKeyBox.Password = [string]$script:ApiKey
$script:SettingsPathLabel.Text = "Settings (saved credentials encrypted with Windows DPAPI): $script:SettingsPath"
$script:ManagerLogPathLabel.Text = "Logs: $script:ManagerLogPath and $script:BridgeLogPath"
$script:BridgeScriptPathLabel.Text = "Bridge runtime: $script:BridgeScriptPath"
$script:BridgePortCard.Text = "127.0.0.1:$($script:CurrentSettings.Port)"
Update-ModelAdvice
Update-TunnelUi

$script:ApiKeyBox.Add_PasswordChanged({ $script:ApiKey = $script:ApiKeyBox.Password })
$script:ModelCombo.Add_SelectionChanged({ Update-ModelAdvice })
$script:ModelCombo.Add_LostKeyboardFocus({ Update-ModelAdvice })
# Base URL is validated by the API operation before making requests.
$script:PortBox.Add_LostKeyboardFocus({ Update-CursorValues })

$script:ApiOperationTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ApiOperationTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:ApiOperationTimer.Add_Tick({
    try {
        if ($script:ApiOperation -and $script:ApiOperation.Handle.IsCompleted) {
            Complete-ApiOperation
        }
    } catch {
        $msg = Get-ErrorSummary $_
        try { Write-AppLog "Unhandled background-operation completion error: $msg" } catch { }
        try {
            $script:ApiOperationTimer.Stop()
            if ($script:ApiOperation -and $script:ApiOperation.PowerShell) { $script:ApiOperation.PowerShell.Dispose() }
            $script:ApiOperation = $null
            Set-ApiOperationControls $true
            $script:ApiTestResultText.Text = "Operation failed safely: $msg"
            $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::Salmon
            Set-StatusText "Operation failed; app remains open" "Salmon"
        } catch { }
    }
})

$script:TestApiButton.Add_Click({
    try { Start-ApiOperation 'Test' }
    catch { $msg = Get-ErrorSummary $_; Write-AppLog "Could not start API test: $msg"; Set-StatusText 'Could not start API test' 'Salmon'; $script:ApiTestResultText.Text = $msg; $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::Salmon }
    Refresh-LogView
})
$script:FetchModelsButton.Add_Click({
    try { Start-ApiOperation 'Models' }
    catch { $msg = Get-ErrorSummary $_; Write-AppLog "Could not fetch models: $msg"; Set-StatusText 'Could not fetch models' 'Salmon'; $script:ApiTestResultText.Text = $msg; $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::Salmon }
    Refresh-LogView
})
$script:StrongestModelButton.Add_Click({
    try { Select-StrongestAvailableModel }
    catch { [System.Windows.MessageBox]::Show((Get-ErrorSummary $_), 'Model selection', 'OK', 'Warning') | Out-Null }
})
$saveAction = {
    try { Save-SettingsFromUi; [System.Windows.MessageBox]::Show('Settings saved.', 'AI Prime Cursor Manager', 'OK', 'Information') | Out-Null }
    catch { [System.Windows.MessageBox]::Show((Get-ErrorSummary $_), 'Save Settings Failed', 'OK', 'Error') | Out-Null }
    Refresh-LogView
}
$script:SaveSettingsButton.Add_Click($saveAction)
$script:SaveSettingsButton2.Add_Click($saveAction)
$script:ForgetKeyButton.Add_Click({
    $answer = [System.Windows.MessageBox]::Show('Forget the saved and current AI Prime Tech API key? If the bridge is running, stop it and start again after entering a key.', 'Forget API Key', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        Stop-Bridge
        $script:ApiKey = ''
        $script:ApiKeyBox.Clear()
        $script:CurrentSettings.EncryptedApiKey = ''
        $script:CurrentSettings.RememberApiKey = $false
        $script:RememberKeyCheck.IsChecked = $false
        Save-SettingsCore
        Write-AppLog 'AI Prime Tech key cleared from manager memory and saved settings.'
        Set-StatusText 'API key forgotten' 'Orange'
        Refresh-LogView
    }
})
$script:StartBridgeButton.Add_Click({
    try {
        Save-SettingsFromUi
        Start-Bridge
        if ($script:BridgeStatusCard.Text -notlike 'Running*') {
            $script:BridgeStatusCard.Text = 'Started — verify with Test Bridge'
            $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::Orange
        }
    }
    catch {
        $msg = Get-ErrorSummary $_
        try { Write-AppLog "Bridge start failed: $msg" } catch { }
        try {
            Set-StatusText 'Bridge start failed' 'Salmon'
            $script:BridgeStatusCard.Text = 'Start failed'
            $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::Salmon
            $script:ApiTestResultText.Text = $msg
            $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::Salmon
        } catch { }
    }
    try { Refresh-LogView } catch { }
})
$script:StopBridgeButton.Add_Click({
    try {
        Stop-Bridge
        $script:BridgeStatusCard.Text = "Stopped"
        $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGray
    } catch {
        $msg = Get-ErrorSummary $_
        try { Write-AppLog "Bridge stop failed: $msg" } catch { }
        try { Set-StatusText "Stop failed: $msg" 'Salmon' } catch { }
    }
})
$script:TestBridgeButton.Add_Click({
    try { Start-ApiOperation 'Bridge' }
    catch {
        $msg = Get-ErrorSummary $_
        try { Write-AppLog "Could not start bridge test: $msg" } catch { }
        try {
            Set-StatusText 'Could not start bridge test' 'Salmon'
            $script:ApiTestResultText.Text = $msg
            $script:ApiTestResultText.Foreground = [System.Windows.Media.Brushes]::Salmon
        } catch { }
    }
    try { Refresh-LogView } catch { }
})
$script:StartTunnelButton.Add_Click({
    try { Start-QuickTunnel }
    catch {
        $msg = Get-ErrorSummary $_
        Write-AppLog "Quick Tunnel start failed: $msg"
        if ($script:TunnelStatusCard) { $script:TunnelStatusCard.Text = "Failed · $msg"; $script:TunnelStatusCard.Foreground = [System.Windows.Media.Brushes]::Salmon }
        Set-StatusText 'Quick Tunnel failed' 'Salmon'
    }
    try { Refresh-LogView } catch { }
})
$script:StopTunnelButton.Add_Click({
    try { Stop-QuickTunnel }
    catch { $msg = Get-ErrorSummary $_; Write-AppLog "Quick Tunnel stop failed: $msg"; Set-StatusText "Tunnel stop failed: $msg" 'Salmon' }
})
$script:CopyTunnelUrlButton.Add_Click({ try { Copy-TunnelPublicUrl } catch { Set-StatusText (Get-ErrorSummary $_) 'Orange' } })
$script:CopyTunnelBaseButton.Add_Click({ try { Copy-TunnelBaseUrl } catch { Set-StatusText (Get-ErrorSummary $_) 'Orange' } })

$script:OpenCursorSetupButton.Add_Click({ $script:MainTabs.SelectedIndex = 1 })
$script:CopyBaseButton.Add_Click({ try { Copy-Text $script:CursorBaseLabel.Text 'Cursor Base URL' } catch { } })
$script:CopyModelButton.Add_Click({ try { Copy-Text $script:CursorModelLabel.Text 'Cursor model alias' } catch { } })
$script:CopyKeyButton.Add_Click({ try { Copy-Text $script:BridgeKey 'Local bridge key' } catch { } })
$script:RevealKeyButton.Add_Click({
    if ($script:CursorKeyRevealBox.Visibility -eq [System.Windows.Visibility]::Collapsed) {
        $script:CursorKeyRevealBox.Text = $script:BridgeKey
        $script:CursorKeyPassword.Visibility = [System.Windows.Visibility]::Collapsed
        $script:CursorKeyRevealBox.Visibility = [System.Windows.Visibility]::Visible
        $script:RevealKeyButton.Content = 'Hide'
    } else {
        $script:CursorKeyPassword.Visibility = [System.Windows.Visibility]::Visible
        $script:CursorKeyRevealBox.Visibility = [System.Windows.Visibility]::Collapsed
        $script:RevealKeyButton.Content = 'Reveal'
    }
})
$script:CopyAllButton.Add_Click({
    $text = "Base URL: $($script:CursorBaseLabel.Text)`r`nAPI Key: [copy with Copy Key button for security]`r`nCustom Model: $($script:CursorModelLabel.Text)`r`n`r`nEnable Use OpenAI API Key and Override OpenAI Base URL in Cursor Settings → Models."
    try { Copy-Text $text 'Cursor setup summary' } catch { }
})
$script:CopyJsonButton.Add_Click({
    $jsonObject = [pscustomobject]@{
        note = "Informational only: bridge is configured in Cursor Settings Models, not as an MCP server."
        baseUrl = [string]$script:CursorBaseLabel.Text
        model = [string]$script:CursorModelLabel.Text
    }
    $json = $jsonObject | ConvertTo-Json -Depth 3
    try { Copy-Text $json "Bridge configuration information" } catch { }
})
$script:RefreshLogsButton.Add_Click({ Refresh-LogView })
$script:ClearLogsButton.Add_Click({
    $answer = [System.Windows.MessageBox]::Show('Clear manager and bridge logs?', 'Clear Logs', 'YesNo', 'Question')
    if ($answer -eq 'Yes') {
        Set-Content -Path $script:ManagerLogPath -Value '' -Encoding UTF8
        Set-Content -Path $script:BridgeLogPath -Value '' -Encoding UTF8
        $script:LastDisplayedLogs = ''
        Write-AppLog 'Logs cleared by user.'
        Refresh-LogView
    }
})
$script:ExportLogsButton.Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'Text log (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.FileName = ('AIPrimeCursorLogs-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($dialog.ShowDialog() -eq $true) {
        Refresh-LogView
        [System.IO.File]::WriteAllText($dialog.FileName, $script:LogBox.Text, [System.Text.UTF8Encoding]::new($false))
        Write-AppLog 'Logs exported by user.'
        Refresh-LogView
        Set-StatusText 'Logs exported' 'LightGreen'
    }
})
$script:OpenDataFolderButton.Add_Click({
    $folderPath = $script:AppDataDir
    if (Test-Path -LiteralPath $folderPath) {
        Start-Process -FilePath explorer.exe -ArgumentList $folderPath
    } else {
        Set-StatusText "App data folder does not exist yet." "Orange"
    }
})
$script:OpenScriptFolderButton.Add_Click({
    $folderPath = $PSScriptRoot
    if (Test-Path -LiteralPath $folderPath) {
        Start-Process -FilePath explorer.exe -ArgumentList $folderPath
    }
})

$script:LogTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:LogTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:LogTimer.Add_Tick({
    $queued = $null
    while ($script:LogQueue.TryDequeue([ref]$queued)) {
        Write-AppLog $queued
        $queued = $null
    }
    if (Test-BridgeRunning) {
        $script:BridgeStatusCard.Text = "Running"
        $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGreen
    } elseif ($script:BridgeProcess) {
        $script:BridgeStatusCard.Text = "Stopped"
        $script:BridgeStatusCard.Foreground = [System.Windows.Media.Brushes]::LightGray
        $script:BridgeProcess = $null
    }
    try { Update-TunnelUi } catch { }
    if ($script:MainTabs.SelectedIndex -eq 2) { Refresh-LogView }
})
$script:MainTabs.Add_SelectionChanged({
    if ($script:MainTabs.SelectedIndex -eq 2) { Refresh-LogView }
})
$script:LogTimer.Start()

$script:Window.Add_Closing({
    try { Stop-QuickTunnel } catch { }
    try { $script:LogTimer.Stop() } catch { }
    try { $script:ApiOperationTimer.Stop() } catch { }
    if ($script:ApiOperation) {
        try { $script:ApiOperation.PowerShell.Stop() } catch { }
        try { $script:ApiOperation.PowerShell.Dispose() } catch { }
        $script:ApiOperation = $null
    }
    try { Save-SettingsFromUi } catch { }
    if (Test-BridgeRunning) {
        try { $script:BridgeProcess.Kill(); [void]$script:BridgeProcess.WaitForExit(3000) } catch { }
        Write-AppLog "Manager closing; local bridge stopped."
    }
})

Write-AppLog ("AI Prime Cursor Manager launched.")
Update-TunnelUi
Refresh-LogView
[void]$script:Window.ShowDialog()