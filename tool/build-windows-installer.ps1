[CmdletBinding()]
param(
    [string]$RuntimeDir,
    [string]$OutputDir,
    [string]$Iscc,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectPath = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not $RuntimeDir) { $RuntimeDir = Join-Path $projectPath ("build\windows\$Architecture\runner\Release") }
if (-not $OutputDir) {
    $OutputDir = Join-Path $projectPath 'build\windows\installer'
    if ($Architecture -eq 'arm64') { $OutputDir = Join-Path $OutputDir 'arm64' }
}
$runtimePath = (Resolve-Path -LiteralPath $RuntimeDir).ProviderPath.TrimEnd('\')
$outputPath = [IO.Path]::GetFullPath($OutputDir).TrimEnd('\')
if ($outputPath.Equals($runtimePath, [StringComparison]::OrdinalIgnoreCase) -or
    $outputPath.StartsWith($runtimePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installer output must be outside the runtime directory.'
}

$pubspec = [IO.File]::ReadAllText((Join-Path $projectPath 'pubspec.yaml'))
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) { throw 'Expected pubspec version major.minor.patch+build.' }
$appVersion = $versionMatch.Groups[1].Value
$buildNumber = $versionMatch.Groups[2].Value
$fullVersion = $appVersion + '+' + $buildNumber
$numericVersion = $appVersion + '.' + $buildNumber
# Construct the localized name without depending on Windows PowerShell's script encoding.
$appName = -join ([char[]](0x6587, 0x6790, 0x52A9, 0x624B))
$baseName = $appName + '-' + $appVersion + '-Windows-' + $Architecture + '-Setup'
$installerPath = Join-Path $outputPath ($baseName + '.exe')
if ((Test-Path -LiteralPath $installerPath) -and -not $Force) {
    throw 'An installer with this version already exists. Use -Force to replace that build deliberately.'
}

$requiredFiles = @(
    'asterlink.exe', 'asterlink_gopeed.exe', 'asterlink_js.dll', 'flutter_windows.dll', 'libmpv-2.dll',
    'WebView2Loader.dll', 'msvcp140.dll', 'vcruntime140.dll',
    'data\app.so', 'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin',
    'data\flutter_assets\assets\licenses\THIRD_PARTY_NOTICES.md',
    'data\flutter_assets\assets\licenses\QuickJS-NG-LICENSE.txt'
)
if ($Architecture -eq 'x64') { $requiredFiles += 'vcruntime140_1.dll' }
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $runtimePath $relativePath) -PathType Leaf)) {
        throw "Incomplete Windows runtime: missing $relativePath"
    }
}
$runtimeVersion = (Get-Item -LiteralPath (Join-Path $runtimePath 'asterlink.exe')).VersionInfo.ProductVersion
if ($runtimeVersion -ne $fullVersion) {
    throw "Windows runtime version $runtimeVersion does not match pubspec $fullVersion. Rebuild Windows first."
}
$entries = @(Get-ChildItem -LiteralPath $runtimePath -Recurse -Force)
if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
    throw 'The runtime must not contain links or junctions.'
}
$runtimeFiles = @($entries | Where-Object { -not $_.PSIsContainer })
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')
Assert-AsterLinkWindowsArchitecture -RuntimePath $runtimePath -Architecture $Architecture
foreach ($file in $runtimeFiles) {
    $relativeFilePath = $file.FullName.Substring($runtimePath.Length + 1)
    if ($file.Name -match '(?i)(\.(jks|keystore|p12|pfx|pem|pdb|log)$|^unins\d+\.|^state-v\d|^\.env)' -or
        $relativeFilePath -match '(?i)(^|[\\/])(\.local|\.git|diagnostics|gopeed)([\\/]|$)') {
        throw "The runtime contains a development or user-data file: $($file.Name)"
    }
}

if (-not $Iscc) {
    $found = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($found) { $Iscc = $found.Source }
}
if (-not $Iscc) {
    $compilerCandidates = @(
        'D:\Tools\InnoSetup6\ISCC.exe',
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $compilerCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $Iscc = $candidate; break }
    }
}
if (-not $Iscc -or -not (Test-Path -LiteralPath $Iscc -PathType Leaf)) {
    throw 'Install Inno Setup 6.7.3, then pass -Iscc <path to ISCC.exe>. See windows/installer/README.md.'
}
$compilerPath = (Resolve-Path -LiteralPath $Iscc).ProviderPath

# Pin the official bootstrapper rather than the changing Evergreen redirect.
$dependencyPath = Join-Path $projectPath '.local\windows-installer'
$webViewPath = Join-Path $dependencyPath 'MicrosoftEdgeWebview2Setup.exe'
$webViewHash = '83004A28553BCF2F932BF03564FBAB407B8E1F59CD265F8DC99CC53D028E459C'
$webViewUrl = 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/ae30a660-6c9f-4f57-873b-30350e750fa0/MicrosoftEdgeWebview2Setup.exe'
New-Item -ItemType Directory -Path $dependencyPath -Force | Out-Null
$cached = (Test-Path -LiteralPath $webViewPath) -and
    ((Get-FileHash -LiteralPath $webViewPath -Algorithm SHA256).Hash -eq $webViewHash)
