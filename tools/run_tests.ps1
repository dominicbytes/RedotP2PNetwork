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
$diagnosticsFiles = @((Join-Path $projectPath 'tests/known_engine_diagnostics.txt'), $ExtraAllowedDiagnosticsFile)
$allowedDiagnostics = @(Get-AllowedEngineDiagnostics -Files $diagnosticsFiles -EngineVersion $engineVersion)
$classCache = Join-Path $projectPath '.godot/global_script_class_cache.cfg'

function Assert-EditorImportComplete {
    if (-not (Test-Path -LiteralPath $classCache)) { throw 'Editor import did not create the script class cache.' }
    $cache = Get-Content -LiteralPath $classCache -Raw
    foreach ($script in Get-ChildItem -LiteralPath (Join-Path $projectPath 'addons/redot_p2p_network') -Filter '*.gd' -Recurse) {
        $declaration = Select-String -LiteralPath $script.FullName -Pattern '^class_name (\w+)'
        if ($null -ne $declaration) {
            $className = $declaration.Matches[0].Groups[1].Value
            if ($cache -notmatch ('"class": &"' + [regex]::Escape($className) + '"')) {
                throw "Editor import did not register addon class $className."
            }
        }
    }
}

function Invoke-Redot {
    param([string[]]$Arguments, [string]$Label, [string]$LogName, [string]$RequiredMarker = '')
    Write-Output "== $Label =="
    $stdout = Join-Path $artifactPath "$LogName.stdout.log"
    $stderr = Join-Path $artifactPath "$LogName.stderr.log"
    $process = Start-TestProcess -RedotBin $resolvedRedot -Arguments $Arguments -ProjectPath $projectPath -Stdout $stdout -Stderr $stderr
    try {
        Wait-TestProcess -Process $process -TimeoutSeconds $TimeoutSeconds -Label $Label
        $stepDiagnostics = $allowedDiagnostics
        if ($LogName -eq 'import') {
            Assert-EditorImportComplete
            $stepDiagnostics = @(Get-AllowedEngineDiagnostics -Files $diagnosticsFiles -EngineVersion $engineVersion -Step 'editor-import')
        }
        Assert-EngineDiagnostics -Logs @($stdout, $stderr) -AllowedDiagnostics $stepDiagnostics -Label $Label
        # Known Redot 26.3-stable headless editor shutdown leak; an engine fix
        # has been submitted. Remove this exception once a fixed engine is pinned.
        # The fresh class cache above proves import completed before shutdown.
        $knownImportCrash = $LogName -eq 'import' -and $engineVersion.StartsWith('26.3') -and $process.ExitCode -eq -1073741819
        if ($process.ExitCode -ne 0 -and -not $knownImportCrash) { throw "$Label failed with exit code $($process.ExitCode)." }
        if ($RequiredMarker -and (Get-Content -LiteralPath $stdout -Raw) -notmatch "(?m)^$RequiredMarker\r?$") {
            throw "$Label did not reach its completion marker."
        }
    }
    finally { Stop-TestProcessTree -Process $process }
}

Push-Location $projectPath
try {
    # Discard stale completion evidence before every import.
    if (Test-Path -LiteralPath $classCache) { Remove-Item -LiteralPath $classCache -Force }
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
