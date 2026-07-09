param(
    [switch]$SkipPipInstall
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$SourceDir = Join-Path $RepoRoot "src"
$PortableDir = Join-Path $RepoRoot "portable"
$BuildDir = Join-Path $RepoRoot ".build\pyinstaller"
$SpecDir = Join-Path $BuildDir "spec"
$SharedRuntimeDir = Join-Path $PortableDir "p50_ble_runtime"
$BuildVenvDir = Join-Path $RepoRoot ".build\build-venv"

function Add-PythonCandidate($list, $seen, [string]$fileName, [string[]]$prefixArguments) {
    if (-not $fileName -or -not (Test-Path -LiteralPath $fileName)) { return }
    $key = ($fileName + " " + ($prefixArguments -join " ")).ToLowerInvariant()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    [void]$list.Add([pscustomobject]@{ FileName = $fileName; PrefixArguments = $prefixArguments })
}

function Get-PythonLauncher {
    $candidates = New-Object System.Collections.ArrayList
    $seen = @{}
    Get-Command python -All -ErrorAction SilentlyContinue | ForEach-Object { Add-PythonCandidate $candidates $seen $_.Source @() }
    Get-Command py -All -ErrorAction SilentlyContinue | ForEach-Object { Add-PythonCandidate $candidates $seen $_.Source @("-3") }
    foreach ($candidate in $candidates) {
        $args = @($candidate.PrefixArguments) + @("-c", "import sys; print(sys.executable)")
        $out = & $candidate.FileName @args 2>$null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    throw "No usable Python was found on this build machine."
}

function Invoke-Python($python, [string[]]$arguments) {
    $allArgs = @($python.PrefixArguments) + $arguments
    & $python.FileName @allArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed: $($python.FileName) $($allArgs -join ' ')"
    }
}

function Ensure-PythonPackage($python, [string]$importName, [string]$pipName) {
    $args = @("-c", "import $importName")
    & $python.FileName @($python.PrefixArguments + $args) 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    if ($SkipPipInstall) {
        throw "Missing Python package '$pipName'. Re-run without -SkipPipInstall or install it manually."
    }
    Invoke-Python $python @("-m", "pip", "install", "--upgrade", $pipName)
}

function Build-Helper($python, [string]$scriptName, [string]$exeName) {
    $scriptPath = Join-Path $SourceDir $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing helper script: $scriptPath" }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($exeName)
    Remove-Item -LiteralPath (Join-Path $PortableDir $name) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $BuildDir $name) -Recurse -Force -ErrorAction SilentlyContinue
    $args = @(
        "-m", "PyInstaller",
        "--noconfirm",
        "--clean",
        "--onedir",
        "--contents-directory", ".",
        "--name", $name,
        "--distpath", $PortableDir,
        "--workpath", $BuildDir,
        "--specpath", $SpecDir,
        "--paths", $SourceDir,
        "--collect-submodules", "bleak",
        "--hidden-import", "PIL.Image",
        "--hidden-import", "PIL.ImageDraw",
        "--hidden-import", "PIL.ImageFont",
        "--exclude-module", "numpy",
        "--exclude-module", "scipy",
        "--exclude-module", "pandas",
        "--exclude-module", "matplotlib",
        "--exclude-module", "IPython",
        "--exclude-module", "jupyter",
        "--exclude-module", "tkinter",
        $scriptPath
    )
    & $python.FileName @($python.PrefixArguments + $args)
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed for $scriptName" }
    $exePath = Join-Path (Join-Path $PortableDir $name) $exeName
    if (-not (Test-Path -LiteralPath $exePath)) { throw "Expected exe was not created: $exePath" }
    return $exePath
}

function Publish-SessionRuntime([string]$sessionExe) {
    $sessionDir = Split-Path -Parent $sessionExe
    Remove-Item -LiteralPath $SharedRuntimeDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $sessionDir -Destination $SharedRuntimeDir
    return [pscustomobject]@{
        Session = Join-Path $SharedRuntimeDir "p50_ble_session.exe"
        Runtime = $SharedRuntimeDir
    }
}

New-Item -ItemType Directory -Force -Path $PortableDir, $BuildDir, $SpecDir | Out-Null

if ($SkipPipInstall) {
    $python = Get-PythonLauncher
    Ensure-PythonPackage $python "bleak" "bleak"
    Ensure-PythonPackage $python "PIL" "pillow"
    Ensure-PythonPackage $python "PyInstaller" "pyinstaller"
} else {
    $bootstrapPython = Get-PythonLauncher
    $repoFullPath = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
    $venvFullPath = [System.IO.Path]::GetFullPath($BuildVenvDir)
    if (-not $venvFullPath.StartsWith($repoFullPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Build virtual environment must stay inside the repository."
    }
    if (Test-Path -LiteralPath $BuildVenvDir) {
        Remove-Item -LiteralPath $BuildVenvDir -Recurse -Force
    }
    Invoke-Python $bootstrapPython @("-m", "venv", $BuildVenvDir)
    $venvPython = Join-Path $BuildVenvDir "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        throw "Build virtual environment did not create Python: $venvPython"
    }
    $python = [pscustomobject]@{ FileName = $venvPython; PrefixArguments = @() }
    Invoke-Python $python @("-m", "pip", "install", "-r", (Join-Path $RepoRoot "requirements-dev.txt"))
}

Write-Host "Build Python: $($python.FileName) $($python.PrefixArguments -join ' ')"

$sessionExe = Build-Helper $python "p50_ble_session.py" "p50_ble_session.exe"
$runtime = Publish-SessionRuntime $sessionExe

Write-Host ""
Write-Host "Portable BLE runtime created:"
Write-Host "  $($runtime.Runtime)"
Write-Host "  $($runtime.Session)"
