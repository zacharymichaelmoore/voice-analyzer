//
//  RecordingAnalyzerWidgetBundle.swift
//  RecordingAnalyzerWidget
//
//  Created by Zachary Moore on 11/23/25.
//

import WidgetKit
import SwiftUI

@main
struct RecordingAnalyzerWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingAnalyzerWidget()
        RecordingAnalyzerWidgetControl()
        RecordingAnalyzerWidgetLiveActivity()
    }
}
