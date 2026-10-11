param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile
)
$ErrorActionPreference = 'Stop'

try {
    if (-not (Test-Path -LiteralPath $SourceFile)) { throw "Source PowerShell file not found: $SourceFile" }
    $source = Get-Content -LiteralPath $SourceFile -Raw -Encoding UTF8
    # Parse PowerShell syntax before attempting WPF startup, so broken scripts fail early with a precise line.
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($SourceFile, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $longStringTokens = @($tokens | Where-Object {
            $_.Kind.ToString() -match 'String' -and $_.Extent.EndLineNumber -gt $_.Extent.StartLineNumber
        })
        foreach ($token in $longStringTokens) {
            $preview = [string]$token.Extent.Text
            if ($preview.Length -gt 180) { $preview = $preview.Substring(0, 180) }
            Write-Host ("STRING TOKEN {0}: lines {1}-{2}: {3}" -f $token.Kind, $token.Extent.StartLineNumber, $token.Extent.EndLineNumber, $preview.Replace("`r", '\\r').Replace("`n", '\\n')) -ForegroundColor Yellow
        }
        $lines = $source -split '\r?\n'
        $details = foreach ($parseError in $parseErrors) {
            $lineNumber = $parseError.Extent.StartLineNumber
            $lineText = if ($lineNumber -gt 0 -and $lineNumber -le $lines.Count) { $lines[$lineNumber - 1].Trim() } else { $parseError.Extent.Text }
            "Line $lineNumber, column $($parseError.Extent.StartColumnNumber): $($parseError.Message) | Text: $lineText"
        }
        throw ("PowerShell syntax errors in {0}:`n{1}" -f $SourceFile, ($details -join "`n"))
    }
    $helperPath = Join-Path (Split-Path -Parent $SourceFile) 'cloudflare-tunnel-manager.ps1'
    if (Test-Path -LiteralPath $helperPath) {
        $helperTokens = $null
        $helperErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$helperTokens, [ref]$helperErrors)
        if ($helperErrors -and $helperErrors.Count -gt 0) {
            $first = $helperErrors[0]
            throw ("PowerShell syntax error in {0}:{1}: {2}" -f $helperPath, $first.Extent.StartLineNumber, $first.Message)
        }
        Write-Host 'PASS: Main and tunnel-helper PowerShell syntax parsed successfully.' -ForegroundColor Green
    } else {
        Write-Host 'WARN: Standalone tunnel helper is missing; EXE fallback helper will be used.' -ForegroundColor Yellow
    }
    $pattern = '(?s)\$xaml\s*=\s*@''\r?\n(.*?)\r?\n''@'
    $match = [regex]::Match($source, $pattern)
    $xmlText = $null
    if ($match.Success) {
        $xmlText = $match.Groups[1].Value
    } else {
        $base64Match = [regex]::Match($source, '(?m)^\$xamlBase64\s*=\s*''([A-Za-z0-9+/=]+)''\s*

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
            if ($seenStyles.ContainsKey($target)) { throw "Duplicate implicit WPF Style resource for TargetType '$target'. This causes ResourceDictionary startup failure." }
            $seenStyles[$target] = $true
        }
    }

    $bindingMatch = [regex]::Match($source, '(?s)\$controlNames\s*=\s*@\((.*?)\r?\n\)')
    if (-not $bindingMatch.Success) { throw 'Could not locate the named-control binding list.' }
    $controlNames = [regex]::Matches($bindingMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    foreach ($controlName in $controlNames) {
        if (-not $seenNames.ContainsKey($controlName)) { throw "Control binding '$controlName' has no matching x:Name in XAML." }
    }

    Write-Host "PASS: XAML is well-formed XML." -ForegroundColor Green
    Write-Host "PASS: $($seenNames.Count) unique x:Name controls." -ForegroundColor Green
    Write-Host "PASS: $($seenStyles.Count) unique implicit WPF styles; no duplicate TargetType keys." -ForegroundColor Green
    Write-Host "PASS: $($controlNames.Count) bound control names resolve." -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "XAML preflight FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
})
        if (-not $base64Match.Success) { throw 'Could not locate embedded XAML or its Base64 payload.' }
        $xmlText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64Match.Groups[1].Value))
    }

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
            if ($seenStyles.ContainsKey($target)) { throw "Duplicate implicit WPF Style resource for TargetType '$target'. This causes ResourceDictionary startup failure." }
            $seenStyles[$target] = $true
        }
    }

    $bindingMatch = [regex]::Match($source, '(?s)\$controlNames\s*=\s*@\((.*?)\r?\n\)')
    if (-not $bindingMatch.Success) { throw 'Could not locate the named-control binding list.' }
    $controlNames = [regex]::Matches($bindingMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    foreach ($controlName in $controlNames) {
        if (-not $seenNames.ContainsKey($controlName)) { throw "Control binding '$controlName' has no matching x:Name in XAML." }
    }

    Write-Host "PASS: XAML is well-formed XML." -ForegroundColor Green
    Write-Host "PASS: $($seenNames.Count) unique x:Name controls." -ForegroundColor Green
    Write-Host "PASS: $($seenStyles.Count) unique implicit WPF styles; no duplicate TargetType keys." -ForegroundColor Green
    Write-Host "PASS: $($controlNames.Count) bound control names resolve." -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "XAML preflight FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}