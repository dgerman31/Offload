import SwiftUI
import WidgetKit

/// The widget extension's entry point.
///
/// One member for now — the focus timer's Live Activity. Home Screen and Lock Screen widgets
/// would be added to this bundle rather than to a second extension.
@main
struct OffloadWidgetBundle: WidgetBundle {
    var body: some Widget {
        FocusActivityWidget()
    }
}
