// Design-System von Junels: Graphit-Flächen, Mint als Akzent, feine Ränder,
// Inter für Text, JetBrains Mono für Kennungen und Zahlen.

import 'package:flutter/material.dart';

/// Zusätzliche Farb-Token, die das Material-Schema nicht kennt.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.canvas,
    required this.panel,
    required this.raised,
    required this.border,
    required this.borderStrong,
    required this.muted,
    required this.faint,
    required this.mint,
    required this.mintSoft,
    required this.amber,
    required this.amberSoft,
    required this.red,
    required this.redSoft,
    required this.blue,
    required this.blueSoft,
    required this.violet,
    required this.violetSoft,
    required this.dots,
  });

  /// Hintergrund hinter allen Flächen (Arbeitsbereich).
  final Color canvas;

  /// Seitenleisten und Kopfbereiche.
  final Color panel;

  /// Karten über einer Fläche (Hover, Eingabe).
  final Color raised;
  final Color border;
  final Color borderStrong;

  /// Sekundärtext.
  final Color muted;

  /// Tertiärtext, Platzhalter.
  final Color faint;
  final Color mint;
  final Color mintSoft;
  final Color amber;
  final Color amberSoft;
  final Color red;
  final Color redSoft;
  final Color blue;
  final Color blueSoft;
  final Color violet;
  final Color violetSoft;

  /// Punktraster im Canvas.
  final Color dots;

  static const dark = AppColors(
    canvas: Color(0xFF18191C),
    panel: Color(0xFF1E1F23),
    raised: Color(0xFF2A2C31),
    border: Color(0xFF2F3137),
    borderStrong: Color(0xFF3E4048),
    muted: Color(0xFF9EA1A8),
    faint: Color(0xFF6C6F77),
    mint: Color(0xFF5FD4A0),
    mintSoft: Color(0xFF1D3A2E),
    amber: Color(0xFFF2C14E),
    amberSoft: Color(0xFF3A3020),
    red: Color(0xFFF07A7A),
    redSoft: Color(0xFF3D2426),
    blue: Color(0xFF7AA7F7),
    blueSoft: Color(0xFF1F2B44),
    violet: Color(0xFFAE8CFA),
    violetSoft: Color(0xFF2C2443),
    dots: Color(0xFF2A2C31),
  );

  static const light = AppColors(
    canvas: Color(0xFFF4F5F7),
    panel: Color(0xFFFBFBFC),
    raised: Color(0xFFF0F1F3),
    border: Color(0xFFE3E5E9),
    borderStrong: Color(0xFFCDD0D6),
    muted: Color(0xFF5F636B),
    faint: Color(0xFF8E929A),
    mint: Color(0xFF119A67),
    mintSoft: Color(0xFFDDF4E9),
    amber: Color(0xFFB7860B),
    amberSoft: Color(0xFFFBF0D3),
    red: Color(0xFFD14545),
    redSoft: Color(0xFFFBE3E3),
    blue: Color(0xFF2F6BD8),
    blueSoft: Color(0xFFE1EBFC),
    violet: Color(0xFF7C4FE0),
    violetSoft: Color(0xFFEDE5FD),
    dots: Color(0xFFDADDE2),
  );

  static AppColors of(BuildContext context) => Theme.of(context).extension<AppColors>() ?? dark;

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      canvas: l(canvas, other.canvas),
      panel: l(panel, other.panel),
      raised: l(raised, other.raised),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      muted: l(muted, other.muted),
      faint: l(faint, other.faint),
      mint: l(mint, other.mint),
      mintSoft: l(mintSoft, other.mintSoft),
      amber: l(amber, other.amber),
      amberSoft: l(amberSoft, other.amberSoft),
      red: l(red, other.red),
      redSoft: l(redSoft, other.redSoft),
      blue: l(blue, other.blue),
      blueSoft: l(blueSoft, other.blueSoft),
      violet: l(violet, other.violet),
      violetSoft: l(violetSoft, other.violetSoft),
      dots: l(dots, other.dots),
    );
  }
}

