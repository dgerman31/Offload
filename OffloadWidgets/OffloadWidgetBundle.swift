import SwiftUI
import WidgetKit

/// The widget extension's entry point.
///
/// Two Live Activities: the focus timer, and today's Anki queue. Home Screen and Lock Screen
/// widgets would be added to this bundle rather than to a second extension.
@main
struct OffloadWidgetBundle: WidgetBundle {
    var body: some Widget {
        FocusActivityWidget()
        AnkiActivityWidget()
    }
}
