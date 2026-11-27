$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $projectPath 'tool/build-common.ps1')
$stage = Join-Path $projectPath ('.local/build-config-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$count = 0
try {
    $fixtureVariable = 'ASTERLINK_ENV_RESTORE_TEST_' + [Guid]::NewGuid().ToString('N')
    try {
        foreach ($previous in @($null, 'false', 'fixture')) {
            $saved = @{ $fixtureVariable = $previous }
            [Environment]::SetEnvironmentVariable($fixtureVariable, 'temporary', 'Process')
            Restore-AsterLinkEnvironment -SavedEnvironment $saved
            $restored = [Environment]::GetEnvironmentVariable($fixtureVariable, 'Process')
            if ($previous -ceq $null) {
                if (Test-Path -LiteralPath "Env:$fixtureVariable") { throw 'An absent variable was restored as an empty override.' }
            } elseif ($restored -cne $previous) {
                throw 'The previous environment value was not restored.'
            }
            $count++
        }
    } finally { Remove-Item -LiteralPath "Env:$fixtureVariable" -ErrorAction SilentlyContinue }
    $source = Join-Path $projectPath 'config/build.community.json'
    $settings = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $source
    if ($settings.controlEnabled -or $settings.githubRepository -or $settings.applicationId -ne 'com.asterlink.app.community') {
        throw 'Community configuration must not point to author services.'
    }
    if ($settings.PSObject.Properties.Name -contains 'metricsEnabled') {
        throw 'The statistics SDK must remain built in.'
    }
    $count++
    $configured = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $source -ConfigUrl 'https://config.example.test/control.json'
    if (-not $configured.controlEnabled) { throw 'An explicit valid config URL must enable configuration.' }
    if ($configured.announcementsUrl -ne 'https://config.example.test/announcements.json') { throw 'The independent announcement URL was not derived from the configured directory.' }
    if ($settings.announcementsUrl) { throw 'Unconfigured builds must not use an author announcement endpoint.' }
    $count++
    $offline = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $source -ConfigUrl 'https://config.example.test/control.json' -Offline
    if ($offline.controlEnabled -or $offline.githubRepository -or $offline.announcementsUrl) { throw 'Offline builds must not check updates or announcements.' }
    $count++
    $customAnnouncements = [IO.File]::ReadAllText($source) | ConvertFrom-Json
    $customAnnouncements.announcementsUrl = 'https://news.example.test/messages.json'
    $customPath = Join-Path $stage 'announcement-config.json'
    [IO.File]::WriteAllText($customPath, ($customAnnouncements | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $custom = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $customPath
    if ($custom.announcementsUrl -ne $customAnnouncements.announcementsUrl) { throw 'The custom announcement endpoint was ignored.' }
    $customOffline = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $customPath -Offline
    if ($customOffline.announcementsUrl) { throw 'An offline build retained its custom announcement endpoint.' }
    $count++
    foreach ($badAnnouncementsUrl in @('http://news.example.test/feed.json', 'https://news.example.test/feed.json#fragment', 'https://user:pass@news.example.test/feed.json')) {
        $customAnnouncements.announcementsUrl = $badAnnouncementsUrl
        [IO.File]::WriteAllText($customPath, ($customAnnouncements | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $customPath | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'An unsafe announcement endpoint was accepted.' }
        $count++
    }
    foreach ($invalidUrl in @('http://config.example.test/a', 'https://config.example.test/a#fragment', 'https://name:pass@config.example.test/a')) {
        $rejected = $false
        try { Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $source -ConfigUrl $invalidUrl | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'An unsafe config URL was accepted.' }
        $count++
    }
    foreach ($change in @(
        @{ field = 'controlEnabled'; value = 'false' },
        @{ field = 'applicationId'; value = 'invalid id' },
        @{ field = 'githubRepository'; value = '../other/repo' },
        @{ field = 'metricsAppKey'; value = 'invalid' }
    )) {
        $invalid = [IO.File]::ReadAllText($source) | ConvertFrom-Json
        $invalid.($change.field) = $change.value
        $file = Join-Path $stage 'invalid.json'
        [IO.File]::WriteAllText($file, ($invalid | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $file | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw "Invalid build field was accepted: $($change.field)" }
        $count++
    }
    # Source a copy so this fixture never reads or modifies real private settings.
    $definesRoot = Join-Path $stage 'defines-project'
    New-Item -ItemType Directory -Path (Join-Path $definesRoot 'tool'), (Join-Path $definesRoot '.local') -Force | Out-Null
    $definesScript = Join-Path $definesRoot 'tool/build-common.ps1'
    Copy-Item -LiteralPath (Join-Path $projectPath 'tool/build-common.ps1') -Destination $definesScript
    [IO.File]::WriteAllText((Join-Path $definesRoot '.local/baidu-api.defines.json'), 'invalid retired config', [Text.UTF8Encoding]::new($false))
    $defines = & {
        . $definesScript
        Get-AsterLinkDartDefines -Settings $settings
    }
    if ($defines -match 'baidu-api|ASTERLINK_BAIDU') { throw 'Retired Baidu service configuration was injected into the build.' }
    $count++
    $rejected = $false
    try { Invoke-AsterLinkTool -Command python -Arguments @('-c', 'raise SystemExit(7)') }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'A nonzero native exit code was accepted.' }
    $count++
    Invoke-AsterLinkTool -Command python -Arguments @('-c', 'import sys; sys.stderr.write(chr(110)+chr(10))') -Failure 'A successful command was rejected'
    $count++
    $officialRoot = Join-Path $stage 'official-project'
    New-Item -ItemType Directory -Path (Join-Path $officialRoot 'config'), (Join-Path $officialRoot '.local') -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination (Join-Path $officialRoot 'config/build.community.json')
    $rejected = $false
    try { Get-AsterLinkOfficialBuildSettings -ProjectPath $officialRoot | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Missing private settings must not fall back to a public template.' }
    $count++
    $officialConfig = Join-Path $officialRoot '.local/build-config.json'
    $officialSettings = [IO.File]::ReadAllText($source) | ConvertFrom-Json
    $officialSettings.applicationId = 'com.asterlink.app'
    $officialSettings.controlEnabled = $true
    $officialSettings.controlUrl = 'https://config.example.test/official.json'
    $officialSettings.metricsChannel = 'official'
    [IO.File]::WriteAllText($officialConfig, ($officialSettings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $selected = Get-AsterLinkOfficialBuildSettings -ProjectPath $officialRoot
    if ($selected.applicationId -ne 'com.asterlink.app' -or
        $selected.controlUrl -ne $officialSettings.controlUrl -or
        $selected.metricsChannel -ne 'official') {
        throw 'The official entry did not use the local private build settings.'
    }
    $count++
    Copy-Item -LiteralPath $source -Destination $officialConfig -Force
    $rejected = $false
    try { Get-AsterLinkOfficialBuildSettings -ProjectPath $officialRoot | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'A public template cannot masquerade as the official application.' }
    $count++
    Write-Output "Build configuration checks passed: $count"
} finally {
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    $allowed = [IO.Path]::GetFullPath((Join-Path $projectPath '.local')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStage.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a test directory outside the local test workspace.'
    }
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
