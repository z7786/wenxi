import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import 'downloads_page.dart';
import 'common.dart';
import 'transfer_overlay_control.dart';
import 'uploads_page.dart';

class TransfersPage extends StatefulWidget {
  const TransfersPage(this.services, {super.key, this.active = true});
  final AppServices services;
  final bool active;
  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  AppServices get services => widget.services;
  bool _downloadSelecting = false;

  void _selectionChanged(bool value) {
    if (mounted && value != _downloadSelecting) {
      setState(() => _downloadSelecting = value);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: services.transferTab,
    builder: (context, value, _) {
      final tab = value == 0 ? 0 : 1;
      return Material(
        color: backgroundSurface(context, fallback: Colors.transparent),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 12, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: SizedBox(
                          width: double.infinity,
                          child: CupertinoSlidingSegmentedControl<int>(
                            groupValue: tab,
                            backgroundColor: fill(context),
                            thumbColor: Theme.of(context).colorScheme.surface,
                            children: {
                              0: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: _tab(
                                  context,
                                  '下载',
                                  CupertinoIcons.arrow_down,
                                  tab == 0,
                                  themeAccent(context),
                                ),
                              ),
                              1: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: _tab(
                                  context,
                                  '上传',
                                  CupertinoIcons.arrow_up,
                                  tab == 1,
                                  themeCompanion(context),
                                ),
                              ),
                            },
                            onValueChanged: (value) {
                              if (value != null) {
                                services.transferTab.value = value;
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (services.downloadOverlay.supported) ...[
                    const SizedBox(width: 10),
                    TransferOverlayControl(
                      services.downloadOverlay,
                      compact: true,
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: tab,
                children: [
                  DownloadsPage(
                    services,
                    active: widget.active && tab == 0,
                    onSelectionChanged: _selectionChanged,
                  ),
                  UploadsPage(services, active: widget.active && tab == 1),
                ],
              ),
            ),
            if (tab == 0 && !_downloadSelecting)
              ValueListenableBuilder(
                valueListenable: services.browserReturn,
                builder: (context, target, _) => target == null
                    ? const SizedBox.shrink()
                    : SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: Material(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primaryContainer,
                                elevation: 4,
                                shadowColor: Colors.black26,
                                borderRadius: BorderRadius.circular(18),
                                child: InkWell(
                                  key: const Key('transfer-return-browser'),
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: services.requestBrowserReturn,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          CupertinoIcons.arrow_uturn_left,
                                          size: 20,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onPrimaryContainer,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                '返回解析目录',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              Text(
                                                target.directory,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Icon(
                                          CupertinoIcons.chevron_right,
                                          size: 16,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
          ],
        ),
      );
    },
  );

  Widget _tab(
    BuildContext context,
    String label,
    IconData icon,
    bool selected,
    Color accent,
  ) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(icon, size: 15, color: selected ? accent : secondary(context)),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? accent : secondary(context),
        ),
      ),
    ],
  );
}
