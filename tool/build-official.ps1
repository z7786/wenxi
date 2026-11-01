[CmdletBinding()]
param(
    [ValidateSet('all', 'android', 'windows')][string]$Platform = 'all',
    [string]$Flutter = 'flutter',
    [string]$Go = 'go',
    [string]$Iscc,
    [ValidateSet('x64', 'arm64')][string]$WindowsArchitecture = 'x64',
    [string]$SevenZip,
    [switch]$RebuildNative,
    [switch]$Force,
    [switch]$CheckConfig
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'build-common.ps1')
$settings = Get-AsterLinkOfficialBuildSettings -ProjectPath $projectPath
$buildConfig = Join-Path $projectPath '.local/build-config.json'
$buildAndroid = $Platform -in @('all', 'android')
$buildWindows = $Platform -in @('all', 'windows')
if ($buildAndroid -and -not (Test-Path -LiteralPath (Join-Path $projectPath '.local/keystore.properties') -PathType Leaf)) {
    throw 'Official Android builds require the original .local/keystore.properties and its signing key.'
}
if ($CheckConfig) {
    Write-Host 'Official local configuration validated. No public template was used and no build was run.'
    return
}
Test-AsterLinkVersion -ProjectPath $projectPath -Flutter $Flutter
$lockPath = Join-Path $projectPath '.local/official-build.lock'
try {
    $buildLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch { throw 'An official build is already using this project. Wait for it to finish.' }
try {
    if ($buildAndroid) {
        & (Join-Path $PSScriptRoot 'build-android.ps1') -Flutter $Flutter -Go $Go -BuildConfig $buildConfig -RebuildNative:$RebuildNative
        Write-Host ('Official APK: ' + (Join-Path $projectPath 'build/app/outputs/flutter-apk/app-release.apk'))
    }
    if ($buildWindows) {
        & (Join-Path $PSScriptRoot 'build-windows.ps1') -Flutter $Flutter -Go $Go -BuildConfig $buildConfig -Architecture $WindowsArchitecture -SevenZip $SevenZip
        & (Join-Path $PSScriptRoot 'build-windows-installer.ps1') -Iscc $Iscc -Architecture $WindowsArchitecture -Force:$Force
    }
} finally { $buildLock.Dispose() }
