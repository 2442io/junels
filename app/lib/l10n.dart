// Sprache der Oberfläche: Deutsch (Quelltext) oder Englisch (Übersetzungstabelle).
// tr('Deutscher Text') liefert in Englisch die Übersetzung – fehlt sie, bleibt der deutsche Text.

import 'l10n_en.dart';

/// 'de' oder 'en' – wird beim Start aus den Einstellungen gesetzt
String appLang = 'de';

bool get isEnglish => appLang == 'en';

String tr(String de) => appLang == 'en' ? (enStrings[de] ?? de) : de;
