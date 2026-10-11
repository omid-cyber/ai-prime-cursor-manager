param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile
)
$ErrorActionPreference = 'Stop'

try {
    if (-not (Test-Path -LiteralPath $SourceFile)) {
        throw "Source PowerShell file not found: $SourceFile"
    }
    $source = Get-Content -LiteralPath $SourceFile -Raw -Encoding UTF8

    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($SourceFile, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $longStringTokens = @($tokens | Where-Object {
            $_.Kind.ToString() -match 'String' -and $_.Extent.EndLineNumber -gt $_.Extent.StartLineNumber
        })
        $debugTokens = @($tokens | Where-Object {
            $_.Kind.ToString() -match 'String' -and (
                ($_.Extent.StartLineNumber -ge 400 -and $_.Extent.StartLineNumber -le 530) -or
                $_.Extent.EndLineNumber -gt $_.Extent.StartLineNumber
            )
        })
        foreach ($t in $debugTokens) {
            $preview = [string]$t.Extent.Text
            $preview = $preview -replace '[\r\n]+', ' '
            if ($preview.Length -gt 160) { $preview = $preview.Substring(0, 160) }
            Write-Host ("STRING TOKEN {0} {1}:{2}-{3}:{4} chars={5} text={6}" -f $t.Kind, $t.Extent.StartLineNumber, $t.Extent.StartColumnNumber, $t.Extent.EndLineNumber, $t.Extent.EndColumnNumber, $t.Extent.Text.Length, $preview) -ForegroundColor Yellow
        }
        $lines = $source -split "\r?\n"
        $details = foreach ($e in $parseErrors) {
            $lineNumber = $e.Extent.StartLineNumber
            $lineText = if ($lineNumber -gt 0 -and $lineNumber -le $lines.Count) { $lines[$lineNumber - 1].Trim() } else { $e.Extent.Text }
            "Line $lineNumber, column $($e.Extent.StartColumnNumber): $($e.Message) | $lineText"
        }
        throw ("PowerShell syntax errors in {0}:{1}{2}" -f $SourceFile, [Environment]::NewLine, ($details -join [Environment]::NewLine))
    }

    $helperPath = Join-Path (Split-Path -Parent $SourceFile) 'cloudflare-tunnel-manager.ps1'
    if (Test-Path -LiteralPath $helperPath) {
        $helperTokens = $null
        $helperErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$helperTokens, [ref]$helperErrors)
        if ($helperErrors -and $helperErrors.Count -gt 0) {
            $e = $helperErrors[0]
            throw ("PowerShell syntax error in {0}:{1}: {2}" -f $helperPath, $e.Extent.StartLineNumber, $e.Message)
        }
    }
    Write-Host 'PASS: Main and tunnel-helper PowerShell syntax parsed successfully.' -ForegroundColor Green

    # Extract the embedded Base64 XAML using plain string operations (no brittle regex).
    $base64Marker = '$xamlBase64 = '''
    $base64Start = $source.IndexOf($base64Marker, [System.StringComparison]::Ordinal)
    if ($base64Start -lt 0) { throw 'Embedded XAML Base64 assignment was not found.' }
    $payloadStart = $base64Start + $base64Marker.Length
    $payloadEnd = $source.IndexOf("'", $payloadStart)
    if ($payloadEnd -le $payloadStart) { throw 'Embedded XAML Base64 payload is malformed.' }
    $payload = $source.Substring($payloadStart, $payloadEnd - $payloadStart)
    $xmlText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))

    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $false
    $xml.LoadXml($xmlText)

    $xNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $presentationNs = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
    $seenNames = @{}
    foreach ($node in $xml.GetElementsByTagName('*')) {
        $name = $node.GetAttribute('Name', $xNs)
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            if ($seenNames.ContainsKey($name)) { throw "Duplicate x:Name in XAML: $name" }
            $seenNames[$name] = $true
        }
    }

    $seenStyles = @{}
    foreach ($style in $xml.GetElementsByTagName('Style', $presentationNs)) {
        $target = $style.GetAttribute('TargetType')
        $key = $style.GetAttribute('Key', $xNs)
        if (-not [string]::IsNullOrWhiteSpace($target) -and [string]::IsNullOrWhiteSpace($key)) {
            if ($seenStyles.ContainsKey($target)) { throw "Duplicate implicit WPF Style for TargetType '$target'." }
            $seenStyles[$target] = $true
        }
    }

    # Resolve the pipe-delimited control names used by the main script.
    $namesMarker = '$controlNamesText = "'
    $namesStart = $source.IndexOf($namesMarker, [System.StringComparison]::Ordinal)
    if ($namesStart -lt 0) { throw 'The control-name declaration was not found.' }
    $namesPayloadStart = $namesStart + $namesMarker.Length
    $namesPayloadEnd = $source.IndexOf('"', $namesPayloadStart)
    if ($namesPayloadEnd -le $namesPayloadStart) { throw 'The control-name declaration is malformed.' }
    $namesText = $source.Substring($namesPayloadStart, $namesPayloadEnd - $namesPayloadStart)
    $controlNames = @($namesText -split '\|')

    foreach ($controlName in $controlNames) {
        if (-not $seenNames.ContainsKey($controlName)) { throw "Control binding '$controlName' has no matching x:Name in XAML." }
    }

    Write-Host 'PASS: Main and tunnel-helper PowerShell syntax parsed successfully.' -ForegroundColor Green
    Write-Host 'PASS: XAML is well-formed XML.' -ForegroundColor Green
    Write-Host "PASS: $($seenNames.Count) unique x:Name controls." -ForegroundColor Green
    Write-Host "PASS: $($seenStyles.Count) unique implicit WPF styles." -ForegroundColor Green
    Write-Host "PASS: $($controlNames.Count) bound control names resolve." -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "XAML preflight FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
