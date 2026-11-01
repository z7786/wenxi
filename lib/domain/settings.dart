import '../core/json.dart';
import 'models.dart';
import 'appearance.dart';
import 'background.dart';
import 'download_retries.dart';
import 'github_acceleration.dart';

class BrowserDisplaySettings {
  const BrowserDisplaySettings({
    this.view = 'list',
    this.sort = 'name',
    this.ascending = true,
    this.searchSubfolders = false,
  });

  final String view, sort;
  final bool ascending, searchSubfolders;

  Json toJson() => {
    'view': view,
    'sort': sort,
    'ascending': ascending,
    'searchSubfolders': searchSubfolders,
  };

  factory BrowserDisplaySettings.fromJson(Json j) => BrowserDisplaySettings(
    view: j.str('view') == 'grid' ? 'grid' : 'list',
    sort: ['name', 'size', 'date'].contains(j.str('sort'))
        ? j.str('sort')
        : 'name',
    ascending: j.boolean('ascending', true),
    searchSubfolders: j.boolean('searchSubfolders'),
  );
}

class AppSettings {
  const AppSettings({
    this.theme = 'System',
    this.themePalette = AppPalette.blue,
    this.glassStyle = GlassStyle.clear,
    this.background = const BackgroundSettings(),
    this.hideResourceNavigation = false,
    this.fontScalePercent = 100,
    this.threads = 64,
    this.concurrent = 3,
    this.retries = defaultDownloadRetries,
    this.speedLimit = 0,
    this.btUploadLimit = 512 * 1024,
    this.threadOverrides = const {},
    this.githubAcceleration = const GitHubAcceleration(),
    this.destination,
    this.browserView = 'list',
    this.browserDisplays = const {},
    this.clipboardRecognition = true,
    this.quarkGuestDirectDownload = false,
    this.ucGuestDirectDownload = true,
    this.quarkAuthenticatedDirectDownload = false,
    this.hideGuestDownloadNotice = false,
    this.hideBaiduDownloadNotice = false,
    this.warnOnMobileDataDownload = true,
  });
  final String theme;
  final AppPalette themePalette;
  final GlassStyle glassStyle;
  final BackgroundSettings background;
  final bool hideResourceNavigation;
  final int fontScalePercent;
  static const minFontScalePercent = 80;
  static const maxFontScalePercent = 180;
  static const maxConcurrentDownloads = 32;
  final int threads, concurrent, retries, speedLimit;
  final int btUploadLimit;
  final Map<String, int> threadOverrides;
  final GitHubAcceleration githubAcceleration;
  final String? destination;
  final String browserView;
  final Map<String, BrowserDisplaySettings> browserDisplays;
  BrowserDisplaySettings browserDisplayFor(CloudPlatform platform) =>
      browserDisplays[platform.key] ??
      BrowserDisplaySettings(view: browserView);
  final bool clipboardRecognition;
  final bool quarkGuestDirectDownload;
  final bool ucGuestDirectDownload;
  final bool quarkAuthenticatedDirectDownload;
  final bool hideGuestDownloadNotice;
  final bool hideBaiduDownloadNotice;
  final bool warnOnMobileDataDownload;
  static const profiles = {
    'github': ('GitHub', 8),
    'pikpak': ('PikPak网盘', 8),
    'feijipan': ('小飞机网盘', 8),
    'ctfile': ('城通网盘', 8),
    'baidu': ('百度网盘', 8),
    'baidu_direct': ('百度网盘 · 账号直链', 3),
    'baidu_public': ('百度网盘 · 公益解析', 64),
    'quark_route_1': ('夸克 · 直链', 512),
    'quark_route_2': ('夸克 · 快传', 64),
    'uc': ('UC网盘', 512),
    'xunlei': ('迅雷网盘', 64),
    'pan123': ('123网盘', 64),
    'guangya': ('光鸭云盘', 64),
    'aliyun': ('阿里云盘', 8),
    'yidong': ('中国移动云盘', 64),
    'tianyi': ('天翼云盘', 64),
    'ilanzou': ('蓝奏云优享版', 64),
    'weiyun': ('腾讯微云', 64),
    'pan115': ('115网盘', 16),
    'wopan': ('中国联通云盘', 64),
  };
  String? connectionProfileFor(CloudPlatform? platform, [String? profile]) =>
      profile == 'baidu_preview' || profiles.containsKey(profile)
      ? profile
      : switch (platform) {
          CloudPlatform.github => 'github',
          CloudPlatform.pikpak => 'pikpak',
          CloudPlatform.feijipan => 'feijipan',
          CloudPlatform.ctfile => 'ctfile',
          CloudPlatform.baidu => 'baidu',
          CloudPlatform.quark => 'quark_route_1',
          CloudPlatform.uc => 'uc',
          CloudPlatform.xunlei => 'xunlei',
          CloudPlatform.pan123 => 'pan123',
          CloudPlatform.guangya => 'guangya',
          CloudPlatform.aliyun => 'aliyun',
          CloudPlatform.c139 => 'yidong',
          CloudPlatform.tianyi => 'tianyi',
          CloudPlatform.ilanzou => 'ilanzou',
          CloudPlatform.weiyun => 'weiyun',
          CloudPlatform.pan115 => 'pan115',
          CloudPlatform.wopan => 'wopan',
          CloudPlatform.lanzou || null => null,
        };
  int connectionsFor(CloudPlatform? platform, [String? profile]) {
    if (profile == 'lan' && platform == null) return threads.clamp(1, 4);
    final resolved = connectionProfileFor(platform, profile);
    final key = resolved == 'baidu_preview' ? 'baidu' : resolved;
    if (key == null) return threads.clamp(1, 512);
    final override = threadOverrides[key];
    final configured =
        (override == null
                ? profiles[key]!.$2
                : override == 0
                ? threads
                : override)
            .clamp(1, 512);
    return {'aliyun', 'baidu_direct'}.contains(key)
        ? configured.clamp(1, 8)
        : configured;
  }

