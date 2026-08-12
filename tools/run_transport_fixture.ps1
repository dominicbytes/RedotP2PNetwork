param(
    [Parameter(Mandatory = $true)]
    [string]$RedotBin,
    [ValidateSet('enet', 'websocket')]
    [string]$Transport,
    [ValidateSet('core', 'facade')]
    [string]$Scenario = 'core',
    [int]$Port = 32777
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

$quotedProjectPath = '"' + $projectPath + '"'
$fixtureScript = 'tests/integration/enet_endpoint.gd'
if ($Scenario -eq 'facade') {
    $fixtureScript = 'tests/integration/facade_endpoint.gd'
}
$commonArguments = @(
    '--headless',
    '--path', $quotedProjectPath,
    '--script', $fixtureScript,
    '--'
)

$hostArguments = $commonArguments + @('--role=host', "--transport=$Transport", "--port=$Port")
$clientArguments = $commonArguments + @('--role=client', "--transport=$Transport", "--port=$Port")
$hostProcess = $null
$clientProcess = $null

try {
    $hostProcess = Start-Process -FilePath $RedotBin -ArgumentList $hostArguments -WorkingDirectory $projectPath -WindowStyle Hidden -RedirectStandardOutput $hostOut -RedirectStandardError $hostErr -PassThru
    Start-Sleep -Milliseconds 500
    $clientProcess = Start-Process -FilePath $RedotBin -ArgumentList $clientArguments -WorkingDirectory $projectPath -WindowStyle Hidden -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ((-not $hostProcess.HasExited -or -not $clientProcess.HasExited) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $hostProcess.Refresh()
        $clientProcess.Refresh()
    }

    if (-not $hostProcess.HasExited -or -not $clientProcess.HasExited) {
        throw "$Transport fixture timed out."
    }

    $hostProcess.WaitForExit()
    $clientProcess.WaitForExit()
    $hostText = Get-Content -LiteralPath $hostOut -Raw
    $clientText = Get-Content -LiteralPath $clientOut -Raw
    $hostErrorText = Get-Content -LiteralPath $hostErr -Raw
    $clientErrorText = Get-Content -LiteralPath $clientErr -Raw

    $hostExitCode = $hostProcess.ExitCode
    $clientExitCode = $clientProcess.ExitCode
    $hostFailed = $null -ne $hostExitCode -and $hostExitCode -ne 0
    $clientFailed = $null -ne $clientExitCode -and $clientExitCode -ne 0
    if ($hostFailed -or $clientFailed) {
        throw "$Transport fixture process failed (host exit $hostExitCode, client exit $clientExitCode).`nHOST:`n$hostText$hostErrorText`nCLIENT:`n$clientText$clientErrorText"
    }
    $marker = $Transport.ToUpperInvariant()
    if ($Scenario -eq 'facade') {
        $marker = "${marker}_FACADE"
    }
    if ($hostText -notmatch "${marker}_HOST_PASS" -or $clientText -notmatch "${marker}_CLIENT_PASS") {
        throw "$Transport fixture did not report both pass markers.`nHOST:`n$hostText$hostErrorText`nCLIENT:`n$clientText$clientErrorText"
    }
    Write-Output "${marker}_TWO_PROCESS_FIXTURE_PASS"
}
finally {
    if ($null -ne $clientProcess -and -not $clientProcess.HasExited) {
        Stop-Process -Id $clientProcess.Id -Force
    }
    if ($null -ne $hostProcess -and -not $hostProcess.HasExited) {
        Stop-Process -Id $hostProcess.Id -Force
    }
}
