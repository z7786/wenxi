import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'player_theme.dart';

/// Presents recovery choices; the player page owns their asynchronous lifecycle.
class PlayerErrorPanel extends StatelessWidget {
  const PlayerErrorPanel({
    super.key,
    required this.error,
    required this.retryLabel,
    required this.onRetry,
    required this.showExternalPlayer,
    required this.onExternalPlayer,
    required this.showDownload,
    required this.downloadLabel,
    required this.onDownload,
  });

  final String error, retryLabel, downloadLabel;
  final bool showExternalPlayer, showDownload;
  final VoidCallback? onRetry, onExternalPlayer, onDownload;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Material(
            color: playerPanelColor,
            borderRadius: BorderRadius.circular(14),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.exclamationmark_circle,
                    color: Colors.white60,
                    size: 32,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    children: [
                      FilledButton(onPressed: onRetry, child: Text(retryLabel)),
                      if (showExternalPlayer)
                        OutlinedButton(
                          onPressed: onExternalPlayer,
                          child: const Text('外部播放器'),
                        ),
                      if (showDownload)
                        OutlinedButton(
                          onPressed: onDownload,
                          child: Text(downloadLabel),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