/// Abstände und Radien.
abstract final class Ui {
  static const r = 12.0; // Standard-Radius (Karten, Felder)
  static const rLg = 18.0; // große Flächen, Dialoge
  static const mono = 'JetBrainsMono';
  static const font = 'Inter';
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final c = dark ? AppColors.dark : AppColors.light;
  final surface = dark ? const Color(0xFF222328) : Colors.white;
  final onSurface = dark ? const Color(0xFFECEDEF) : const Color(0xFF16171A);
  final scheme = ColorScheme(
    brightness: b,
    primary: c.mint,
    onPrimary: dark ? const Color(0xFF0C2419) : Colors.white,
    primaryContainer: c.mintSoft,
    onPrimaryContainer: dark ? const Color(0xFFBFF0D8) : const Color(0xFF0B4D33),
    secondary: dark ? const Color(0xFFB9BCC3) : const Color(0xFF41454D),
    onSecondary: dark ? const Color(0xFF18191C) : Colors.white,
    secondaryContainer: c.raised,
    onSecondaryContainer: onSurface,
    tertiary: c.violet,
    onTertiary: Colors.white,
    tertiaryContainer: c.violetSoft,
    onTertiaryContainer: onSurface,
    error: c.red,
    onError: Colors.white,
    errorContainer: c.redSoft,
    onErrorContainer: dark ? const Color(0xFFFFC9C9) : const Color(0xFF7A1F1F),
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: c.muted,
    surfaceDim: c.canvas,
    surfaceBright: c.raised,
    surfaceContainerLowest: c.canvas,
    surfaceContainerLow: c.panel,
    surfaceContainer: surface,
    surfaceContainerHigh: c.raised,
    surfaceContainerHighest: dark ? const Color(0xFF30323A) : const Color(0xFFE8EAEE),
    outline: c.borderStrong,
    outlineVariant: c.border,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: dark ? const Color(0xFFECEDEF) : const Color(0xFF222328),
    onInverseSurface: dark ? const Color(0xFF18191C) : Colors.white,
    inversePrimary: c.mint,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    fontFamily: Ui.font,
    visualDensity: VisualDensity.standard,
  );
  final text = base.textTheme.apply(bodyColor: onSurface, displayColor: onSurface);
  final tt = text.copyWith(
    headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.4),
    headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.6),
    titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.3, fontSize: 20),
    titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.1),
    titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    bodyLarge: text.bodyLarge?.copyWith(height: 1.5, fontSize: 15),
    bodyMedium: text.bodyMedium?.copyWith(height: 1.45),
    bodySmall: text.bodySmall?.copyWith(color: c.muted, height: 1.4),
    labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
    labelSmall: text.labelSmall?.copyWith(fontWeight: FontWeight.w500, letterSpacing: 0.2),
  );

  final borderSide = BorderSide(color: c.border);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.r), side: borderSide);
  const stadium = StadiumBorder();
  const btnPad = EdgeInsets.symmetric(horizontal: 18, vertical: 12);

  return base.copyWith(
    textTheme: tt,
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    extensions: [c],
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: c.canvas,
      surfaceTintColor: Colors.transparent,
      foregroundColor: onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: tt.titleMedium?.copyWith(fontSize: 17),
      shape: Border(bottom: borderSide),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: surface,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      margin: EdgeInsets.zero,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      iconColor: c.muted,
      selectedColor: onSurface,
      selectedTileColor: c.mintSoft,
      subtitleTextStyle: tt.bodySmall,
      horizontalTitleGap: 12,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: c.muted,
      collapsedIconColor: c.muted,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1B1C20) : const Color(0xFFF6F7F9),
      hintStyle: TextStyle(color: c.faint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Ui.r), borderSide: borderSide),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Ui.r), borderSide: borderSide),
      disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Ui.r), borderSide: BorderSide(color: c.border.withValues(alpha: 0.5))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Ui.r), borderSide: BorderSide(color: c.mint, width: 1.4)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: stadium,
        padding: btnPad,
        textStyle: tt.labelLarge,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: stadium,
        padding: btnPad,
        foregroundColor: onSurface,
        side: BorderSide(color: c.borderStrong),
        textStyle: tt.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: stadium, textStyle: tt.labelLarge, foregroundColor: c.mint),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(shape: stadium, elevation: 0, padding: btnPad),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.muted, highlightColor: c.raised),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: c.border),
        selectedBackgroundColor: c.mintSoft,
        selectedForegroundColor: dark ? const Color(0xFFBFF0D8) : const Color(0xFF0B4D33),
        backgroundColor: surface,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      side: borderSide,
      shape: const StadiumBorder(),
      labelStyle: tt.labelMedium?.copyWith(color: onSurface),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.transparent : c.borderStrong),
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : c.muted),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.rLg), side: borderSide),
      titleTextStyle: tt.titleLarge,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(Ui.rLg)), side: borderSide),
      showDragHandle: true,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: c.panel,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.r), side: borderSide),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.r), side: borderSide)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF34363D) : const Color(0xFF26282D),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: Ui.font),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF2E3036) : const Color(0xFF26282D),
      contentTextStyle: const TextStyle(color: Colors.white, fontFamily: Ui.font),
      actionTextColor: c.mint,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.r)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.mint, linearTrackColor: c.raised),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.mint,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
      highlightElevation: 0,
      shape: const StadiumBorder(),
    ),
    badgeTheme: BadgeThemeData(backgroundColor: c.red, textColor: Colors.white),
    tabBarTheme: TabBarThemeData(
      labelColor: onSurface,
      unselectedLabelColor: c.muted,
      indicatorColor: c.mint,
      dividerColor: c.border,
      labelStyle: tt.labelLarge,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.panel,
      indicatorColor: c.mintSoft,
      surfaceTintColor: Colors.transparent,
    ),
    sliderTheme: SliderThemeData(activeTrackColor: c.mint, thumbColor: c.mint, inactiveTrackColor: c.raised),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
  );
}

