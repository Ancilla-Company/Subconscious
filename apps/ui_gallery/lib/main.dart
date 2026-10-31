// A review page for the shared UI kit: every exported component, in the form
// theme the app uses, with its name and variant written above it. Nothing here
// is wired to anything; the samples only show how the kit looks.
//
// A separate Windows-only app on purpose: it has its own runner (ui_gallery.exe),
// so it can stay open while the main app is built and debugged. The other
// platforms use the same kit, so this one window is enough to review it.
//
// Run it with the "UI Kit Gallery" launch configuration, or from apps/ui_gallery:
//   flutter run -d windows

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

void main() => runApp(const UiGalleryApp());

void _noop() {}

void _ignore(String _) {}

enum _Variant {
  light('Light'),
  dark('Dark'),
  neutralLight('Neutral light'),
  neutralDark('Neutral dark');

  const _Variant(this.label);
  final String label;

  ThemeData get theme => switch (this) {
    _Variant.light => AppTheme.light(),
    _Variant.dark => AppTheme.dark(),
    _Variant.neutralLight => AppTheme.light(monochrome: true),
    _Variant.neutralDark => AppTheme.dark(monochrome: true),
  };
}

final class UiGalleryApp extends StatefulWidget {
  const UiGalleryApp({super.key});

  @override
  State<UiGalleryApp> createState() => _UiGalleryAppState();
}

final class _UiGalleryAppState extends State<UiGalleryApp> {
  _Variant _variant = _Variant.light;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Shared UI kit gallery',
    debugShowCheckedModeBanner: false,
    theme: _variant.theme,
    // The app builds its forms, dialogs and sheets under the form theme.
    builder: (BuildContext context, Widget? child) =>
        AppFormTheme(child: child ?? const SizedBox.shrink()),
    home: _GalleryPage(
      variant: _variant,
      onVariant: (_Variant value) => setState(() => _variant = value),
    ),
  );
}

final class _GalleryPage extends StatefulWidget {
  const _GalleryPage({required this.variant, required this.onVariant});

  final _Variant variant;
  final ValueChanged<_Variant> onVariant;

  @override
  State<_GalleryPage> createState() => _GalleryPageState();
}

