import 'package:flutter/foundation.dart';

/// Whether Caldo is running as a desktop app rather than on a phone — on
/// Linux, the one desktop it is built for.
///
/// Asked of Flutter rather than of `dart:io`: the widget tests run on a
/// Linux host and are told they are on Android, which is what keeps them
/// testing the phone, and a test of the desktop says so for itself
/// (`debugDefaultTargetPlatformOverride`).
bool get onDesktop => defaultTargetPlatform == TargetPlatform.linux;
