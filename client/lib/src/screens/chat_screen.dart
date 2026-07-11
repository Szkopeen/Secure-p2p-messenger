import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../crypto/codec.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../platform/file_exporter.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.appState,
    required this.contact,
    super.key,
  });

  final AppState appState;
  final Contact contact;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocus = FocusNode();
  int _lastMessageCount = 0;
  int _pendingSends = 0;
  bool _didInitialScroll = false;

  bool get _isSending => _pendingSends > 0;

  @override
  void dispose() {
    _text.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final messages = widget.appState.messagesFor(widget.contact.userId);
        final p2p = widget.appState.isP2pConnected(widget.contact.userId);
        _scheduleInitialScroll(messages.length);
        _handleMessageCountChange(messages.length);

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.contact.displayName),
                Text(
                  p2p ? 'P2P' : 'Relay',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Wyslij plik',
                onPressed: _isSending ? null : _sendFile,
                icon: const Icon(Icons.attach_file),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    return _MessageBubble(
                      appState: widget.appState,
                      contact: widget.contact,
                      message: messages[index],
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          focusNode: _inputFocus,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          decoration: const InputDecoration(
                            hintText: 'Wiadomosc',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          onSubmitted: (_) => _sendText(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Wyslij',
                        onPressed: _sendText,
                        icon: _isSending
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      _inputFocus.requestFocus();
      return;
    }

    _text.clear();
    _inputFocus.requestFocus();
    _incrementPendingSends();
    try {
      await widget.appState.sendText(widget.contact, text);
    } catch (error) {
      _showError(error);
    } finally {
      _decrementPendingSends();
      if (mounted) _inputFocus.requestFocus();
    }
  }

  Future<void> _sendFile() async {
    _incrementPendingSends();
    try {
      await widget.appState.sendFile(widget.contact);
    } catch (error) {
      _showError(error);
    } finally {
      _decrementPendingSends();
    }
  }

  void _handleMessageCountChange(int messageCount) {
    if (messageCount == _lastMessageCount) return;
    final shouldScroll = messageCount > _lastMessageCount && _isNearBottom();
    _lastMessageCount = messageCount;
    if (shouldScroll) _scrollToBottom();
  }

  void _scheduleInitialScroll(int messageCount) {
    if (_didInitialScroll) return;
    _didInitialScroll = true;
    _lastMessageCount = messageCount;
    _scrollToBottom(jump: true);
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= 96;
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (jump) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        Future<void>.delayed(const Duration(milliseconds: 80), () {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        });
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _incrementPendingSends() {
    if (!mounted) return;
    setState(() => _pendingSends += 1);
  }

  void _decrementPendingSends() {
    if (!mounted) return;
    setState(() {
      if (_pendingSends > 0) _pendingSends -= 1;
    });
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }
}

enum _MessageAction { retract, deleteLocal }

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.appState,
    required this.contact,
    required this.message,
  });

  final AppState appState;
  final Contact contact;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.direction == MessageDirection.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            message.payload.text ?? '',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    final outbound = message.direction == MessageDirection.outbound;
    final color = outbound
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Align(
      alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              message.retracted
                  ? _RetractedMessageView(outbound: outbound)
                  : _PayloadView(payload: message.payload),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _statusLine(message, context),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _MessageActionsButton(
                    canRetract: _canRetract(message),
                    onSelected: (action) => _handleAction(context, action),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLine(ChatMessage message, BuildContext context) {
    final time =
        TimeOfDay.fromDateTime(message.createdAt.toLocal()).format(context);
    final transport =
        message.transport == null ? '' : ' / ${message.transport}';
    return '${message.status.name}$transport / $time';
  }

  bool _canRetract(ChatMessage message) {
    return message.direction == MessageDirection.outbound &&
        !message.retracted &&
        message.status != MessageStatus.failed &&
        message.payload.type != PlainPayloadType.retraction;
  }

  Future<void> _handleAction(
      BuildContext context, _MessageAction action) async {
    try {
      switch (action) {
        case _MessageAction.retract:
          await appState.retractMessage(contact, message);
          break;
        case _MessageAction.deleteLocal:
          await appState.deleteMessageLocally(contact.userId, message.id);
          break;
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }
}

class _MessageActionsButton extends StatelessWidget {
  const _MessageActionsButton({
    required this.canRetract,
    required this.onSelected,
  });

  final bool canRetract;
  final ValueChanged<_MessageAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_MessageAction>(
      tooltip: 'Opcje wiadomosci',
      icon: const Icon(Icons.more_vert, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 180),
      itemBuilder: (context) => [
        if (canRetract)
          const PopupMenuItem(
            value: _MessageAction.retract,
            child: _MessageMenuItem(
              icon: Icons.undo,
              label: 'Cofnij dla wszystkich',
            ),
          ),
        const PopupMenuItem(
          value: _MessageAction.deleteLocal,
          child: _MessageMenuItem(
            icon: Icons.delete_outline,
            label: 'Usun lokalnie',
          ),
        ),
      ],
      onSelected: onSelected,
    );
  }
}

class _MessageMenuItem extends StatelessWidget {
  const _MessageMenuItem({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}

class _RetractedMessageView extends StatelessWidget {
  const _RetractedMessageView({required this.outbound});

  final bool outbound;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.block, size: 18),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            outbound
                ? 'Usunieto wyslana wiadomosc.'
                : 'Wiadomosc zostala usunieta.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
          ),
        ),
      ],
    );
  }
}

class _PayloadView extends StatelessWidget {
  const _PayloadView({required this.payload});

  final PlainPayload payload;

  @override
  Widget build(BuildContext context) {
    return switch (payload.type) {
      PlainPayloadType.text => SelectableText(payload.text ?? ''),
      PlainPayloadType.retraction => const Text('Wiadomosc zostala usunieta.'),
      PlainPayloadType.file => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isImagePayload(payload)) ...[
              _ImagePreview(payload: payload),
              const SizedBox(height: 8),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.insert_drive_file_outlined),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        payload.fileName ?? 'plik',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(_formatBytes(payload.fileSize ?? 0)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Zapisz',
                  onPressed: payload.fileBytesBase64 == null
                      ? null
                      : () async {
                          try {
                            await saveReceivedFile(
                              fileName: payload.fileName ?? 'plik',
                              bytes: unb64(payload.fileBytesBase64!),
                              mimeType: payload.mimeType,
                            );
                          } catch (error) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())),
                            );
                          }
                        },
                  icon: const Icon(Icons.download),
                ),
              ],
            ),
          ],
        ),
    };
  }

  bool _isImagePayload(PlainPayload payload) {
    if (payload.fileBytesBase64 == null) return false;
    final mimeType = payload.mimeType?.toLowerCase();
    if (mimeType != null && mimeType.startsWith('image/')) return true;
    final name = payload.fileName?.toLowerCase() ?? '';
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp') ||
        name.endsWith('.bmp');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.payload});

  final PlainPayload payload;

  @override
  Widget build(BuildContext context) {
    final bytes = unb64(payload.fileBytesBase64!);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showImageDialog(context, bytes),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 320,
            maxHeight: 240,
          ),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }

  void _showImageDialog(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: EdgeInsets.zero,
          child: SizedBox.expand(
            child: Stack(
              children: [
                Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: Image.memory(bytes),
                  ),
                ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: IconButton.filled(
                    tooltip: 'Zamknij',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