  Json toJson() => {
    'theme': theme,
    'themePalette': themePalette.name,
    'glassStyle': glassStyle.name,
    'background': background.toJson(),
    'hideResourceNavigation': hideResourceNavigation,
    'fontScalePercent': fontScalePercent,
    'threads': threads,
    'concurrent': concurrent,
    'retries': retries,
    'downloadRetryPolicy': 1,
    'speedLimit': speedLimit,
    'btUploadLimit': btUploadLimit,
    'downloadThreadOverrides': threadOverrides,
    'githubAcceleration': githubAcceleration.toJson(),
    'githubAccelerationPolicy': 1,
    'destination': destination,
    'browserView': browserView,
    'browserDisplays': {
      for (final entry in browserDisplays.entries)
        entry.key: entry.value.toJson(),
    },
    'clipboardRecognition': clipboardRecognition,
    'quarkGuestDirectDownload': quarkGuestDirectDownload,
    'ucGuestDirectDownload': ucGuestDirectDownload,
    'ucGuestDownloadPolicy': 1,
    'quarkAuthenticatedDirectDownload': quarkAuthenticatedDirectDownload,
    'hideGuestDownloadNotice': hideGuestDownloadNotice,
    'hideBaiduDownloadNotice': hideBaiduDownloadNotice,
    'warnOnMobileDataDownload': warnOnMobileDataDownload,
  };
  factory AppSettings.fromJson(Json j) => AppSettings(
    theme: ['System', 'Light', 'Dark'].contains(j.str('theme'))
        ? j.str('theme')
        : 'System',
    themePalette: AppPalette.parse(j['themePalette']),
    glassStyle: GlassStyle.parse(j['glassStyle']),
    background: BackgroundSettings.fromJson(j.obj('background')),
    hideResourceNavigation: j.boolean('hideResourceNavigation'),
    fontScalePercent: j
        .integer('fontScalePercent', 100)
        .clamp(minFontScalePercent, maxFontScalePercent),
    threads: j.integer('threads', 64).clamp(1, 512),
    concurrent: j.integer('concurrent', 3).clamp(1, maxConcurrentDownloads),
    // Adopt the former default once; later explicit choices persist.
    retries:
        j.integer('downloadRetryPolicy') < 1 &&
            j.integer('retries', defaultDownloadRetries) == 3
        ? defaultDownloadRetries
        : j
              .integer('retries', defaultDownloadRetries)
              .clamp(0, maxDownloadRetries),
    speedLimit: j.integer('speedLimit').clamp(0, 1 << 50),
    btUploadLimit: j
        .integer('btUploadLimit', 512 * 1024)
        .clamp(0, 10000000 * 1024),
    threadOverrides: {
      for (final e in j.obj('downloadThreadOverrides').entries)
        if (profiles.containsKey(e.key))
          e.key: (int.tryParse('${e.value}') ?? 0).clamp(0, 512),
    },
    githubAcceleration: GitHubAcceleration.fromJson(
      j.obj('githubAcceleration'),
      // Adopt the enabled default once; later explicit direct choices persist.
      migrateLegacyDefault: j.integer('githubAccelerationPolicy') < 1,
    ),
    destination: j['destination']?.toString(),
    browserView: j.str('browserView') == 'grid' ? 'grid' : 'list',
    browserDisplays: {
      for (final entry in j.obj('browserDisplays').entries)
        if (CloudPlatform.fromKey(entry.key) != null && entry.value is Map)
          entry.key: BrowserDisplaySettings.fromJson(asJson(entry.value)),
    },
    clipboardRecognition: j.boolean('clipboardRecognition', true),
    quarkGuestDirectDownload: j.boolean('quarkGuestDirectDownload', false),
    // Enable the new default once for legacy settings; subsequent explicit
    // choices keep their value, including disabling it after this upgrade.
    ucGuestDirectDownload: j.integer('ucGuestDownloadPolicy') >= 1
        ? j.boolean('ucGuestDirectDownload', true)
        : true,
    quarkAuthenticatedDirectDownload: j.boolean(
      'quarkAuthenticatedDirectDownload',
      false,
    ),
    hideGuestDownloadNotice: j.boolean('hideGuestDownloadNotice', false),
    hideBaiduDownloadNotice: j.boolean('hideBaiduDownloadNotice', false),
    warnOnMobileDataDownload: j.boolean('warnOnMobileDataDownload', true),
  );
  AppSettings update(Json fields) =>
      AppSettings.fromJson({...toJson(), ...fields});
}
