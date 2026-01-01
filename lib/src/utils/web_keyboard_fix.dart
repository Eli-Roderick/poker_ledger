import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Workaround wrapper for Flutter web keyboard dismiss bug.
/// See: https://github.com/flutter/flutter/issues/179438
/// 
/// On web, wraps the child in a GestureDetector that unfocuses text fields
/// when tapping outside, encouraging users to dismiss keyboard via tap
/// rather than the buggy back gesture.
class WebKeyboardFix extends StatelessWidget {
  final Widget child;
  const WebKeyboardFix({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    
    return GestureDetector(
      onTap: () {
        // Unfocus any focused text field when tapping outside
        FocusScope.of(context).unfocus();
      },
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}
