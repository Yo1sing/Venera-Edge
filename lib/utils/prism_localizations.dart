import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/l10n.dart' as prism;

import 'translations.dart';

class PrismLocalizations implements prism.UiLocalizations {
  const PrismLocalizations(this.locale);

  static const delegate = _PrismLocalizationsDelegate();
  final Locale locale;

  @override
  String get back => 'Back'.translateFor(locale);
  @override
  String get cancel => 'Cancel'.translateFor(locale);
  @override
  String get clearSearch => 'Clear search'.translateFor(locale);
  @override
  String get close => 'Close'.translateFor(locale);
  @override
  String get copy => 'Copy'.translateFor(locale);
  @override
  String get cut => 'Cut'.translateFor(locale);
  @override
  String get dialog => 'Dialog'.translateFor(locale);
  @override
  String get hidePassword => 'Hide password'.translateFor(locale);
  @override
  String get more => 'more'.translateFor(locale);
  @override
  String get noSearchResults => 'No search results'.translateFor(locale);
  @override
  String get paste => 'Paste'.translateFor(locale);
  @override
  String get reset => 'Reset'.translateFor(locale);
  @override
  String get select => 'Select'.translateFor(locale);
  @override
  String get search => 'Search'.translateFor(locale);
  @override
  String get selectAll => 'Select All'.translateFor(locale);
  @override
  String get showLess => 'Show less'.translateFor(locale);
  @override
  String get showMore => 'Show more'.translateFor(locale);
  @override
  String get showPassword => 'Show password'.translateFor(locale);
  @override
  String get sort => 'Sort'.translateFor(locale);
  @override
  String get submit => 'Submit'.translateFor(locale);
}

class _PrismLocalizationsDelegate
    extends LocalizationsDelegate<prism.UiLocalizations> {
  const _PrismLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'zh' || locale.languageCode == 'en';

  @override
  Future<prism.UiLocalizations> load(Locale locale) =>
      SynchronousFuture(PrismLocalizations(locale));

  @override
  bool shouldReload(_PrismLocalizationsDelegate old) => false;
}
