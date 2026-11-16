import 'models.dart';

/// Search, recommendation and update shares retain this preference on reopen.
class QuarkShareTransfer {
  static const preferenceKey = 'quarkMobileTransfer';

  static bool prefersMobile(BrowseSession session) =>
      session.platform == CloudPlatform.quark &&
      session.mode == BrowseMode.share &&
      session.meta(preferenceKey) == 'true';

  static BrowseSession preferMobile(BrowseSession session) =>
      session.platform == CloudPlatform.quark &&
          session.mode == BrowseMode.share
      ? BrowseSession(
          platform: session.platform,
          mode: session.mode,
          title: session.title,
          rootId: session.rootId,
          metadata: {...session.metadata, preferenceKey: 'true'},
          sourceLink: session.sourceLink,
        )
      : session;

  static BrowseSession inherit(BrowseSession source, BrowseSession reopened) =>
      prefersMobile(source) ? preferMobile(reopened) : reopened;
}
