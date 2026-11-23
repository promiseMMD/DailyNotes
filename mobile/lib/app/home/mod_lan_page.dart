// W4 LAN web console. Only simple Tiptap text can be edited.
// Month aggregates and complex rich text remain read-only for data safety.
import 'package:mui/mui.dart';

import 'mod_lan_service.dart';

class ModLanWebPage extends StatefulWidget {
  const ModLanWebPage({super.key});
  @override
  State<ModLanWebPage> createState() => _ModLanWebPageState();
}

class _ModLanWebPageState extends State<ModLanWebPage> {
  final service = ModLanServer.instance;
  bool busy = false;
  String? error;

  Future<void> start() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try { await service.start(); }
    catch (e) { if (mounted) setState(() => error = '启动失败：$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> stop() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try { await service.stop(); }
    catch (e) { if (mounted) setState(() => error = '停止失败：$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('局域网 Web 工作台（W4）')),
    body: AnimatedBuilder(
      animation: Listenable.merge([service.running, service.pendingPair, service.connections]),
      builder: (context, _) {
        final running = service.isRunning;
        final pending = service.pendingPair.value;
        return ListView(padding: const EdgeInsets.all(16), children: [
          const Card(child: Padding(padding: EdgeInsets.all(14), child: Text(
            '当前为 W4 安全测试版：电脑经手机配对后可新建和编辑简单文本日记。'
            '原有含图片、复杂富文本及月度聚合日记仍然只读，避免不完整编辑器破坏内容。'))),
          const SizedBox(height: 8),
          Card(child: Column(children: [
            SwitchListTile(
              title: const Text('开启局域网 Web 服务'),
              subtitle: Text(running ? '已运行：${service.address} · PC 可编辑简单文本日记' : '默认关闭；需同一可信 Wi-Fi'),
              value: running, onChanged: busy ? null : (v) => v ? start() : stop(),
            ),
            if (running) ...[
              ListTile(title: const Text('在电脑浏览器输入'),
                subtitle: SelectableText(service.address ?? ''),
                trailing: const Icon(Icons.monitor)),
              ListTile(title: const Text('已授权会话'),
                trailing: Text('${service.connections.value}')),
              TextButton.icon(onPressed: service.revokeAll,
                icon: const Icon(Icons.phonelink_erase),
                label: const Text('撤销全部电脑授权')),
            ],
          ])),
          if (pending != null) Card(child: Padding(
            padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('电脑请求连接', style: context.theme.typography.titleMedium.emphasized.onSurface),
                const SizedBox(height: 8),
                Text('IP：${pending.address}'),
                Text('浏览器：${pending.userAgent}', maxLines: 2, overflow: TextOverflow.ellipsis),
                Text('验证码：${pending.code}', style: context.theme.typography.titleLarge.onSurface),
                const Text('核对电脑浏览器的验证码；确认后此浏览器才可以查看日记。'),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: () => service.reject(pending.id), child: const Text('拒绝')),
                  FilledButton(onPressed: () => service.approve(pending.id), child: const Text('允许本次连接')),
                ]),
              ],
            ),
          )),
          if (error != null) Padding(padding: const EdgeInsets.all(10),
            child: Text(error!, style: context.theme.typography.bodyMedium.error)),
          Padding(padding: const EdgeInsets.all(12), child: Text(
            '隐私提示：HTTP 连接未加密，配对无法阻止局域网流量窃听或篡改。'
            '仅在完全可信的私人 Wi-Fi 使用，不要在公共 Wi-Fi 使用。'
            '手机锁屏服务依赖 Android 前台服务，系统强制停止或省电策略仍可能断开连接。',
            style: context.theme.typography.bodySmall.onSurfaceVariant)),
        ]);
      },
    ),
  );
}
