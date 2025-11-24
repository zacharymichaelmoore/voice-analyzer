//
//  RecordingAttributes.swift
//  recording-analyzer
//
//  Created by Zachary Moore on 11/24/25.
//


#if canImport(ActivityKit)
import ActivityKit
#endif

import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst)
struct RecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // This is the dynamic data (the timer)
        var recordingStartDate: Date
    }

    // This is static data (the name)
    var recordingName: String
}
#endif