// ------------------------------------------------------------------ Bausteine

/// Kleiner Großbuchstaben-Abschnittstitel („SPACES“, „FAVORITEN“).
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(12, 18, 8, 8)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(
          child: Text(text.toUpperCase(),
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.3, color: c.faint, fontFamily: Ui.font)),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// Farbiger Status-Chip („In Arbeit“, „Blockiert“, „Abgeschlossen“).
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, required this.color, this.soft, this.icon, this.dense = false});
  final String label;
  final Color color;
  final Color? soft;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final bg = soft ?? color.withValues(alpha: 0.16);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1 : 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: dense ? 11 : 13, color: color), const SizedBox(width: 4)],
        Text(label,
            style: TextStyle(
                fontSize: dense ? 10.5 : 11.5, fontWeight: FontWeight.w600, color: color, fontFamily: Ui.font, height: 1.3)),
      ]),
    );
  }
}

/// Kennung in Monospace (z. B. „VOR-001 · 45 %“).
class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.color, this.size = 11.5});
  final String text;
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) => Text(text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontFamily: Ui.mono, fontSize: size, color: color ?? AppColors.of(context).muted, letterSpacing: 0));
}

/// Fläche mit feinem Rand (Ersatz für Card, wenn mehr Kontrolle nötig ist).
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.color,
    this.borderColor,
    this.radius = Ui.r,
    this.onTap,
  });
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final Color? color;
  final Color? borderColor;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = BorderRadius.circular(radius);
    return Padding(
      padding: margin,
      child: Material(
        color: color ?? scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: borderColor ?? c.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      ),
    );
  }
}

/// Runder Icon-Knopf mit Rand (wie in der Werkzeugleiste).
class PillIconButton extends StatelessWidget {
  const PillIconButton(
      {super.key, required this.icon, required this.tooltip, this.onPressed, this.badge = false, this.active = false, this.badgeColor});
  final Color? badgeColor;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool badge;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? c.mintSoft : scheme.surface,
        shape: CircleBorder(side: BorderSide(color: active ? c.mint.withValues(alpha: 0.5) : c.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Badge(
              isLabelVisible: badge,
              smallSize: 8,
              backgroundColor: badgeColor,
              child: Icon(icon,
                  size: 19,
                  color: onPressed == null ? c.faint.withValues(alpha: 0.5) : (active ? c.mint : scheme.onSurface)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Leerer Zustand mit Symbol, Titel, Text und optionaler Aktion.
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.title, this.text, this.action});
  final IconData icon;
  final String title;
  final String? text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: c.mintSoft, borderRadius: BorderRadius.circular(16)),
          child: Icon(icon, color: c.mint, size: 26),
        ),
        const SizedBox(height: 14),
        Text(title, style: t.titleMedium, textAlign: TextAlign.center),
        if (text != null) ...[
          const SizedBox(height: 6),
          Text(text!, style: t.bodyMedium?.copyWith(color: c.muted), textAlign: TextAlign.center),
        ],
        if (action != null) ...[const SizedBox(height: 16), action!],
      ]),
    );
  }
}