final class _GalleryPageState extends State<_GalleryPage> {
  final TextEditingController _search = TextEditingController(text: 'agents');
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Shared UI kit gallery'),
      actions: <Widget>[
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: AppSegmentedControl<_Variant>(
            expand: false,
            selected: widget.variant,
            onChanged: widget.onVariant,
            segments: <AppSegment<_Variant>>[
              for (final _Variant value in _Variant.values)
                AppSegment<_Variant>(value: value, label: value.label),
            ],
          ),
        ),
      ],
    ),
    body: Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _formFields(),
            _dropdowns(),
            _switchesAndButtons(),
            _iconButtons(),
            _navigation(),
            _rows(),
            _menusAndControls(),
            _surfaces(),
            _settingsPanels(),
            _chat(),
            _overlays(context),
            _tokens(context),
          ],
        ),
      ),
    ),
  );

  // --- Forms ---------------------------------------------------------------

  Widget _formFields() => _Section(
    title: 'Form fields',
    children: <Widget>[
      const _Sample('AppFieldLabel', AppFieldLabel('Field label')),
      const _Sample(
        'AppTextField: label and hint',
        AppTextField(label: 'Name', hintText: 'Workspace name'),
      ),
      const _Sample(
        'AppTextField: with a value',
        AppTextField(label: 'Name', initialValue: 'Subconscious'),
      ),
      const _Sample(
        'AppTextField: helper text',
        AppTextField(
          label: 'Port',
          initialValue: '51515',
          helperText: 'The engine listens on this port.',
        ),
      ),
      const _Sample(
        'AppTextField: error',
        AppTextField(
          label: 'Name',
          initialValue: '',
          errorText: 'A name is required.',
        ),
      ),
      const _Sample(
        'AppTextField: disabled',
        AppTextField(label: 'Name', initialValue: 'Locked', enabled: false),
      ),
      const _Sample(
        'AppTextField: read-only',
        AppTextField(
          label: 'UUID',
          initialValue: '3f9c1c0e-7a52-4a7e-9c2b-5d1f0a6e8b11',
          readOnly: true,
        ),
      ),
      const _Sample(
        'AppTextField: obscureText (password)',
        AppTextField(label: 'Password', initialValue: 'secret', obscureText: true),
      ),
      const _Sample(
        'AppTextField: multi-line (minLines 3, maxLines 6)',
        AppTextField(
          label: 'Instructions',
          hintText: 'How this agent should behave',
          minLines: 3,
          maxLines: 6,
        ),
      ),
      const _Sample(
        'AppTextField: bare, no label',
        AppTextField(hintText: 'No label above'),
      ),
      _Sample(
        'AppTextField: fixed-height value row (height 32, prefix icon)',
        const AppTextField(
          initialValue: r'C:\code\Subconscious',
          readOnly: true,
          height: 32,
          prefixIcon: Icon(FluentIcons.folder_20_regular, size: 16),
        ),
      ),
      const _Sample(
        'AppSearchField: empty',
        AppSearchField(hintText: 'Search agents'),
      ),
      _Sample(
        'AppSearchField: with text',
        AppSearchField(controller: _search, hintText: 'Search agents'),
      ),
      _Sample(
        'AppFieldRow: field with outlined action buttons',
        AppFieldRow(
          field: const AppTextField(
            initialValue: 'Value to copy',
            readOnly: true,
          ),
          actions: <Widget>[
            AppIconButton(
              outlined: true,
              tooltip: 'Copy',
              icon: FluentIcons.copy_20_regular,
              onPressed: _noop,
            ),
            AppIconButton(
              outlined: true,
              tooltip: 'Remove',
              icon: FluentIcons.delete_20_regular,
              destructive: true,
              onPressed: _noop,
            ),
          ],
        ),
      ),
      _Sample(
        'AppToolbar with a find box: AppTextField (height 32) beside 32 dp buttons',
        AppToolbar(
          children: <Widget>[
            const SizedBox(
              width: 150,
              child: AppTextField(hintText: 'Find', height: 32, initialValue: 'model'),
            ),
            AppIconButton(
              tooltip: 'Previous',
              icon: FluentIcons.arrow_up_20_regular,
              onPressed: _noop,
            ),
            AppIconButton(
              tooltip: 'Next',
              icon: FluentIcons.arrow_down_20_regular,
              onPressed: _noop,
            ),
          ],
        ),
      ),
    ],
  );

  // --- Dropdowns and pickers -------------------------------------------------

  Widget _dropdowns() => _Section(
    title: 'Dropdowns and pickers',
    children: <Widget>[
      _Sample(
        'AppPickerButton: workspace switcher (icon, label, chevron; opens a menu)',
        SizedBox(
          width: 200,
          child: AppPickerButton<String>(
            icon: FluentIcons.folder_20_regular,
            label: 'All workspaces',
            items: const <AppMenuItem<String>>[
              AppMenuItem<String>(
                value: '',
                label: 'All workspaces',
                icon: FluentIcons.apps_20_regular,
                selected: true,
              ),
              AppMenuItem<String>(
                value: 'a',
                label: 'Alpha',
                icon: FluentIcons.folder_20_regular,
              ),
            ],
            onSelected: (_) {},
          ),
        ),
      ),
      const _Sample(
        'AppPickerButton: disabled',
        SizedBox(
          width: 200,
          child: AppPickerButton<String>(
            icon: FluentIcons.folder_20_regular,
            label: 'Alpha',
            enabled: false,
            items: <AppMenuItem<String>>[],
            onSelected: _ignore,
          ),
        ),
      ),
      _Sample(
        'AppDropdown (string options, label above)',
        AppDropdown(
          label: 'Theme',
          value: 'Light',
          options: const <String>['Light', 'Dark', 'Device'],
          onChanged: (_) {},
        ),
      ),
      _Sample(
        'AppDropdownField<T>: with a value',
        AppDropdownField<String>(
          value: 'gpt',
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'gpt', child: Text('GPT model')),
            DropdownMenuItem<String>(value: 'claude', child: Text('Claude')),
          ],
          onChanged: (_) {},
        ),
      ),
      _Sample(
        'AppDropdownField<T>: hint, nothing selected',
        AppDropdownField<String>(
          hint: const Text('Select a model'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'gpt', child: Text('GPT model')),
          ],
          onChanged: (_) {},
        ),
      ),
      const _Sample(
        'AppDropdownField<T>: disabled',
        AppDropdownField<String>(
          value: 'gpt',
          items: <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'gpt', child: Text('GPT model')),
          ],
          onChanged: null,
        ),
      ),
      _Sample(
        'AppCompactDropdown: toolbar dropdown (composer model picker, headers)',
        SizedBox(
          width: 160,
          child: AppCompactDropdown<String>(
            value: '',
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: '', child: Text('All workspaces')),
              DropdownMenuItem<String>(value: 'a', child: Text('Alpha')),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    ],
  );

  // --- Switches, buttons, messages ------------------------------------------

  Widget _switchesAndButtons() => _Section(
    title: 'Switches, buttons and messages',
    children: <Widget>[
      _Sample(
        'AppSwitchTile: on',
        AppSwitchTile(title: 'Enabled', value: true, onChanged: (_) {}),
      ),
      _Sample(
        'AppSwitchTile: off, with a subtitle',
        AppSwitchTile(
          title: 'Customize tools',
          subtitle: 'Off: use the workspace policy.',
          value: false,
          onChanged: (_) {},
        ),
      ),
      const _Sample(
        'AppSwitchTile: disabled',
        AppSwitchTile(title: 'Locked', value: true, onChanged: null),
      ),
      _Sample(
        'AppSwitch: normal (on, off, disabled), then compact',
        Row(
          children: <Widget>[
            AppSwitch(value: true, onChanged: (_) {}, semanticLabel: 'On'),
            AppSwitch(value: false, onChanged: (_) {}, semanticLabel: 'Off'),
            const AppSwitch(
              value: true,
              onChanged: null,
              semanticLabel: 'Disabled',
            ),
            AppSwitch(
              value: true,
              compact: true,
              onChanged: (_) {},
              semanticLabel: 'Compact',
            ),
          ],
        ),
      ),
      _Sample(
        'AppButtonRow: FilledButton, OutlinedButton, TextButton',
        AppButtonRow(
          children: <Widget>[
            FilledButton(onPressed: _noop, child: const Text('Save')),
            OutlinedButton(onPressed: _noop, child: const Text('Cancel')),
            TextButton(onPressed: _noop, child: const Text('Skip')),
          ],
        ),
      ),
      const _Sample(
        'AppButtonRow: disabled',
        AppButtonRow(
          children: <Widget>[
            FilledButton(onPressed: null, child: Text('Save')),
            OutlinedButton(onPressed: null, child: Text('Cancel')),
            TextButton(onPressed: null, child: Text('Skip')),
          ],
        ),
      ),
      _Sample(
        'AppButtonRow: buttons with icons',
        AppButtonRow(
          children: <Widget>[
            FilledButton.icon(
              onPressed: _noop,
              icon: const Icon(FluentIcons.add_20_regular),
              label: const Text('New'),
            ),
            OutlinedButton.icon(
              onPressed: _noop,
              icon: const Icon(FluentIcons.arrow_download_20_regular),
              label: const Text('Export'),
            ),
          ],
        ),
      ),
      const _Sample('AppSectionHeading', AppSectionHeading(title: 'Section heading')),
      const _Sample(
        'AppFormError',
        AppFormError(error: 'Operation failed: the engine is not connected.'),
      ),
      const _Sample('AppEmptyMessage', AppEmptyMessage('Nothing here yet.')),
      _Sample(
        'AppEmptyMessage: with an action',
        AppEmptyMessage(
          "Couldn't load agents.",
          action: OutlinedButton(onPressed: _noop, child: const Text('Retry')),
        ),
      ),
    ],
  );

  Widget _iconButtons() => _Section(
    title: 'Icon buttons',
    children: <Widget>[
      _Sample(
        'AppIconButton: small (24)',
        AppIconButton(
          tooltip: 'Close',
          icon: FluentIcons.dismiss_20_regular,
          size: AppIconButtonSize.small,
          onPressed: _noop,
        ),
        width: 170,
      ),
      _Sample(
        'AppIconButton: compact (32, default)',
        AppIconButton(
          tooltip: 'Add',
          icon: FluentIcons.add_20_regular,
          onPressed: _noop,
        ),
        width: 170,
      ),
      _Sample(
        'AppIconButton: regular (40)',
        AppIconButton(
          tooltip: 'Add',
          icon: FluentIcons.add_20_regular,
          size: AppIconButtonSize.regular,
          onPressed: _noop,
        ),
        width: 170,
      ),
      _Sample(
        'AppIconButton: selected',
        AppIconButton(
          tooltip: 'Threads',
          icon: FluentIcons.chat_multiple_20_regular,
          selected: true,
          onPressed: _noop,
        ),
        width: 170,
      ),
      _Sample(
        'AppIconButton: outlined',
        AppIconButton(
          tooltip: 'Save',
          icon: FluentIcons.save_20_regular,
          outlined: true,
          onPressed: _noop,
        ),
        width: 170,
      ),
      _Sample(
        'AppIconButton: destructive',
        AppIconButton(
          tooltip: 'Delete',
          icon: FluentIcons.delete_20_regular,
          destructive: true,
          onPressed: _noop,
        ),
        width: 170,
      ),
      _Sample(
        'AppIconButton: outlined and busy',
        AppIconButton(
          tooltip: 'Saving',
          icon: FluentIcons.save_20_regular,
          outlined: true,
          busy: true,
          onPressed: _noop,
        ),
        width: 170,
      ),
      const _Sample(
        'AppIconButton: disabled',
        AppIconButton(
          tooltip: 'Disabled',
          icon: FluentIcons.save_20_regular,
          onPressed: null,
        ),
        width: 170,
      ),
    ],
  );

  // --- Navigation ------------------------------------------------------------

  Widget _navigation() => _Section(
    title: 'Navigation',
    children: <Widget>[
      _Sample(
        'FlyoutNavButton',
        FlyoutNavButton(
          icon: FluentIcons.apps_24_regular,
          selectedIcon: FluentIcons.apps_24_filled,
          label: 'Workspaces',
          onPressed: _noop,
        ),
        width: 260,
      ),
      _Sample(
        'FlyoutNavButton: selected',
        FlyoutNavButton(
          icon: FluentIcons.bot_24_regular,
          selectedIcon: FluentIcons.bot_24_filled,
          label: 'Agents',
          selected: true,
          onPressed: _noop,
        ),
        width: 260,
      ),
      _Sample(
        'AppFlyoutHeader (logo + title)',
        AppFlyoutHeader(
          title: 'Subconscious',
          logo: SvgPicture.asset(
            'assets/branding/logo.svg',
            package: 'shared_ui_kit',
            colorFilter: ColorFilter.mode(
              Theme.of(context).colorScheme.onSurface,
              BlendMode.srcIn,
            ),
            semanticsLabel: 'Subconscious logo',
          ),
        ),
        width: 260,
      ),
      const _Sample(
        'AppPanelDivider (draggable handle, no callback here)',
        SizedBox(height: 60, child: Center(child: AppPanelDivider())),
        width: 260,
      ),
      const _Sample(
        'AppVerticalRule',
        SizedBox(height: 60, child: Center(child: AppVerticalRule())),
        width: 260,
      ),
      const _Sample(
        'AppSidebarDivider',
        SizedBox(width: 40, child: AppSidebarDivider()),
        width: 260,
      ),
      _Sample(
        'AppSegmentedControl',
        AppSegmentedControl<String>(
          selected: 'b',
          onChanged: (_) {},
          segments: const <AppSegment<String>>[
            AppSegment<String>(value: 'a', label: 'Light'),
            AppSegment<String>(value: 'b', label: 'Dark'),
            AppSegment<String>(value: 'c', label: 'Device'),
          ],
        ),
        width: 320,
      ),
      _Sample(
        'AppSegmentedControl: with icons, not expanded',
        AppSegmentedControl<String>(
          expand: false,
          selected: 'a',
          onChanged: (_) {},
          segments: const <AppSegment<String>>[
            AppSegment<String>(
              value: 'a',
              label: 'List',
              icon: FluentIcons.text_bullet_list_20_regular,
            ),
            AppSegment<String>(
              value: 'b',
              label: 'Grid',
              icon: FluentIcons.grid_20_regular,
            ),
          ],
        ),
        width: 320,
      ),
      _Sample(
        'AppToolbar, AppToolbarDivider, AppTextToggle',
        AppToolbar(
          children: <Widget>[
            AppIconButton(
              tooltip: 'Undo',
              icon: FluentIcons.arrow_undo_20_regular,
              onPressed: _noop,
            ),
            AppIconButton(
              tooltip: 'Redo',
              icon: FluentIcons.arrow_redo_20_regular,
              onPressed: _noop,
            ),
            const AppToolbarDivider(),
            AppTextToggle(
              label: 'Aa',
              tooltip: 'Match case',
              selected: true,
              onPressed: _noop,
            ),
            AppTextToggle(
              label: 'ab',
              tooltip: 'Whole word',
              selected: false,
              underline: true,
              onPressed: _noop,
            ),
          ],
        ),
        width: 320,
      ),
    ],
  );

  // --- List rows ---------------------------------------------------------------

  Widget _rows() => _Section(
    title: 'List rows',
    children: <Widget>[
      _Sample(
        'AppListRow',
        AppListRow(title: 'Untitled thread', onTap: _noop),
        width: 300,
      ),
      _Sample(
        'AppListRow: dense (32)',
        AppListRow(title: 'Untitled thread', dense: true, onTap: _noop),
        width: 300,
      ),
      _Sample(
        'AppListRow: selected',
        AppListRow(title: 'Project plan', selected: true, onTap: _noop),
        width: 300,
      ),
      _Sample(
        'AppListRow: bold title and subtitle (workspace button)',
        AppListRow(
          title: 'Subconscious',
          titleBold: true,
          subtitle: 'The main workspace for the desktop app',
          onTap: _noop,
        ),
        width: 300,
      ),
      _Sample(
        'AppListRow: leading icon, subtitle, trailing icon (agent button)',
        AppListRow(
          leading: const Icon(FluentIcons.bot_20_regular),
          title: 'Researcher',
          titleBold: true,
          subtitle: 'Finds things on the web',
          trailing: const Icon(FluentIcons.globe_16_regular, size: 16),
          onTap: _noop,
        ),
        width: 300,
      ),
      _Sample(
        'AppListRow: selected with leading icon',
        AppListRow(
          leading: const Icon(FluentIcons.bot_20_regular),
          title: 'Editor',
          titleBold: true,
          subtitle: 'Polishes drafts',
          selected: true,
          onTap: _noop,
        ),
        width: 300,
      ),
      _Sample(
        'AppListRow: trailing control (trailingInteractive)',
        AppListRow(
          title: 'Web search',
          subtitle: 'Search the internet',
          trailingInteractive: true,
          trailing: AppSwitch(
            value: true,
            compact: true,
            onChanged: (_) {},
            semanticLabel: 'Web search',
          ),
          onTap: _noop,
        ),
        width: 300,
      ),
      const _Sample(
        'AppListRow: disabled (onTap null)',
        AppListRow(title: 'Unavailable', onTap: null),
        width: 300,
      ),
      _Sample(
        'AppTreeRow: folders and files',
        Column(
          children: <Widget>[
            AppTreeRow(
              label: 'lib',
              depth: 0,
              leading: const Icon(FluentIcons.folder_16_regular, size: 16),
              trailing: const Icon(FluentIcons.chevron_down_12_regular, size: 12),
              onTap: _noop,
            ),
            AppTreeRow(
              label: 'main.dart',
              depth: 1,
              selected: true,
              leading: const Icon(FluentIcons.document_16_regular, size: 16),
              onTap: _noop,
            ),
            AppTreeRow(
              label: 'drop target',
              depth: 1,
              highlighted: true,
              leading: const Icon(FluentIcons.folder_16_regular, size: 16),
              onTap: _noop,
            ),
            AppTreeRow(
              label: 'docs',
              subtitle: r'C:\code\docs',
              leading: const Icon(FluentIcons.folder_16_regular, size: 16),
              onTap: _noop,
            ),
          ],
        ),
        width: 300,
      ),
    ],
  );

  // --- Menus and small controls --------------------------------------------------

  Widget _menusAndControls() => _Section(
    title: 'Menus and small controls',
    children: <Widget>[
      _Sample(
        'AppPopupMenu: default icon trigger',
        AppPopupMenu<String>(
          items: const <AppMenuItem<String>>[
            AppMenuItem<String>(
              value: 'rename',
              label: 'Rename',
              icon: Icons.edit_outlined,
            ),
            AppMenuItem<String>(
              value: 'copy',
              label: 'Copy link',
              subtitle: 'To the clipboard',
              icon: Icons.link,
            ),
            AppMenuItem<String>(
              value: 'delete',
              label: 'Delete',
              icon: Icons.delete_outline,
              enabled: false,
            ),
          ],
          onSelected: (_) {},
        ),
        width: 240,
      ),
      _Sample(
        'AppPopupMenu: checked single choice, custom child',
        AppPopupMenu<String>(
          items: const <AppMenuItem<String>>[
            AppMenuItem<String>(value: 'a', label: 'Small', checked: false),
            AppMenuItem<String>(value: 'b', label: 'Medium', checked: true),
            AppMenuItem<String>(value: 'c', label: 'Large', checked: false),
          ],
          onSelected: (_) {},
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Open the menu'),
          ),
        ),
        width: 240,
      ),
      const _Sample('AppBadge: neutral', AppBadge('default'), width: 200),
      const _Sample(
        'AppBadge: accent',
        AppBadge('3', tone: AppBadgeTone.accent),
        width: 200,
      ),
      const _Sample(
        'AppBadge: error',
        AppBadge('offline', tone: AppBadgeTone.error),
        width: 200,
      ),
      const _Sample(
        'AppBadge: with an icon',
        AppBadge('notes.md', icon: Icons.description_outlined),
        width: 200,
      ),
      _Sample(
        'AppBadge: removable',
        AppBadge('report.pdf', icon: Icons.attach_file, onDeleted: _noop),
        width: 200,
      ),
      const _Sample(
        'AppStatusDot: connected, connecting, disconnected',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AppStatusDot(status: AppStatus.connected),
            SizedBox(height: 4),
            AppStatusDot(status: AppStatus.connecting),
            SizedBox(height: 4),
            AppStatusDot(status: AppStatus.disconnected),
          ],
        ),
        width: 240,
      ),
      const _Sample(
        'AppStatusDot: dot only',
        AppStatusDot(status: AppStatus.connected, showLabel: false),
        width: 200,
      ),
    ],
  );

  // --- Surfaces ------------------------------------------------------------------

  Widget _surfaces() => _Section(
    title: 'Cards and banners',
    children: <Widget>[
      const _Sample(
        'AppCard',
        AppCard(child: Text('A card with some content.')),
        width: 300,
      ),
      const _Sample(
        'AppCard: selected',
        AppCard(selected: true, child: Text('The selected card.')),
        width: 300,
      ),
      _Sample(
        'AppCard: tappable',
        const AppCard(onTap: _noop, child: Text('Tap this card.')),
        width: 300,
      ),
      const _Sample(
        'AppSectionCard: bordered, with subtitle and trailing',
        AppSectionCard(
          title: 'Builtin Tools',
          subtitle: 'Enable tools provided by the engine.',
          trailing: AppBadge('12'),
          child: Text('Section content goes here.'),
        ),
        width: 340,
      ),
      const _Sample(
        'AppSectionCard: expandable (expansion panel)',
        AppSectionCard(
          title: 'Models',
          expandable: true,
          initiallyExpanded: true,
          child: Text('Expanded content.'),
        ),
        width: 340,
      ),
      const _Sample(
        'AppSectionCard: expandable, collapsed',
        AppSectionCard(
          title: 'Custom Tools',
          subtitle: 'Registered by ID.',
          expandable: true,
          initiallyExpanded: false,
          child: Text('Hidden content.'),
        ),
        width: 340,
      ),
      const _Sample(
        'AppBanner: info',
        AppBanner(message: 'The engine is starting.'),
        width: 380,
      ),
      _Sample(
        'AppBanner: warning with title and actions',
        AppBanner(
          tone: AppBannerTone.warning,
          title: 'Sign-in required',
          message: 'This tool needs you to sign in before it can run.',
          actions: <Widget>[
            TextButton(onPressed: _noop, child: const Text('Later')),
            FilledButton(onPressed: _noop, child: const Text('Sign in')),
          ],
        ),
        width: 380,
      ),
      const _Sample(
        'AppBanner: error',
        AppBanner(
          tone: AppBannerTone.error,
          message: 'No engine is reachable.',
        ),
        width: 380,
      ),
      _Sample(
        'AppBanner: with content (a field) and a truncated message',
        const AppBanner(
          title: 'Paste the code',
          message:
              'A long message that is cut after two lines so the banner stays '
              'compact even when the explanation keeps going and going.',
          messageMaxLines: 2,
          content: AppTextField(hintText: 'Authorization code'),
        ),
        width: 380,
      ),
      const _Sample(
        'AppToolbar: wraps its children when narrow',
        SizedBox(
          width: 180,
          child: AppToolbar(
            children: <Widget>[
              AppIconButton(
                tooltip: 'One',
                icon: FluentIcons.text_bold_20_regular,
                onPressed: _noop,
              ),
              AppIconButton(
                tooltip: 'Two',
                icon: FluentIcons.text_italic_20_regular,
                onPressed: _noop,
              ),
              AppIconButton(
                tooltip: 'Three',
                icon: FluentIcons.text_underline_20_regular,
                onPressed: _noop,
              ),
              AppIconButton(
                tooltip: 'Four',
                icon: FluentIcons.text_strikethrough_20_regular,
                onPressed: _noop,
              ),
              AppIconButton(
                tooltip: 'Five',
                icon: FluentIcons.text_quote_20_regular,
                onPressed: _noop,
              ),
              AppIconButton(
                tooltip: 'Six',
                icon: FluentIcons.link_20_regular,
                onPressed: _noop,
              ),
            ],
          ),
        ),
        width: 220,
      ),
    ],
  );

  // --- Settings panels -------------------------------------------------------

  Widget _settingsPanels() => _Section(
    title: 'Expansion panels and device cards',
    children: <Widget>[
      _Sample(
        'AppExpansionCard: collapsed, with a status label',
        AppExpansionCard(
          title: 'Claude',
          subtitle: 'Anthropic, claude-sonnet',
          trailingLabel: 'API key saved',
          expanded: false,
          onToggle: _noop,
          child: const Text('The editor shows here.'),
        ),
        width: 420,
      ),
      _Sample(
        'AppExpansionCard: expanded, with an editor',
        AppExpansionCard(
          title: 'Filesystem server',
          subtitle: 'MCP server, npx',
          trailingLabel: 'Connected',
          expanded: true,
          onToggle: _noop,
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppTextField(label: 'Name', initialValue: 'Filesystem server'),
              AppSwitchTile(title: 'Enabled', value: true, onChanged: null),
            ],
          ),
        ),
        width: 420,
      ),
      _Sample(
        'AppDeviceCard: this device, an engine with its clients',
        AppDeviceCard(
          device: AppDeviceTile(
            title: 'WORKSTATION (this device)',
            subtitle: 'Online, Full node, windows, local',
            detail: 'Clients: Phone, Browser',
            badge: const AppBadge('Connected', tone: AppBadgeTone.accent),
            actions: <Widget>[
              TextButton(onPressed: _noop, child: const Text('Remove')),
            ],
          ),
          clients: const <AppDeviceTile>[
            AppDeviceTile(title: 'Phone', subtitle: 'Online, Client, android'),
            AppDeviceTile(title: 'Browser', subtitle: 'Offline, Client, web'),
          ],
        ),
        width: 440,
      ),
      _Sample(
        'AppDeviceCard: a pending device with actions',
        AppDeviceCard(
          device: AppDeviceTile(
            title: 'LAPTOP',
            subtitle: 'Online, Full node, macos, pending',
            actions: <Widget>[
              FilledButton.tonal(onPressed: _noop, child: const Text('Approve')),
              TextButton(onPressed: _noop, child: const Text('Remove')),
            ],
          ),
        ),
        width: 440,
      ),
    ],
  );
  // --- Chat --------------------------------------------------------------------------

  Widget _chat() => _Section(
    title: 'Chat',
    children: <Widget>[
      const _Sample(
        'AppMessageBubble: user',
        AppMessageBubble(
          role: AppMessageRole.user,
          child: Text('Can you summarise the notes?'),
        ),
        width: 380,
      ),
      const _Sample(
        'AppMessageBubble: assistant',
        AppMessageBubble(
          role: AppMessageRole.assistant,
          child: Text('Here is a summary of the notes you asked about.'),
        ),
        width: 380,
      ),
      const _Sample(
        'AppMessageBubble: assistant, unboxed',
        AppMessageBubble(
          role: AppMessageRole.assistant,
          boxed: false,
          child: Text('A long answer that reads better without a box.'),
        ),
        width: 380,
      ),
      const _Sample(
        'AppMessageBubble: system',
        AppMessageBubble(
          role: AppMessageRole.system,
          child: Text('The thread was moved to another workspace.'),
        ),
        width: 380,
      ),
      for (final AppActivityState state in AppActivityState.values)
        _Sample(
          'AppActivityCard: ${state.name}',
          AppActivityCard(
            title: 'read filesystem file: notes.txt',
            state: state,
            subtitle: 'C:\\notes\\notes.txt',
            meta: state == AppActivityState.running ? null : '1.2 s',
            badges: <Widget>[
              if (state == AppActivityState.success)
                const AppBadge('Approved', tone: AppBadgeTone.accent),
              if (state == AppActivityState.failure)
                const AppBadge('Denied', tone: AppBadgeTone.error),
            ],
          ),
          width: 380,
        ),
      const _Sample(
        'AppActivityCard: expanded, with AppActivitySection',
        AppActivityCard(
          title: 'search_knowledge',
          state: AppActivityState.success,
          initiallyExpanded: true,
          meta: '0.4 s',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppActivitySection(label: 'Arguments', text: '{"query": "plan"}'),
              AppActivitySection(
                label: 'Error',
                text: 'The index is not ready.',
                isError: true,
              ),
            ],
          ),
        ),
        width: 380,
      ),
    ],
  );

  // --- Dialogs, sheets, snack bars --------------------------------------------------------

  Widget _overlays(BuildContext context) => _Section(
    title: 'Dialogs, sheets and snack bars',
    children: <Widget>[
      _Sample(
        'AppDialog (shown inline)',
        AppDialog(
          title: 'Delete workspace?',
          content: const Text('This also deletes its threads and cannot be undone.'),
          actions: <Widget>[
            TextButton(onPressed: _noop, child: const Text('Cancel')),
            FilledButton(onPressed: _noop, child: const Text('Delete')),
          ],
        ),
        width: 420,
      ),
      _Sample(
        'AppBottomSheet (shown inline)',
        AppBottomSheet(
          title: 'More',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppListRow(title: 'Rename', minHeight: 48, onTap: _noop),
              AppListRow(title: 'Delete', minHeight: 48, onTap: _noop),
            ],
          ),
        ),
        width: 420,
      ),
      _Sample(
        'showAppDialog, showAppBottomSheet, showAppSnack (open them)',
        AppButtonRow(
          children: <Widget>[
            OutlinedButton(
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (BuildContext context) => AppDialog(
                  title: 'A dialog',
                  width: 360,
                  content: const Text('Opened with showAppDialog.'),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              child: const Text('Dialog'),
            ),
            OutlinedButton(
              onPressed: () => showAppBottomSheet<void>(
                context: context,
                title: 'A sheet',
                builder: (BuildContext context) => AppListRow(
                  title: 'Opened with showAppBottomSheet',
                  minHeight: 48,
                  onTap: () => Navigator.pop(context),
                ),
              ),
              child: const Text('Sheet'),
            ),
            OutlinedButton(
              onPressed: () => showAppSnack(context, 'Agent UUID copied'),
              child: const Text('Snack'),
            ),
            OutlinedButton(
              onPressed: () => showAppSnack(
                context,
                "Couldn't save the agent.",
                isError: true,
              ),
              child: const Text('Error snack'),
            ),
          ],
        ),
        width: 420,
      ),
    ],
  );

  // --- Tokens -------------------------------------------------------------------------------

  Widget _tokens(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Map<String, Color> swatches = <String, Color>{
      'primary': colors.primary,
      'secondary': colors.secondary,
      'secondaryContainer': colors.secondaryContainer,
      'surface': colors.surface,
      'surfaceContainerLowest': colors.surfaceContainerLowest,
      'surfaceContainerLow': colors.surfaceContainerLow,
      'surfaceContainerHigh': colors.surfaceContainerHigh,
      'outlineVariant': colors.outlineVariant,
      'onSurface': colors.onSurface,
      'onSurfaceVariant': colors.onSurfaceVariant,
      'error': colors.error,
      'errorContainer': colors.errorContainer,
      'inverseSurface': colors.inverseSurface,
      'statusConnected': AppColors.statusConnected,
      'statusConnecting': AppColors.statusConnecting,
      'statusDisconnected': AppColors.statusDisconnected,
    };
    final Map<String, BorderRadius> radii = <String, BorderRadius>{
      'AppRadii.standard (6, every component)': AppRadii.standard,
    };
    return _Section(
      title: 'Tokens',
      children: <Widget>[
        for (final MapEntry<String, Color> entry in swatches.entries)
          _Sample(
            'Color: ${entry.key}',
            DecoratedBox(
              decoration: BoxDecoration(
                color: entry.value,
                borderRadius: AppRadii.standard,
                border: Border.all(color: colors.outlineVariant),
              ),
              child: const SizedBox(height: 36, width: double.infinity),
            ),
            width: 170,
          ),
        for (final MapEntry<String, BorderRadius> entry in radii.entries)
          _Sample(
            entry.key,
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.secondaryContainer,
                borderRadius: entry.value,
                border: Border.all(color: colors.outlineVariant),
              ),
              child: const SizedBox(height: 36, width: double.infinity),
            ),
            width: 170,
          ),
        const _Sample(
          'AppSpacing.control (4) and AppSpacing.row (8)',
          Row(
            children: <Widget>[
              _Block(width: 40),
              AppSpacing.controlGap,
              _Block(width: 40),
              SizedBox(width: AppSpacing.row),
              _Block(width: 40),
            ],
          ),
          width: 260,
        ),
        _Sample(
          'AppDensity.control (32) and touchControl (48)',
          Row(
            children: <Widget>[
              Container(
                height: AppDensity.control,
                width: AppDensity.control,
                color: colors.secondaryContainer,
              ),
              const SizedBox(width: 8),
              Container(
                height: AppDensity.touchControl,
                width: AppDensity.touchControl,
                color: colors.secondaryContainer,
              ),
            ],
          ),
          width: 260,
        ),
      ],
    );
  }
}

final class _Block extends StatelessWidget {
  const _Block({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) => Container(
    height: 24,
    width: width,
    color: Theme.of(context).colorScheme.secondaryContainer,
  );
}

/// A titled group of samples, wrapped onto as many lines as the window needs.
final class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const Divider(height: 24),
          Wrap(spacing: 28, runSpacing: 24, children: children),
        ],
      ),
    );
  }
}

/// One component in one state, with its name written above it.
final class _Sample extends StatelessWidget {
  const _Sample(this.label, this.child, {this.width = 320});

  final String label;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFamily: 'Consolas',
              fontFamilyFallback: const <String>['monospace'],
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
