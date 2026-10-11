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

    # Parse the complete source with Windows PowerShell's parser before doing XAML checks.
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($SourceFile, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $details = foreach ($e in $parseErrors) {
            $lineNumber = $e.Extent.StartLineNumber
            $lineText = ($source -split '\r?\n')[$lineNumber - 1].Trim()
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

    # The application embeds XAML as Base64 so XML markup is not parsed as PowerShell source.
    $base64Match = [regex]::Match($source, '(?m)^\$xamlBase64\s*=\s*''([A-Za-z0-9+/=]+)''\s*$')
    if ($base64Match.Success) {
        $xmlText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64Match.Groups[1].Value))
    } else {
        # Backward compatibility with older source bundles.
        $legacyMatch = [regex]::Match($source, '(?s)\$xaml\s*=\s*@''\r?\n(.*?)\r?\n''@')
        if (-not $legacyMatch.Success) {
            throw 'Could not locate embedded XAML or its Base64 payload.'
        }
        $xmlText = $legacyMatch.Groups[1].Value
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
            if ($seenNames.ContainsKey($name)) {
                throw "Duplicate x:Name in XAML: $name"
            }
            $seenNames[$name] = $true
        }
    }

    $seenStyles = @{}
    foreach ($style in $xml.GetElementsByTagName('Style', $presentationNs)) {
        $target = $style.GetAttribute('TargetType')
        $key = $style.GetAttribute('Key', $xNs)
        if (-not [string]::IsNullOrWhiteSpace($target) -and [string]::IsNullOrWhiteSpace($key)) {
            if ($seenStyles.ContainsKey($target)) {
                throw "Duplicate implicit WPF Style for TargetType '$target'."
            }
            $seenStyles[$target] = $true
        }
    }

    $bindingMatch = [regex]::Match($source, '(?m)^\$controlNamesText\s*=\s*"([^"]+)"\s*
        $legacyBinding = [regex]::Match($source, '(?s)\$controlNames\s*=\s*@\((.*?)\r?\n\)')
        if (-not $legacyBinding.Success) {
            throw 'Could not locate the named-control binding list.'
        }
        $controlNames = [regex]::Matches($legacyBinding.Groups[1].Value, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value }
    }

    foreach ($controlName in $controlNames) {
        if (-not $seenNames.ContainsKey($controlName)) {
            throw "Control binding '$controlName' has no matching x:Name in XAML."
        }
    }

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
)
    if ($bindingMatch.Success) {
        $controlNames = @($bindingMatch.Groups[1].Value -split '\|')
    } else {
        $legacyBinding = [regex]::Match($source, '(?s)\$controlNames\s*=\s*@\((.*?)\r?\n\)')
        if (-not $legacyBinding.Success) {
            throw 'Could not locate the named-control binding list.'
        }
        $controlNames = [regex]::Matches($legacyBinding.Groups[1].Value, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value }
    }

    foreach ($controlName in $controlNames) {
        if (-not $seenNames.ContainsKey($controlName)) {
            throw "Control binding '$controlName' has no matching x:Name in XAML."
        }
    }

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
