[CmdletBinding()]
param([string]$Flutter = 'flutter', [string]$BuildConfig, [switch]$Simulator)
$ErrorActionPreference = 'Stop'
if (-not $IsMacOS) { throw 'Build iOS on macOS with Xcode installed.' }
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'build-common.ps1')
$settings = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $BuildConfig
$defines = @(Get-AsterLinkDartDefines -Settings $settings)
Test-AsterLinkVersion -ProjectPath $projectPath -Flutter $Flutter
Push-Location $projectPath
try {
    Invoke-AsterLinkTool -Command $Flutter -Arguments @('pub', 'get', '--enforce-lockfile') -Failure 'Locked Flutter dependencies failed'
    if ($Simulator) {
        Invoke-AsterLinkTool -Command $Flutter -Arguments (@('build', 'ios', '--simulator', '--debug', '--no-pub', '--target=tool/ios-smoke.dart') + $defines) -Failure 'iOS simulator build failed'
    } else {
        Invoke-AsterLinkTool -Command 'python' -Arguments @('tool/build-ios-core.py') -Failure 'iOS native download core build failed'
        Invoke-AsterLinkTool -Command $Flutter -Arguments (@('build', 'ios', '--release', '--no-codesign', '--no-pub') + $defines) -Failure 'Unsigned iOS device build failed'
    }
} finally { Pop-Location }
