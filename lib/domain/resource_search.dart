import '../core/json.dart';
import 'links.dart';
import 'models.dart';
import 'ed2k.dart';

class ResourceSearchLink {
  const ResourceSearchLink({
    required this.url,
    required this.cloudName,
    this.password = '',
    this.openTicket = '',
  });
  final String url, cloudName, password, openTicket;
}

/// A share discovered on the public web, before resolving its files.
class ResourceSearchHit {
  ResourceSearchHit._({
    required this.title,
    required this.url,
    required this.cloudName,
    required this.link,
    this.password = '',
    this.description = '',
    this.sourceName = '',
    this.date = '',
    this.openTicket = '',
    this.poolSupported = false,
    this.recommendationId = 0,
    this.category = '',
    this.coverUrl = '',
    this.links = const [],
  });

  final String title, url, cloudName, password, description, sourceName, date;
  final String openTicket;
  final bool poolSupported;
  final int recommendationId;
  final String category;
  final String coverUrl;
  final List<ResourceSearchLink> links;
  final ParsedLink? link;
  CloudPlatform? get platform => link?.platform;
  bool get canParse =>
      link?.kind == LinkKind.magnet ||
      link?.kind == LinkKind.torrent ||
      link?.kind == LinkKind.ed2k ||
      link?.kind == LinkKind.cloudShare &&
          platform?.supportsShareParsing == true;
  String get identity => link?.kind == LinkKind.magnet
      ? 'magnet:${Uri.parse(url).queryParameters['xt']?.toLowerCase() ?? url}'
      : link?.kind == LinkKind.ed2k
      ? 'ed2k:${Ed2kLink.parse(url).hash}:${Ed2kLink.parse(url).size}'
      : link?.shareId != null
      ? '${platform?.key ?? link?.unsupportedPlatform?.name ?? Uri.parse(url).host}:${link!.shareId}'
      : url;
  String get shareText => '$url${password.isEmpty ? '' : '\n提取码：$password'}';
  String get copyText => '$title\n$shareText';

  factory ResourceSearchHit.fromRaw(Object? raw) {
    final Json value;
    if (raw is List && raw.length >= 4) {
      // Compatibility with older deployments; new API streams use objects.
      value = {
        'source': raw[0],
        'title': raw[1],
        'url': raw[2],
        'cloud_name': raw[3],
        if (raw.length > 4) 'datetime': raw[4],
        if (raw.length > 5) 'description': raw[5],
        if (raw.length > 9) 'source_name': raw[9],
      };
    } else {
      value = asJson(raw);
    }
    final rawLinkValues = value['links'];
    final rawLinks = rawLinkValues is List
        ? rawLinkValues.whereType<Map>().take(8).toList()
        : const <Map>[];
    final firstLink = rawLinks.isEmpty ? null : rawLinks.first;
    final rawUrl =
        (firstLink?['url']?.toString() ??
                value.str('share_link', value.str('url')))
            .trim();
    require(rawUrl.isNotEmpty && rawUrl.length <= 8192, '资源链接无效');
    final magnet = rawUrl.toLowerCase().startsWith('magnet:?');
    final url = magnet
        ? rawUrl
        : rawUrl.toLowerCase().startsWith('ed2k://')
        ? Ed2kLink.parse(rawUrl).url
        : LinkParser.normalize(rawUrl);
    final parsed = LinkParser.parse(url).firstOrNull;
    require(!magnet || parsed?.kind == LinkKind.magnet, '磁力链接无效');
    final rawPassword = value.str('password').trim();
    final password = _searchPassword(
      parsed,
      rawPassword,
    ).ifEmpty(parsed?.passcode ?? '');
    final link = password.isNotEmpty ? parsed?.withPasscode(password) : parsed;
    String bounded(String key, int max, [String fallback = '']) {
      final text = value.str(key, fallback).trim();
      return text.length > max ? text.substring(0, max) : text;
    }

    final parsedLinks = <ResourceSearchLink>[];
    for (final raw in rawLinks) {
      final candidate = raw['url']?.toString().trim() ?? '';
      if (candidate.isEmpty) continue;
      final normalized = candidate.toLowerCase().startsWith('magnet:?')
          ? candidate
          : candidate.toLowerCase().startsWith('ed2k://')
          ? Ed2kLink.parse(candidate).url
          : LinkParser.normalize(candidate);
      final parsedCandidate = LinkParser.parse(normalized).firstOrNull;
      if (parsedCandidate == null) continue;
      final candidatePassword = raw['password']?.toString().trim() ?? '';
      final safePassword = _searchPassword(
        parsedCandidate,
        candidatePassword,
      ).ifEmpty(parsedCandidate.passcode ?? '');
      parsedLinks.add(
        ResourceSearchLink(
          url: normalized,
          cloudName: (raw['cloud_name']?.toString().trim().isNotEmpty == true)
              ? raw['cloud_name'].toString().trim()
              : parsedCandidate.kind == LinkKind.ed2k
              ? 'ED2K'
              : parsedCandidate.cloudLabel ?? '其他网盘',
          password: safePassword,
          openTicket: raw['open_ticket']?.toString().trim() ?? '',
        ),
      );
    }
    if (parsedLinks.isEmpty) {
      parsedLinks.add(
        ResourceSearchLink(
          url: url,
          cloudName: parsed?.kind == LinkKind.ed2k
              ? 'ED2K'
              : parsed?.cloudLabel ?? '其他网盘',
          password: password,
          openTicket: value.str('open_ticket'),
        ),
      );
    }
    return ResourceSearchHit._(
      title: bounded('title', 512, value.str('name')).ifEmpty('未命名资源'),
      url: url,
      cloudName: parsed?.kind == LinkKind.magnet
          ? '磁力链接'
          : parsed?.kind == LinkKind.torrent
          ? 'BT 种子'
          : parsed?.kind == LinkKind.ed2k
          ? 'ED2K'
          : parsed?.cloudLabel ?? bounded('cloud_name', 64, '其他网盘'),
      link: link,
      password: password,
      description: bounded('description', 2000),
      recommendationId: value.integer('recommendation_id'),
      category: bounded('category', 32),
      coverUrl: _imageUrl(bounded('cover_url', 2048)),
      sourceName: bounded(
        'source_name',
        80,
        value.str('source_display', '网络聚合'),
      ),
      date: bounded('datetime', 40),
      openTicket: bounded('open_ticket', 24000),
      poolSupported: value.boolean(
        'pool_supported',
        {
              CloudPlatform.baidu,
              CloudPlatform.quark,
              CloudPlatform.uc,
              CloudPlatform.xunlei,
              CloudPlatform.guangya,
              CloudPlatform.aliyun,
              CloudPlatform.c139,
            }.contains(parsed?.platform) ||
            Uri.tryParse(url)?.host == 'pan.wkbrowser.com',
      ),
      links: List.unmodifiable(parsedLinks),
    );
  }

