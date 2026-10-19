# Shared bounded engine processes and strict diagnostic checks for test runners.
function Start-TestProcess {
    param([string]$RedotBin, [string[]]$Arguments, [string]$ProjectPath,
          [string]$Stdout, [string]$Stderr)
    $quotedArguments = @($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' })
    $process = Start-Process -FilePath $RedotBin -ArgumentList $quotedArguments -WorkingDirectory $ProjectPath -WindowStyle Hidden -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    # Retain the native handle before a short-lived child exits (Windows PowerShell).
    $null = $process.Handle
    return $process
}

function Stop-TestProcessTree {
    param([System.Diagnostics.Process]$Process)
    if ($null -ne $Process -and -not $Process.HasExited) {
        & taskkill.exe /PID $Process.Id /T /F | Out-Null
        if (-not $Process.WaitForExit(5000)) {
            throw 'Timed-out process did not terminate after process-tree cleanup.'
        }
    }
}

function Wait-TestProcess {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds, [string]$Label)
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-TestProcessTree -Process $Process
        throw "$Label timed out after $TimeoutSeconds seconds."
    }
    # Flush redirected output before reading logs.
    $Process.WaitForExit()
    if ($null -eq $Process.ExitCode) {
        throw "$Label did not provide an exit code."
    }
}

function Get-AllowedEngineDiagnostics {
    param([string[]]$Files, [string]$EngineVersion, [string]$Step = '')
    foreach ($file in $Files) {
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $hasComment = $false
        foreach ($line in Get-Content -LiteralPath $file) {
            $entry = $line.Trim()
            if ($entry.Length -eq 0) { continue }
            if ($entry.StartsWith('#')) { $hasComment = $true; continue }
            if (-not $hasComment) { throw 'Each diagnostic allowlist entry needs an explanatory comment.' }
            $hasComment = $false
            if ($entry -match '^\[([^\]]+)\]\s*(.*)$') {
                $versionPrefix = $Matches[1]
                $entry = $Matches[2]
                if (-not $EngineVersion.StartsWith($versionPrefix, [StringComparison]::Ordinal)) { continue }
            }
            if ($entry -match '^\[editor-import\]\s*(.*)$') {
                $entry = $Matches[1]
                if ($Step -ne 'editor-import') { continue }
            }
            $null = [regex]::new($entry)
            $entry
        }
    }
}

function Assert-EngineDiagnostics {
    param([string[]]$Logs, [string[]]$AllowedDiagnostics, [string]$Label)
    foreach ($log in $Logs) {
        foreach ($line in Get-Content -LiteralPath $log) {
            $plain = $line -replace '\x1b\[[0-9;]*m', ''
            if ($plain -notmatch '^\s*(?:SCRIPT ERROR|USER ERROR|USER WARNING|ERROR|WARNING):') { continue }
            $allowed = $false
            foreach ($pattern in $AllowedDiagnostics) {
                if ($plain -match $pattern) { $allowed = $true; break }
            }
            if (-not $allowed) {
                # Keep machine-specific engine text in local logs, out of exception bodies.
                throw "$Label emitted an unapproved engine diagnostic; inspect its test logs."
            }
        }
    }
}

function Get-TestEngineVersion {
    param([string]$RedotBin, [string]$ProjectPath, [string]$ArtifactPath)
    $stdout = Join-Path $ArtifactPath 'version.stdout.log'
    $stderr = Join-Path $ArtifactPath 'version.stderr.log'
    $process = Start-TestProcess -RedotBin $RedotBin -Arguments @('--version') -ProjectPath $ProjectPath -Stdout $stdout -Stderr $stderr
    try {
        Wait-TestProcess -Process $process -TimeoutSeconds 10 -Label 'Engine identity'
        if ($process.ExitCode -ne 0) { throw 'Engine identity failed.' }
        Assert-EngineDiagnostics -Logs @($stdout, $stderr) -AllowedDiagnostics @() -Label 'Engine identity'
        $version = (Get-Content -LiteralPath $stdout -Raw).Trim()
        if ($version -notmatch '^\d+\.\d+\.') { throw 'Engine did not report a version.' }
        return $version
    }
    finally { Stop-TestProcessTree -Process $process }
}
