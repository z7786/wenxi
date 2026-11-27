import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../data/resource_search.dart';
import 'common.dart';

Future<String?> showResourceSearchHistory(
  BuildContext context,
  ResourceSearch search,
) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  useSafeArea: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 700),
  builder: (context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .7,
    child: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: search.store,
        builder: (context, _) {
          final history = search.allHistory;
          return Column(
            key: const Key('resource-search-history-sheet'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '搜索历史',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (history.isNotEmpty)
                      TextButton(
                        key: const Key('resource-clear-history'),
                        onPressed: () async {
                          try {
                            await search.clearHistory();
                          } catch (error) {
                            if (context.mounted) {
                              message(context, errorText(error));
                            }
                          }
                        },
                        child: const Text('清空'),
                      ),
                    IconButton(
                      key: const Key('resource-search-history-close'),
                      tooltip: '关闭搜索历史',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(CupertinoIcons.xmark, size: 18),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: history.isEmpty
                    ? const Center(
                        child: SingleChildScrollView(
                          child: EmptyPanel(
                            '暂无搜索历史',
                            '搜索过的关键词会保存在这里',
                            icon: CupertinoIcons.clock,
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const Key('resource-search-history-list'),
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: history.length,
                        itemBuilder: (context, index) {
                          final term = history[index];
                          return ListTile(
                            key: ValueKey('resource-history-$term'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 4,
                            ),
                            leading: Icon(
                              CupertinoIcons.clock,
                              size: 20,
                              color: secondary(context),
                            ),
                            title: Text(term),
                            trailing: Icon(
                              CupertinoIcons.chevron_right,
                              size: 16,
                              color: secondary(context),
                            ),
                            onTap: () => Navigator.pop(context, term),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  ),
);