  ResourceSearchHit withLink(ResourceSearchLink selected) =>
      ResourceSearchHit._(
        title: title,
        url: selected.url,
        cloudName: selected.cloudName,
        link: selected.password.isEmpty
            ? LinkParser.parse(selected.url).firstOrNull
            : LinkParser.parse(
                selected.url,
              ).firstOrNull?.withPasscode(selected.password),
        password: selected.password,
        openTicket: selected.openTicket.ifEmpty(openTicket),
        description: description,
        sourceName: sourceName,
        date: date,
        poolSupported: poolSupported,
        recommendationId: recommendationId,
        category: category,
        coverUrl: coverUrl,
        links: links,
      );

  ResourceSearchHit merge(ResourceSearchHit other) {
    final best = other._completeness > _completeness ? other : this;
    final pass = password.ifEmpty(other.password);
    return ResourceSearchHit._(
      title: best.title,
      url: best.url,
      cloudName: best.cloudName,
      link: pass.isEmpty ? best.link : best.link?.withPasscode(pass),
      password: pass,
      description: best.description.ifEmpty(
        description.ifEmpty(other.description),
      ),
      sourceName: best.sourceName,
      date: best.date.ifEmpty(date.ifEmpty(other.date)),
      openTicket: other.openTicket.ifEmpty(openTicket),
      poolSupported: other.poolSupported || poolSupported,
      recommendationId: other.recommendationId > 0
          ? other.recommendationId
          : recommendationId,
      category: other.category.ifEmpty(category),
      coverUrl: other.coverUrl.ifEmpty(coverUrl),
      links: other.links.length > 1 ? other.links : links,
    );
  }

  int get _completeness =>
      (password.isEmpty ? 0 : 100) +
      (description.isEmpty ? 0 : 20) +
      title.length.clamp(0, 80);
}

