import 'package:flutter/material.dart';

/// A tutorial step that highlights a specific area of the screen
class TutorialStep {
  final String title;
  final String description;
  final GlobalKey? targetKey;
  final Alignment tooltipAlignment;
  final int? navigationIndex; // Which bottom nav tab to show (null = stay on current)
  final bool showSkip;
  
  const TutorialStep({
    required this.title,
    required this.description,
    this.targetKey,
    this.tooltipAlignment = Alignment.bottomCenter,
    this.navigationIndex,
    this.showSkip = true,
  });
}

/// Controller for managing tutorial state
class TutorialController extends ChangeNotifier {
  final List<TutorialStep> steps;
  int _currentStep = 0;
  bool _isActive = false;
  
  TutorialController({required this.steps});
  
  int get currentStep => _currentStep;
  bool get isActive => _isActive;
  bool get isLastStep => _currentStep >= steps.length - 1;
  TutorialStep? get currentTutorialStep => 
      _isActive && _currentStep < steps.length ? steps[_currentStep] : null;
  
  void start() {
    _currentStep = 0;
    _isActive = true;
    notifyListeners();
  }
  
  void next() {
    if (_currentStep < steps.length - 1) {
      _currentStep++;
      notifyListeners();
    } else {
      finish();
    }
  }
  
  void previous() {
    if (_currentStep > 0) {
      _currentStep--;
      notifyListeners();
    }
  }
  
  void finish() {
    _isActive = false;
    notifyListeners();
  }
  
  void skip() {
    finish();
  }
}

/// Overlay widget that shows the tutorial with spotlight effect
class TutorialOverlay extends StatefulWidget {
  final TutorialController controller;
  final Widget child;
  final VoidCallback? onComplete;
  final Function(int)? onNavigationRequested;
  
  const TutorialOverlay({
    super.key,
    required this.controller,
    required this.child,
    this.onComplete,
    this.onNavigationRequested,
  });
  
  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> 
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  
  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
    
    widget.controller.addListener(_onControllerChanged);
    if (widget.controller.isActive) {
      _animationController.forward();
    }
  }
  
  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _animationController.dispose();
    super.dispose();
  }
  
  void _onControllerChanged() {
    if (widget.controller.isActive) {
      _animationController.forward();
      // Handle navigation if needed
      final step = widget.controller.currentTutorialStep;
      if (step?.navigationIndex != null && widget.onNavigationRequested != null) {
        widget.onNavigationRequested!(step!.navigationIndex!);
      }
    } else {
      _animationController.reverse().then((_) {
        widget.onComplete?.call();
      });
    }
    setState(() {});
  }
  
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (widget.controller.isActive)
          FadeTransition(
            opacity: _fadeAnimation,
            child: _buildOverlay(context),
          ),
      ],
    );
  }
  
  Widget _buildOverlay(BuildContext context) {
    final step = widget.controller.currentTutorialStep;
    if (step == null) return const SizedBox.shrink();
    
    return Stack(
      children: [
        // Dark overlay with spotlight cutout
        _SpotlightOverlay(
          targetKey: step.targetKey,
          overlayColor: Colors.black.withValues(alpha: 0.75),
        ),
        // Tooltip
        _TutorialTooltip(
          step: step,
          stepIndex: widget.controller.currentStep,
          totalSteps: widget.controller.steps.length,
          isLastStep: widget.controller.isLastStep,
          onNext: widget.controller.next,
          onPrevious: widget.controller.currentStep > 0 
              ? widget.controller.previous 
              : null,
          onSkip: widget.controller.skip,
        ),
      ],
    );
  }
}

/// Custom painter for the spotlight overlay
class _SpotlightOverlay extends StatelessWidget {
  final GlobalKey? targetKey;
  final Color overlayColor;
  
  const _SpotlightOverlay({
    this.targetKey,
    required this.overlayColor,
  });
  
  @override
  Widget build(BuildContext context) {
    Rect? targetRect;
    
    if (targetKey?.currentContext != null) {
      final RenderBox renderBox = 
          targetKey!.currentContext!.findRenderObject() as RenderBox;
      final position = renderBox.localToGlobal(Offset.zero);
      final size = renderBox.size;
      targetRect = Rect.fromLTWH(
        position.dx - 8,
        position.dy - 8,
        size.width + 16,
        size.height + 16,
      );
    }
    
    return CustomPaint(
      size: MediaQuery.of(context).size,
      painter: _SpotlightPainter(
        targetRect: targetRect,
        overlayColor: overlayColor,
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect? targetRect;
  final Color overlayColor;
  
  _SpotlightPainter({
    this.targetRect,
    required this.overlayColor,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = overlayColor;
    
    if (targetRect != null) {
      // Create a path with a hole for the spotlight
      final path = Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRRect(RRect.fromRectAndRadius(targetRect!, const Radius.circular(12)))
        ..fillType = PathFillType.evenOdd;
      
      canvas.drawPath(path, paint);
      
      // Draw a highlight border around the target
      final borderPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(targetRect!, const Radius.circular(12)),
        borderPaint,
      );
    } else {
      // No target - just draw the overlay
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    }
  }
  
  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) {
    return targetRect != oldDelegate.targetRect;
  }
}

/// Tooltip widget that shows the tutorial text
class _TutorialTooltip extends StatelessWidget {
  final TutorialStep step;
  final int stepIndex;
  final int totalSteps;
  final bool isLastStep;
  final VoidCallback onNext;
  final VoidCallback? onPrevious;
  final VoidCallback onSkip;
  
  const _TutorialTooltip({
    required this.step,
    required this.stepIndex,
    required this.totalSteps,
    required this.isLastStep,
    required this.onNext,
    this.onPrevious,
    required this.onSkip,
  });
  
  @override
  Widget build(BuildContext context) {
    // Position the tooltip based on target location
    Alignment alignment = step.tooltipAlignment;
    double? top, bottom, left, right;
    
    if (step.targetKey?.currentContext != null) {
      final RenderBox renderBox = 
          step.targetKey!.currentContext!.findRenderObject() as RenderBox;
      final position = renderBox.localToGlobal(Offset.zero);
      final size = renderBox.size;
      final screenSize = MediaQuery.of(context).size;
      
      // Determine best position for tooltip
      final targetCenterY = position.dy + size.height / 2;
      if (targetCenterY < screenSize.height / 2) {
        // Target is in top half - show tooltip below
        top = position.dy + size.height + 24;
      } else {
        // Target is in bottom half - show tooltip above
        bottom = screenSize.height - position.dy + 24;
      }
    } else {
      // No target - center the tooltip
      alignment = Alignment.center;
    }
    
    Widget tooltip = Container(
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Progress indicator
          Row(
            children: [
              Text(
                'Step ${stepIndex + 1} of $totalSteps',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (step.showSkip && !isLastStep)
                TextButton(
                  onPressed: onSkip,
                  child: const Text('Skip Tutorial'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Title
          Text(
            step.title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          
          // Description
          Text(
            step.description,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          
          // Navigation buttons
          Row(
            children: [
              if (onPrevious != null)
                OutlinedButton(
                  onPressed: onPrevious,
                  child: const Text('Back'),
                ),
              if (onPrevious != null) const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: onNext,
                  child: Text(isLastStep ? 'Get Started!' : 'Next'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    
    if (top != null || bottom != null) {
      return Positioned(
        top: top,
        bottom: bottom,
        left: left ?? 0,
        right: right ?? 0,
        child: tooltip,
      );
    }
    
    return Align(
      alignment: alignment,
      child: tooltip,
    );
  }
}
