/// Manifest of the embedded `.srs` rule sets. **Pure Dart**, no Flutter dependency.
///
/// Two consumers: the GUI uses `rootBundle` to unpack them into a writable
/// directory (`rule_sets.dart`), and the command line references them directly by
/// path in the install directory (`bin/aurora_cli.dart`). There is only one
/// manifest, so the two sides do not each keep a table and update only one when a
/// new rule set is added.
library;

/// rule-set tag -> asset file name.
const auroraRuleSetFiles = <String, String>{
  'geosite-cn': 'geosite-cn.srs',
  'geoip-cn': 'geoip-cn.srs',
  'geosite-geolocation-!cn': 'geosite-geolocation-!cn.srs',
};

/// Asset directory (relative to the Flutter assets root).
const auroraRuleSetAssetDir = 'assets/rule_sets';
