import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/ab_model.dart';
import '../../models/peer_model.dart';
import '../../models/peer_tab_model.dart';
import '../../models/platform_model.dart';
import 'peer_card.dart';

class WellDeskFolderTree extends StatefulWidget {
  const WellDeskFolderTree({Key? key}) : super(key: key);

  @override
  State<WellDeskFolderTree> createState() => _WellDeskFolderTreeState();
}

class _WellDeskFolderTreeState extends State<WellDeskFolderTree> {
  static const _groupPrefix = 'group:';
  final Set<String> _expanded = {};
  String _loadedScope = '';
  bool _busy = false;

  bool _isGroupTag(String tag) => tag.startsWith(_groupPrefix);
  List<String> _folderTags() => gFFI.abModel.currentAbTags
      .where((tag) => !_isGroupTag(tag)).toList();
  List<String> _groupTags() => gFFI.abModel.currentAbTags
      .where(_isGroupTag).toList();

  String get _scope =>
      '${gFFI.userModel.userName.value}:${gFFI.abModel.currentName.value}';
  String get _storageKey => 'welldesk-folder-expansion:$_scope';

  void _loadExpansion() {
    if (_loadedScope == _scope) return;
    _loadedScope = _scope;
    _expanded.clear();
    try {
      final raw = bind.mainGetLocalOption(key: _storageKey);
      if (raw.isNotEmpty) {
        _expanded.addAll((jsonDecode(raw) as List).whereType<String>());
      }
    } catch (_) {
      // A malformed local preference must not hide the server's address book.
    }
  }

