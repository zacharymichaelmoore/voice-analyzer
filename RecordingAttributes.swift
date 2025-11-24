import ActivityKit
import Foundation

struct RecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // We don't need to pass the timer every second.
        // We pass the "recording start time" and the system counts up for us.
        var recordingStartDate: Date
    }

    // Static data (doesn't change during the recording)
    var recordingName: String
}
