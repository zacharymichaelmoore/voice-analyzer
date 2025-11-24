//
//  RecordingAnalyzerWidget.swift
//  RecordingAnalyzerWidget
//
//  Created by Zachary Moore on 11/23/25.
//

import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - 1. LIVE ACTIVITY WIDGET (Lock Screen)
struct RecordingAnalyzerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            // MARK: LOCK SCREEN UI
            VStack(spacing: 12) {
                HStack {
                    // Left Side: Status
                    Image(systemName: "mic.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    
                    Text("Recording")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    // Right Side: Timer
                    Text(context.state.recordingStartDate, style: .timer)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundColor(.white)
                }
                
                // Bottom: Visualizer
                HStack(spacing: 4) {
                    ForEach(0..<12) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red.opacity(0.8))
                            .frame(height: CGFloat.random(in: 10...25))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 30)
            }
            .padding(16)
            .background(
                // IMPORTANT: Make background more prominent
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.95))
            )
            .activityBackgroundTint(Color.red.opacity(0.2))
            .activitySystemActionForegroundColor(Color.white)
            
        } dynamicIsland: { context in
            // MARK: DYNAMIC ISLAND
            DynamicIsland {
                // Expanded UI
                DynamicIslandExpandedRegion(.leading) {
                    HStack {
                        Image(systemName: "mic.fill").foregroundColor(.red)
                        Text("Rec").font(.headline).foregroundColor(.white)
                    }.padding(.leading, 8)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.recordingStartDate, style: .timer)
                        .monospacedDigit()
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.trailing, 8)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 3) {
                        ForEach(0..<20) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.red)
                                .frame(width: 4, height: CGFloat.random(in: 10...30))
                        }
                    }
                    .frame(height: 40)
                }
            } compactLeading: {
                HStack {
                    Image(systemName: "mic.fill").foregroundColor(.red)
                }.padding(.leading, 4)
            } compactTrailing: {
                Text(context.state.recordingStartDate, style: .timer)
                    .monospacedDigit()
                    .frame(width: 40)
                    .font(.caption2)
                    .foregroundColor(.white)
            } minimal: {
                Image(systemName: "mic.fill").foregroundColor(.red)
            }
        }
    }
}

// MARK: - 2. STANDARD HOME SCREEN WIDGET
struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), configuration: ConfigurationAppIntent())
    }
    
    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry {
        SimpleEntry(date: Date(), configuration: configuration)
    }
    
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        let entry = SimpleEntry(date: Date(), configuration: configuration)
        return Timeline(entries: [entry], policy: .atEnd)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
}

struct RecordingAnalyzerWidgetEntryView : View {
    var entry: Provider.Entry
    
    var body: some View {
        VStack {
            Text("Voice Analyzer")
                .font(.headline)
            Text("Ready to record")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct RecordingAnalyzerWidget: Widget {
    let kind: String = "RecordingAnalyzerWidget"
    
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            RecordingAnalyzerWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

extension ConfigurationAppIntent {
    fileprivate static var smiley: ConfigurationAppIntent {
        let intent = ConfigurationAppIntent()
        intent.favoriteEmoji = "😀"
        return intent
    }
}