/// Logo-Zeichen: abgerundetes Quadrat mit Verlauf.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 30});
  final double size;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.mint, Color.lerp(c.mint, c.blue, 0.65)!],
        ),
      ),
      alignment: Alignment.center,
      child: Text('J',
          style: TextStyle(
              fontFamily: Ui.font, fontWeight: FontWeight.w700, fontSize: size * 0.55, color: const Color(0xFF0C2419), height: 1)),
    );
  }
}

/// Seitenkopf für Unterseiten: großer Titel, Untertitel, Aktionen.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const [], this.icon});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    // Handy: der Titel steht schon oben in der Leiste – nur die Erklärung zeigen, kurz und dezent
    if (MediaQuery.sizeOf(context).width < 700) {
      if ((subtitle ?? '').isEmpty && actions.isEmpty) return const SizedBox(height: 4);
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((subtitle ?? '').isNotEmpty) Expanded(child: Text(subtitle!, style: t.bodySmall?.copyWith(color: c.muted))) else const Spacer(),
          ...actions,
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (icon != null) ...[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: c.mintSoft, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: c.mint, size: 22),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.headlineSmall),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: t.bodyMedium?.copyWith(color: c.muted)),
            ],
          ]),
        ),
        ...actions,
      ]),
    );
  }
}

/// KI-Hinweis unter erzeugten Inhalten – mit dem offiziellen EU-Symbol „AI“
/// (https://digital-strategy.ec.europa.eu/de/policies/eu-icons-labelling-ai-generated-content).
class AiNotice extends StatelessWidget {
  const AiNotice({super.key, this.images = false, this.compact = false});

  /// Enthält die Antwort erzeugte Bilder?
  final bool images;
  final bool compact;

  static const text = 'Mit KI erzeugt · KI kann Fehler machen – Wichtiges bitte prüfen.';

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final label = images ? 'Mit KI erzeugt, auch die Bilder · KI kann Fehler machen – Wichtiges bitte prüfen.' : text;
    return Semantics(
      label: 'Hinweis: Dieser Inhalt wurde mit KI erzeugt. KI kann Fehler machen.',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.only(top: compact ? 2 : 6),
        child: Row(mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max, children: [
          Image.asset(dark ? 'assets/ai_label/ai_white.png' : 'assets/ai_label/ai_black.png',
              height: 15, filterQuality: FilterQuality.medium, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: c.faint, fontFamily: Ui.font, height: 1.3)),
          ),
        ]),
      ),
    );
  }
}

/// EU-Symbol „AI GENERATED“ als Plakette (z. B. über KI-Bildern in der Vorschau).
class AiGeneratedBadge extends StatelessWidget {
  const AiGeneratedBadge({super.key, this.height = 18});
  final double height;
  @override
  Widget build(BuildContext context) => Semantics(
        label: 'KI-generiertes Bild',
        child: Image.asset('assets/ai_label/ai_generated_black.png',
            height: height, filterQuality: FilterQuality.medium, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
      );
}


/// Bottom-Sheet mit sichtbarem ✕ zum Schließen (Android: nicht nur durch Tippen daneben).
Future<T?> showSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  String? title,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      showDragHandle: false,
      useSafeArea: true,
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 6, 0),
          child: Row(children: [
            Expanded(child: title == null ? const SizedBox() : Text(title, style: Theme.of(ctx).textTheme.titleMedium)),
            IconButton(tooltip: 'Schließen', icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
          ]),
        ),
        Flexible(child: builder(ctx)),
      ]),
    );