  Future<String?> _input(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(translate('Cancel'))),
          TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: Text(translate('OK'))),
        ],
      ),
    );
    controller.dispose();
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _createFolder(String parent) async {
    final name = await _input('Название папки');
    if (name == null || !mounted) return;
    final path = parent.isEmpty ? name : '$parent/$name';
    if (name.contains('/') || name.contains('\\') ||
        name == '.' || name == '..' || name == kUntagged ||
        path.length > 80 || path.split('/').length > 12) {
      BotToast.showText(text: 'Имя без / и \\, полный путь до 80 символов.');
      return;
    }
    if (path.startsWith(_groupPrefix) || gFFI.abModel.currentAbTags.contains(path)) {
      BotToast.showText(text: 'Такая папка уже существует.');
      return;
    }
    await _run(() async {
      if (!await gFFI.abModel.addTags([path])) return false;
      if (!mounted) return true;
      setState(() => _expanded.add(parent));
      bind.mainSetLocalOption(
          key: _storageKey, value: jsonEncode(_expanded.toList()));
      return true;
    });
  }

  Future<void> _createGroup() async {
    final name = await _input('Название группы');
    if (name == null || !mounted) return;
    final tag = '$_groupPrefix$name';
    if (name.contains('/') || name.contains('\\') || tag.length > 80) {
      BotToast.showText(text: 'Название группы должно быть короче 75 символов, без / и \\.');
      return;
    }
    if (gFFI.abModel.currentAbTags.contains(tag)) {
      BotToast.showText(text: 'Такая группа уже существует.');
      return;
    }
    await _run(() => gFFI.abModel.addTags([tag]));
  }

  Future<bool> _confirmDelete(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(translate('Cancel'))),
            TextButton(onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(translate('Delete'))),
          ],
        ),
      ) ?? false;

  Future<void> _deleteFolder(String path) async {
    final tags = _folderTags()
        .where((tag) => tag == path || tag.startsWith('$path/')).toList();
    final count = gFFI.abModel.currentAbPeers.where((peer) =>
        peer.tags.any((tag) => tags.contains(tag))).length;
    if (!await _confirmDelete('Удалить папку «$path»?',
        'Вложенные папки будут удалены. $count компьютеров останутся в книге без этих папок.')) return;
    await _run(() async {
      for (final tag in tags) {
        if (!await gFFI.abModel.deleteTag(tag)) return false;
      }
      return true;
    });
  }

  Future<void> _deleteGroup(String tag) async {
    final name = tag.substring(_groupPrefix.length);
    if (!await _confirmDelete('Удалить группу «$name»?',
        'Компьютеры останутся в адресной книге.')) return;
    await _run(() => gFFI.abModel.deleteTag(tag));
  }

  Future<bool> _moveComputer(Peer peer, String folder) async {
    final tags = peer.tags.whereType<String>()
        .where((tag) => _isGroupTag(tag)).toList();
    if (folder.isNotEmpty) tags.add(folder);
    final result = await gFFI.abModel.changeTagForPeers([peer.id], tags);
    await gFFI.abModel.pullNonLegacyAfterChange();
    return result;
  }

  Future<bool> _toggleGroup(Peer peer, String tag) async {
    final tags = peer.tags.whereType<String>().toList();
    if (tags.contains(tag)) { tags.remove(tag); } else { tags.add(tag); }
    final result = await gFFI.abModel.changeTagForPeers([peer.id], tags);
    await gFFI.abModel.pullNonLegacyAfterChange();
    return result;
  }

  Future<void> _addComputer(String folder) async {
    final id = await _input('ID компьютера');
    if (id == null || !mounted) return;
    await _run(() async {
      if (folder.isNotEmpty && !gFFI.abModel.currentAbTags.contains(folder)) {
        if (!await gFFI.abModel.addTags([folder])) return false;
      }
      final existing = gFFI.abModel.currentAbPeers
          .firstWhereOrNull((peer) => peer.id == id);
      if (existing != null) {
        return _moveComputer(existing, folder);
      }
      final error = await gFFI.abModel.addPeersTo([
        {'id': id, 'tags': folder.isEmpty ? <String>[] : [folder]}
      ], gFFI.abModel.currentName.value);
      if (error != null && error.isNotEmpty) {
        BotToast.showText(text: error);
        return false;
      }
      return true;
    });
  }

  Future<void> _run(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!await action()) {
        BotToast.showText(text: 'Не удалось сохранить изменение на сервере.');
      }
    } catch (error) {
      BotToast.showText(text: 'Ошибка сохранения: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _select(String? path) {
    final model = gFFI.abModel;
    model.filterByIntersection.value = false;
    model.selectedTags.value = path == null
        ? <String>[]
        : path == kUntagged
            ? [kUntagged]
            : model.currentAbTags
                .where((tag) => tag == path || tag.startsWith('$path/'))
                .toList();
  }

  Widget _peer(Peer peer, List<String> folders, bool canWrite) => ListTile(
        dense: true,
        leading: const Icon(Icons.computer, size: 19),
        title: Text(peer.alias.isEmpty ? peer.id : peer.alias,
            overflow: TextOverflow.ellipsis),
        subtitle: peer.alias.isEmpty ? null : Text(peer.id),
        onTap: () => connectInPeerTab(context, peer, PeerTabIndex.ab),
        trailing: !canWrite ? null : Row(mainAxisSize: MainAxisSize.min, children: [
          PopupMenuButton<String>(
            tooltip: 'Переместить в папку',
            icon: const Icon(Icons.drive_file_move_outline),
            onSelected: (folder) => _run(() => _moveComputer(peer, folder)),
            itemBuilder: (_) => [
              const PopupMenuItem(value: '', child: Text('Без папки')),
              ...folders.map((folder) => PopupMenuItem(
                  value: folder, child: Text(folder))),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'Группы компьютера',
            icon: const Icon(Icons.group_outlined),
            onSelected: (group) => _run(() => _toggleGroup(peer, group)),
            itemBuilder: (_) => _groupTags().map((tag) => PopupMenuItem(
              value: tag,
              child: Row(children: [
                Icon(peer.tags.contains(tag) ? Icons.check_box : Icons.check_box_outline_blank, size: 18),
                const SizedBox(width: 8),
                Text(tag.substring(_groupPrefix.length)),
              ]),
            )).toList(),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) => Obx(() {
        _loadExpansion();
        final model = gFFI.abModel;
        final peers = model.currentAbPeers.toList();
        final paths = <String>{};
        for (final tag in _folderTags()) {
          final parts = tag.split('/');
          for (var i = 1; i <= parts.length; i++) {
            paths.add(parts.take(i).join('/'));
          }
        }
        final folders = paths.toList()..sort();
        final groups = _groupTags()..sort();
        final canWrite = model.current.canWrite() && !_busy;
        Widget folder(String path) {
          final children = folders.where((candidate) =>
              candidate.startsWith('$path/') &&
              !candidate.substring(path.length + 1).contains('/'));
          final members = peers.where((peer) => peer.tags.contains(path)).toList()
            ..sort((a, b) => a.getId().toLowerCase().compareTo(b.getId().toLowerCase()));
          final open = _expanded.contains(path);
          void toggle() {
            setState(() {
              if (open) { _expanded.remove(path); } else { _expanded.add(path); }
            });
            bind.mainSetLocalOption(
                key: _storageKey, value: jsonEncode(_expanded.toList()));
            _select(path);
          }
          return Column(
            key: ValueKey('$_scope:$path'),
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: IconButton(
                  tooltip: open ? 'Свернуть папку' : 'Раскрыть папку',
                  icon: Icon(open ? Icons.keyboard_arrow_down : Icons.chevron_right),
                  onPressed: toggle,
                ),
                title: Row(children: [
                  Icon(open ? Icons.folder_open : Icons.folder_outlined, size: 19),
                  const SizedBox(width: 5),
                  Expanded(child: Text('${path.split('/').last} (${members.length})',
                      overflow: TextOverflow.ellipsis)),
                ]),
                onTap: toggle,
                trailing: canWrite ? PopupMenuButton<String>(
                  tooltip: 'Действия с папкой',
                  onSelected: (action) => action == 'folder'
                      ? _createFolder(path) : action == 'delete'
                          ? _deleteFolder(path) : _addComputer(path),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'folder', child: Text('Создать подпапку')),
                    PopupMenuItem(value: 'computer', child: Text('Добавить компьютер')),
                    PopupMenuItem(value: 'delete', child: Text('Удалить папку')),
                  ],
                ) : null,
              ),
              if (open) Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ...children.map(folder),
                  ...members.map((peer) => _peer(peer, folders, canWrite)),
                  if (children.isEmpty && members.isEmpty)
                    const Padding(padding: EdgeInsets.all(8), child: Text('Папка пуста')),
                ]),
              ),
            ],
          );
        }
        final unfiled = peers.where((peer) => !peer.tags.any((tag) =>
            tag is String && !_isGroupTag(tag))).toList()
          ..sort((a, b) => a.getId().toLowerCase().compareTo(b.getId().toLowerCase()));
        return ListView(
          padding: const EdgeInsets.all(4),
          children: [
            if (_busy) const LinearProgressIndicator(),
            ListTile(dense: true, leading: const Icon(Icons.devices),
                title: const Text('Все компьютеры'), onTap: () => _select(null)),
            if (canWrite) Row(children: [
              Expanded(child: TextButton.icon(
                  onPressed: () => _createFolder(''),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Папка'))),
              IconButton(onPressed: () => _addComputer(''),
                  tooltip: 'Добавить компьютер', icon: const Icon(Icons.add_to_queue)),
            ]),
            ...folders.where((path) => !path.contains('/')).map(folder),
            ListTile(dense: true, leading: const Icon(Icons.groups_outlined),
                title: const Text('Группы устройств'),
                trailing: canWrite ? IconButton(
                    tooltip: 'Создать группу',
                    icon: const Icon(Icons.add), onPressed: _createGroup) : null),
            ...groups.map((tag) => ListTile(
              dense: true,
              leading: const Icon(Icons.label_outline),
              title: Text('${tag.substring(_groupPrefix.length)} (${peers.where((peer) => peer.tags.contains(tag)).length})',
                  overflow: TextOverflow.ellipsis),
              onTap: () => _select(tag),
              trailing: canWrite ? IconButton(
                  tooltip: 'Удалить группу',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteGroup(tag)) : null,
            )),
            ExpansionTile(
              key: ValueKey('$_scope:unfiled'),
              title: const Text('Без папки'),
              leading: const Icon(Icons.folder_open),
              children: unfiled.map((peer) => _peer(peer, folders, canWrite)).toList(),
            ),
          ],
        );
      });
}
