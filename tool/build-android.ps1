[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [string]$Go = 'go',
    [string]$BuildConfig,
    [string]$ConfigUrl,
    [switch]$Offline,
    [switch]$Unsigned,
    [switch]$RebuildNative
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'build-common.ps1')
$settings = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $BuildConfig -ConfigUrl $ConfigUrl -Offline:$Offline
$dartDefines = @(Get-AsterLinkDartDefines -Settings $settings)
Test-AsterLinkVersion -ProjectPath $projectPath -Flutter $Flutter
if (-not $Unsigned -and -not (Test-Path -LiteralPath (Join-Path $projectPath '.local/keystore.properties'))) {
    throw 'Create .local/keystore.properties with your own signing key, or use -Unsigned for a build check.'
}
$savedEnvironment = @{}
foreach ($name in @('PUB_HOSTED_URL', 'FLUTTER_STORAGE_BASE_URL', 'TEMP', 'TMP', 'GRADLE_USER_HOME', 'PUB_CACHE',
    'ORG_GRADLE_PROJECT_ASTERLINK_APPLICATION_ID',
    'ORG_GRADLE_PROJECT_UMENG_APPKEY', 'ORG_GRADLE_PROJECT_UMENG_CHANNEL', 'ORG_GRADLE_PROJECT_ASTERLINK_UNSIGNED')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    if (-not $env:PUB_HOSTED_URL) { $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn' }
    if (-not $env:FLUTTER_STORAGE_BASE_URL) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
    $env:TEMP = Join-Path $projectPath '.local\build-tmp'
    $env:TMP = $env:TEMP
    $env:GRADLE_USER_HOME = Join-Path $projectPath '.local\gradle-home'
    $env:PUB_CACHE = Join-Path $projectPath '.local\pub-cache'
    $env:ORG_GRADLE_PROJECT_ASTERLINK_APPLICATION_ID = $settings.applicationId
    if ($settings.metricsAppKey) { $env:ORG_GRADLE_PROJECT_UMENG_APPKEY = $settings.metricsAppKey }
    $env:ORG_GRADLE_PROJECT_UMENG_CHANNEL = $settings.metricsChannel
    $env:ORG_GRADLE_PROJECT_ASTERLINK_UNSIGNED = $Unsigned.IsPresent.ToString().ToLowerInvariant()
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    if ($RebuildNative -or -not (Test-Path -LiteralPath (Join-Path $projectPath 'android/app/libs/gopeed-1.8.1.aar'))) {
        & (Join-Path $projectPath 'native/build-gopeed.ps1') -Go $Go
    }
    Push-Location -LiteralPath $projectPath
    try {
        Invoke-AsterLinkTool -Command $Flutter -Arguments @('pub', 'get', '--enforce-lockfile') -Failure 'Locked Flutter dependencies failed; use the package host recorded in pubspec.lock'
        Invoke-AsterLinkTool -Command $Flutter -Arguments (@('build', 'apk', '--release', '--no-pub', '--target-platform', 'android-arm64') + $dartDefines) -Failure 'Android release build failed'
        & (Join-Path $PSScriptRoot 'normalize-local-properties.ps1')
    } finally { Pop-Location }
} finally {
    Restore-AsterLinkEnvironment -SavedEnvironment $savedEnvironment
}