String _searchPassword(ParsedLink? parsed, String value) {
  final password = value.trim();
  if (!RegExp(r'^[A-Za-z0-9]{1,12}$').hasMatch(password)) return '';
  if (parsed?.platform != CloudPlatform.tianyi) return password;
  if (parsed?.passcode?.isNotEmpty == true) return parsed!.passcode!;
  final shareCode = parsed?.shareId ?? '';
  // `code` identifies a Tianyi share. It is not the access code.
  // Older search responses accidentally used its first six characters.
  if (shareCode == password ||
      (password.length == 6 &&
          shareCode.length > 6 &&
          shareCode.startsWith(password))) {
    return '';
  }
  return password;
}

String _imageUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? value
      : '';
}

class ResourceCategory {
  const ResourceCategory({
    required this.id,
    required this.name,
    required this.resources,
  });
  final int id;
  final String name;
  final List<ResourceSearchHit> resources;
}

class ResourceCatalog {
  const ResourceCatalog({this.popular = const [], this.categories = const []});
  final List<ResourceSearchHit> popular;
  final List<ResourceCategory> categories;

  factory ResourceCatalog.fromJson(Json value) {
    final raw = value['categories'];
    require(raw is List && raw.length <= 32, '资源分类响应格式无效');
    return ResourceCatalog(
      popular: ResourceSearchBatch.fromJson({
        'results': value['popular'],
      }).items,
      categories: [
        for (final entry in raw as List)
          if (asJson(entry).integer('id') > 0)
            ResourceCategory(
              id: asJson(entry).integer('id'),
              name: asJson(entry)
                  .str('name')
                  .substring(0, asJson(entry).str('name').length.clamp(0, 32)),
              resources: ResourceSearchBatch.fromJson({
                'results': asJson(entry)['resources'],
              }).items,
            ),
      ],
    );
  }
}

/// Only public file metadata is sent; access tokens and account cookies stay local.
class ResourceSearchFileSelection {
  const ResourceSearchFileSelection({
    required this.fileId,
    required this.parentId,
    required this.name,
    required this.size,
  });
  final String fileId, parentId, name;
  final int size;
  Json toJson() => {
    'file_id': fileId,
    'parent_id': parentId,
    'name': name,
    'size': size,
  };
}

/// The returned share is separate from the search hit, so results stay intact.
class ResourceSearchOpenResult {
  const ResourceSearchOpenResult({
    required this.hit,
    required this.mode,
    this.reason = '',
    this.message = '',
    this.transferScope = '',
    this.sourceFileId = '',
  });
  final ResourceSearchHit hit;
  final String mode, reason, message, transferScope, sourceFileId;
  bool get transferred => mode == 'temp_share' || mode == 'pool_share';

  factory ResourceSearchOpenResult.fromJson(
    ResourceSearchHit source,
    Json data,
  ) {
    final mode = data.str('mode');
    require(
      {'original', 'temp_share', 'pool_share'}.contains(mode),
      '转存服务响应格式无效',
    );
    if (mode == 'original') {
      return ResourceSearchOpenResult(
        hit: source,
        mode: mode,
        reason: data.str('reason'),
        message: data.str('message').ifEmpty('暂时未能生成新的分享链接'),
      );
    }
    final url = data.str('url').trim();
    require(
      url.startsWith('https://') || url.startsWith('http://'),
      '转存服务没有返回有效链接',
    );
    return ResourceSearchOpenResult(
      hit: ResourceSearchHit.fromRaw({
        'title': source.title,
        'url': url,
        'cloud_name': data.str('netdisk_name', source.cloudName),
        // A new share must never inherit the original share's password.
        if (data.str('password').isNotEmpty) 'password': data.str('password'),
        'description': source.description,
        'source_name': source.sourceName,
        'datetime': source.date,
        'pool_supported': false,
      }),
      mode: mode,
      transferScope: data.str('transfer_scope'),
      sourceFileId: data.str('source_file_id'),
    );
  }
}

class ResourceSearchBatch {
  const ResourceSearchBatch(this.items, {this.complete = false});
  final List<ResourceSearchHit> items;
  final bool complete;

  factory ResourceSearchBatch.fromJson(Json value) {
    if (value['type'] == 'error' || value['success'] == false) {
      throw AppException(value.str('message').ifEmpty('搜索暂时不可用，请稍后重试'));
    }
    final raw = value['results'];
    require(raw is List, '搜索结果格式无效');
    final items = <ResourceSearchHit>[];
    for (final item in raw as List) {
      try {
        items.add(ResourceSearchHit.fromRaw(item));
      } on AppException {
        // One malformed upstream link must not discard useful results.
      } on FormatException {
        continue;
      }
    }
    return ResourceSearchBatch(
      items,
      complete: value['type'] == 'complete' || value['success'] == true,
    );
  }
}
