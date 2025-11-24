import ActivityKit
import WidgetKit
import SwiftUI

struct RecordingAnalyzerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            // MARK: - LOCK SCREEN APPEARANCE
            HStack {
                // 1. Simulated Waveform (Visual only)
                HStack(spacing: 3) {
                    ForEach(0..<12) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red.opacity(0.8))
                            .frame(width: 3, height: .random(in: 10...25))
                            .animation(
                                .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.1),
                                value: true
                            )
                    }
                }
                .frame(width: 60)
                
                Spacer()
                
                // 2. The Timer
                // This magic Text initializer counts up automatically from the date!
                Text(timerInterval: context.state.recordingStartDate...Date().addingTimeInterval(60*60*24), countsDown: false)
                    .monospacedDigit()
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Spacer()
                
                // 3. Stop Button
                // Since this requires advanced AppIntents to handle background stopping,
                // we will use a Link to open the app and stop it immediately.
                Link(destination: URL(string: "voicememos://stop")!) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.2), lineWidth: 3)
                            .frame(width: 45, height: 45)
                        Circle().fill(Color.red).frame(width: 25, height: 25)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(Color.white)
            
        } dynamicIsland: { context in
            // MARK: - DYNAMIC ISLAND (iPhone 14 Pro/15/16)
            DynamicIsland {
                // Expanded UI (Long press on Island)
                DynamicIslandExpandedRegion(.leading) {
                    HStack {
                        Image(systemName: "mic.fill").foregroundColor(.red)
                        Text("Recording").font(.caption).bold()
                    }.padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Stop Button
                    Link(destination: URL(string: "voicememos://stop")!) {
                        Image(systemName: "stop.circle.fill")
                            .resizable()
                            .frame(width: 30, height: 30)
                            .foregroundColor(.red)
                    }.padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        // Waveform
                        HStack(spacing: 2) {
                            ForEach(0..<8) { _ in
                                RoundedRectangle(cornerRadius: 1).fill(.red).frame(width: 2, height: 12)
                            }
                        }
                        Spacer()
                        // Timer
                        Text(timerInterval: context.state.recordingStartDate...Date().addingTimeInterval(86400), countsDown: false)
                            .monospacedDigit()
                            .font(.title2)
                            .foregroundColor(.white)
                        Spacer()
                    }
                }
            } compactLeading: {
                // Small Island (Left)
                Image(systemName: "mic.fill").foregroundColor(.red)
            } compactTrailing: {
                // Small Island (Right) - The Timer
                Text(timerInterval: context.state.recordingStartDate...Date().addingTimeInterval(86400), countsDown: false)
                    .monospacedDigit()
                    .frame(width: 50)
                    .font(.caption2)
                    .foregroundColor(.red)
            } minimal: {
                Image(systemName: "mic.fill").foregroundColor(.red)
            }
        }
    }
}
