import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine_llm_provider.dart';

final class EngineChatPanel extends StatefulWidget {
  const EngineChatPanel({required this.provider, this.title, super.key});

  final EngineLlmProvider provider;
  final String? title;

  @override
  State<EngineChatPanel> createState() => _EngineChatPanelState();
}

final class _EngineChatPanelState extends State<EngineChatPanel> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<ModelInfo> _models = const <ModelInfo>[];
  bool _isSending = false;
  Object? _error;
  int _modelLoadVersion = 0;

  @override
  void initState() {
    super.initState();
    widget.provider.addListener(_onProviderChanged);
    unawaited(_loadModels());
    _scheduleScrollToBottom();
  }

  @override
  void didUpdateWidget(covariant EngineChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider == widget.provider) return;
    oldWidget.provider.removeListener(_onProviderChanged);
    widget.provider.addListener(_onProviderChanged);
    _models = const <ModelInfo>[];
    _error = null;
    unawaited(_loadModels());
    _scheduleScrollToBottom();
  }

  Future<void> _loadModels() async {
    final int version = ++_modelLoadVersion;
    try {
      final List<ModelInfo> loaded = await widget.provider.repository
          .listModels();
      if (!mounted || version != _modelLoadVersion) return;
      setState(() => _models = loaded);
    } on Object catch (error) {
      if (!mounted || version != _modelLoadVersion) return;
      setState(() => _error = error);
    }
  }

  void _onProviderChanged() {
    if (mounted) setState(() {});
    _scheduleScrollToBottom();
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final String content = _composer.text.trim();
    if (content.isEmpty || _isSending) return;
    _composer.clear();
    setState(() {
      _isSending = true;
      _error = null;
    });
    try {
      await for (final String _ in widget.provider.sendMessageStream(content)) {
        // Provider notifications redraw the streaming response.
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _isSending = false);
      _scheduleScrollToBottom();
    }
  }

  @override
  void dispose() {
    _modelLoadVersion++;
    widget.provider.removeListener(_onProviderChanged);
    _composer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<EngineChatMessage> messages = widget.provider.history.toList(
      growable: false,
    );
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.title?.trim().isNotEmpty ?? false)
            _ChatHeader(title: widget.title!),
          Expanded(
            child: messages.isEmpty
                ? const _EmptyChat()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                    itemCount: messages.length,
                    itemBuilder: (BuildContext context, int index) =>
                        _MessageBubble(
                          message: messages[index],
                          timestamp: widget.provider.timestampFor(
                            messages[index],
                          ),
                        ),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Text(
                '$_error',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          _Composer(
            controller: _composer,
            models: _models,
            selectedModelId: widget.provider.modelId,
            isSending: _isSending,
            onModelSelected: widget.provider.selectModel,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

final class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Container(
    height: 48,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

final class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        'Ask anything…',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.timestamp});

  final EngineChatMessage message;
  final DateTime? timestamp;

  @override
  Widget build(BuildContext context) {
    final bool isUser = message.origin == EngineChatMessageOrigin.user;
    final String text = message.text;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: isUser ? 0.82 : 0.94,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(13, 11, 8, 7),
          decoration: BoxDecoration(
            color: isUser
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SelectableText(
                text,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(height: 1.45),
              ),
              Row(
                children: <Widget>[
                  if (timestamp != null)
                    Text(
                      _formatTimestamp(timestamp!),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Copy message',
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: text.isEmpty
                        ? null
                        : () => Clipboard.setData(ClipboardData(text: text)),
                    icon: const Icon(FluentIcons.copy_16_regular, size: 14),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.models,
    required this.selectedModelId,
    required this.isSending,
    required this.onModelSelected,
    required this.onSend,
  });

  final TextEditingController controller;
  final List<ModelInfo> models;
  final String? selectedModelId;
  final bool isSending;
  final ValueChanged<String?> onModelSelected;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final String? effectiveModelId = selectedModelId?.trim().isNotEmpty ?? false
        ? selectedModelId
        : null;
    final bool hasSelectedModel = models.any(
      (ModelInfo model) => model.id == effectiveModelId,
    );
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: controller,
            enabled: !isSending,
            minLines: 3,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: 'Ask anything…',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(14, 12, 14, 4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: effectiveModelId ?? '',
                        items: <DropdownMenuItem<String>>[
                          const DropdownMenuItem<String>(
                            value: '',
                            child: Text(
                              'Default model',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (effectiveModelId != null && !hasSelectedModel)
                            DropdownMenuItem<String>(
                              value: effectiveModelId,
                              child: Text(
                                effectiveModelId,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          for (final ModelInfo model in models)
                            DropdownMenuItem<String>(
                              value: model.id,
                              child: Text(
                                model.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: isSending
                            ? null
                            : (String? value) => onModelSelected(
                                value == null || value.isEmpty ? null : value,
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox.square(
                  dimension: 36,
                  child: IconButton(
                    tooltip: 'Send',
                    onPressed: isSending ? null : onSend,
                    style: IconButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(3),
                        side: BorderSide(color: colors.outlineVariant),
                      ),
                    ),
                    icon: isSending
                        ? const SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(FluentIcons.send_20_regular, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTimestamp(DateTime value) {
  final DateTime local = value.toLocal();
  final int hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final String minute = local.minute.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  final String month = local.month.toString().padLeft(2, '0');
  final String period = local.hour < 12 ? 'am' : 'pm';
  return '$day/$month/${local.year} $hour:$minute $period';
}
