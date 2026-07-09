param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [switch]$SkipTests,
    [switch]$SkipRuntimeBuild,
    [switch]$SkipPipInstall
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$BuildRoot = Join-Path $RepoRoot ".build\release"
$StageRoot = Join-Path $BuildRoot "stage"

function Test-BleRuntimeIpc([string]$exePath) {
    $output = @(
        '{"id":1,"cmd":"status"}',
        '{"id":2,"cmd":"runtime-check"}',
        '{"id":3,"cmd":"exit"}'
    ) | & $exePath
    if ($LASTEXITCODE -ne 0) { throw "Portable BLE runtime smoke test failed to start: $exePath" }
    $responses = @($output | ForEach-Object { $_ | ConvertFrom-Json })
    if ($responses.Count -ne 3 -or
        -not $responses[0].ok -or
        $responses[0].result.connected -or
        -not $responses[1].ok -or
        $responses[1].result.backend -ne "BleakScannerWinRT" -or
        -not $responses[2].ok) {
        throw "Portable BLE runtime returned an invalid IPC smoke-test response: $exePath"
    }
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use the form 1.2.3."
}
if (-not ([System.IO.Path]::GetFullPath($StageRoot)).StartsWith([System.IO.Path]::GetFullPath($RepoRoot), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release staging directory must stay inside the repository."
}

if (-not $SkipTests) {
    Push-Location $RepoRoot
    try {
        & python -m unittest discover -s tests -v
        if ($LASTEXITCODE -ne 0) { throw "Python tests failed." }
        & python -m mypy src tests
        if ($LASTEXITCODE -ne 0) { throw "Python type check failed." }
        & python -m compileall -q src tests
        if ($LASTEXITCODE -ne 0) { throw "Python compile check failed." }
        & powershell -NoProfile -ExecutionPolicy Bypass -File ".\P50_Print_Assistant.ps1" -SelfTest
        if ($LASTEXITCODE -ne 0) { throw "GUI self-test failed." }
        & powershell -NoProfile -ExecutionPolicy Bypass -File ".\P50_Print_Assistant.ps1" -BleIpcSelfTest
        if ($LASTEXITCODE -ne 0) { throw "BLE IPC self-test failed." }
    } finally {
        Pop-Location
    }
}

if (-not $SkipRuntimeBuild) {
    $runtimeBuildArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ScriptDir "build_portable_ble.ps1"))
    if ($SkipPipInstall) { $runtimeBuildArgs += "-SkipPipInstall" }
    & powershell @runtimeBuildArgs
    if ($LASTEXITCODE -ne 0) { throw "Portable BLE runtime build failed." }
}

$runtimeDir = Join-Path $RepoRoot "portable\p50_ble_runtime"
$sessionExe = Join-Path $runtimeDir "p50_ble_session.exe"
if (-not (Test-Path -LiteralPath $sessionExe)) {
    throw "Portable BLE session helper was not found: $sessionExe"
}
if (Test-Path -LiteralPath (Join-Path $runtimeDir "p50_ble_probe.exe")) {
    throw "The release runtime should contain only p50_ble_session.exe."
}

Test-BleRuntimeIpc $sessionExe

$packageName = "P50_Print_Assistant_v${Version}"
$assetName = "P50_Print_Assistant_v${Version}_windows_portable"
$packageDir = Join-Path $StageRoot $packageName
$zipPath = Join-Path $BuildRoot "$assetName.zip"

if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

foreach ($file in @("LICENSE", "P50_Print_Assistant.ps1", "README.md", "Start_P50_Print_Assistant.vbs")) {
    Copy-Item -LiteralPath (Join-Path $RepoRoot $file) -Destination $packageDir
}
Copy-Item -LiteralPath (Join-Path $RepoRoot "docs") -Destination (Join-Path $packageDir "docs") -Recurse
Copy-Item -LiteralPath $runtimeDir -Destination (Join-Path $packageDir "runtime") -Recurse

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $packageDir "P50_Print_Assistant.ps1") -SelfTest
if ($LASTEXITCODE -ne 0) { throw "Staged release GUI/runtime self-test failed." }

Compress-Archive -LiteralPath $packageDir -DestinationPath $zipPath -CompressionLevel Optimal

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $longestEntry = $archive.Entries | Sort-Object { $_.FullName.Length } -Descending | Select-Object -First 1
    if ($longestEntry.FullName.Length -gt 140) {
        throw "Release archive contains an excessively long relative path ($($longestEntry.FullName.Length)): $($longestEntry.FullName)"
    }
} finally {
    $archive.Dispose()
}

$deepSmokeRoot = Join-Path $BuildRoot ("deep-path-smoke-" + ("x" * 40))
$buildRootPrefix = [System.IO.Path]::GetFullPath($BuildRoot).TrimEnd('\') + '\'
if (-not ([System.IO.Path]::GetFullPath($deepSmokeRoot)).StartsWith($buildRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Deep-path smoke directory must stay inside the release build directory."
}
if (Test-Path -LiteralPath $deepSmokeRoot) { Remove-Item -LiteralPath $deepSmokeRoot -Recurse -Force }
try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $deepSmokeRoot
    Test-BleRuntimeIpc (Join-Path (Join-Path $deepSmokeRoot $packageName) "runtime\p50_ble_session.exe")
} finally {
    if (Test-Path -LiteralPath $deepSmokeRoot) { Remove-Item -LiteralPath $deepSmokeRoot -Recurse -Force }
}

$hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
Write-Host "Release package: $zipPath"
Write-Host "SHA256: $($hash.Hash.ToLowerInvariant())"
