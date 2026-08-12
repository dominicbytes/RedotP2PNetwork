param(
    [Parameter(Mandatory = $true)]
    [string]$RedotBin
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedRedot = (Resolve-Path -LiteralPath $RedotBin).Path

function Invoke-Redot {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    Write-Output "== $Label =="
    & $resolvedRedot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

Push-Location $projectPath
try {
    Invoke-Redot -Label 'Engine identity' -Arguments @('--version')
    Invoke-Redot -Label 'Editor import' -Arguments @(
        '--headless', '--editor', '--path', $projectPath, '--quit'
    )
    Invoke-Redot -Label 'Unit and security tests' -Arguments @(
        '--headless', '--path', $projectPath, '--script', 'tests/run_all.gd'
    )

    $fixtureScript = Join-Path $PSScriptRoot 'run_transport_fixture.ps1'
    & $fixtureScript -RedotBin $resolvedRedot -Transport enet -Scenario core -Port 32777
    & $fixtureScript -RedotBin $resolvedRedot -Transport websocket -Scenario core -Port 32778
    & $fixtureScript -RedotBin $resolvedRedot -Transport enet -Scenario facade -Port 32779
    & $fixtureScript -RedotBin $resolvedRedot -Transport websocket -Scenario facade -Port 32780

    Invoke-Redot -Label 'Bounded quickstart run' -Arguments @(
        '--headless', '--path', $projectPath, '--quit-after', '3'
    )
    Write-Output 'REDOTP2PNETWORK_TEST_SUITE_PASS'
}
finally {
    Pop-Location
}
