function Restore-AsterLinkEnvironment {
    param([hashtable]$SavedEnvironment)
    foreach ($name in $SavedEnvironment.Keys) {
        if ($null -eq $SavedEnvironment[$name]) {
            # Remove absent variables explicitly: newer PowerShell/.NET versions
            # preserve empty strings, which override Gradle property defaults.
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $SavedEnvironment[$name], 'Process')
        }
    }
}

function Invoke-AsterLinkTool {
    param([string]$Command, [string[]]$Arguments, [string]$Failure = 'Build command failed')
    Get-Command $Command -ErrorAction Stop | Out-Null
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell wraps native stderr in ErrorRecord objects, even
        # for successful commands. Preserve the message and check the exit code.
        $ErrorActionPreference = 'Continue'
        & $Command @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        $commandExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($commandExit -ne 0) { throw "$Failure (exit code $commandExit)." }
}

function Get-AsterLinkBuildSettings {
    param([string]$ProjectPath, [string]$BuildConfig, [string]$ConfigUrl, [switch]$Offline)
    if (-not $BuildConfig) {
        $BuildConfig = Join-Path $ProjectPath '.local/build-config.json'
        if (-not (Test-Path -LiteralPath $BuildConfig -PathType Leaf)) {
            $BuildConfig = Join-Path $ProjectPath 'config/build.community.json'
        }
    }
    $settings = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $BuildConfig).ProviderPath) | ConvertFrom-Json
    $expected = @('controlEnabled', 'controlUrl', 'githubRepository', 'applicationId', 'metricsAppKey', 'metricsChannel')
    $names = @($settings.PSObject.Properties.Name)
    if (@(Compare-Object ($expected | Sort-Object) ($names | Where-Object { $_ -ne 'announcementsUrl' } | Sort-Object)).Count -ne 0) {
        throw 'Build config must have the required fields in config/build.community.json, plus optional announcementsUrl.'
    }
    if ($names -notcontains 'announcementsUrl') { $settings | Add-Member -NotePropertyName announcementsUrl -NotePropertyValue '' }
    foreach ($name in @('controlEnabled')) {
        if ($settings.$name -isnot [bool]) { throw "Build config field $name must be a JSON boolean." }
    }
    foreach ($name in @('controlUrl', 'announcementsUrl', 'githubRepository', 'applicationId', 'metricsAppKey', 'metricsChannel')) {
        if ($settings.$name -isnot [string]) { throw "Build config field $name must be a string." }
        $settings.$name = $settings.$name.Trim()
    }
    if ($ConfigUrl) { $settings.controlUrl = $ConfigUrl; $settings.controlEnabled = $true }
    if ($Offline) { $settings.controlEnabled = $false; $settings.githubRepository = ''; $settings.announcementsUrl = '' }
    if ($settings.controlEnabled) {
        $uri = $null
        if (-not [Uri]::TryCreate($settings.controlUrl, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.Port -lt 1 -or
            $uri.UserInfo -or $uri.Fragment -or $settings.controlUrl.Length -gt 2048 -or
            $settings.controlUrl -match '[\s\x00-\x1f\x7f\\]') {
            throw 'controlUrl must be an absolute HTTPS URL without credentials or a fragment.'
        }
    }
    if (-not $settings.announcementsUrl -and $settings.controlEnabled) {
        $controlUri = [Uri]$settings.controlUrl
        if (-not $controlUri.Query -and $controlUri.AbsolutePath.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
            $settings.announcementsUrl = [Uri]::new($controlUri, 'announcements.json').AbsoluteUri
        }
    }
    if ($settings.announcementsUrl) {
        $announcementsUri = $null
        if (-not [Uri]::TryCreate($settings.announcementsUrl, [UriKind]::Absolute, [ref]$announcementsUri) -or
            $announcementsUri.Scheme -ne 'https' -or -not $announcementsUri.Host -or $announcementsUri.Port -lt 1 -or
            $announcementsUri.UserInfo -or $announcementsUri.Fragment -or $settings.announcementsUrl.Length -gt 2048 -or
            $settings.announcementsUrl -match '[\s\x00-\x1f\x7f\\]') {
            throw 'announcementsUrl must be an absolute HTTPS URL without credentials or a fragment.'
        }
    }
    if ($settings.githubRepository -and $settings.githubRepository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$') {
        throw 'githubRepository must be empty or owner/repository.'
    }
    if ($settings.applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
        throw 'applicationId must be a valid Android application ID.'
    }
    if ($settings.metricsAppKey -and $settings.metricsAppKey -notmatch '^[0-9a-fA-F]{24}$') {
        throw 'metricsAppKey must be empty (use the built-in value) or a 24-character key.'
    }
    if ($settings.metricsChannel -notmatch '^[A-Za-z0-9_.-]{1,64}$') {
        throw 'metricsChannel must use 1-64 letters, digits, dots, underscores or hyphens.'
    }
    return $settings
}

