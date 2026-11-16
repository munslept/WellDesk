import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../common.dart' hide Dialog;
import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http;

/// Server-backed address book shown directly in the desktop address-book tab.
class WellDeskBook extends StatefulWidget {
  const WellDeskBook({Key? key}) : super(key: key);
  @override
  State<WellDeskBook> createState() => _WellDeskBookState();
}

class _WellDeskBookState extends State<WellDeskBook> {
  Timer? timer;
  List<dynamic> books = [];
  Map<String, dynamic>? book;
  String? guid;
  String folder = '*', search = '', error = '', identity = '';
  bool busy = false, editing = false;

  @override
  void initState() {
    super.initState();
    reload();
    timer = Timer.periodic(const Duration(seconds: 15), (_) => reload());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<String> account() async =>
      '${await bind.mainGetApiServer()}|${getHttpHeaders()['Authorization']}';

  Future<dynamic> request(String path,
      {String method = 'GET', dynamic body}) async {
    final before = await account();
    if (before != identity)
      throw Exception('Аккаунт изменился. Обновите книгу.');
    final uri = Uri.parse('${await bind.mainGetApiServer()}$path');
    final headers = {...getHttpHeaders(), 'Content-Type': 'application/json'};
    final response = method == 'GET'
        ? await http.get(uri, headers: headers)
        : method == 'PUT'
            ? await http.put(uri, headers: headers, body: jsonEncode(body))
            : method == 'DELETE'
                ? await http.delete(uri,
                    headers: headers, body: jsonEncode(body))
                : await http.post(uri,
                    headers: headers, body: jsonEncode(body));
    if (before != await account())
      throw Exception('Аккаунт изменился. Обновите книгу.');
    final data = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
          data is Map ? data['error'] : 'HTTP ${response.statusCode}');
    }
    return data;
  }

  Future<void> reload() async {
    if (busy || editing || !mounted) return;
    setState(() => busy = true);
    try {
      final current = await account();
      if (identity != current) {
        identity = current;
        books = [];
        book = null;
        guid = null;
        folder = '*';
      }
      final profiles = await request('/api/console/books?pageSize=500');
      final nextBooks = profiles['data'] as List;
      if (!nextBooks.any((b) => b['guid'] == guid)) {
        final personal = nextBooks.where((b) => b['personal'] == true);
        guid = nextBooks.isEmpty
            ? null
            : (personal.isNotEmpty ? personal.first : nextBooks.first)['guid'];
      }
      final nextBook =
          guid == null ? null : await request('/api/book?guid=$guid');
      if (!mounted) return;
      setState(() {
        books = nextBooks;
        book = nextBook == null ? null : Map<String, dynamic>.from(nextBook);
        if (folder != '*' && folder.isNotEmpty && !folders.contains(folder)) {
          folder = '*';
        }
        error = '';
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool get writable => books.any((b) => b['guid'] == guid && b['rule'] >= 2);
  List<String> get folders => List<String>.from(book?['data']['folders'] ?? []);

  Future<void> change(String path, String method, dynamic body) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await request(path, method: method, body: body);
      if (!mounted) return;
      setState(() => error = '');
    } catch (e) {
      if (mounted)
        setState(() => error = '$e\nОбновите книгу и повторите изменение.');
      rethrow;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> editFolder({bool rename = false}) async {
    if (book == null || busy) return;
    final revision = book!['revision'], selectedGuid = guid;
    editing = true;
    final controller = TextEditingController(
        text: rename
            ? folder
            : (folder == '*' || folder.isEmpty ? '' : '$folder/'));
    String? message;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title: Text(rename
                      ? 'Переместить / переименовать папку'
                      : 'Создать папку'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                            labelText:
                                'Полный путь, например Офис/Бухгалтерия')),
                    if (message != null)
                      Text(message!, style: const TextStyle(color: Colors.red)),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Отмена')),
                    TextButton(
                        onPressed: () async {
                          try {
                            await change(
                                '/api/welldesk/folder?guid=$selectedGuid',
                                rename ? 'PUT' : 'POST', {
                              'revision': revision,
                              'name': rename ? folder : controller.text.trim(),
                              if (rename) 'target': controller.text.trim(),
                            });
                            if (ctx.mounted) Navigator.pop(ctx);
                          } catch (e) {
                            if (ctx.mounted)
                              update(() => message = e.toString());
                          }
                        },
                        child: const Text('Сохранить'))
                  ],
                )));
    controller.dispose();
    editing = false;
    await reload();
  }

  Future<void> deleteFolder() async {
    if (book == null || busy) return;
    editing = true;
    final revision = book!['revision'];
    final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('Удалить $folder?'),
              content: const Text(
                  'Вложенные папки будут удалены. Устройства останутся в корне книги.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Отмена')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Удалить'))
              ],
            ));
    if (result == true) {
      try {
        await change('/api/welldesk/folder?guid=$guid', 'DELETE',
            {'revision': revision, 'name': folder});
        folder = '*';
      } catch (_) {/* The error remains visible in the view. */}
    }
    editing = false;
    await reload();
  }

  Future<void> editPeer([Map<String, dynamic>? peer]) async {
    if (book == null || busy) return;
    editing = true;
    final snapshot = jsonDecode(jsonEncode(book!));
    final id = TextEditingController(text: peer?['id'] ?? '');
    final alias = TextEditingController(text: peer?['alias'] ?? '');
    final note = TextEditingController(text: peer?['note'] ?? '');
    var destination = peer?['folder'] ?? (folder == '*' ? '' : folder);
    String? message;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title: Text(peer == null
                      ? 'Добавить устройство'
                      : 'Изменить устройство'),
                  content: SizedBox(
                      width: 420,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(
                            controller: id,
                            readOnly: peer != null,
                            decoration: const InputDecoration(labelText: 'ID')),
                        TextField(
                            controller: alias,
                            decoration:
                                const InputDecoration(labelText: 'Название')),
                        DropdownButtonFormField<String>(
                            value: destination,
                            isExpanded: true,
                            items: ['', ...folders]
                                .map((f) => DropdownMenuItem(
                                    value: f,
                                    child: Text(f.isEmpty ? 'Без папки' : f)))
                                .toList(),
                            onChanged: (v) =>
                                update(() => destination = v ?? '')),
                        TextField(
                            controller: note,
                            decoration:
                                const InputDecoration(labelText: 'Заметки')),
                        if (message != null)
                          Text(message!,
                              style: const TextStyle(color: Colors.red)),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Отмена')),
                    TextButton(
                        onPressed: () async {
                          try {
                            final data =
                                jsonDecode(jsonEncode(snapshot['data']));
                            final peers = data['peers'] as List;
                            final value = {
                              ...?peer,
                              'id': id.text.trim(),
                              'alias': alias.text,
                              'note': note.text,
                              'folder': destination,
                              'saved': true
                            };
                            if (peer == null) {
                              peers.add(value);
                            } else {
                              peers[peers.indexWhere(
                                  (p) => p['id'] == peer['id'])] = value;
                            }
                            await change(
                                '/api/book?guid=${snapshot['guid']}', 'PUT', {
                              'revision': snapshot['revision'],
                              'data': data
                            });
                            if (ctx.mounted) Navigator.pop(ctx);
                          } catch (e) {
                            if (ctx.mounted)
                              update(() => message = e.toString());
                          }
                        },
                        child: const Text('Сохранить'))
                  ],
                )));
    id.dispose();
    alias.dispose();
    note.dispose();
    editing = false;
    await reload();
  }

  List<Widget> branches(String parent, Set<String> paths) {
    final children = paths
        .where((f) => f.contains('/')
            ? f.substring(0, f.lastIndexOf('/')) == parent
            : parent.isEmpty)
        .toList()
      ..sort();
    return children
        .map((f) => ExpansionTile(
              key: PageStorageKey('$guid:$f'),
              initiallyExpanded: true,
              title: TextButton(
                  onPressed: () => setState(() => folder = f),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(f.split('/').last,
                          style: TextStyle(
                              fontWeight: folder == f
                                  ? FontWeight.bold
                                  : FontWeight.normal)))),
              leading: const Icon(Icons.folder_outlined),
              children: branches(f, paths)
                  .map((w) => Padding(
                      padding: const EdgeInsets.only(left: 12), child: w))
                  .toList(),
            ))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final paths = <String>{};
    for (final f in folders) {
      final parts = f.split('/');
      for (var i = 1; i <= parts.length; i++) {
        paths.add(parts.take(i).join('/'));
      }
    }
    final query = search.trim().toLowerCase();
    final peers = (book?['data']['peers'] as List? ?? [])
        .where((p) =>
            (query.isNotEmpty || folder == '*' || p['folder'] == folder) &&
            '${p['id']} ${p['alias']} ${p['note']} ${p['folder']}'
                .toLowerCase()
                .contains(query))
        .toList()
      ..sort((a, b) =>
          '${a['alias'] == '' ? a['id'] : a['alias']}'
              .toLowerCase()
              .compareTo('${b['alias'] == '' ? b['id'] : b['alias']}'
                  .toLowerCase()));

    final folderTree = ListView(children: [
      ListTile(
          dense: true,
          leading: const Icon(Icons.computer_outlined),
          title: const Text('Все компьютеры'),
          selected: folder == '*',
          onTap: () => setState(() => folder = '*')),
      ...branches('', paths),
    ]);
    final deviceList = peers.isEmpty
        ? Center(child: Text(query.isEmpty ? 'В этой папке нет компьютеров' : 'Ничего не найдено'))
        : ListView.builder(
            itemCount: peers.length,
            itemBuilder: (ctx, i) {
              final p = Map<String, dynamic>.from(peers[i]);
              final alias = '${p['alias'] ?? ''}'.trim();
              final note = '${p['note'] ?? ''}'.trim();
              return ListTile(
                  dense: true,
                  title: Text(alias.isEmpty ? '${p['id']}' : alias,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    '${p['id']}',
                    if (query.isNotEmpty && '${p['folder']}'.isNotEmpty)
                      '${p['folder']}',
                    if (note.isNotEmpty) note,
                  ].join(' · '), overflow: TextOverflow.ellipsis),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (writable)
                      IconButton(
                          tooltip: 'Изменить / переместить',
                          onPressed: busy ? null : () => editPeer(p),
                          icon: const Icon(Icons.edit_outlined, size: 19)),
                    IconButton(
                        tooltip: 'Подключиться',
                        onPressed: () async {
                          if (await account() != identity || !mounted) {
                            await reload();
                            return;
                          }
                          final sharedPassword = '${p['password'] ?? ''}';
                          connect(context, p['id'],
                              password: sharedPassword.isEmpty
                                  ? null
                                  : sharedPassword,
                              isSharedPassword: sharedPassword.isNotEmpty);
                        },
                        icon: const Icon(Icons.desktop_windows_outlined)),
                  ]));
            });

    return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
        child: Column(children: [
          Row(children: [
            Flexible(
                child: DropdownButton<String>(
                    value: guid,
                    isExpanded: true,
                    hint: const Text('Войдите в аккаунт'),
                    items: books
                        .map((b) => DropdownMenuItem<String>(
                            value: b['guid'],
                            child: Text(b['personal'] == true
                                ? 'Мои компьютеры'
                                : '${b['name']}',
                                overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: busy
                        ? null
                        : (v) {
                            setState(() {
                              guid = v;
                              book = null;
                              folder = '*';
                            });
                            reload();
                          })),
            IconButton(
                tooltip: 'Обновить',
                onPressed: busy ? null : reload,
                icon: const Icon(Icons.refresh)),
            if (writable) ...[
              IconButton(
                  tooltip: 'Создать папку',
                  onPressed: busy ? null : () => editFolder(),
                  icon: const Icon(Icons.create_new_folder_outlined)),
              IconButton(
                  tooltip: 'Добавить компьютер',
                  onPressed: busy ? null : () => editPeer(),
                  icon: const Icon(Icons.add_to_queue)),
              if (folder != '*' && folder.isNotEmpty)
                PopupMenuButton<String>(
                    tooltip: 'Действия с папкой',
                    onSelected: (action) => action == 'rename'
                        ? editFolder(rename: true)
                        : deleteFolder(),
                    itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('Переименовать папку')),
                          PopupMenuItem(value: 'delete', child: Text('Удалить папку')),
                        ]),
            ],
          ]),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (error.isNotEmpty)
            Text(error, style: const TextStyle(color: Colors.red)),
          TextField(
              decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Поиск по ID, имени или заметке',
                  suffixText: '${peers.length}'),
              onChanged: (v) => setState(() => search = v)),
          const SizedBox(height: 8),
          Expanded(child: LayoutBuilder(builder: (context, size) {
            if (size.maxWidth < 650) {
              return Column(children: [
                SizedBox(height: 120, child: folderTree),
                const Divider(height: 1),
                Expanded(child: deviceList),
              ]);
            }
            return Row(children: [
              SizedBox(width: 210, child: folderTree),
              const VerticalDivider(width: 12),
              Expanded(child: deviceList),
            ]);
          })),
        ]));
  }
}
