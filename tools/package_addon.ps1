param(
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectPath 'dist'
}
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

$pluginConfig = Get-Content -LiteralPath (Join-Path $projectPath 'addons\redot_p2p_network\plugin.cfg') -Raw
$versionMatch = [regex]::Match($pluginConfig, '(?m)^version="([0-9A-Za-z.-]+)"$')
if (-not $versionMatch.Success) {
    throw 'Could not read a safe version from addon plugin.cfg.'
}
$version = $versionMatch.Groups[1].Value
$packageBase = "redot-p2p-network-$version"
$archivePath = Join-Path $outputPath "$packageBase.zip"
$checksumPath = "$archivePath.sha256"
$stagingPath = Join-Path $outputPath ".staging-$packageBase"

$normalizedOutput = $outputPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$normalizedStaging = [System.IO.Path]::GetFullPath($stagingPath)
if (-not $normalizedStaging.StartsWith($normalizedOutput, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to use a staging path outside the selected output directory.'
}

try {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stagingPath 'addons') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stagingPath 'docs') | Out-Null

    Copy-Item -LiteralPath (Join-Path $projectPath 'addons\redot_p2p_network') -Destination (Join-Path $stagingPath 'addons') -Recurse
    foreach ($fileName in @('README.md', 'LICENSE', 'NOTICE.md', 'SECURITY.md', 'CHANGELOG.md')) {
        Copy-Item -LiteralPath (Join-Path $projectPath $fileName) -Destination $stagingPath
    }
    Copy-Item -LiteralPath (Join-Path $projectPath 'docs\compatibility') -Destination (Join-Path $stagingPath 'docs') -Recurse
    Copy-Item -LiteralPath (Join-Path $projectPath 'docs\security') -Destination (Join-Path $stagingPath 'docs') -Recurse
    Copy-Item -LiteralPath (Join-Path $projectPath 'docs\migration-from-godotp2pnetwork.md') -Destination (Join-Path $stagingPath 'docs')
    Copy-Item -LiteralPath (Join-Path $projectPath 'docs\transports.md') -Destination (Join-Path $stagingPath 'docs')

    Add-Type -AssemblyName System.IO.Compression
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
    $archive = [System.IO.Compression.ZipArchive]::new(
        $archiveStream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    try {
        $stagingPrefixLength = $stagingPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Length + 1
        $fixedTimestamp = [System.DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
        $files = Get-ChildItem -LiteralPath $stagingPath -Recurse -File | Sort-Object FullName
        foreach ($file in $files) {
            $entryName = $file.FullName.Substring($stagingPrefixLength).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTimestamp
            $sourceStream = [System.IO.File]::OpenRead($file.FullName)
            $entryStream = $entry.Open()
            try {
                $sourceStream.CopyTo($entryStream)
            }
            finally {
                $entryStream.Dispose()
                $sourceStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
        $archiveStream.Dispose()
    }
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $checksumPath -Value "$hash  $([System.IO.Path]::GetFileName($archivePath))" -Encoding ascii

    Write-Output "PACKAGE=$archivePath"
    Write-Output "SHA256=$hash"
}
finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}
