import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ssh_transport.dart';

/// Opens a channel to the remote `dsh web` over whatever SSH connection is
/// current; may wait for a reconnect.
typedef TunnelOpener = Future<TunnelChannel> Function();

/// `127.0.0.1:<ephemeral>` on the phone, piped to the remote `dsh web`.
///
/// The listener outlives individual SSH connections: when SSH drops, open
/// sockets die (so DshClient's mux notices and retries), and new sockets wait
/// in [TunnelOpener] until the link has reconnected. The local port, and so
/// the DshClient's base URL, stays the same across reconnects.
class LocalForwarder {
  LocalForwarder._(this._server, this._serverV6, this._open, {this.remoteAuthority});

  final ServerSocket _server;
  final ServerSocket? _serverV6;
  final TunnelOpener _open;
  final Set<_Pair> _pairs = {};
  final Set<Socket> _pending = {};
  bool _closed = false;

  /// Optional `127.0.0.1:<remotePort>` authority so browser OAuth callbacks
  /// arriving at `127.0.0.1:<localPort>` pass DSH's Host header fence.
  String? remoteAuthority;

  static Future<LocalForwarder> bind(
    TunnelOpener open, {
    int preferredPort = 0,
    String? remoteAuthority,
  }) async {
    ServerSocket server;
    if (preferredPort > 0) {
      try {
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, preferredPort);
      } catch (_) {
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      }
    } else {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    ServerSocket? serverV6;
    try {
      serverV6 = await ServerSocket.bind(InternetAddress.loopbackIPv6, server.port);
    } catch (_) {
      // IPv6 loopback unavailable or port taken on ::1: IPv4 loopback still works.
    }
    final forwarder = LocalForwarder._(server, serverV6, open, remoteAuthority: remoteAuthority);
    server.listen(forwarder._accept, onError: (_) {});
    serverV6?.listen(forwarder._accept, onError: (_) {});
    return forwarder;
  }

  int get port => _server.port;

  /// Number of live socket ↔ channel pairs.
  int get activeConnections => _pairs.length;

  Future<void> _accept(Socket socket) async {
    if (_closed) {
      socket.destroy();
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _pending.add(socket);
    final TunnelChannel channel;
    try {
      channel = await _open();
    } catch (_) {
      _pending.remove(socket);
      socket.destroy();
      return;
    }
    if (!_pending.remove(socket) || _closed) {
      channel.destroy();
      socket.destroy();
      return;
    }
    final pair = _Pair(
      socket,
      channel,
      remoteAuthority: remoteAuthority,
      onDone: (p) => _pairs.remove(p),
    );
    _pairs.add(pair);
    pair.start();
  }

  /// Cuts every open connection (SSH is gone; let clients notice now rather
  /// than at their next write).
  void dropConnections() {
    for (final socket in _pending) {
      socket.destroy();
    }
    _pending.clear();
    for (final pair in [..._pairs]) {
      pair.destroy();
    }
    _pairs.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    dropConnections();
    await _server.close();
    await _serverV6?.close().catchError((_) {});
  }
}

class _Pair {
  _Pair(this.socket, this.channel, {this.remoteAuthority, required this.onDone});

  final Socket socket;
  final TunnelChannel channel;
  final String? remoteAuthority;
  final void Function(_Pair) onDone;
  StreamSubscription<List<int>>? _up;
  StreamSubscription<List<int>>? _down;
  bool _firstChunk = true;
  bool _done = false;

  List<int> _rewriteHostIfNeeded(List<int> data) {
    if (!_firstChunk) return data;
    _firstChunk = false;
    final authority = remoteAuthority;
    if (authority == null || authority.isEmpty || data.length < 16) return data;
    // Fast check for HTTP request start ('G', 'P', 'H', 'D', 'O')
    final b0 = data[0];
    if (b0 != 0x47 && b0 != 0x50 && b0 != 0x48 && b0 != 0x44 && b0 != 0x4F) return data;
    final text = latin1.decode(data);
    final headerEnd = text.indexOf('\r\n\r\n');
    if (headerEnd < 0) return data;
    final head = text.substring(0, headerEnd + 2);
    final rewritten = head.replaceFirstMapped(
      RegExp(r'\r\nHost:[ \t]*(?:127\.0\.0\.1|localhost)(?::\d+)?[ \t]*\r\n', caseSensitive: false),
      (_) => '\r\nHost: $authority\r\n',
    );
    if (identical(head, rewritten) || head == rewritten) return data;
    return latin1.encode(rewritten + text.substring(headerEnd + 2));
  }

  void start() {
    final authority = remoteAuthority;
    _up = socket.listen(
      authority == null || authority.isEmpty
          ? channel.sink.add
          : (chunk) => channel.sink.add(_rewriteHostIfNeeded(chunk)),
      onDone: () {
        unawaited(channel.sink.close().catchError((_) {}));
      },
      onError: (_) => destroy(),
      cancelOnError: true,
    );
    _down = channel.stream.listen(
      socket.add,
      onDone: () async {
        try {
          await socket.flush();
        } catch (_) {}
        destroy();
      },
      onError: (_) => destroy(),
      cancelOnError: true,
    );
  }

  void destroy() {
    if (_done) return;
    _done = true;
    unawaited(_up?.cancel());
    unawaited(_down?.cancel());
    try {
      channel.destroy();
    } catch (_) {}
    socket.destroy();
    onDone(this);
  }
}
