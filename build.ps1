<#
.SYNOPSIS
    Builds the homelab-seed installer image on Windows.

.DESCRIPTION
    Needs only Docker Desktop (Linux containers) - no WSL shell, no Git Bash.
    The build itself runs in a privileged Linux container, exactly as with build.sh.
    Files referenced in the configuration must be inside the directory of the
    configuration file.

.PARAMETER Config
    Configuration file (default: config.env next to this script).

.PARAMETER Output
    Output directory (default: out\ next to this script).

.PARAMETER Xz
    Compress the image with xz.

.PARAMETER Bundle
    Only validate the configuration and pack it into <Output>\config.bundle.b64,
    to be stored as a CI secret (see README).

.EXAMPLE
    .\build.ps1
.EXAMPLE
    .\build.ps1 -Config ..\my-homelab\seed\config.env -Xz
.EXAMPLE
    .\build.ps1 -Bundle
#>
[CmdletBinding()]
param(
    [string]$Config = (Join-Path $PSScriptRoot 'config.env'),
    [string]$Output = (Join-Path $PSScriptRoot 'out'),
    [switch]$Xz,
    [switch]$Bundle
)

$ErrorActionPreference = 'Stop'
$BuilderImage = 'homelab-seed-builder:local'

function Stop-Build([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    Stop-Build "$Config not found. Create it with: Copy-Item config.example.env config.env"
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Stop-Build 'Docker Desktop is required: https://docs.docker.com/desktop/setup/install/windows-install/'
}
$osType = docker info --format '{{.OSType}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    Stop-Build 'Docker is not running. Start Docker Desktop and try again.'
}
if ($osType -ne 'linux') {
    Stop-Build 'Docker Desktop must use Linux containers (right-click the tray icon: "Switch to Linux containers").'
}

# Scripts with Windows line endings fail inside the container.
$buildScript = Join-Path $PSScriptRoot 'builder\build-image.sh'
if ([IO.File]::ReadAllText($buildScript).Contains("`r")) {
    Stop-Build ("The repository was checked out with Windows line endings. Clone it again with:`n" +
        '  git clone -c core.autocrlf=false https://github.com/chris199512/homelab-seed.git')
}

$configFile = Get-Item -LiteralPath $Config
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$outDir = (Resolve-Path -LiteralPath $Output).Path

$version = 'unknown'
if (Get-Command git -ErrorAction SilentlyContinue) {
    $described = git -C $PSScriptRoot describe --always --dirty 2>$null
    if ($LASTEXITCODE -eq 0 -and $described) { $version = $described }
}

Write-Host '==> Preparing the builder container' -ForegroundColor Cyan
docker build --quiet -t $BuilderImage (Join-Path $PSScriptRoot 'builder') | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-Build 'Building the builder container failed.' }

docker run --rm --privileged `
    -e "SEED_CONFIG_NAME=$($configFile.Name)" `
    -e "SEED_VERSION=$version" `
    -e "SEED_XZ=$($Xz.IsPresent.ToString().ToLower())" `
    -e "SEED_MODE=$(if ($Bundle) { 'bundle' } else { 'build' })" `
    -v "${PSScriptRoot}:/src:ro" `
    -v "$($configFile.DirectoryName):/config:ro" `
    -v 'homelab-seed-cache:/cache' `
    -v 'homelab-seed-work:/work' `
    -v "${outDir}:/out" `
    $BuilderImage bash /src/builder/build-image.sh
if ($LASTEXITCODE -ne 0) { Stop-Build 'The build failed (see the messages above).' }

if ($Bundle) {
    Write-Host "==> Config bundle written to $(Join-Path $outDir 'config.bundle.b64')" -ForegroundColor Green
} else {
    Write-Host "==> Image written to $outDir" -ForegroundColor Green
}
