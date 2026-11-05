[CmdletBinding()]
param([string]$Flutter = 'flutter', [string]$Go = 'go', [string]$BuildConfig)
$ErrorActionPreference = 'Stop'
if (-not $IsMacOS) { throw 'Build macOS on a Mac or GitHub macOS runner.' }
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'build-common.ps1')
$settings = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $BuildConfig
$defines = @(Get-AsterLinkDartDefines -Settings $settings)
Test-AsterLinkVersion -ProjectPath $projectPath -Flutter $Flutter
$nativePath = Join-Path $projectPath 'native/bin/macos-arm64'
New-Item -ItemType Directory -Path $nativePath -Force | Out-Null
$savedEnvironment = @{}
foreach ($name in @('GOOS', 'GOARCH', 'CGO_ENABLED')) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:GOOS = 'darwin'; $env:GOARCH = 'arm64'; $env:CGO_ENABLED = '0'
    Push-Location (Join-Path $projectPath 'native/gopeed')
    try {
        Invoke-AsterLinkTool -Command $Go -Arguments @('build', '-mod=vendor', '-tags', 'nosqlite', '-trimpath', '-ldflags', '-s -w -checklinkname=0 -X github.com/GopeedLab/gopeed/pkg/base.Version=1.8.1', '-o', (Join-Path $nativePath 'asterlink_gopeed'), './cmd/asterlink') -Failure 'macOS download helper build failed'
    } finally { Pop-Location }
} finally { Restore-AsterLinkEnvironment $savedEnvironment }
Push-Location $projectPath
try {
    $sources = @('bridge.c', 'quickjs/quickjs.c', 'quickjs/libregexp.c', 'quickjs/libunicode.c', 'quickjs/dtoa.c') | ForEach-Object { Join-Path $projectPath "vendor_plugins/asterlink_js/src/$_" }
    Invoke-AsterLinkTool -Command 'clang' -Arguments (@('-arch', 'arm64', '-dynamiclib', '-O2', '-std=gnu11', '-mmacosx-version-min=11.0', '-I', (Join-Path $projectPath 'vendor_plugins/asterlink_js/src/quickjs'), '-o', (Join-Path $nativePath 'libasterlink_js.dylib')) + $sources) -Failure 'macOS parser runtime build failed'
    Invoke-AsterLinkTool -Command $Flutter -Arguments @('pub', 'get', '--enforce-lockfile') -Failure 'Locked Flutter dependencies failed'
    Invoke-AsterLinkTool -Command $Flutter -Arguments (@('build', 'macos', '--release', '--no-pub') + $defines) -Failure 'macOS application build failed'
    $apps = @(Get-ChildItem -LiteralPath 'build/macos/Build/Products/Release' -Filter '*.app' -Directory)
    if ($apps.Count -ne 1) { throw 'Expected one macOS app bundle.' }
    $destination = Join-Path $apps[0].FullName 'Contents/MacOS/asterlink_gopeed'
    Copy-Item -LiteralPath (Join-Path $nativePath 'asterlink_gopeed') -Destination $destination
    & chmod 755 $destination
    if ($LASTEXITCODE -ne 0) { throw 'Could not set download helper permissions.' }
    Invoke-AsterLinkTool -Command 'codesign' -Arguments @('--force', '--sign', '-', $destination) -Failure 'Download helper ad hoc signing failed'
    Invoke-AsterLinkTool -Command 'codesign' -Arguments @('--force', '--deep', '--sign', '-', '--entitlements', 'macos/Runner/Release.entitlements', $apps[0].FullName) -Failure 'Test app ad hoc signing failed'
    Write-Host "macOS ARM64 app ready: $($apps[0].Name). Developer ID signing and notarization are not configured."
} finally { Pop-Location }