function Get-AsterLinkDartDefines {
    param($Settings)
    "--dart-define=ASTERLINK_ANNOUNCEMENTS_URL=$($Settings.announcementsUrl)"
    @(
        "--dart-define=ASTERLINK_CONTROL_ENABLED=$($Settings.controlEnabled.ToString().ToLowerInvariant())"
        "--dart-define=ASTERLINK_CONTROL_URL=$($Settings.controlUrl)"
        "--dart-define=ASTERLINK_GITHUB_REPO=$($Settings.githubRepository)"
    )
    $baiduConfig = Join-Path (Split-Path -Parent $PSScriptRoot) '.local/baidu-api.defines.json'
    if (Test-Path -LiteralPath $baiduConfig -PathType Leaf) {
        $baidu = Get-Content -Raw -Encoding utf8 -LiteralPath $baiduConfig | ConvertFrom-Json
        $serviceUri = $null
        if (-not [Uri]::TryCreate($baidu.ASTERLINK_BAIDU_API_URL, [UriKind]::Absolute, [ref]$serviceUri) -or
            $serviceUri.Scheme -notin @('http', 'https') -or $serviceUri.UserInfo -or
            $serviceUri.Query -or $serviceUri.Fragment -or
            $baidu.ASTERLINK_BAIDU_API_PUBLIC_KEY -notmatch '^[0-9a-fA-F]{768,1024}$' -or
            $baidu.ASTERLINK_BAIDU_API_ACCESS_KEY -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'Invalid private Baidu API build configuration.'
        }
        if ($baidu.ASTERLINK_BAIDU_RELAY_API_URL) {
            $relayUri = $null
            if (-not [Uri]::TryCreate($baidu.ASTERLINK_BAIDU_RELAY_API_URL, [UriKind]::Absolute, [ref]$relayUri) -or
                $relayUri.Scheme -notin @('http', 'https') -or -not $relayUri.Host -or
                $relayUri.UserInfo -or $relayUri.Query -or $relayUri.Fragment -or
                -not $relayUri.AbsolutePath.EndsWith('/') -or
                $baidu.ASTERLINK_BAIDU_RELAY_API_URL -match '[\s\x00-\x1f\x7f\\]') {
                throw 'Invalid private Baidu relay API build configuration.'
            }
        }
        "--dart-define-from-file=$baiduConfig"
    }
    $commandConfig = Join-Path (Split-Path -Parent $PSScriptRoot) '.local/cloud-command.defines.json'
    $parserConfig = Join-Path (Split-Path -Parent $PSScriptRoot) '.local/parser-hub.defines.json'
    if (Test-Path -LiteralPath $parserConfig -PathType Leaf) {
        $parserHub = Get-Content -Raw -Encoding utf8 -LiteralPath $parserConfig | ConvertFrom-Json
        $parserUri = $null
        $parserHubUrl = [string]$parserHub.ASTERLINK_PARSER_HUB_URL
        if ($parserHubUrl -and (
            -not [Uri]::TryCreate($parserHubUrl, [UriKind]::Absolute, [ref]$parserUri) -or
            $parserUri.Scheme -notin @('http', 'https') -or -not $parserUri.Host -or
            $parserUri.Port -lt 1 -or $parserUri.UserInfo -or $parserUri.Query -or $parserUri.Fragment -or
            $parserHubUrl.Length -gt 2048 -or $parserHubUrl -match '[\s\x00-\x1f\x7f\\]')) {
            throw 'Invalid optional parser hub fallback URL.'
        }
        if ($parserHub.ASTERLINK_PARSER_HUB_KEY -notmatch '^wxp_[a-f0-9]{48}$' -or
            $parserHub.ASTERLINK_PARSER_HUB_PUBLIC_KEY -notmatch '^[A-Za-z0-9+/=]{400,12000}$') {
            throw 'Invalid private parser hub build configuration.'
        }
        if ($parserHub.PSObject.Properties.Name -contains 'ASTERLINK_PARSER_RULES_BACKUP_URL' -and $parserHub.ASTERLINK_PARSER_RULES_BACKUP_URL) {
            $parserBackupUri = $null
            if (-not [Uri]::TryCreate($parserHub.ASTERLINK_PARSER_RULES_BACKUP_URL, [UriKind]::Absolute, [ref]$parserBackupUri) -or
                $parserBackupUri.Scheme -ne 'https' -or -not $parserBackupUri.Host -or $parserBackupUri.UserInfo -or $parserBackupUri.Fragment) {
                throw 'Invalid parser rules backup URL; use a public HTTPS JSON address.'
            }
        }
        "--dart-define-from-file=$parserConfig"
    }
    if (Test-Path -LiteralPath $commandConfig -PathType Leaf) {
        $commandKeys = Get-Content -Raw -Encoding utf8 -LiteralPath $commandConfig | ConvertFrom-Json
        foreach ($entry in @(@('ASTERLINK_QUARK_COMMAND_KEY', 88), @('ASTERLINK_UC_COMMAND_KEY', 24))) {
            $value = $commandKeys.($entry[0])
            if ($value -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($value) -ne $entry[1]) {
                throw 'Invalid private cloud command build configuration.'
            }
        }
        "--dart-define-from-file=$commandConfig"
    }
}

function Test-AsterLinkVersion {
    param([string]$ProjectPath, [string]$Flutter)
    $flutterPath = (Get-Command $Flutter -ErrorAction Stop).Source
    $dartPath = Join-Path (Split-Path -Parent $flutterPath) 'dart.bat'
    if (-not (Test-Path -LiteralPath $dartPath -PathType Leaf)) { $dartPath = 'dart' }
    Invoke-AsterLinkTool -Command $dartPath -Arguments @((Join-Path $ProjectPath 'tool/sync_version.dart'), '--check') -Failure 'Application version check failed'
}

function Get-AsterLinkOfficialBuildSettings {
    param([string]$ProjectPath)
    $configPath = Join-Path $ProjectPath '.local/build-config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'Official builds require .local/build-config.json. Public templates are not used as a fallback.'
    }
    $settings = Get-AsterLinkBuildSettings -ProjectPath $ProjectPath -BuildConfig $configPath
    if ($settings.applicationId -ne 'com.asterlink.app') {
        throw 'The local official build config must retain applicationId com.asterlink.app.'
    }
    return $settings
}