if (-not $cached) {
    $partialPath = Join-Path $dependencyPath 'MicrosoftEdgeWebview2Setup.exe.download'
    Write-Host 'Downloading the WebView2 bootstrapper from Microsoft...'
    $savedProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $webViewUrl -OutFile $partialPath -TimeoutSec 180
    } finally { $ProgressPreference = $savedProgress }
    if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash -ne $webViewHash) {
        throw 'WebView2 bootstrapper checksum mismatch; the download was not used.'
    }
    $downloadSignature = Get-AuthenticodeSignature -LiteralPath $partialPath
    if ($downloadSignature.Status -ne 'Valid' -or
        $downloadSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw 'WebView2 bootstrapper publisher signature did not verify.'
    }
    Move-Item -LiteralPath $partialPath -Destination $webViewPath -Force
}
$signature = Get-AuthenticodeSignature -LiteralPath $webViewPath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw 'Cached WebView2 bootstrapper publisher signature did not verify.'
}

$languagePath = Join-Path $projectPath 'windows\installer\languages\ChineseSimplified.isl'
if ((Get-FileHash -LiteralPath $languagePath -Algorithm SHA256).Hash -ne
    '7D544B9BB1D142CFA11F2E5D3CC8ABE2E55F8E066C5124E3772675AA236E1278') {
    throw 'The pinned Inno Setup Chinese translation changed. Review it before updating its checksum.'
}

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$payload = @($runtimeFiles | Sort-Object FullName | ForEach-Object {
    [pscustomobject][ordered]@{
        path = $_.FullName.Substring($runtimePath.Length + 1).Replace('\', '/')
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$arguments = @(
    '/Q',
    ('/DRuntimeDir=' + $runtimePath),
    ('/DAppVersion=' + $appVersion),
    ('/DAppFullVersion=' + $fullVersion),
    ('/DAppFileVersion=' + $numericVersion),
    ('/DAppArchitecture=' + $Architecture),
    ('/DInstallerOutputDir=' + $outputPath),
    ('/DWebView2Setup=' + $webViewPath),
    (Join-Path $projectPath 'windows\installer\asterlink.iss')
)
Write-Host "Building Windows installer $fullVersion from $($payload.Count) runtime files..."
$savedErrorPreference = $ErrorActionPreference
try {
    # Windows PowerShell represents native stderr as ErrorRecord objects.
    # Capture it for the log, then use the compiler exit code as the outcome.
    $ErrorActionPreference = 'Continue'
    $compilerOutput = @(& $compilerPath @arguments 2>&1)
    $compilerExitCode = $LASTEXITCODE
} finally { $ErrorActionPreference = $savedErrorPreference }
$logPath = Join-Path $outputPath 'installer-build.log'
[IO.File]::WriteAllLines($logPath, [string[]]$compilerOutput, $utf8)
if ($compilerExitCode -ne 0) {
    $compilerOutput | ForEach-Object { Write-Host $_ }
    throw "Installer compilation failed with exit code $compilerExitCode. See $logPath"
}
foreach ($file in $payload) {
    if ((Get-FileHash -LiteralPath (Join-Path $runtimePath $file.path) -Algorithm SHA256).Hash -ne $file.sha256) {
        throw 'The runtime changed while the installer was compiling. Build again from a stable release directory.'
    }
}
$installerFile = Get-Item -LiteralPath $installerPath
$installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{
    appVersion = $fullVersion
    architecture = $Architecture
    installer = [ordered]@{file=$installerFile.Name; bytes=$installerFile.Length; sha256=$installerHash}
    payloadFileCount = $payload.Count
    payloadBytes = ($payload | Measure-Object -Property bytes -Sum).Sum
    payload = $payload
    webView2Bootstrapper = [ordered]@{
        version = '1.3.269.9'; url = $webViewUrl
        sha256 = $webViewHash.ToLowerInvariant(); signature = [string]$signature.Status
    }
    compiler = $compilerPath
    builtAt = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $outputPath 'installer-manifest.json'), ($manifest | ConvertTo-Json -Depth 7), $utf8)
[IO.File]::WriteAllText((Join-Path $outputPath 'SHA256SUMS.txt'), ($installerHash + '  ' + $installerFile.Name + "`r`n"), $utf8)
Write-Host "Installer ready: $installerPath"
Write-Host "Size: $([math]::Round($installerFile.Length / 1MB, 2)) MiB; SHA256: $installerHash"
