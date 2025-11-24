import WidgetKit
import SwiftUI

@main
struct RecordingAnalyzerWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingAnalyzerWidget()       // The Standard Home Screen Widget
        RecordingAnalyzerLiveActivity() // The Lock Screen Live Activity
    }
}
