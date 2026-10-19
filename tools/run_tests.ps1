param(
    [Parameter(Mandatory = $true)]
    [string]$RedotBin,
    [string]$ExtraAllowedDiagnosticsFile = '',
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test_process.ps1')

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedRedot = (Resolve-Path -LiteralPath $RedotBin).Path
$artifactPath = Join-Path $projectPath 'tests/.artifacts/suite'
New-Item -ItemType Directory -Force -Path $artifactPath | Out-Null
$engineVersion = Get-TestEngineVersion -RedotBin $resolvedRedot -ProjectPath $projectPath -ArtifactPath $artifactPath
Write-Output "Engine: $engineVersion"
$allowedDiagnostics = @(Get-AllowedEngineDiagnostics -Files @(
    (Join-Path $projectPath 'tests/known_engine_diagnostics.txt'), $ExtraAllowedDiagnosticsFile
) -EngineVersion $engineVersion)

function Invoke-Redot {
    param([string[]]$Arguments, [string]$Label, [string]$LogName, [string]$RequiredMarker = '')
    Write-Output "== $Label =="
    $stdout = Join-Path $artifactPath "$LogName.stdout.log"
    $stderr = Join-Path $artifactPath "$LogName.stderr.log"
    $process = Start-TestProcess -RedotBin $resolvedRedot -Arguments $Arguments -ProjectPath $projectPath -Stdout $stdout -Stderr $stderr
    try {
        Wait-TestProcess -Process $process -TimeoutSeconds $TimeoutSeconds -Label $Label
        Assert-EngineDiagnostics -Logs @($stdout, $stderr) -AllowedDiagnostics $allowedDiagnostics -Label $Label
        if ($process.ExitCode -ne 0) { throw "$Label failed with exit code $($process.ExitCode)." }
        if ($RequiredMarker -and (Get-Content -LiteralPath $stdout -Raw) -notmatch "(?m)^$RequiredMarker\r?$") {
            throw "$Label did not reach its completion marker."
        }
    }
    finally { Stop-TestProcessTree -Process $process }
}

Push-Location $projectPath
try {
    Invoke-Redot -Label 'Editor import' -LogName 'import' -Arguments @(
        '--headless', '--audio-driver', 'Dummy', '--editor', '--path', $projectPath, '--import', '--quit-after', '600'
    )
    Invoke-Redot -Label 'Unit and security tests' -LogName 'unit' -RequiredMarker 'UNIT_TESTS_PASS' -Arguments @(
        '--headless', '--audio-driver', 'Dummy', '--path', $projectPath, '--script', 'tests/run_all.gd', '--quit-after', '20000'
    )

    $fixtureScript = Join-Path $PSScriptRoot 'run_transport_fixture.ps1'
    $port = 32777
    foreach ($scenario in @('core', 'facade')) {
        foreach ($transport in @('enet', 'websocket')) {
            & $fixtureScript -RedotBin $resolvedRedot -Transport $transport -Scenario $scenario -Port $port -ExtraAllowedDiagnosticsFile $ExtraAllowedDiagnosticsFile
            $port++
        }
    }

    Invoke-Redot -Label 'Bounded quickstart run' -LogName 'quickstart' -Arguments @(
        '--headless', '--audio-driver', 'Dummy', '--path', $projectPath, '--quit-after', '3'
    )
    Write-Output 'REDOTP2PNETWORK_TEST_SUITE_PASS'
}
finally { Pop-Location }
