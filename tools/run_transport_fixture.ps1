param(
    [Parameter(Mandatory = $true)]
    [string]$RedotBin,
    [ValidateSet('enet', 'websocket')]
    [string]$Transport,
    [ValidateSet('core', 'facade')]
    [string]$Scenario = 'core',
    [int]$Port = 32777,
    [string]$ExtraAllowedDiagnosticsFile = '',
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test_process.ps1')

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$artifactPath = Join-Path $projectPath "tests\.artifacts\$Transport-$Scenario-fixture"
New-Item -ItemType Directory -Force -Path $artifactPath | Out-Null

$hostOut = Join-Path $artifactPath 'host.stdout.log'
$hostErr = Join-Path $artifactPath 'host.stderr.log'
$clientOut = Join-Path $artifactPath 'client.stdout.log'
$clientErr = Join-Path $artifactPath 'client.stderr.log'
Set-Content -LiteralPath $hostOut -Value ''
Set-Content -LiteralPath $hostErr -Value ''
Set-Content -LiteralPath $clientOut -Value ''
Set-Content -LiteralPath $clientErr -Value ''

$engineVersion = Get-TestEngineVersion -RedotBin $RedotBin -ProjectPath $projectPath -ArtifactPath $artifactPath
$allowedDiagnostics = @(Get-AllowedEngineDiagnostics -Files @(
    (Join-Path $projectPath 'tests/known_engine_diagnostics.txt'), $ExtraAllowedDiagnosticsFile
) -EngineVersion $engineVersion)
$fixtureScript = 'tests/integration/enet_endpoint.gd'
if ($Scenario -eq 'facade') {
    $fixtureScript = 'tests/integration/facade_endpoint.gd'
}
$commonArguments = @(
    '--headless', '--audio-driver', 'Dummy', '--quit-after', '20000',
    '--path', $projectPath,
    '--script', $fixtureScript,
    '--'
)

$hostArguments = $commonArguments + @('--role=host', "--transport=$Transport", "--port=$Port")
$clientArguments = $commonArguments + @('--role=client', "--transport=$Transport", "--port=$Port")
$hostProcess = $null
$clientProcess = $null

try {
    $hostProcess = Start-TestProcess -RedotBin $RedotBin -Arguments $hostArguments -ProjectPath $projectPath -Stdout $hostOut -Stderr $hostErr
    Start-Sleep -Milliseconds 500
    $clientProcess = Start-TestProcess -RedotBin $RedotBin -Arguments $clientArguments -ProjectPath $projectPath -Stdout $clientOut -Stderr $clientErr

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ((-not $hostProcess.HasExited -or -not $clientProcess.HasExited) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $hostProcess.Refresh()
        $clientProcess.Refresh()
    }

    if (-not $hostProcess.HasExited -or -not $clientProcess.HasExited) {
        throw "$Transport fixture timed out."
    }

    Wait-TestProcess -Process $hostProcess -TimeoutSeconds 1 -Label 'Fixture host'
    Wait-TestProcess -Process $clientProcess -TimeoutSeconds 1 -Label 'Fixture client'
    Assert-EngineDiagnostics -Logs @($hostOut, $hostErr, $clientOut, $clientErr) -AllowedDiagnostics $allowedDiagnostics -Label "$Transport $Scenario fixture"
    $hostText = Get-Content -LiteralPath $hostOut -Raw
    $clientText = Get-Content -LiteralPath $clientOut -Raw

    $hostExitCode = $hostProcess.ExitCode
    $clientExitCode = $clientProcess.ExitCode
    $hostFailed = $null -eq $hostExitCode -or $hostExitCode -ne 0
    $clientFailed = $null -eq $clientExitCode -or $clientExitCode -ne 0
    if ($hostFailed -or $clientFailed) {
        throw "$Transport fixture process failed (host exit $hostExitCode, client exit $clientExitCode). Inspect the fixture logs."
    }
    $marker = $Transport.ToUpperInvariant()
    if ($Scenario -eq 'facade') {
        $marker = "${marker}_FACADE"
    }
    if ($hostText -notmatch "(?m)^${marker}_HOST_PASS\r?$" -or $clientText -notmatch "(?m)^${marker}_CLIENT_PASS\r?$") {
        throw "$Transport fixture did not report both pass markers. Inspect the fixture logs."
    }
    Write-Output "${marker}_TWO_PROCESS_FIXTURE_PASS"
}
finally {
    if ($null -ne $clientProcess -and -not $clientProcess.HasExited) {
        Stop-TestProcessTree -Process $clientProcess
    }
    if ($null -ne $hostProcess -and -not $hostProcess.HasExited) {
        Stop-TestProcessTree -Process $hostProcess
    }
}
