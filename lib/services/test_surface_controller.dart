/// TestSurfaceController — the live state behind the one Computer target
/// implemented this phase (`sysai-test-surface`).
///
/// Both a human clicking/typing in `ComputerView` and a Controlled
/// Computer Use action requested by a Run call the exact same methods
/// here. That shared code path is what makes a programmatic action real
/// rather than a state mutation bypass: there is no second, action-only
/// way to change this surface's state.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const List<String> kTestSurfaceOptions = ['Option A', 'Option B', 'Option C'];

/// The `RepaintBoundary` key `ComputerView` attaches to the rendered test
/// surface. A module-level key (rather than something threaded through
/// Riverpod) because the consumer — `RunExecutor`, a plain provider with
/// no `BuildContext` — needs to reach it directly, exactly like
/// `key.currentContext` is the only way in from outside the widget tree.
final GlobalKey testSurfaceRepaintKey = GlobalKey(debugLabel: 'sysai-test-surface-repaint-boundary');

class TestSurfaceState {
  final String fieldValue;
  final bool checked;
  final String selectedOption;
  final bool submitted;
  final int scrollPosition; // 0..100, an abstract scroll-region offset
  final String? lastAction;
  final DateTime updatedAt;

  const TestSurfaceState({
    this.fieldValue = '',
    this.checked = false,
    this.selectedOption = 'Option A',
    this.submitted = false,
    this.scrollPosition = 0,
    this.lastAction,
    required this.updatedAt,
  });

  factory TestSurfaceState.initial() => TestSurfaceState(updatedAt: DateTime.now());

  TestSurfaceState copyWith({
    String? fieldValue,
    bool? checked,
    String? selectedOption,
    bool? submitted,
    int? scrollPosition,
    String? lastAction,
  }) => TestSurfaceState(
    fieldValue: fieldValue ?? this.fieldValue,
    checked: checked ?? this.checked,
    selectedOption: selectedOption ?? this.selectedOption,
    submitted: submitted ?? this.submitted,
    scrollPosition: scrollPosition ?? this.scrollPosition,
    lastAction: lastAction ?? this.lastAction,
    updatedAt: DateTime.now(),
  );

  /// The manifest `computer.observe` reports for this target — real
  /// current state, not a static description.
  Map<String, dynamic> toObserveManifest() => {
    'success': true,
    'controls': [
      {'id': 'main_field', 'type': 'text_field', 'value': fieldValue},
      {'id': 'agree_checkbox', 'type': 'checkbox', 'value': checked},
      {'id': 'option_dropdown', 'type': 'dropdown', 'value': selectedOption, 'options': kTestSurfaceOptions},
      {'id': 'submit_button', 'type': 'button', 'value': submitted},
      {'id': 'scroll_region', 'type': 'scroll_region', 'value': scrollPosition},
    ],
  };
}

class TestSurfaceController extends StateNotifier<TestSurfaceState> {
  TestSurfaceController() : super(TestSurfaceState.initial());

  Map<String, dynamic> observe() => state.toObserveManifest();

  void setFieldValue(String value) {
    state = state.copyWith(fieldValue: value, lastAction: 'type:main_field');
  }

  void toggleCheckbox() {
    state = state.copyWith(checked: !state.checked, lastAction: 'click:agree_checkbox');
  }

  void selectOption(String option) {
    if (!kTestSurfaceOptions.contains(option)) return;
    state = state.copyWith(selectedOption: option, lastAction: 'click:option_dropdown');
  }

  void submit() {
    state = state.copyWith(submitted: true, lastAction: 'click:submit_button');
  }

  void scrollBy(int delta) {
    state = state.copyWith(scrollPosition: (state.scrollPosition + delta).clamp(0, 100), lastAction: 'scroll:scroll_region');
  }

  void backspace() {
    if (state.fieldValue.isEmpty) return;
    state = state.copyWith(fieldValue: state.fieldValue.substring(0, state.fieldValue.length - 1), lastAction: 'key:main_field');
  }

  void reset() => state = TestSurfaceState.initial();

  // ── Dispatch for Controlled Computer Use actions ──────────────────────
  //
  // Every branch here is a direct call to one of the methods above — the
  // same ones the widget's own onPressed/onChanged callbacks call. There
  // is deliberately no separate "act on behalf of an action" code path.

  Map<String, dynamic> executeClick(String? selector) {
    switch (selector) {
      case 'submit_button':
        submit();
        return {'success': true, 'action': 'click', 'selector': selector};
      case 'agree_checkbox':
        toggleCheckbox();
        return {'success': true, 'action': 'click', 'selector': selector};
      case 'option_dropdown':
        final next = kTestSurfaceOptions[(kTestSurfaceOptions.indexOf(state.selectedOption) + 1) % kTestSurfaceOptions.length];
        selectOption(next);
        return {'success': true, 'action': 'click', 'selector': selector, 'value': next};
      default:
        return {'success': false, 'error': 'Unknown or unselectable control for click: $selector'};
    }
  }

  Map<String, dynamic> executeType(String? selector, String? text) {
    if (selector != 'main_field' || text == null) {
      return {'success': false, 'error': 'type requires selector "main_field" and non-null text'};
    }
    setFieldValue(text);
    return {'success': true, 'action': 'type', 'selector': selector, 'value': text};
  }

  Map<String, dynamic> executeKey(String? selector, String? key) {
    if (selector != 'main_field') {
      return {'success': false, 'error': 'key requires selector "main_field"'};
    }
    switch (key) {
      case 'Backspace':
        backspace();
        return {'success': true, 'action': 'key', 'selector': selector, 'key': key};
      case 'Enter':
        submit();
        return {'success': true, 'action': 'key', 'selector': selector, 'key': key};
      default:
        return {'success': false, 'error': 'Unsupported key: $key'};
    }
  }

  Map<String, dynamic> executeScroll(String? selector, String? direction) {
    if (selector != 'scroll_region') {
      return {'success': false, 'error': 'scroll requires selector "scroll_region"'};
    }
    scrollBy(direction == 'up' ? -10 : 10);
    return {'success': true, 'action': 'scroll', 'selector': selector, 'position': state.scrollPosition};
  }
}

final testSurfaceControllerProvider =
    StateNotifierProvider<TestSurfaceController, TestSurfaceState>((ref) => TestSurfaceController());
