import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http;

/// A separate server-backed view; the existing peer tabs remain available.
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
        guid = nextBooks.isEmpty ? null : nextBooks.first['guid'];
      }
      final nextBook =
          guid == null ? null : await request('/api/book?guid=$guid');
      if (!mounted) return;
      setState(() {
        books = nextBooks;
        book = nextBook == null ? null : Map<String, dynamic>.from(nextBook);
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
    final peers = (book?['data']['peers'] as List? ?? [])
        .where((p) =>
            (folder == '*' || p['folder'] == folder) &&
            '${p['id']} ${p['alias']} ${p['note']}'
                .toLowerCase()
                .contains(search.toLowerCase()))
        .toList();
    return Dialog(
        child: SizedBox(
            width: 1100,
            height: 720,
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Row(children: [
                    const Expanded(
                        child: Text('Адресная книга welldesk',
                            style: TextStyle(fontSize: 20))),
                    IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close))
                  ]),
                  Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        DropdownButton<String>(
                            value: guid,
                            hint: const Text('Войдите в аккаунт'),
                            items: books
                                .map((b) => DropdownMenuItem<String>(
                                    value: b['guid'],
                                    child: Text(b['personal'] == true
                                        ? 'Личная книга'
                                        : b['name'])))
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
                                  }),
                        TextButton(
                            onPressed: busy ? null : reload,
                            child: const Text('Обновить')),
                        if (writable) ...[
                          TextButton(
                              onPressed: busy ? null : () => editFolder(),
                              child: const Text('Создать папку')),
                          TextButton(
                              onPressed: busy ? null : () => editPeer(),
                              child: const Text('Добавить устройство')),
                          if (folder != '*' && folder.isNotEmpty) ...[
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () => editFolder(rename: true),
                                child:
                                    const Text('Переименовать / переместить')),
                            TextButton(
                                onPressed: busy ? null : deleteFolder,
                                child: const Text('Удалить папку')),
                          ],
                        ],
                      ]),
                  if (busy) const LinearProgressIndicator(),
                  if (error.isNotEmpty)
                    Text(error, style: const TextStyle(color: Colors.red)),
                  TextField(
                      decoration:
                          const InputDecoration(labelText: 'Поиск устройств'),
                      onChanged: (v) => setState(() => search = v)),
                  Expanded(
                      child: Row(children: [
                    SizedBox(
                        width: 250,
                        child: ListView(children: [
                          ListTile(
                              title: const Text('Все устройства'),
                              selected: folder == '*',
                              onTap: () => setState(() => folder = '*')),
                          ListTile(
                              title: const Text('Без папки'),
                              selected: folder == '',
                              onTap: () => setState(() => folder = '')),
                          ...branches('', paths),
                        ])),
                    const VerticalDivider(),
                    Expanded(
                        child: ListView.builder(
                            itemCount: peers.length,
                            itemBuilder: (ctx, i) {
                              final p = Map<String, dynamic>.from(peers[i]);
                              return ListTile(
                                  title: Text(
                                      '${p['alias'] == '' ? p['id'] : p['alias']} · ${p['id']}'),
                                  subtitle:
                                      Text('${p['folder']}  ${p['note']}'),
                                  trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (writable)
                                          IconButton(
                                              tooltip: 'Изменить / переместить',
                                              onPressed: busy
                                                  ? null
                                                  : () => editPeer(p),
                                              icon: const Icon(Icons.edit)),
                                        IconButton(
                                            tooltip: 'Подключиться',
                                            onPressed: () async {
                                              if (await account() != identity ||
                                                  !mounted) {
                                                await reload();
                                                return;
                                              }
                                              connect(context, p['id'],
                                                  password: p['password'] == ''
                                                      ? null
                                                      : p['password'],
                                                  isSharedPassword:
                                                      p['password'] != '');
                                            },
                                            icon: const Icon(
                                                Icons.desktop_windows)),
                                      ]));
                            }))
                  ])),
                  const Text(
                      'Синхронизация с сервером каждые 15 секунд. Изменения сохраняются сразу.'),
                ]))));
  }
}
