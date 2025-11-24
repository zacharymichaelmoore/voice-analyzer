@preconcurrency import AVFoundation
import Foundation
import Network
import ReplayKit
import Speech
import SwiftUI
import ActivityKit

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// MARK: - 1. CONFIG & API
let API_KEY = "" // Enter your Gemini API Key here
let MODEL_NAME = "gemini-3-pro-preview"

//#if os(iOS) && !targetEnvironment(macCatalyst)
//struct RecordingAttributes: ActivityAttributes {
//    public struct ContentState: Codable, Hashable {
//                var recordingStartDate: Date
//    }
//
//    var recordingName: String
//}
//#endif

// MARK: - 2. FILE SYSTEM HELPERS
struct FileHelper {
    static func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    static func getFileURL(for fileName: String) -> URL {
        getDocumentsDirectory().appendingPathComponent(fileName)
    }
    
    static func getBaseURL(customURL: URL?) -> URL {
        if let custom = customURL, (try? custom.checkResourceIsReachable()) == true {
            return custom
        }
        return getDocumentsDirectory()
    }
}

// MARK: - 3. HELPER: DIRECTORY MONITOR
class DirectoryMonitor: NSObject, NSFilePresenter {
    var presentedItemURL: URL?
    var presentedItemOperationQueue: OperationQueue = OperationQueue.main
    
    private let onChange: () -> Void
    
    init(url: URL, onChange: @escaping () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }
    
    deinit {
        NSFileCoordinator.removeFilePresenter(self)
    }
    
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        onChange()
        completionHandler(nil)
    }
}

// MARK: - 4. MODELS

import UniformTypeIdentifiers

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    
    var text: String
    
    init(text: String = "") {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

struct Recording: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    let date: Date
    var duration: TimeInterval
    var fileName: String
    var transcript: String?
    var isFavorite: Bool = false
    var folderName: String? = nil
    
    var tags: [String: [Tag]] = [:]
    
    var isTranscribing: Bool = false
    var isEnhancing: Bool = false
    var isQueued: Bool = false
    
    var sentenceSegments: [String] {
        guard let t = transcript else { return [] }
        return t.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
    
    var relativeDateString: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return date.formatted(date: .numeric, time: .omitted)
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    var isLoading: Bool = false
    enum Role { case user, model }
}

struct Citation: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    let startTime: TimeInterval
    let speaker: String
    let text: String
    let recordingID: UUID
}

enum AnalysisTab: String, CaseIterable {
    case chat = "Chat"
    case code = "Code"
}

struct EditConfig: Identifiable {
    let id = UUID()
    let recording: Recording
    var showTranscriptInitially: Bool
}

struct Theme: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    
    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct AttributeType: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    
    init(id: UUID = UUID(), name: String, symbol: String = "") {
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

struct Tag: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var text: String
    var colorIndex: Int
    var themeID: UUID?
    var isAttribute: Bool = false
    var attributeTypeID: UUID?
    
    init(id: UUID = UUID(), text: String, colorIndex: Int, themeID: UUID? = nil, isAttribute: Bool = false, attributeTypeID: UUID? = nil) {
        self.id = id
        self.text = text
        self.colorIndex = colorIndex
        self.themeID = themeID
        self.isAttribute = isAttribute
        self.attributeTypeID = attributeTypeID
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
        themeID = try container.decodeIfPresent(UUID.self, forKey: .themeID)
        isAttribute = try container.decodeIfPresent(Bool.self, forKey: .isAttribute) ?? false
        attributeTypeID = try container.decodeIfPresent(UUID.self, forKey: .attributeTypeID)
    }
}

struct CodingDatabase: Codable {
    var themes: [Theme]
    var attributeTypes: [AttributeType] = []
    var codes: [Tag]
}

struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    var tags: [Tag] = [] // New property
}

struct PlaybackRequest: Identifiable, Equatable {
    // Stable ID: uniquely identifies this specific moment in this specific recording
    var id: String {
        "\(recording.id.uuidString)_\(time)"
    }
    
    let recording: Recording
    let time: TimeInterval
    
    init(recording: Recording, time: TimeInterval) {
        self.recording = recording
        self.time = time
    }
    
    static func == (lhs: PlaybackRequest, rhs: PlaybackRequest) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - 5. TRANSCRIPTION SERVICE
class Transcriber: ObservableObject {
    struct PendingJob {
        let url: URL
        let context: String
        let onUpdate: (String) -> Void
        let onCompletion: (String) -> Void
        let onError: (String) -> Void
    }
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var pendingJobs: [URL: PendingJob] = [:]
    private var isConnected: Bool = true
    
    init() {
        monitor.pathUpdateHandler = { path in
            let status = path.status == .satisfied
            DispatchQueue.main.async {
                self.isConnected = status
                if status { self.flushQueue() }
            }
        }
        monitor.start(queue: queue)
    }
    
    func transcribeAudio(url: URL, context: String, onQueued: @escaping () -> Void, onUpdate: @escaping (String) -> Void, onCompletion: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        let job = PendingJob(url: url, context: context, onUpdate: onUpdate, onCompletion: onCompletion, onError: onError)
        
        if isConnected {
            // Add a slight delay to ensure file handle is released by AVAudioRecorder
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                self.performGeminiTranscription(job: job)
            }
        } else {
            print("⚠️ Offline. Queuing transcription for \(url.lastPathComponent)")
            pendingJobs[url] = job
            onQueued()
        }
    }
    
    private func flushQueue() {
        guard !pendingJobs.isEmpty else { return }
        print("🛜 Back Online. Flushing \(pendingJobs.count) jobs...")
        for (_, job) in pendingJobs {
            job.onUpdate("")
            // Run on background thread
            DispatchQueue.global(qos: .utility).async {
                self.performGeminiTranscription(job: job)
            }
        }
        pendingJobs.removeAll()
    }
    
    private func performGeminiTranscription(job: PendingJob, retryCount: Int = 0) {
        // 1. START BACKGROUND TASK (Keeps app alive if user locks phone)
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        if #available(iOS 13.0, *) {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        
        // Helper to end task safely
        let endTask = {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        
        // 2. READ DATA (With Retry Logic)
        var audioData: Data?
        do {
            audioData = try Data(contentsOf: job.url)
        } catch {
            // If file is busy/locked, retry once after 1 second
            if retryCount < 2 {
                print("⚠️ File busy, retrying read in 1s...")
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    self.performGeminiTranscription(job: job, retryCount: retryCount + 1)
                    endTask() // End the current task, the retry will start a new one
                }
                return
            } else {
                job.onError("Could not read audio file: \(error.localizedDescription)")
                endTask()
                return
            }
        }
        
        guard let finalData = audioData else {
            job.onError("Audio data is empty.")
            endTask()
            return
        }
        
        // 3. PREPARE REQUEST
        let base64Audio = finalData.base64EncodedString()
        var apiKey = UserDefaults.standard.string(forKey: "GEMINI_API_KEY") ?? ""
        if apiKey.isEmpty { apiKey = API_KEY }
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(MODEL_NAME):generateContent?key=\(apiKey)") else {
            job.onError("Invalid URL")
            endTask()
            return
        }
        
        var prompt = "Transcribe this audio file verbatim.\n"
        prompt += "CRITICAL INSTRUCTIONS:\n"
        prompt += "1. You must be precise with timestamps. They must match the audio file exactly.\n"
        prompt += "2. Do not hallucinate timestamps. If there is silence, do not skip the time forward.\n"
        prompt += "3. Reset your internal clock to 00:00 at the start of the file.\n"
        prompt += "FORMAT: `[MM:SS] Speaker Name: Text`\n"
        
        if !job.context.isEmpty {
            prompt += "\nCONTEXT: \"\(job.context)\"\n"
            prompt += "INSTRUCTION: Use context to identify speakers."
        } else {
            prompt += "INSTRUCTION: Identify speakers as 'Speaker 1', etc."
        }
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        ["inline_data": ["mime_type": "audio/m4a", "data": base64Audio]]
                    ]
                ]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 3600
        
        print("🚀 Sending to Gemini (\(MODEL_NAME))...")
        
        // 4. PERFORM UPLOAD
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { endTask() } // Ensure background task ends when request is done
            
            if let error = error { job.onError("Network Error: \(error.localizedDescription)"); return }
            guard let data = data else { job.onError("No data"); return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let content = candidates.first?["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let text = parts.first?["text"] as? String {
                    DispatchQueue.main.async {
                        print("✅ Gemini Transcription Complete")
                        job.onCompletion(text)
                    }
                } else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorObj = json["error"] as? [String: Any],
                       let message = errorObj["message"] as? String {
                        job.onError("Gemini Error: \(message)")
                    } else {
                        job.onError("Failed to parse Gemini response.")
                    }
                }
            } catch {
                job.onError("JSON Error: \(error.localizedDescription)")
            }
        }.resume()
    }
}

// MARK: - 6. GEMINI AI SERVICE (STREAMING CHAT)
class GeminiService {
    // We return an AsyncThrowingStream to yield text chunks as they arrive
    func streamChat(history: [ChatMessage], context: String) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                var apiKey = UserDefaults.standard.string(forKey: "GEMINI_API_KEY") ?? ""
                if apiKey.isEmpty { apiKey = API_KEY }
                
                guard !apiKey.isEmpty else {
                    continuation.finish(throwing: NSError(domain: "App", code: 401, userInfo: [NSLocalizedDescriptionKey: "API Key Missing"]))
                    return
                }
                
                // 1. URL CHANGE: Use 'streamGenerateContent' and 'alt=sse' for easy parsing
                guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(MODEL_NAME):streamGenerateContent?alt=sse&key=\(apiKey)") else {
                    continuation.finish(throwing: NSError(domain: "App", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
                    return
                }
                
                // 2. CONSTRUCT HISTORY (Context + Chat)
                // 2. CONSTRUCT HISTORY (Context + Chat)
                var apiContents: [[String: Any]] = []
                let systemContext = """
                                You are an AI assistant helping analyze qualitative data. 
                                Context provided below contains transcripts from voice recordings.
                                
                                METADATA EXPLANATION:
                                Some lines contain qualitative codes enclosed in curly braces, like: 
                                {CODES: CodeName (Theme: ThemeName)}. 
                                These codes represent manual categorization of the text by the researcher.
                                
                                INSTRUCTIONS:
                                1. You can answer questions based on the text AND the codes.
                                2. If asked about a specific Theme, look for codes associated with that Theme.
                                3. The source text is already strictly numbered with tags like [1], [2], etc.
                                When citing sources, YOU MUST USE THESE EXACT EXISTING NUMBERS.
                                DO NOT count sentences yourself. Use the numbers provided in the text.
                                
                                STRICT FORMATTING RULES:
                                - Output PLAIN TEXT ONLY.
                                - DO NOT use Markdown formatting.
                                - DO NOT use asterisks (**) for bold.
                                - DO NOT use hash marks (#) for headers.
                                - Use CAPITAL LETTERS for section headers instead of bold.
                                - Write in plain paragraphs.
                                
                                CONTEXT:
                                \(context)
                                """
                
                for (index, msg) in history.enumerated() {
                    if msg.isLoading { continue }
                    var textToSend = msg.text
                    // Inject the huge context into the VERY FIRST message only
                    if index == 0 && msg.role == .user {
                        textToSend = systemContext + "\n\nUSER QUESTION: " + msg.text
                    }
                    apiContents.append(["role": msg.role == .user ? "user" : "model", "parts": [["text": textToSend]]])
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["contents": apiContents])
                request.timeoutInterval = 180 // 3 minutes timeout for long "thinking"
                
                do {
                    // 3. STREAMING REQUEST
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: NSError(domain: "App", code: 500, userInfo: [NSLocalizedDescriptionKey: "Server Error"]))
                        return
                    }
                    
                    // 4. PARSE LINES (Server-Sent Events)
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6)) // Remove "data: "
                            if jsonStr == "[DONE]" { break }
                            
                            if let data = jsonStr.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let candidates = json["candidates"] as? [[String: Any]],
                               let content = candidates.first?["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]],
                               let text = parts.first?["text"] as? String {
                                
                                continuation.yield(text)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - 7. VIEW MODEL
@MainActor
class VoiceMemosModel: ObservableObject {
    enum SelectionState {
        case all     // 100% selected
        case some    // 1% to 99% selected (Indeterminate)
        case none    // 0% selected
    }
    @Published var attributeTypes: [AttributeType] = []
    @Published var chatScrollID: UUID?
    @Published var themes: [Theme] = []
    @Published var savedCodes: [Tag] = []
    @Published var recordings: [Recording] = []
    @Published var userFolders: [String] = []
    @Published var searchText: String = ""
    @Published var selectedRecordingIDs: Set<UUID> = []
    @Published var activeRecording: Recording?
    @Published var selectedTab: Int = 0
    @Published var analysisTabSelection: AnalysisTab = .chat
    @Published var chatHistory: [ChatMessage] = []
    @Published var navigationPath = NavigationPath()
    @Published var activeCitation: Citation?
    @Published var playbackRequest: PlaybackRequest?
    
    private let transcriber = Transcriber()
    private var suppressReloads = false
    private var reloadWorkItem: DispatchWorkItem?
    
    static let timestampRegex = try? NSRegularExpression(pattern: "\\[(\\d{2}):(\\d{2})\\]")
    
    @AppStorage("storageBookmarkData") private var storageBookmarkData: Data?
    private var customStorageURL: URL?
    private var directoryMonitor: DirectoryMonitor?
    
    init() {
        restoreStorageAccess()
        setupMonitor()
        loadExistingRecordings()
        triggerDebouncedReload()
    }
    
    deinit {
        customStorageURL?.stopAccessingSecurityScopedResource()
        directoryMonitor = nil
    }
    
    var allCount: Int { recordings.count }
    
    var sortedSelectedRecordings: [Recording] {
        recordings
            .filter { selectedRecordingIDs.contains($0.id) }
            .sorted(by: { $0.date > $1.date })
    }
    
    var combinedTranscriptContext: String {
        let selectedRecs = sortedSelectedRecordings
        if selectedRecs.isEmpty { return "" }
        
        var globalIndex = 0
        var context = ""
        let regex = VoiceMemosModel.timestampRegex
        
        for rec in selectedRecs {
            globalIndex += 1
            context += "[\(globalIndex)] --- SOURCE: \(rec.name) ---\n"
            
            let segments = rec.sentenceSegments
            for segment in segments {
                globalIndex += 1
                
                var metaContext = ""
                if let regex = regex,
                   let match = regex.firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment)) {
                    
                    let r1 = Range(match.range(at: 1), in: segment)!
                    let r2 = Range(match.range(at: 2), in: segment)!
                    
                    if let min = Double(segment[r1]), let sec = Double(segment[r2]) {
                        let startTime = (min * 60) + sec
                        let key = String(startTime)
                        
                        if let tags = rec.tags[key], !tags.isEmpty {
                            // 1. Separate Codes and Attributes
                            let codes = tags.filter { !$0.isAttribute }
                            let attributes = tags.filter { $0.isAttribute }
                            
                            var parts: [String] = []
                            
                            if !codes.isEmpty {
                                let desc = codes.map { tag -> String in
                                    let themeName = themes.first(where: { $0.id == tag.themeID })?.name ?? "No Theme"
                                    return "\(tag.text) (Theme: \(themeName))"
                                }.joined(separator: ", ")
                                parts.append("{CODES: \(desc)}")
                            }
                            
                            if !attributes.isEmpty {
                                let desc = attributes.map { tag -> String in
                                    if let typeID = tag.attributeTypeID,
                                       let typeName = attributeTypes.first(where: { $0.id == typeID })?.name {
                                        return "\(tag.text) (Type: \(typeName))"
                                    }
                                    return tag.text
                                }.joined(separator: ", ")
                                parts.append("{ATTRIBUTES: \(desc)}")
                            }
                            
                            if !parts.isEmpty {
                                metaContext = " " + parts.joined(separator: " ")
                            }
                        }
                    }
                }
                
                context += "[\(globalIndex)] \(segment)\(metaContext)\n"
            }
            context += "\n"
        }
        return context
    }
    
    var storageLocationName: String {
        if let url = customStorageURL {
            if (try? url.checkResourceIsReachable()) == true {
                return url.lastPathComponent
            } else {
                DispatchQueue.main.async { self.resetStorageLocation() }
                return "On My iPhone"
            }
        }
        return "On My iPhone"
    }
    
    // MARK: - Color Helper for Export
    private func getHexCode(for index: Int) -> String {
        // Matches the 'tagColors' extension at the bottom of your file
        let hexColors = [
            "#007AFF", // 0: Blue
            "#AF52DE", // 1: Purple
            "#FF2D55", // 2: Pink
            "#FF3B30", // 3: Red
            "#FF9500", // 4: Orange
            "#FFCC00", // 5: Yellow
            "#28CD41", // 6: Green
            "#8E8E93"  // 7: Gray
        ]
        
        if index >= 0 && index < hexColors.count {
            return hexColors[index]
        }
        return "#007AFF" // Default to Blue
    }
    
    private func getRootURL() -> URL {
        if let folder = customStorageURL, (try? folder.checkResourceIsReachable()) == true {
            return folder
        }
        return FileHelper.getDocumentsDirectory()
    }
    
    func updateAttributeTypeSymbol(id: UUID, symbol: String) {
        if let index = attributeTypes.firstIndex(where: { $0.id == id }) {
            withAnimation {
                attributeTypes[index].symbol = symbol
            }
            saveDatabase()
            objectWillChange.send()
        }
    }
    
    func generateCSVExport() -> CSVDocument {
        // 1. Update Header: Added "Attribute Category" column
        var csvText = "Type,Code/Attribute,Attribute Category,Color Name,Recording Name,Timestamp,Theme,Text Segment\n"
        let regex = VoiceMemosModel.timestampRegex
        
        for recording in recordings {
            guard let transcript = recording.transcript, !recording.tags.isEmpty else { continue }
            let lines = transcript.components(separatedBy: "\n").filter { !$0.isEmpty }
            
            for line in lines {
                var startTime: TimeInterval = 0
                if let regex = regex,
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let r1 = Range(match.range(at: 1), in: line)!
                    let r2 = Range(match.range(at: 2), in: line)!
                    if let min = Double(line[r1]), let sec = Double(line[r2]) {
                        startTime = (min * 60) + sec
                    }
                }
                
                let key = String(startTime)
                if let tagsForLine = recording.tags[key] {
                    for tag in tagsForLine {
                        let type = tag.isAttribute ? "Attribute" : "Code"
                        
                        let themeName = themes.first(where: { $0.id == tag.themeID })?.name ?? ""
                        
                        var attributeTypeName = ""
                        if tag.isAttribute, let typeID = tag.attributeTypeID {
                            attributeTypeName = attributeTypes.first(where: { $0.id == typeID })?.name ?? ""
                        }
                        
                        let colorName = getColorName(for: tag.colorIndex)
                        let timeStr = formatTime(startTime)
                        
                        let safeType = sanitizeCSV(type)
                        let safeCode = sanitizeCSV(tag.text)
                        let safeCategory = sanitizeCSV(attributeTypeName)
                        let safeColor = sanitizeCSV(colorName)
                        let safeRecording = sanitizeCSV(recording.name)
                        let safeTheme = sanitizeCSV(themeName)
                        let safeText = sanitizeCSV(line)
                        
                        csvText += "\(safeType),\(safeCode),\(safeCategory),\(safeColor),\(safeRecording),\(timeStr),\(safeTheme),\(safeText)\n"
                    }
                }
            }
        }
        return CSVDocument(text: csvText)
    }
    
    // Helper to escape commas and quotes for CSV
    private func sanitizeCSV(_ text: String) -> String {
        var newText = text.replacingOccurrences(of: "\"", with: "\"\"")
        if newText.contains(",") || newText.contains("\n") {
            newText = "\"\(newText)\""
        }
        return newText
    }
    
    private func getColorName(for index: Int) -> String {
        switch index {
        case 0: return "Blue"
        case 1: return "Purple"
        case 2: return "Pink"
        case 3: return "Red"
        case 4: return "Orange"
        case 5: return "Yellow"
        case 6: return "Green"
        case 7: return "Gray"
        default: return "Blue"
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    private func getDatabaseURL() -> URL {
        return getRootURL().appendingPathComponent("coding_database.json")
    }
    
    func triggerDebouncedReload() {
        reloadWorkItem?.cancel()
        
        let newItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            if self.suppressReloads { return }

            print("🔄 Executing Debounced Reload...")
            self.loadExistingRecordings()
            self.loadThemesAndCodes()
        }
        
        reloadWorkItem = newItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: newItem)
    }
    
    func loadThemesAndCodes() {
        let url = getDatabaseURL()
        
        // 1. Try to read the file
        if let data = try? Data(contentsOf: url),
           let db = try? JSONDecoder().decode(CodingDatabase.self, from: data) {
            
            print("✅ Loaded Coding Database from: \(url.lastPathComponent)")
            
            withAnimation {
                self.themes = db.themes
                self.savedCodes = db.codes
                self.attributeTypes = db.attributeTypes
            }
        } else {
            print("⚠️ No coding_database.json found at \(url.path). Starting with empty library.")
            self.themes = []
            self.savedCodes = []
            self.attributeTypes = []
        }
    }
    
    private func saveDatabase() {
        let url = getDatabaseURL()
        let db = CodingDatabase(themes: self.themes, attributeTypes: self.attributeTypes, codes: self.savedCodes)
        
        do {
            let data = try JSONEncoder().encode(db)
            try data.write(to: url)
            print("💾 Saved Coding Database to: \(url.path)")
        } catch {
            print("❌ Failed to save coding database: \(error.localizedDescription)")
        }
    }
    
    @discardableResult
    func addAttributeType(name: String) -> UUID {
        let newID = UUID()
        let newType = AttributeType(id: newID, name: name)
        
        // 1. Update Memory IMMEDIATELY (UI stays stable)
        withAnimation {
            attributeTypes.append(newType)
        }
        
        // 2. CANCEL any pending reloads (Stop the loop before it starts)
        reloadWorkItem?.cancel()
        
        // 3. Save to Disk
        saveDatabase()
        
        // 4. BLOCK the inevitable file-watcher callback
        // We create a "Dummy" work item that does nothing, effectively muting the next event
        let suppressionItem = DispatchWorkItem { }
        reloadWorkItem = suppressionItem
        
        // We schedule this dummy item into the future.
        // If the file watcher fires in the next 1.0s, it will try to cancel
        // this dummy item and schedule a real one, but we can also use a flag
        // combined with this logic for double safety.
        
        return newID
    }
    
    func addTheme(name: String) {
        let newTheme = Theme(name: name)
        
        self.suppressReloads = true
        
        themes.append(newTheme)
        saveDatabase()
        
        print("✅ Added new theme '\(name)' and saved to database.")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.suppressReloads = false
        }
    }
    
    func saveThemes() {
        saveDatabase()
    }
    
    func saveCodeToLibrary(_ tag: Tag) {
        // Check if code exists (case insensitive) to prevent duplicates
        if let index = savedCodes.firstIndex(where: { $0.text.lowercased() == tag.text.lowercased() }) {
            // Update existing (e.g. if color/theme changed)
            savedCodes[index] = tag
        } else {
            savedCodes.append(tag)
        }
        
        saveDatabase()
    }
    
    func getCodes(for themeID: UUID?) -> [Tag] {
        if let id = themeID {
            return savedCodes.filter { $0.themeID == id }
        }
        return savedCodes
    }
    
    func getFileUrl(for recording: Recording) -> URL {
        let root = getRootURL()
        if let folder = recording.folderName {
            return root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(recording.fileName)
        }
        return root.appendingPathComponent(recording.fileName)
    }
    
    func getSelectionState(folder: String?) -> SelectionState {
        let scope = folder == nil ? recordings : recordings.filter { $0.folderName == folder }
        
        if scope.isEmpty { return .none }
        
        let scopeIDs = Set(scope.map { $0.id })
        
        let intersectionCount = selectedRecordingIDs.intersection(scopeIDs).count
        
        if intersectionCount == scopeIDs.count {
            return .all  // Everything is selected
        } else if intersectionCount > 0 {
            return .some // Indeterminate (The "Minus" State)
        } else {
            return .none // Nothing selected
        }
    }
    
    func getTranscriptUrl(for recording: Recording) -> URL {
        let audioUrl = getFileUrl(for: recording)
        
        let txtName = audioUrl.deletingPathExtension().lastPathComponent + "_transcript.txt"
        
        return audioUrl.deletingLastPathComponent().appendingPathComponent(txtName)
    }
    
    private func setupMonitor() {
        let urlToWatch = getRootURL()
        directoryMonitor = DirectoryMonitor(url: urlToWatch) { [weak self] in
            self?.triggerDebouncedReload()
        }
    }
    
    private func restoreStorageAccess() {
        guard let data = storageBookmarkData else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            if url.startAccessingSecurityScopedResource() {
                customStorageURL = url
            } else {
                storageBookmarkData = nil
            }
        } catch {
            storageBookmarkData = nil
        }
    }
    
    func setCustomStorageLocation(_ url: URL) {
        customStorageURL?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else { return }
        
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            storageBookmarkData = data
            customStorageURL = url
            setupMonitor()
            loadExistingRecordings()
            triggerDebouncedReload()
            objectWillChange.send()
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }
    
    func resetStorageLocation() {
        customStorageURL?.stopAccessingSecurityScopedResource()
        customStorageURL = nil
        storageBookmarkData = nil
        setupMonitor()
        loadExistingRecordings()
        triggerDebouncedReload()
        objectWillChange.send()
    }
    
    private func loadExistingRecordings() {
        if suppressReloads { return }
        
        let root = getRootURL()
        if customStorageURL != nil { _ = root.startAccessingSecurityScopedResource() }
        
        var newRecordings: [Recording] = []
        var detectedFolders: [String] = []
        
        do {
            let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: .skipsHiddenFiles)
            
            for item in items {
                let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                let isDir = vals?.isDirectory ?? false
                
                if isDir {
                    let folderName = item.lastPathComponent
                    detectedFolders.append(folderName)
                    
                    if let subItems = try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) {
                        for sub in subItems {
                            if ["m4a", "mp3", "wav"].contains(sub.pathExtension.lowercased()) {
                                newRecordings.append(createRecording(url: sub, folder: folderName))
                            }
                        }
                    }
                } else {
                    if ["m4a", "mp3", "wav"].contains(item.pathExtension.lowercased()) {
                        newRecordings.append(createRecording(url: item, folder: nil))
                    }
                }
            }
            
            DispatchQueue.main.async {
                withAnimation {
                    self.userFolders = detectedFolders.sorted()
                    self.recordings = newRecordings.sorted(by: { $0.date > $1.date })
                }
            }
        } catch {
            print("Load failed: \(error)")
        }
    }
    
    private func createRecording(url: URL, folder: String?) -> Recording {
        let fileName = url.lastPathComponent
        let vals = try? url.resourceValues(forKeys: [.creationDateKey])
        let date = vals?.creationDate ?? Date()
        
        var duration: TimeInterval = 0
        if let audioPlayer = try? AVAudioPlayer(contentsOf: url) {
            duration = audioPlayer.duration
        }
        
        // Derive the expected transcript URL
        let txtName = url.deletingPathExtension().lastPathComponent + "_transcript.txt"
        let txtURL = url.deletingLastPathComponent().appendingPathComponent(txtName)
        
        var diskTranscript: String? = nil
        
        do {
            diskTranscript = try String(contentsOf: txtURL, encoding: .utf8)
            print("✅ SUCCESSFULLY LOADED: \(txtName)")
        } catch {
            // If UTF-8 fails, sometimes it's a slightly different text format, so we try ASCII as a backup
            if let secondaryTry = try? String(contentsOf: txtURL, encoding: .ascii) {
                diskTranscript = secondaryTry
                print("✅ Loaded (ASCII): \(txtName)")
            } else {
                // This print helps us debug if it's still failing
                print("⚠️ Transcript file not read: \(txtName). Error: \(error.localizedDescription)")
            }
        }
        // -----------------------------
        
        var loadedTags: [String: [Tag]] = [:]
        let tagsJsonName = url.deletingPathExtension().lastPathComponent + "_tags.json"
        let tagsURL = url.deletingLastPathComponent().appendingPathComponent(tagsJsonName)
        
        if let data = try? Data(contentsOf: tagsURL),
           let decoded = try? JSONDecoder().decode([String: [Tag]].self, from: data) {
            loadedTags = decoded
        }
        
        var idToUse = UUID()
        var isTranscribingState = false
        var isEnhancingState = false
        var isQueuedState = false
        var transcriptToUse = diskTranscript
        
        if let existing = self.recordings.first(where: { $0.fileName == fileName && $0.folderName == folder }) {
            idToUse = existing.id
            isTranscribingState = existing.isTranscribing
            isEnhancingState = existing.isEnhancing
            isQueuedState = existing.isQueued
            
            if isTranscribingState || isEnhancingState {
                transcriptToUse = existing.transcript
            }
            
            // Should we keep memory tags?
            // If we just loaded from disk, disk might be older if we haven't saved,
            // but usually createRecording is called on load.
            // Let's prefer the disk load unless it's empty and memory isn't.
            if loadedTags.isEmpty && !existing.tags.isEmpty {
                loadedTags = existing.tags
            }
        }
        
        return Recording(
            id: idToUse,
            name: fileName.replacingOccurrences(of: ".m4a", with: "")
                .replacingOccurrences(of: ".mp3", with: "")
                .replacingOccurrences(of: ".wav", with: ""),
            date: date,
            duration: duration,
            fileName: fileName,
            transcript: transcriptToUse,
            isFavorite: false,
            folderName: folder,
            tags: loadedTags, // <--- Inject Tags Here
            isTranscribing: isTranscribingState,
            isEnhancing: isEnhancingState,
            isQueued: isQueuedState
        )
    }
    
    func createFolder(name: String) {
        let root = getRootURL()
        let folderURL = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadExistingRecordings()
    }
    
    func deleteFolder(at offsets: IndexSet) {
        let root = getRootURL()
        offsets.forEach { index in
            let folderName = userFolders[index]
            let folderURL = root.appendingPathComponent(folderName, isDirectory: true)
            let contents = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            contents?.forEach { fileURL in
                let destURL = root.appendingPathComponent(fileURL.lastPathComponent)
                try? FileManager.default.moveItem(at: fileURL, to: destURL)
            }
            try? FileManager.default.removeItem(at: folderURL)
        }
        loadExistingRecordings()
    }
    
    func renameFolder(from oldName: String, to newName: String) {
        let root = getRootURL()
        let oldURL = root.appendingPathComponent(oldName, isDirectory: true)
        let newURL = root.appendingPathComponent(newName, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            loadExistingRecordings()
        } catch { print("Failed to rename folder: \(error)") }
    }
    
    func moveRecording(_ recording: Recording, to folderName: String?) {
        let currentURL = getFileUrl(for: recording)
        let currentTxtURL = getTranscriptUrl(for: recording)
        let root = getRootURL()
        var destDir = root
        if let f = folderName { destDir = root.appendingPathComponent(f, isDirectory: true) }
        let destURL = destDir.appendingPathComponent(recording.fileName)
        let destTxtURL = destDir.appendingPathComponent(recording.fileName.replacingOccurrences(of: ".m4a", with: "_transcript.txt"))
        
        do {
            try FileManager.default.moveItem(at: currentURL, to: destURL)
            if FileManager.default.fileExists(atPath: currentTxtURL.path) {
                try FileManager.default.moveItem(at: currentTxtURL, to: destTxtURL)
            }
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
                recordings[index].folderName = folderName
            }
        } catch { print("Move failed: \(error)") }
    }
    
    func retryTranscription(recording: Recording) {
        // 1. Find the recording index
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            withAnimation {
                // 2. Reset state to show loading spinner
                recordings[index].isTranscribing = true
                // 3. Clear the error message so the transcript view updates
                recordings[index].transcript = nil
            }
        }
        
        // 4. Re-run the private transcription logic
        runTranscription(
            for: recording.fileName,
            folder: recording.folderName,
            context: "", // Retries usually don't have new context
            isEnhancing: false
        )
    }
    
    // In VoiceMemosModel.swift
    
    @discardableResult
    func saveNewRecording(fileName: String, duration: TimeInterval, folder: String?) -> UUID {
        // Note: 'fileName' is now "temp_raw.m4a"
        
        // 1. Source: The temporary file from the AudioRecorder
        let tempSourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        // 2. Destination: Determine the final folder and name
        let root = getRootURL()
        var destDir = root
        if let f = folder {
            destDir = root.appendingPathComponent(f, isDirectory: true)
        }
        
        // 3. Unique Naming Logic (this is correct)
        let baseName = "New Recording \(recordings.count + 1)"
        var finalName = baseName
        var counter = 1
        var destURL = destDir.appendingPathComponent("\(finalName).m4a")
        
        // Ensure the final name is unique in the destination directory
        while FileManager.default.fileExists(atPath: destURL.path) {
            finalName = "\(baseName) (\(counter))"
            destURL = destDir.appendingPathComponent("\(finalName).m4a")
            counter += 1
        }
        let finalFileName = destURL.lastPathComponent
        
        // 4. MOVE THE FILE from the temporary location to its final destination
        do {
            // Ensure the destination directory exists
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            try FileManager.default.moveItem(at: tempSourceURL, to: destURL)
            print("✅ Moved temporary file to: \(destURL.path)")
        } catch {
            print("❌ CRITICAL: Failed to move temporary file: \(error).")
            // Handle the error, maybe by deleting the temp file and showing an alert
            try? FileManager.default.removeItem(at: tempSourceURL)
            // You could return an empty UUID or handle this failure case as needed
            return UUID()
        }
        
        // 5. Create the model object and update the UI
        let newID = UUID()
        // Use the name *without* the file extension for the UI
        let newRec = Recording(id: newID, name: finalName, date: Date(), duration: duration, fileName: finalFileName, transcript: nil, folderName: folder, isTranscribing: true)
        
        // The directory monitor will eventually pick this up, but we add it manually
        // for an instant UI update. We disable the monitor briefly to prevent a double-add.
        self.suppressReloads = true
        withAnimation { recordings.insert(newRec, at: 0) }
        
        // Allow the directory monitor to resume after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.suppressReloads = false
        }
        
        // 6. RUN TRANSCRIPTION on the file at its new, final location
        runTranscription(for: finalFileName, folder: folder, context: "", isEnhancing: false)
        
        return newID
    }
    
    func enhanceTranscription(recording: Recording, context: String) {
        self.suppressReloads = true
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            withAnimation {
                recordings[index].isEnhancing = true // SET ENHANCING STATE
                recordings[index].isQueued = false
            }
        }
        runTranscription(for: recording.fileName, folder: recording.folderName, context: context, isEnhancing: true)
    }
    
    private func runTranscription(for fileName: String, folder: String?, context: String, isEnhancing: Bool) {
        let root = getRootURL()
        var destDir = root
        if let f = folder { destDir = root.appendingPathComponent(f, isDirectory: true) }
        let destURL = destDir.appendingPathComponent(fileName)
        
        transcriber.transcribeAudio(url: destURL, context: context, onQueued: { [weak self] in
            DispatchQueue.main.async {
                if let index = self?.recordings.firstIndex(where: { $0.fileName == fileName && $0.folderName == folder }) {
                    self?.recordings[index].isQueued = true
                    if isEnhancing {
                        self?.recordings[index].isEnhancing = false
                    } else {
                        self?.recordings[index].isTranscribing = false
                    }
                }
            }
        }, onUpdate: { [weak self] text in
            DispatchQueue.main.async {
                if let index = self?.recordings.firstIndex(where: { $0.fileName == fileName && $0.folderName == folder }) {
                    self?.recordings[index].isQueued = false
                    if isEnhancing {
                        self?.recordings[index].isEnhancing = true
                    } else {
                        self?.recordings[index].isTranscribing = true
                    }
                }
            }
        }, onCompletion: { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let index = self.recordings.firstIndex(where: { $0.fileName == fileName && $0.folderName == folder }) {
                    self.recordings[index].transcript = text
                    
                    // Reset states
                    self.recordings[index].isTranscribing = false
                    self.recordings[index].isEnhancing = false
                    self.recordings[index].isQueued = false
                    
                    let txtURL = destDir.appendingPathComponent(fileName.replacingOccurrences(of: ".m4a", with: "_transcript.txt"))
                    try? text.write(to: txtURL, atomically: true, encoding: .utf8)
                    
                    self.suppressReloads = false
                }
            }
        }, onError: { [weak self] errorMsg in
            DispatchQueue.main.async {
                print("Transcription Error: \(errorMsg)")
                if let index = self?.recordings.firstIndex(where: { $0.fileName == fileName && $0.folderName == folder }) {
                    // Reset states on error
                    self?.recordings[index].isTranscribing = false
                    self?.recordings[index].isEnhancing = false
                    self?.recordings[index].isQueued = false
                    
                    self?.recordings[index].transcript = "Failed: \(errorMsg)"
                    self?.suppressReloads = false
                }
            }
        })
    }
    
    func rename(_ recording: Recording, to newName: String) {
        let sanitized = newName.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>")).joined()
        let newFileName = sanitized + ".m4a"
        let newTxtName = sanitized + "_transcript.txt"
        let oldURL = getFileUrl(for: recording)
        let oldTxtURL = getTranscriptUrl(for: recording)
        let dir = oldURL.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent(newFileName)
        let newTxtURL = dir.appendingPathComponent(newTxtName)
        guard oldURL != newURL else { return }
        
        do {
            if let folder = customStorageURL { _ = folder.startAccessingSecurityScopedResource() }
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            if FileManager.default.fileExists(atPath: oldTxtURL.path) {
                try FileManager.default.moveItem(at: oldTxtURL, to: newTxtURL)
            }
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
                recordings[index].fileName = newFileName
                recordings[index].name = sanitized
            }
        } catch { print("Rename failed: \(error)") }
    }
    
    func delete(_ recording: Recording) {
        let url = getFileUrl(for: recording)
        let txtUrl = getTranscriptUrl(for: recording)
        let tagsUrl = getTagsFileUrl(for: recording)
        
        if let folder = customStorageURL { _ = folder.startAccessingSecurityScopedResource() }
        
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: txtUrl)
        try? FileManager.default.removeItem(at: tagsUrl)
        
        withAnimation {
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings.remove(at: index) }
            selectedRecordingIDs.remove(recording.id)
            if activeRecording?.id == recording.id { activeRecording = nil }
        }
    }
    
    func duplicate(_ recording: Recording) {
        let newRec = Recording(id: UUID(), name: recording.name + " Copy", date: Date(), duration: recording.duration, fileName: recording.fileName, transcript: recording.transcript, isFavorite: recording.isFavorite, folderName: recording.folderName)
        withAnimation { recordings.insert(newRec, at: 0) }
    }
    
    func toggleFavorite(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index].isFavorite.toggle() }
    }
    
    func toggleSelection(for id: UUID) {
        if selectedRecordingIDs.contains(id) { selectedRecordingIDs.remove(id) }
        else { selectedRecordingIDs.insert(id) }
    }
    
    func filteredRecordings(for folder: String?) -> [Recording] {
        let list = folder == nil ? recordings : recordings.filter { $0.folderName == folder }
        if searchText.isEmpty { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    func resetChat() {
        withAnimation { chatHistory.removeAll(); activeCitation = nil }
    }
    
    func countForFolder(_ name: String) -> Int {
        recordings.filter { $0.folderName == name }.count
    }
    
    func getTagsFileUrl(for recording: Recording) -> URL {
        let audioUrl = getFileUrl(for: recording)
        let jsonName = audioUrl.deletingPathExtension().lastPathComponent + "_tags.json"
        return audioUrl.deletingLastPathComponent().appendingPathComponent(jsonName)
    }
    
    func updateSegmentTags(recordingID: UUID, startTime: TimeInterval, tags: [Tag]) {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        
        // Update the model in memory
        // We use the startTime as the key to associate tags with a specific line
        let key = String(startTime)
        recordings[index].tags[key] = tags
        
        // Save to disk
        saveTagsToDisk(recording: recordings[index])
    }
    
    // MARK: - GLOBAL TAG UPDATES
    
    // MARK: - GLOBAL TAG UPDATES
    
    func updateGlobalTag(_ updatedTag: Tag) {
        // 1. Update OR Insert into Global Library (coding_database.json)
        if let index = savedCodes.firstIndex(where: { $0.id == updatedTag.id }) {
            // Update existing
            savedCodes[index] = updatedTag
        } else {
            // It wasn't in the library yet (legacy tag), so add it now
            savedCodes.append(updatedTag)
        }
        
        // ALWAYS save the database
        saveDatabase()
        print("🌎 Updated Global Library (coding_database.json)")
        
        // 2. Iterate through ALL recordings to find and update this tag
        for i in 0..<recordings.count {
            var recordingChanged = false
            var currentTags = recordings[i].tags
            
            // Check every timestamp key in this recording
            for (timestamp, tagsList) in currentTags {
                if let tagIndex = tagsList.firstIndex(where: { $0.id == updatedTag.id }) {
                    // FOUND IT! Update the properties
                    currentTags[timestamp]?[tagIndex] = updatedTag
                    recordingChanged = true
                }
            }
            
            // 3. If we found the tag in this recording, save the file to disk
            if recordingChanged {
                recordings[i].tags = currentTags
                saveTagsToDisk(recording: recordings[i])
                // print("   -> Updated tag in recording: \(recordings[i].name)")
            }
        }
        
        // 4. Force UI Refresh
        objectWillChange.send()
    }
    
    func saveTagsToDisk(recording: Recording) {
        let url = getTagsFileUrl(for: recording)
        do {
            let data = try JSONEncoder().encode(recording.tags)
            try data.write(to: url)
            // print("Saved tags to \(url.lastPathComponent)")
        } catch {
            print("Failed to save tags: \(error)")
        }
    }
    
    func getCitation(for index: Int) -> Citation? {
        
        let selectedRecs = sortedSelectedRecordings
        
        // We simulate the loop to see exactly where the index falls
        var remainingIndex = index - 1 // Convert 1-based citation to 0-based math
        var globalCounter = 0
        
        for rec in selectedRecs {
            let segments = rec.sentenceSegments
            // Your logic counts the "Header" as 1 index, plus the segments
            let countInRecording = segments.count + 1
            
            _ = globalCounter + 1
            _ = globalCounter + countInRecording
            
            // Check if the requested index falls inside this recording
            if remainingIndex < countInRecording {
                let segmentIndex = max(0, remainingIndex - 1) // -1 because index 0 is the Header
                
                print("   ✅ FOUND! Index [\(index)] maps to segment index \(segmentIndex) in '\(rec.name)'")
                print("   • Time: \(parseTimestamp(from: segments.indices.contains(segmentIndex) ? segments[segmentIndex] : "N/A"))")
                print("-------------------------------------------\n")
                
                if segmentIndex < segments.count {
                    let segmentText = segments[segmentIndex]
                    return Citation(
                        index: index,
                        startTime: parseTimestamp(from: segmentText),
                        speaker: parseSpeaker(from: segmentText),
                        text: segmentText,
                        recordingID: rec.id
                    )
                } else {
                    print("   ⚠️ FOUND, but segmentIndex \(segmentIndex) is out of bounds for array size \(segments.count)")
                    // This happens if the user taps the "Header" citation usually
                }
            } else {
                print("   ⏭️ Not in this file. (Need index \(remainingIndex), but file only has \(countInRecording) items)")
            }
            
            remainingIndex -= countInRecording
            globalCounter += countInRecording
        }
        
        print("❌ FAILURE: The AI cited [\(index)], but your total valid lines only go up to [\(globalCounter)].")
        print("   -> PROOF: The AI hallucinated a number higher than your actual line count.")
        print("-------------------------------------------\n")
        return nil
    }
    
    private func parseTimestamp(from text: String) -> TimeInterval {
        guard let regex = VoiceMemosModel.timestampRegex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return 0
        }
        
        let range1 = Range(match.range(at: 1), in: text)!
        let range2 = Range(match.range(at: 2), in: text)!
        
        if let min = Double(text[range1]), let sec = Double(text[range2]) {
            return (min * 60) + sec
        }
        return 0
    }
    
    private func parseSpeaker(from text: String) -> String {
        let components = text.components(separatedBy: ": ")
        if components.count > 1 {
            let prefix = components[0]
            if let bracketEnd = prefix.lastIndex(of: "]") {
                let nameStart = prefix.index(after: bracketEnd)
                return String(prefix[nameStart...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return "Speaker"
    }
    
    func isBatchSelected(folder: String?) -> Bool {
        let scope = folder == nil ? recordings : recordings.filter { $0.folderName == folder }
        guard !scope.isEmpty else { return false }
        
        let scopeIDs = Set(scope.map { $0.id })
        return scopeIDs.isSubset(of: selectedRecordingIDs)
    }
    
    func toggleBatchSelection(folder: String?) {
        let state = getSelectionState(folder: folder)
        let scope = folder == nil ? recordings : recordings.filter { $0.folderName == folder }
        let scopeIDs = Set(scope.map { $0.id })
        
        switch state {
        case .all, .some:
            selectedRecordingIDs.subtract(scopeIDs)
        case .none:
            // If Empty -> SELECT ALL (Additive)
            selectedRecordingIDs.formUnion(scopeIDs)
        }
    }
}

// MARK: - 8. AUDIO ENGINE

@MainActor
class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVAudioRecorderDelegate {
    
    // MARK: - PUBLISHED STATE
    @Published var isRecording = false
    @Published var recordingError: String?
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioSamples: [CGFloat] = Array(repeating: 0.1, count: 50)
    
    // MARK: - LIVE ACTIVITY STATE
#if os(iOS) && !targetEnvironment(macCatalyst)
    private var currentActivity: Activity<RecordingAttributes>? = nil
#endif
    
    // MARK: - INTERNAL PROPERTIES
    var lastSavedURL: URL?
    private var timer: Timer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    // CRITICAL FIX: Store the completion handler here
    private var onFinishRecording: (() -> Void)?
    
    // MARK: - MAC SPECIFIC PROPERTIES
    private var assetWriter: AVAssetWriter?
    private var audioMicInput: AVAssetWriterInput?
    private var audioAppInput: AVAssetWriterInput?
    private var isWritingStarted = false
    private var startTime: CMTime = .invalid
    private let writerQueue = DispatchQueue(label: "com.yourapp.writerQueue")
    
#if targetEnvironment(macCatalyst)
    private var scStream: SCStream?
    private var micSession: AVCaptureSession?
    private var scOutputHandler: SCKOutputHandler?
#endif
    
    // MARK: - iOS SPECIFIC PROPERTIES
    private var iosRecorder: AVAudioRecorder?
    private var isStopping = false
    private var recordingStartTime: Date?
    
    // MARK: - PUBLIC API
    
    func startRecording() {
        let handlePermission: (Bool) -> Void = { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                guard allowed else {
                    print("⚠️ Microphone permission denied")
                    self.recordingError = "Microphone permission was denied. Please enable it in the Settings app."
                    return
                }
                
                self.isStopping = false
                self.recordingDuration = 0
                self.audioSamples = Array(repeating: 0.1, count: 50)
                self.recordingStartTime = Date()
                self.isWritingStarted = false
                self.startTime = .invalid
                
                let rawFileName = "temp_raw.m4a"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(rawFileName)
                self.lastSavedURL = url
                print("Attempting to record to temporary path: \(url.path)")
                try? FileManager.default.removeItem(at: url)
                
#if targetEnvironment(macCatalyst)
                self.setupMacEngine(url: url)
#else
                self.setupiOSEngine(url: url)
                self.startLiveActivity()
#endif
            }
        }
        
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: handlePermission)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(handlePermission)
        }
    }
    
    func stopRecording(completion: @escaping (String?, TimeInterval) -> Void) {
        guard !isStopping else { return }
        isStopping = true
        
        if let start = self.recordingStartTime {
            self.recordingDuration = Date().timeIntervalSince(start)
        }
        let finalDuration = self.recordingDuration
        self.timer?.invalidate()
        
        Task { @MainActor in
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
            
            let finishClosure: () -> Void = {
                Task { @MainActor in
                    self.isRecording = false
                    guard let rawURL = self.lastSavedURL else {
                        completion(nil, 0)
                        self.endBackgroundTask()
                        return
                    }
                    completion(rawURL.lastPathComponent, finalDuration)
                    self.endBackgroundTask()
                }
            }
            
#if targetEnvironment(macCatalyst)
            stopMacEngine(completion: finishClosure)
#else
            stopiOSEngine(completion: finishClosure)
            stopLiveActivity()
#endif
        }
    }
    
    @MainActor
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                if let start = self.recordingStartTime {
                    self.recordingDuration = Date().timeIntervalSince(start)
                }
                self.updateMeters()
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    private func updateMeters() {
        var level: CGFloat = 0.1
#if targetEnvironment(macCatalyst)
        level = CGFloat.random(in: 0.1...0.5)
#else
        if let rec = self.iosRecorder {
            rec.updateMeters()
            let power = rec.averagePower(forChannel: 0)
            level = CGFloat(max(0.1, (power + 60) / 60))
        }
#endif
        var newSamples = self.audioSamples
        newSamples.removeFirst()
        newSamples.append(level)
        withAnimation(.linear(duration: 0.05)) { self.audioSamples = newSamples }
    }
    
    // MARK: - 🖥️ MAC ENGINE (Simplified for brevity, logic unchanged)
#if targetEnvironment(macCatalyst)
    private func setupMacEngine(url: URL) {
        // ... (Keep your Mac engine code here if needed, usually same as before)
        // Since the critical error is iOS based, I will focus on that,
        // but ensuring the structure remains valid for your copy-paste:
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch { return }
        
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000]
        audioMicInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioMicInput?.expectsMediaDataInRealTime = true
        audioAppInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioAppInput?.expectsMediaDataInRealTime = true
        
        if let w = assetWriter {
            if w.canAdd(audioMicInput!) { w.add(audioMicInput!) }
            if w.canAdd(audioAppInput!) { w.add(audioAppInput!) }
        }
        
        Task {
            if await AVCaptureDevice.requestAccess(for: .audio) {
                self.micSession = AVCaptureSession()
                if let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic) {
                    if micSession!.canAddInput(input) { micSession!.addInput(input) }
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "micQueue"))
                    if micSession!.canAddOutput(output) { micSession!.addOutput(output) }
                }
                DispatchQueue.global(qos: .userInitiated).async { self.micSession?.startRunning() }
            }
            
            do {
                let content = try await SCShareableContent.current
                if let display = content.displays.first {
                    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.capturesAudio = true; config.sampleRate = 48000; config.excludesCurrentProcessAudio = false; config.channelCount = 1; config.width = 100; config.height = 100
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                    self.scStream = SCStream(filter: filter, configuration: config, delegate: nil)
                    self.scOutputHandler = SCKOutputHandler(parent: self)
                    try await self.scStream?.addStreamOutput(self.scOutputHandler!, type: .audio, sampleHandlerQueue: DispatchQueue(label: "scAudioQueue"))
                    try await self.scStream?.startCapture()
                    DispatchQueue.main.async { self.isRecording = true; self.startTimer() }
                }
            } catch { print(error) }
        }
    }
    
    private func stopMacEngine(completion: @escaping () -> Void) {
        Task {
            try? await scStream?.stopCapture()
            micSession?.stopRunning()
            self.scOutputHandler = nil
            if let writer = assetWriter, writer.status == .writing {
                audioMicInput?.markAsFinished(); audioAppInput?.markAsFinished()
                await writer.finishWriting()
            }
            // Simple callback for Mac since we use AVAssetWriter
            completion()
        }
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        Task { @MainActor in self.processBuffer(sampleBuffer, isMic: true) }
    }
    
    private class SCKOutputHandler: NSObject, SCStreamOutput {
        weak var parent: AudioRecorder?
        init(parent: AudioRecorder) { self.parent = parent }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio else { return }
            Task { @MainActor in self.parent?.processBuffer(sampleBuffer, isMic: false) }
        }
    }
    
    private func processBuffer(_ buffer: CMSampleBuffer, isMic: Bool) {
        guard let writer = assetWriter else { return }
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isWritingStarted {
                writer.startWriting()
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                writer.startSession(atSourceTime: pts)
                self.startTime = pts
                self.isWritingStarted = true
            }
            if writer.status == .writing {
                let input = isMic ? self.audioMicInput : self.audioAppInput
                if let input = input, input.isReadyForMoreMediaData { input.append(buffer) }
            }
        }
    }
#endif
    
    // MARK: - 📱 iOS ENGINE (FIXED)
    
    private func setupiOSEngine(url: URL) {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
            
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: session.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            iosRecorder = try AVAudioRecorder(url: url, settings: settings)
            iosRecorder?.delegate = self // CRITICAL FIX: Set Delegate
            iosRecorder?.isMeteringEnabled = true
            
            if iosRecorder?.record() == true {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.startTimer()
                }
                startLiveActivity()
            } else {
                DispatchQueue.main.async { self.recordingError = "Failed to start recording." }
            }
            
            setupInterruptionObserver()
        } catch {
            DispatchQueue.main.async { self.recordingError = "Audio Error: \(error.localizedDescription)" }
        }
    }
    
    private func stopiOSEngine(completion: @escaping () -> Void) {
        // CRITICAL FIX: We do NOT call completion here.
        // We store it, stop the recorder, and wait for the delegate callback.
        self.onFinishRecording = completion
        iosRecorder?.stop()
    }
    
    // CRITICAL FIX: The Delegate method
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.iosRecorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            
            // Fire the stored callback now that file is effectively closed
            self.onFinishRecording?()
            self.onFinishRecording = nil
            
            if !flag { print("⚠️ Audio finished unsuccessfully") }
        }
    }
    
    private func setupInterruptionObserver() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let self = self, let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            
            if type == .ended {
                Task { @MainActor in
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.iosRecorder?.record()
                }
            }
        }
    }
    
    // MARK: - LIVE ACTIVITY HELPERS
    private func startLiveActivity() {
#if os(iOS) && !targetEnvironment(macCatalyst)
        // Keep your existing Live Activity logic here
        // If RecordingAttributes is active in your project:
        /*
        let attributes = RecordingAttributes(recordingName: "New Recording")
        let state = RecordingAttributes.ContentState(recordingStartDate: Date())
        Task {
            try? await Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil), pushType: nil)
        }
        */
#endif
    }
    
    private func stopLiveActivity() {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            self.currentActivity = nil
        }
#endif
    }
}

@MainActor
class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var currentRecordingId: UUID?
    var audioPlayer: AVAudioPlayer?
    var timer: Timer?
    
    func play(url: URL, recordingId: UUID, startTime: TimeInterval = 0) {
        let session = AVAudioSession.sharedInstance()
        
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true)
        } catch {
            print("Playback Session Error: \(error)")
        }
        
        if currentRecordingId != recordingId || audioPlayer == nil {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.delegate = self
                audioPlayer?.prepareToPlay()
                currentRecordingId = recordingId
            } catch {
                print("Playback failed: \(error)")
                return
            }
        }
        
        audioPlayer?.currentTime = startTime
        audioPlayer?.play()
        isPlaying = true
        startTimer()
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        timer?.invalidate()
    }
    
    func stop() {
        audioPlayer?.stop()
        isPlaying = false
        timer?.invalidate()
        currentTime = 0
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if let p = self.audioPlayer {
                    withAnimation(.linear(duration: 0.1)) {
                        self.currentTime = p.currentTime
                    }
                }
            }
        }
    }
    
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
        }
    }
}

// MARK: - DICTATION HELPER
@MainActor
class DictationViewModel: ObservableObject {
    @Published var text = ""
    @Published var isRecording = false
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }
    
    func startRecording() {
        guard !isRecording else { return }
        // Reset
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            
            // <--- 2. WRAP THIS IN DISPATCH QUEUE MAIN ASYNC --->
            DispatchQueue.main.async {
                if let result = result {
                    self.text = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stopRecording()
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true
    }
    
    func stopRecording() {
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false
    }
}

// MARK: - 9. VIEWS (UI COMPONENTS)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrangeSubviews(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? 0, height: rows.last?.maxY ?? 0)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangeSubviews(proposal: proposal, subviews: subviews)
        for row in rows {
            for element in row.elements {
                element.subview.place(at: CGPoint(x: bounds.minX + element.x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }
    
    struct Row {
        var elements: [Element] = []
        var y: CGFloat = 0
        var maxY: CGFloat = 0
    }
    
    struct Element {
        var subview: LayoutSubview
        var x: CGFloat
    }
    
    func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0
        let maxWidth = proposal.width ?? 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if x + size.width > maxWidth && !currentRow.elements.isEmpty {
                // Move to next row
                y += currentRow.maxY + spacing
                rows.append(currentRow)
                currentRow = Row()
                currentRow.y = y
                x = 0
            }
            
            currentRow.elements.append(Element(subview: subview, x: x))
            currentRow.maxY = max(currentRow.maxY, size.height)
            x += size.width + spacing
        }
        
        if !currentRow.elements.isEmpty {
            rows.append(currentRow)
        }
        
        return rows
    }
}

struct ScrubberBar: View {
    @Binding var current: TimeInterval
    let total: TimeInterval
    @State private var isDragging = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(height: isDragging ? 12 : 6)
                let ratio = total > 0 ? current / total : 0
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * ratio, height: isDragging ? 12 : 6)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        withAnimation(.interactiveSpring()) { isDragging = true }
                        let ratio = min(max(0, value.location.x / geo.size.width), 1)
                        current = ratio * total
                    }
                    .onEnded { _ in withAnimation(.interactiveSpring()) { isDragging = false } }
            )
        }.frame(height: 20)
    }
}

struct ContentView: View {
    @StateObject var model = VoiceMemosModel()
    @StateObject var globalPlayer = AudioPlayer()
    
    var tabSelection: Binding<Int> {
        Binding(get: { model.selectedTab }, set: { if $0 == model.selectedTab && $0 == 1 { model.analysisTabSelection = .chat }; model.selectedTab = $0 })
    }
    
    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack { FoldersView() }.environmentObject(model).tabItem { Label("Recordings", systemImage: "waveform") }.tag(0)
            AnalysisMainView().environmentObject(model).tabItem { Label("Analysis", systemImage: "sparkles.rectangle.stack") }.tag(1)
        }
        .accentColor(.blue)
        // GLOBAL SHEET for Playback/Analysis Detail
        .fullScreenCover(item: $model.playbackRequest, onDismiss: {
            globalPlayer.stop()
        }) { request in
            RecordingDetailSheet(
                recording: request.recording,
                showTranscriptInitially: true,
                player: globalPlayer,
                model: model,
                initialSeekTime: request.time
            )
        }
    }
}

struct SettingsView: View {
    @AppStorage("GEMINI_API_KEY") private var apiKey = ""
    @AppStorage("audioInputUID") private var selectedInputUID = "" // Store unique ID of device
    
    @EnvironmentObject var model: VoiceMemosModel
    @Environment(\.dismiss) var dismiss
    
    @State private var showFolderPicker = false
    @State private var availableInputs: [AVAudioSessionPortDescription] = []
    
    var body: some View {
        NavigationStack {
            Form {
                storageSection
                audioSourceSection
                apiKeySection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            // Explicitly handle result as [URL] to help compiler
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        model.setCustomStorageLocation(url)
                    }
                case .failure(let error):
                    print("File importer error: \(error.localizedDescription)")
                }
            }
            .onAppear {
                refreshAudioInputs()
            }
        }
    }
    
    // MARK: - Subviews (Extracted to fix compiler error)
    
    private var storageSection: some View {
        Section(header: Text("Storage Location")) {
            HStack {
                Image(systemName: model.storageLocationName == "On My iPhone" ? "iphone" : "externaldrive.fill")
                    .foregroundColor(.blue)
                    .frame(width: 24)
                
                VStack(alignment: .leading) {
                    Text(model.storageLocationName)
                        .foregroundColor(.primary)
                    if model.storageLocationName != "On My iPhone" {
                        Text("External Drive").font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if model.storageLocationName != "On My iPhone" {
                    Button(action: { model.resetStorageLocation() }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
            Button("Change Location...") { showFolderPicker = true }
        }
    }
    
    private var audioSourceSection: some View {
        Section(
            header: Text("Audio Source"),
            footer: Text("Select which microphone to use. If the selected device disconnects, the app will revert to the iPhone microphone.")
        ) {
            if availableInputs.isEmpty {
                Text("Loading audio devices...")
                    .foregroundColor(.secondary)
            } else {
                ForEach(availableInputs, id: \.uid) { input in
                    Button(action: {
                        selectedInputUID = input.uid
                    }) {
                        HStack {
                            // Dynamic Icon based on device type/name
                            Image(systemName: getIconForPort(input))
                                .foregroundColor(.blue)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading) {
                                Text(input.portName)
                                    .foregroundColor(.primary)
                                Text(getDescriptionForPort(input))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if selectedInputUID == input.uid {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                                    .font(.body.bold())
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var apiKeySection: some View {
        Group {
            Section(header: Text("AI KEY")) {
                SecureField("Enter API Key", text: $apiKey)
            }
            Section {
                Button("Clear Key") { apiKey = "" }
                    .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Helpers
    
    func refreshAudioInputs() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
            self.availableInputs = session.availableInputs ?? []
            
            // Auto-select default if empty
            if selectedInputUID.isEmpty, let first = availableInputs.first {
                selectedInputUID = first.uid
            }
        } catch {
            print("Error fetching inputs: \(error)")
        }
    }
    
    func getIconForPort(_ port: AVAudioSessionPortDescription) -> String {
        let name = port.portName.lowercased()
        let type = port.portType
        
        if name.contains("max") { return "airpods.max" }
        if name.contains("pro") { return "airpods.pro" }
        if name.contains("gen 3") { return "airpods.gen3" }
        
        // Safe availability check
        if #available(iOS 18, *) {
            if name.contains("gen 4") { return "airpods.gen4" }
        }
        
        switch type {
        case .builtInMic: return "mic.fill"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            if name.contains("hearing") || name.contains("aid") {
                return "hearingdevice.ear"
            }
            return "airpods"
        case .headphones, .headsetMic: return "headphones"
        case .carAudio: return "car.fill"
        default: return "waveform.path"
        }
    }
    
    func getDescriptionForPort(_ port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInMic: return "Internal iPhone Microphone"
        case .bluetoothHFP, .bluetoothLE: return "Bluetooth Device"
        default: return "External Audio"
        }
    }
}

struct FoldersView: View {
    @EnvironmentObject var model: VoiceMemosModel
    @State private var showSettings = false
    @State private var showFolderSheet = false
    
    var body: some View {
        List {
            Section {
                NavigationLink(destination: AllRecordingsView(folderFilter: nil)) {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundColor(.blue)
                            .frame(width: 30)
                        Text("All Recordings")
                        Spacer()
                        Text("\(model.allCount)").foregroundColor(.secondary)
                    }
                }
            }
            
            // My Folders
            if !model.userFolders.isEmpty {
                Section(header: Text("My Folders")) {
                    ForEach(model.userFolders, id: \.self) { folder in
                        NavigationLink(destination: AllRecordingsView(folderFilter: folder)) {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundColor(.blue)
                                    .frame(width: 30)
                                Text(folder)
                                Spacer()
                                Text("\(model.countForFolder(folder))").foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: model.deleteFolder)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Voice Memos")
        .onAppear {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = UIColor.systemGroupedBackground
            appearance.shadowColor = .clear
            appearance.shadowImage = UIImage()
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
            if #available(iOS 15.0, *) {
                UINavigationBar.appearance().compactScrollEdgeAppearance = appearance
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: { showFolderSheet = true }) {
                        Image(systemName: "folder.badge.plus")
                    }
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showFolderSheet) {
            FolderSelectionSheet(isMoving: false, recording: nil, autoCreate: true)
                .environmentObject(model)
        }
    }
}

struct FolderSelectionSheet: View {
    @EnvironmentObject var model: VoiceMemosModel
    @Environment(\.dismiss) var dismiss
    
    let isMoving: Bool
    let recording: Recording?
    
    // New property to trigger immediate creation
    var autoCreate: Bool = false
    
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                List {
                    Section {
                        if isMoving {
                            Button(action: {
                                if let rec = recording {
                                    model.moveRecording(rec, to: nil)
                                    dismiss()
                                }
                            }) {
                                HStack {
                                    Image(systemName: "waveform").foregroundColor(.blue).frame(width: 30)
                                    Text("All Recordings")
                                    Spacer()
                                    Text("\(model.allCount)").foregroundColor(.secondary)
                                }
                            }.foregroundColor(.primary)
                        }
                        
                        HStack {
                            Image(systemName: "trash").foregroundColor(.blue).frame(width: 30)
                            Text("Recently Deleted")
                            Spacer()
                            Text("0").foregroundColor(.secondary)
                        }.foregroundColor(.primary)
                    }
                    
                    if !model.userFolders.isEmpty {
                        Section(header: Text("My Folders")) {
                            ForEach(model.userFolders, id: \.self) { folder in
                                Button(action: {
                                    if isMoving, let rec = recording {
                                        model.moveRecording(rec, to: folder)
                                        dismiss()
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "folder").foregroundColor(.blue).frame(width: 30)
                                        Text(folder)
                                        Spacer()
                                        Text("\(model.countForFolder(folder))").foregroundColor(.secondary)
                                    }
                                }.foregroundColor(.primary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                
                // Bottom Bar
                HStack {
                    Spacer()
                    Button(action: { isCreatingFolder = true }) {
                        Image(systemName: "folder.badge.plus")
                            .font(.title2)
                            .foregroundColor(.blue)
                            .padding()
                    }
                }
                .background(.regularMaterial)
            }
            .navigationTitle(isMoving ? "Select a Folder" : "All Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) { Image(systemName: "xmark").foregroundColor(.gray).font(.subheadline.weight(.bold)).padding(6).background(Color(UIColor.secondarySystemBackground)).clipShape(Circle()) }
                }
            }
            // Trigger the alert immediately if autoCreate is true
            .onAppear {
                if autoCreate {
                    // Small delay ensures the view hierarchy is ready for the alert
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isCreatingFolder = true
                    }
                }
            }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Name", text: $newFolderName)
                Button("Cancel", role: .cancel) {
                    newFolderName = ""
                    // If we were auto-creating and cancelled, we should probably dismiss the whole sheet
                    if autoCreate { dismiss() }
                }
                Button("Save") {
                    if !newFolderName.isEmpty {
                        model.createFolder(name: newFolderName)
                        newFolderName = ""
                        // If we were auto-creating, dismiss after save
                        if autoCreate { dismiss() }
                    }
                }
            } message: {
                Text("Enter a name for this folder.")
            }
        }
        .presentationDetents([.large])
    }
}

struct AllRecordingsView: View {
    let initialFolder: String?
    @State private var activeFolder: String?
    
    @EnvironmentObject var model: VoiceMemosModel
    @StateObject var recorder = AudioRecorder()
    @StateObject var player = AudioPlayer()
    
    @State private var expandedRecordingId: UUID?
    @State private var renamingRecordingId: UUID?
    @State private var editConfig: EditConfig?
    @State private var moveConfig: Recording?
    @State private var sheetDetent = PresentationDetent.large
    
    @State private var renameFolderAlert = false
    @State private var newFolderName = ""
    
    private let smoothPhysics = Animation.spring(response: 0.35, dampingFraction: 1.0, blendDuration: 0)
    
    init(folderFilter: String?) {
        self.initialFolder = folderFilter
        _activeFolder = State(initialValue: folderFilter)
    }
    
    var displayTitle: String {
        activeFolder ?? "All Recordings"
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredRecordings(for: activeFolder)) { recording in
                        makeRow(for: recording)
                    }
                }
                .padding(.top, 10)
            }
            .background(Color(UIColor.systemGroupedBackground))
            
            if !recorder.isRecording {
                Button(action: {
                    withAnimation(.spring()) {
                        recorder.startRecording()
                    }
                }) {
                    Circle().fill(Color.red).frame(width: 64, height: 64)
                        .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 3))
                }
                .padding(.bottom, 20)
            }
        }
        .navigationTitle(displayTitle)
        .toolbar {
            if let folderName = activeFolder {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: {
                            newFolderName = folderName
                            renameFolderAlert = true
                        }) {
                            Label("Rename", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .alert("Rename Folder", isPresented: $renameFolderAlert) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { }
            Button("Done") {
                if let oldName = activeFolder, !newFolderName.isEmpty {
                    model.renameFolder(from: oldName, to: newFolderName)
                    activeFolder = newFolderName
                }
            }
        }
        .sheet(isPresented: $recorder.isRecording) {
            CurrentRecordingSheet(recorder: recorder) { f, d in let newID = model.saveNewRecording(fileName: f, duration: d, folder: activeFolder); withAnimation { expandedRecordingId = newID } }
                .presentationDetents([.large]).interactiveDismissDisabled()
        }
        .fullScreenCover(item: $editConfig) { c in
            RecordingDetailSheet(recording: c.recording, showTranscriptInitially: c.showTranscriptInitially, player: player, model: model)
        }
        .sheet(item: $moveConfig) { rec in
            FolderSelectionSheet(isMoving: true, recording: rec)
        }
        .alert("Recording Error", isPresented: .constant(recorder.recordingError != nil), actions: {
            Button("OK", role: .cancel) {
                recorder.recordingError = nil
            }
        }, message: {
            Text(recorder.recordingError ?? "An unknown error occurred.")
        })
    }
    
    // Extracted function to solve "compiler unable to type-check"
    @ViewBuilder
    func makeRow(for recording: Recording) -> some View {
        VStack(spacing: 0) {
            SwipeableRow(onDelete: { model.delete(recording) }) {
                RecordingRow(
                    recording: recording,
                    audioURL: model.getFileUrl(for: recording),
                    isExpanded: expandedRecordingId == recording.id,
                    isRenaming: renamingRecordingId == recording.id,
                    player: player,
                    onTap: {
                        withAnimation(smoothPhysics) {
                            if expandedRecordingId == recording.id {
                                expandedRecordingId = nil
                                player.pause()
                            } else {
                                expandedRecordingId = recording.id
                                model.activeRecording = recording
                                let url = model.getFileUrl(for: recording)
                                try? player.audioPlayer = AVAudioPlayer(contentsOf: url)
                                player.currentRecordingId = recording.id
                                player.pause()
                                player.seek(to: 0)
                            }
                        }
                    },
                    onRename: { renamingRecordingId = recording.id },
                    onCommitRename: { model.rename(recording, to: $0); renamingRecordingId = nil },
                    onDelete: { model.delete(recording) },
                    onPlay: {
                        let url = model.getFileUrl(for: recording)
                        if player.currentRecordingId == recording.id && player.isPlaying {
                            player.pause()
                        } else {
                            player.play(url: url, recordingId: recording.id)
                        }
                    },
                    onEdit: { editConfig = EditConfig(recording: recording, showTranscriptInitially: true) },
                    onToggleFavorite: { model.toggleFavorite(recording) },
                    onMove: { moveConfig = recording }
                )
            }
            Divider()
                .background(Color(UIColor.separator))
                .padding(.leading, 16)
        }
    }
}

// MARK: - Transcript Skeleton
struct TranscriptSkeleton: View {
    @State private var opacity = 0.3
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<8) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 16)
                    .frame(maxWidth: CGFloat.random(in: 200...350))
                    .opacity(opacity)
            }
        }
        .padding()
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                opacity = 0.6
            }
        }
    }
}

// Helper view to animate the waveform based on time
struct LiveWaveformView: View {
    var isPlaying: Bool
    var currentTime: TimeInterval
    
    // We use a simple sine wave math function to simulate movement based on time
    func height(for index: Int) -> CGFloat {
        if !isPlaying { return 20 } // Static height when paused
        
        // Create a wave effect: sin(time + index)
        // We add randomization so it looks like voice frequencies, not a perfect sine wave
        let t = currentTime * 8.0 // Speed
        let i = Double(index)
        let wave = sin(t + i * 0.5)
        let randomScale = Double.random(in: 0.5...1.5) // Jitter
        
        // Map -1...1 to 10...80 range
        let baseHeight = (wave + 1) * 20 + 10
        return CGFloat(max(10, min(100, baseHeight * randomScale))) // Clamp height
    }
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<40, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue.gradient)
                    .frame(width: 3)
                    .frame(height: height(for: index))
                    .animation(.linear(duration: 0.1), value: currentTime)
            }
        }
        .frame(height: 160)
        .drawingGroup() // Metal optimization for many animations
    }
}

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    
    // 1. Add EnvironmentObject to access the global attribute types
    @EnvironmentObject var model: VoiceMemosModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segment.text)
                .font(.body)
                .lineSpacing(6)
            
            // Display Tags inline
            if !segment.tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(segment.tags) { tag in
                        
                        // 2. Updated Tag Display Logic
                        HStack(spacing: 4) {
                            // Check if this tag is an attribute AND has a symbol assigned
                            if tag.isAttribute,
                               let typeID = tag.attributeTypeID,
                               let type = model.attributeTypes.first(where: { $0.id == typeID }),
                               !type.symbol.isEmpty {
                                
                                Text(type.symbol)
                                    .font(.caption2) // Emoji size
                            }
                            
                            // The Tag Name
                            Text(tag.text)
                        }
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(uiColor: .systemGray5)))
                        .foregroundColor(Color.tagColors.indices.contains(tag.colorIndex) ? Color.tagColors[tag.colorIndex] : .blue)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
                .animation(.easeInOut(duration: 0.2), value: isActive || isSelected)
        )
        .contentShape(Rectangle())
        
#if targetEnvironment(macCatalyst)
        .onTapGesture {
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.impactOccurred()
            onLongPress()
        }
#else
        .onTapGesture(perform: onTap)
        .onLongPressGesture {
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.impactOccurred()
            onLongPress()
        }
#endif
    }
    
    private var backgroundColor: Color {
        if isSelected { return Color.blue.opacity(0.15) }
        if isActive { return Color.yellow.opacity(0.3) }
        return Color.clear
    }
}

struct RecordingDetailSheet: View {
    let recordingId: UUID
    @State var showTranscriptInitially: Bool
    @ObservedObject var player: AudioPlayer
    @ObservedObject var model: VoiceMemosModel
    @Environment(\.dismiss) var dismiss
    
    var initialSeekTime: TimeInterval? = nil
    
    @State private var isShowingTranscript: Bool = true
    @State private var isRotating = false
    @State private var showEnhanceSheet = false
    @State private var transcriptSegments: [TranscriptSegment] = []
    
    // Selection State
    @State private var selectedSegmentID: UUID? = nil
    @State private var sheetSegmentIndex: Int? = nil
    
    init(recording: Recording, showTranscriptInitially: Bool, player: AudioPlayer, model: VoiceMemosModel, initialSeekTime: TimeInterval? = nil) {
        self.recordingId = recording.id
        self._showTranscriptInitially = State(initialValue: showTranscriptInitially)
        self.player = player
        self.model = model
        self.initialSeekTime = initialSeekTime
    }
    
    var liveRecording: Recording? {
        model.recordings.first(where: { $0.id == recordingId })
    }
    
    var isCurrentPlayerItem: Bool {
        player.currentRecordingId == recordingId
    }
    
    var activeSegmentId: UUID? {
        guard isCurrentPlayerItem else { return nil }
        return transcriptSegments.first { segment in
            player.currentTime >= segment.startTime && player.currentTime < segment.endTime
        }?.id
    }
    
    var body: some View {
        NavigationStack {
            if let recording = liveRecording {
                VStack(spacing: 0) {
                    headerView(for: recording)
                    
                    metadataView(for: recording)
                    
                    // Main Content Area
                    ZStack(alignment: .bottom) {
                        if isShowingTranscript {
                            transcriptView(for: recording)
                        } else {
                            waveformView
                        }
                        
                        bottomControls(for: recording)
                    }
                }
                .navigationBarHidden(true)
                .ignoresSafeArea(edges: .bottom)
                .onAppear { setupView(recording) }
                .onChange(of: recording.transcript) { _, newText in parseTranscript(newText) }
                .sheet(isPresented: $showEnhanceSheet) {
                    EnhancePromptView(
                        recordingName: recording.name,
                        onCommit: { context in
                            model.enhanceTranscription(recording: recording, context: context)
                            showEnhanceSheet = false
                        }
                    )
                    .presentationDetents([.medium])
                }
                // MARK: - iOS Sheet Logic (Global)
#if !targetEnvironment(macCatalyst)
                .sheet(isPresented: Binding(
                    get: { sheetSegmentIndex != nil },
                    set: { if !$0 { sheetSegmentIndex = nil; selectedSegmentID = nil } }
                )) {
                    if let index = sheetSegmentIndex, transcriptSegments.indices.contains(index) {
                        TaggingSheet(
                            segment: $transcriptSegments[index],
                            recordingID: recording.id,
                            recordingName: liveRecording?.name ?? "Recording"
                        )
                        .environmentObject(model) // <--- CRASH FIX: Inject Model
                    }
                }
#endif
            } else {
                Text("Recording not found")
            }
        }
    }
    
    // MARK: - Subviews
    
    private func headerView(for recording: Recording) -> some View {
        HStack {
            // 1. LEADING: Menu OR Enhancing Status
            if recording.isEnhancing {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .rotationEffect(.degrees(isRotating ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isRotating)
                        .onAppear { isRotating = true }
                    Text("Enhancing...")
                        .font(.caption)
                }
                .padding(.leading, 16)
                .padding(.top, 20)
                .foregroundColor(.purple)
            } else {
                Menu {
                    Button(action: {
                        if !recording.isTranscribing {
                            showEnhanceSheet = true
                        }
                    }) {
                        Label("Enhance Transcription", systemImage: "sparkles")
                    }
                    .disabled(recording.isTranscribing)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundColor(.blue)
                        .padding(.leading, 16)
                        .padding(.top, 20)
                }
            }
            
            // 2. CENTER ACTIONS (Retry or Create)
            if !recording.isTranscribing && !recording.isQueued {
                // CASE A: Transcription Failed -> Show Red "Retry"
                if recording.transcript?.hasPrefix("Failed:") == true {
                    Button(action: { model.retryTranscription(recording: recording) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Retry")
                        }
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                    }
                    .padding(.leading, 12)
                    .padding(.top, 20)
                }
                // CASE B: Transcription Missing -> Show Blue "Transcribe"
                else if recording.transcript == nil || recording.transcript?.isEmpty == true {
                    Button(action: { model.retryTranscription(recording: recording) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.badge.plus")
                            Text("Transcribe")
                        }
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(16)
                    }
                    .padding(.leading, 12)
                    .padding(.top, 20)
                }
            }
            
            Spacer()
            
            Button(action: { dismiss() }) {
                Text("Close")
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            }
            .padding(.trailing, 20)
            .padding(.top, 20)
        }
    }
    
    @ViewBuilder
    private func metadataView(for recording: Recording) -> some View {
        VStack(spacing: 4) {
            Text(recording.name).font(.headline)
            Text(recording.date.formatted(date: .long, time: .shortened))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 15)
        
        Spacer().frame(height: 10)
    }
    
    private func transcriptView(for recording: Recording) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if recording.isEnhancing || recording.isTranscribing {
                        TranscriptSkeleton()
                    } else if transcriptSegments.isEmpty {
                        Text(recording.transcript ?? "Transcript pending or unavailable.")
                            .font(.body)
                            .lineSpacing(6)
                            .padding()
                    } else {
                        ForEach(Array(transcriptSegments.enumerated()), id: \.element.id) { index, segment in
                            TranscriptSegmentRow(
                                segment: segment,
                                isActive: activeSegmentId == segment.id,
                                isSelected: selectedSegmentID == segment.id,
                                onTap: { handleSegmentTap(segment: segment, recording: recording) },
                                onLongPress: {
                                    withAnimation {
                                        selectedSegmentID = segment.id
                                        sheetSegmentIndex = index
                                    }
                                }
                            )
                            .id(segment.id)
                            // MARK: - Mac Popover Logic (Local Scope)
#if targetEnvironment(macCatalyst)
                            .popover(isPresented: Binding(
                                get: { sheetSegmentIndex == index },
                                set: { if !$0 { sheetSegmentIndex = nil; selectedSegmentID = nil } }
                            )) {
                                TaggingSheet(
                                    segment: $transcriptSegments[index],
                                    recordingID: recording.id,
                                    recordingName: liveRecording?.name ?? "Recording"
                                )
                                .environmentObject(model) // <--- CRASH FIX: Inject Model
                                .frame(minWidth: 350, minHeight: 500)
                            }
#endif
                        }
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 220)
            }
            .onChange(of: activeSegmentId) { _, newId in
                if let id = newId, selectedSegmentID == nil {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let seekTime = initialSeekTime {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let segment = transcriptSegments.first(where: { seekTime >= $0.startTime && seekTime < $0.endTime }) {
                            withAnimation { proxy.scrollTo(segment.id, anchor: .center) }
                        }
                    }
                }
            }
        }
    }
    
    private var waveformView: some View {
        VStack {
            Spacer()
            LiveWaveformView(
                isPlaying: isCurrentPlayerItem && player.isPlaying,
                currentTime: isCurrentPlayerItem ? player.currentTime : 0
            )
            Spacer()
        }
        .padding(.bottom, 200)
    }
    
    private func bottomControls(for recording: Recording) -> some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 20) {
                // Time Scrubber
                VStack(spacing: 8) {
                    ScrubberBar(
                        current: Binding(
                            get: { isCurrentPlayerItem ? player.currentTime : 0 },
                            set: { time in
                                if !isCurrentPlayerItem {
                                    let url = model.getFileUrl(for: recording)
                                    player.play(url: url, recordingId: recording.id, startTime: time)
                                    player.pause()
                                }
                                player.seek(to: time)
                            }
                        ),
                        total: recording.duration
                    )
                    HStack {
                        Text(formatTime(isCurrentPlayerItem ? player.currentTime : 0))
                        Spacer()
                        Text("-" + formatTime(recording.duration - (isCurrentPlayerItem ? player.currentTime : 0)))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }
                
                // Playback Buttons
                HStack(spacing: 40) {
                    Button(action: { player.seek(to: player.currentTime - 15) }) {
                        Image(systemName: "gobackward.15").font(.title2)
                    }.disabled(!isCurrentPlayerItem)
                    
                    Button(action: {
                        let url = model.getFileUrl(for: recording)
                        if isCurrentPlayerItem && player.isPlaying {
                            player.pause()
                        } else {
                            player.play(url: url, recordingId: recording.id, startTime: isCurrentPlayerItem ? player.currentTime : 0)
                        }
                    }) {
                        Image(systemName: isCurrentPlayerItem && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 44))
                    }
                    
                    Button(action: { player.seek(to: player.currentTime + 15) }) {
                        Image(systemName: "goforward.15").font(.title2)
                    }.disabled(!isCurrentPlayerItem)
                }
                .foregroundColor(.primary)
                
                // Toggle View Button
                HStack {
                    Button(action: { withAnimation { isShowingTranscript.toggle() } }) {
                        Image(systemName: isShowingTranscript ? "waveform" : "quote.bubble")
                            .font(.title3)
                            .padding(8)
                            .background(isShowingTranscript ? Color.blue : Color(UIColor.secondarySystemBackground))
                            .foregroundColor(isShowingTranscript ? .white : .blue)
                            .clipShape(Circle())
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .padding(.bottom, 20)
            .background(.ultraThinMaterial)
        }
    }
    
    // MARK: - Logic Helpers
    
    func setupView(_ recording: Recording) {
        isShowingTranscript = true
        parseTranscript(recording.transcript)
        if let seekTime = initialSeekTime {
            let url = model.getFileUrl(for: recording)
            player.play(url: url, recordingId: recording.id, startTime: seekTime)
        }
    }
    
    func handleSegmentTap(segment: TranscriptSegment, recording: Recording) {
        if selectedSegmentID != nil {
            withAnimation { selectedSegmentID = nil }
        }
        if isCurrentPlayerItem {
            player.seek(to: segment.startTime)
        } else {
            let url = model.getFileUrl(for: recording)
            player.play(url: url, recordingId: recording.id, startTime: segment.startTime)
        }
    }
    
    func parseTranscript(_ text: String?) {
        guard let text = text, !text.isEmpty else {
            self.transcriptSegments = []
            return
        }
        
        let savedTags = liveRecording?.tags ?? [:]
        
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        var segments: [TranscriptSegment] = []
        let regex = VoiceMemosModel.timestampRegex
        
        for i in 0..<lines.count {
            let line = lines[i]
            var startTime: TimeInterval = 0
            
            if let regex = regex,
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let range1 = Range(match.range(at: 1), in: line)!
                let range2 = Range(match.range(at: 2), in: line)!
                if let min = Double(line[range1]), let sec = Double(line[range2]) {
                    startTime = (min * 60) + sec
                }
            } else {
                startTime = segments.last?.endTime ?? 0
            }
            
            let endTime: TimeInterval = startTime + 60
            
            let key = String(startTime)
            let tagsForThisLine = savedTags[key] ?? []
            
            segments.append(TranscriptSegment(
                id: UUID(),
                startTime: startTime,
                endTime: endTime,
                text: line,
                tags: tagsForThisLine
            ))
        }
        
        for i in 0..<segments.count {
            if i < segments.count - 1 {
                segments[i] = TranscriptSegment(
                    id: segments[i].id,
                    startTime: segments[i].startTime,
                    endTime: segments[i+1].startTime,
                    text: segments[i].text,
                    tags: segments[i].tags
                )
            } else {
                segments[i] = TranscriptSegment(
                    id: segments[i].id,
                    startTime: segments[i].startTime,
                    endTime: segments[i].startTime + 30,
                    text: segments[i].text,
                    tags: segments[i].tags
                )
            }
        }
        self.transcriptSegments = segments
    }
    
    func formatTime(_ time: TimeInterval) -> String {
        let seconds = Int(time) % 60
        let minutes = Int(time) / 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct TaggingSheet: View {
    @Binding var segment: TranscriptSegment
    let recordingID: UUID
    let recordingName: String
    
    @EnvironmentObject var model: VoiceMemosModel
    @Environment(\.dismiss) var dismiss
    
    // State for UI
    @State private var selectedColorIndex: Int = 0
    @State private var isAddingTag = false
    @State private var isAddingAttribute = false
    @State private var newTagText = ""
    @State private var editingTagID: UUID? = nil
    @State private var showDeleteConfirmation = false
    @FocusState private var isInputFocused: Bool
    
    // Theme State
    @State private var selectedThemeID: UUID? = nil
    @State private var isAddingNewTheme = false
    @State private var newThemeName = ""
    
    // Attribute Type State
    @State private var selectedAttributeTypeID: UUID? = nil
    @State private var isAddingNewAttributeType = false
    @State private var newAttributeTypeName = ""
    
    let colors: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .gray]
    var selectedColor: Color { colors[selectedColorIndex] }
    
    var timestampTitle: String {
        let m = Int(segment.startTime) / 60
        let s = Int(segment.startTime) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    var currentThemeName: String {
        if let id = selectedThemeID, let theme = model.themes.first(where: { $0.id == id }) {
            return theme.name
        }
        return "Select Theme"
    }
    
    var currentAttributeTypeName: String {
        if let id = selectedAttributeTypeID, let type = model.attributeTypes.first(where: { $0.id == id }) {
            return type.name
        }
        return "Select Type"
    }
    
    // MARK: - MAIN BODY
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        
                        Text(recordingName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 10)
                        
                        // --- Refactored Sections ---
                        qualitativeCodesSection
                        
                        attributesSection
                        // ---------------------------
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle(timestampTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editingTagID != nil {
                        Button(action: { showDeleteConfirmation = true }) { Image(systemName: "trash").foregroundColor(.red) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if isAddingTag { commitNewTag(isAttribute: false) }
                        if isAddingAttribute { commitNewTag(isAttribute: true) }
                        editingTagID = nil
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
            // Alert for New Theme
            .alert("New Theme", isPresented: $isAddingNewTheme) {
                TextField("Name", text: $newThemeName)
                Button("Cancel", role: .cancel) { newThemeName = "" }
                Button("Save") {
                    if !newThemeName.isEmpty {
                        model.addTheme(name: newThemeName)
                        if let new = model.themes.last { selectedThemeID = new.id }
                        newThemeName = ""
                    }
                }
            } message: { Text("Enter a name for your new theme.") }
            // Alert for New Attribute Type
            .alert("New Attribute Type", isPresented: $isAddingNewAttributeType) {
                TextField("Type Name (e.g. Experience)", text: $newAttributeTypeName)
                Button("Cancel", role: .cancel) { newAttributeTypeName = "" }
                Button("Save") {
                    if !newAttributeTypeName.isEmpty {
                        let newID = model.addAttributeType(name: newAttributeTypeName)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { selectedAttributeTypeID = newID }
                        }
                        newAttributeTypeName = ""
                    }
                }
            } message: { Text("Enter a category name for this attribute.") }
            .confirmationDialog("Delete Tag?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let id = editingTagID { deleteTag(id: id); editingTagID = nil }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { model.triggerDebouncedReload() }
        .onChange(of: selectedAttributeTypeID) { _, newValue in
            if let editID = editingTagID, let index = segment.tags.firstIndex(where: { $0.id == editID }) {
                segment.tags[index].attributeTypeID = newValue
                model.updateGlobalTag(segment.tags[index])
                saveChanges()
            }
        }
        .onChange(of: selectedThemeID) { _, newValue in
            if let editID = editingTagID, let index = segment.tags.firstIndex(where: { $0.id == editID }) {
                segment.tags[index].themeID = newValue
                model.updateGlobalTag(segment.tags[index])
                saveChanges()
            }
        }
    }
    
    // MARK: - EXTRACTED SUBVIEWS (Fixes Compiler Error)
    
    private var qualitativeCodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUALITATIVE CODES").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
            
            colorPickerView
            
            // Theme Picker
            LabeledContent {
                Menu {
                    Button(action: { isAddingNewTheme = true }) { Label("Add theme", systemImage: "plus") }
                    Picker("Select Theme", selection: $selectedThemeID) {
                        Text("Select Theme").tag(UUID?.none)
                        ForEach(model.themes) { theme in
                            Text(theme.name).tag(theme.id as UUID?)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentThemeName)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .foregroundColor(.blue)
                }
            } label: {
                Text("Theme:").font(.callout).foregroundColor(.secondary)
            }
            
            FlowLayout(spacing: 6) {
                inputView(isAttributeMode: false)
                existingTagsView(attributesOnly: false)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var attributesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PARTICIPANT ATTRIBUTES").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
            
            LabeledContent {
                HStack(spacing: 8) {
                    Menu {
                        Button(action: { isAddingNewAttributeType = true }) { Label("Add type", systemImage: "plus") }
                        
                        Picker("Select Type", selection: $selectedAttributeTypeID) {
                            Text("No Type").tag(UUID?.none)
                            ForEach(model.attributeTypes) { type in
                                if type.symbol.isEmpty {
                                    Text(type.name).tag(type.id as UUID?)
                                } else {
                                    Text("\(type.name) \(type.symbol)").tag(type.id as UUID?)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentAttributeTypeName)
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    if let selectedID = selectedAttributeTypeID,
                       let currentType = model.attributeTypes.first(where: { $0.id == selectedID }) {
                        
                        Menu {
                            Button(action: { model.updateAttributeTypeSymbol(id: selectedID, symbol: "") }) {
                                Label("None", systemImage: "slash.circle")
                            }
                            let emojis = ["🏷️", "👤", "🐾", "🧠", "❤️", "⭐", "🔷", "🚩", "🗣️", "👀", "💼", "🎓", "⚙️", "💡", "📍"]
                            
                            ForEach(emojis, id: \.self) { emoji in
                                Button(action: {
                                    model.updateAttributeTypeSymbol(id: selectedID, symbol: emoji)
                                }) {
                                    Text(emoji)
                                }
                            }
                        } label: {
                            if currentType.symbol.isEmpty {
                                Image(systemName: "face.dashed").font(.title3).padding(6).background(Color.teal.opacity(0.1)).clipShape(Circle())
                            } else {
                                Text(currentType.symbol).font(.title3).padding(6).background(Color.teal.opacity(0.1)).clipShape(Circle())
                            }
                        }
                    }
                }
            } label: {
                Text("Attribute Type:").font(.callout).foregroundColor(.secondary)
            }
            
            Divider()
            
            FlowLayout(spacing: 6) {
                inputView(isAttributeMode: true)
                existingTagsView(attributesOnly: true)
            }
            
            if !isAddingAttribute && !isAddingTag {
                Button(action: {
                    withAnimation {
                        isAddingAttribute = true
                        isInputFocused = true
                        editingTagID = nil
                    }
                }) {
                    HStack {
                        Image(systemName: "person.text.rectangle")
                        Text("Add Attribute")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                }
                .padding(.top, 8)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    // MARK: - COMPONENTS
    
    private var colorPickerView: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(selectedColor)
                .frame(width: 40, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<colors.count, id: \.self) { index in
                        ZStack {
                            Circle().fill(colors[index]).frame(width: 24, height: 24)
                            if selectedColorIndex == index { Circle().stroke(Color.blue, lineWidth: 2).frame(width: 30, height: 30) }
                        }
                        .contentShape(Circle())
                        .onTapGesture {
                            withAnimation(.spring()) {
                                selectedColorIndex = index
                                if let editID = editingTagID, let tagIndex = segment.tags.firstIndex(where: { $0.id == editID }) {
                                    segment.tags[tagIndex].colorIndex = index
                                    model.updateGlobalTag(segment.tags[tagIndex])
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func inputView(isAttributeMode: Bool) -> some View {
        if (isAttributeMode && isAddingAttribute) || (!isAttributeMode && isAddingTag) {
            TextField(isAttributeMode ? "Attribute Value" : "Code Name", text: $newTagText)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(isAttributeMode ? Color.gray.opacity(0.2) : selectedColor.opacity(0.2)))
                .frame(minWidth: 80)
                .focused($isInputFocused)
                .submitLabel(.done)
                .onSubmit { commitNewTag(isAttribute: isAttributeMode) }
        } else if !isAttributeMode {
            Button(action: {
                withAnimation {
                    isAddingTag = true
                    isAddingAttribute = false
                    isInputFocused = true
                    editingTagID = nil
                    selectedThemeID = nil
                }
            }) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
                    .foregroundColor(.blue)
            }
        }
    }
    
    private func existingTagsView(attributesOnly: Bool) -> some View {
        ForEach($segment.tags) { $tag in
            if tag.isAttribute == attributesOnly {
                let isEditing = editingTagID == tag.id
                HStack(spacing: 0) {
                    if isEditing {
                        TextField("", text: $tag.text)
                            .font(.subheadline)
                            .fixedSize()
                            .focused($isInputFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                if tag.text.isEmpty { deleteTag(id: tag.id) }
                                else { model.updateGlobalTag(tag) }
                                editingTagID = nil
                            }
                    } else {
                        if attributesOnly {
                            if let typeID = tag.attributeTypeID,
                               let type = model.attributeTypes.first(where: { $0.id == typeID }),
                               !type.symbol.isEmpty {
                                Text(type.symbol).font(.caption2).padding(.trailing, 2)
                            } else {
                                Image(systemName: "person.fill").font(.caption2).padding(.trailing, 4).opacity(0.5)
                            }
                        }
                        Text(tag.text).font(.subheadline)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(attributesOnly ? Color.teal.opacity(0.15) : colors[tag.colorIndex].opacity(0.3)))
                .overlay(Capsule().stroke(isEditing ? Color.blue : (attributesOnly ? Color.teal.opacity(0.5) : Color.clear), lineWidth: attributesOnly ? 1 : 2))
                .padding(2)
                .onTapGesture {
                    withAnimation {
                        isAddingTag = false; isAddingAttribute = false; editingTagID = tag.id
                        
                        if attributesOnly {
                            selectedAttributeTypeID = tag.attributeTypeID
                        } else {
                            selectedColorIndex = tag.colorIndex; selectedThemeID = tag.themeID
                        }
                        
                        isInputFocused = true
                    }
                }
            }
        }
    }
    
    // MARK: - LOGIC
    
    private func commitNewTag(isAttribute: Bool) {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let color = isAttribute ? 7 : selectedColorIndex
            let typeID = isAttribute ? selectedAttributeTypeID : nil
            let thmID = isAttribute ? nil : selectedThemeID
            
            let tag = Tag(text: trimmed, colorIndex: color, themeID: thmID, isAttribute: isAttribute, attributeTypeID: typeID)
            
            withAnimation { segment.tags.append(tag) }
            model.saveCodeToLibrary(tag)
            saveChanges()
        }
        newTagText = ""; isAddingTag = false; isAddingAttribute = false
    }
    
    private func deleteTag(id: UUID) { withAnimation { segment.tags.removeAll { $0.id == id } }; saveChanges() }
    private func saveChanges() { model.updateSegmentTags(recordingID: recordingID, startTime: segment.startTime, tags: segment.tags) }
}

struct ThinkingAnimation: View {
    @State private var startTime: Date = Date()
    @State private var currentTime: Date = Date()
    
    // MARK: - TIMING CONTROLS
    
    // 1. How long the text stays on screen (Animation + Read time)
    private let activeDuration: Double = 1.8
    
    // 2. How long the screen stays EMPTY before restarting
    // CHANGE THIS to control the gap between End and Start
    private let pauseDuration: Double = 0.1
    
    // 3. Speed of the "Wave" (Slower = 0.5)
    private let letterAnimationDuration: Double = 0.5
    
    // 4. How fast it fades out at the end of activeDuration
    private let fadeOutDuration: Double = 0.3
    
    // Computed total loop (Do not change manually)
    private var totalLoopDuration: Double {
        activeDuration + pauseDuration
    }
    
    let timer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array("Thinking...".enumerated()), id: \.offset) { index, char in
                Text(String(char))
                    .font(.body.weight(.medium))
                    .kerning(-0.5)
                    .foregroundColor(.gray)
                    .scaleEffect(scaleForIndex(index))
                    .blur(radius: blurForIndex(index))
                    .opacity(opacityForIndex(index))
            }
        }
        .onReceive(timer) { time in
            currentTime = time
            // Reset logic based on TOTAL duration (Active + Pause)
            if currentTime.timeIntervalSince(startTime) > totalLoopDuration {
                startTime = time
            }
        }
        .onAppear {
            startTime = Date()
            currentTime = Date()
        }
    }
    
    private var elapsedTime: Double {
        currentTime.timeIntervalSince(startTime)
    }
    
    private func relativeTime(for index: Int) -> Double {
        let staggerDelay = Double(index) * 0.06
        return elapsedTime - staggerDelay
    }
    
    // MARK: - Animation Math
    
    private func scaleForIndex(_ index: Int) -> CGFloat {
        let t = relativeTime(for: index)
        if t >= 0 && t < letterAnimationDuration {
            return 1.2 - (t / letterAnimationDuration) * 0.2
        }
        return 1.0
    }
    
    private func blurForIndex(_ index: Int) -> CGFloat {
        let t = relativeTime(for: index)
        if t >= 0 && t < letterAnimationDuration {
            return 5 - (t / letterAnimationDuration) * 5
        }
        return 0
    }
    
    private func opacityForIndex(_ index: Int) -> Double {
        // 1. PAUSE PHASE: If we are in the pause gap, be invisible
        if elapsedTime > activeDuration {
            return 0
        }
        
        // 2. FADE OUT: If we are nearing the end of the ACTIVE duration
        let timeRemainingInActive = activeDuration - elapsedTime
        if timeRemainingInActive < fadeOutDuration {
            return timeRemainingInActive / fadeOutDuration
        }
        
        // 3. FADE IN (Entry)
        let t = relativeTime(for: index)
        if t < 0 { return 0 }
        if t < letterAnimationDuration {
            return t / letterAnimationDuration
        }
        
        // 4. Fully Visible
        return 1.0
    }
}

struct EnhancePromptView: View {
    let recordingName: String
    var onCommit: (String) -> Void
    
    @Environment(\.dismiss) var dismiss
    @StateObject private var dictation = DictationViewModel()
    @State private var descriptionText = ""
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Describe this recording to improve speaker identification and accuracy.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                ZStack(alignment: .topLeading) {
                    if descriptionText.isEmpty && !dictation.isRecording {
                        Text("E.g., 'This is a conversation between Zach and Mike discussing YouTube strategy...'")
                            .foregroundColor(.gray.opacity(0.5))
                            .padding(12)
                    }
                    
                    TextEditor(text: $descriptionText)
                        .frame(height: 120)
                        .padding(4)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                
                HStack {
                    Button(action: {
                        dictation.toggleRecording()
                    }) {
                        HStack {
                            Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.title)
                                .foregroundColor(dictation.isRecording ? .red : .blue)
                            if dictation.isRecording {
                                Text("Listening...")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if !descriptionText.isEmpty {
                        Button("Clear") { descriptionText = "" }
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
                
                Button(action: { onCommit(descriptionText) }) {
                    Text("Process Enhancement")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("Enhance Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: dictation.text) { oldValue, newValue in
                if !newValue.isEmpty {
                    // Append dictation to existing text
                    if !descriptionText.isEmpty && !descriptionText.hasSuffix(" ") {
                        descriptionText += " "
                    }
                    descriptionText += newValue
                    // Clear dictation buffer so subsequent phrases append correctly
                    dictation.text = ""
                }
            }
        }
    }
}

struct OptionsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var speed = 1.0; @State private var skipSilence = false; @State private var enhanceRecording = false
    var body: some View {
        NavigationStack {
            List { Section { VStack(alignment: .leading) { Text("Playback Speed"); HStack { Image(systemName: "tortoise"); Slider(value: $speed, in: 0.5...2.0); Image(systemName: "hare") } }; Toggle("Skip Silence", isOn: $skipSilence); Toggle("Enhance Recording", isOn: $enhanceRecording) } header: { Text("Options") } }.toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct CurrentRecordingSheet: View {
    @ObservedObject var recorder: AudioRecorder
    var onSave: (String, TimeInterval) -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Text("New Recording").font(.headline).padding(.top, 20)
            
            // Visualizer
            HStack(spacing: 3) {
                ForEach(0..<recorder.audioSamples.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: 4, height: 30 + (recorder.audioSamples[i] * 100))
                }
            }
            .frame(height: 120)
            .drawingGroup()
            
            // Timer
            Text(recorder.recordingDuration.formattedDurationLong)
                .font(.system(size: 60, weight: .light))
                .monospacedDigit()
            
            Spacer()
            
            // STOP BUTTON
            Button(action: {
                // FIX: Use the closure to wait for the file to save
                recorder.stopRecording { fileName, duration in
                    if let name = fileName {
                        onSave(name, duration)
                    }
                }
            }) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 4)
                        .frame(width: 72, height: 72)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.bottom, 40)
        }
        .padding()
    }
}

extension Color {
    static let tagColors: [Color] = [
        .blue, .purple, .pink, .red,
        .orange, .yellow, .green, .gray
    ]
}

extension TimeInterval {
    var formattedDuration: String { String(format: "%02d:%02d", Int(self) / 60, Int(self) % 60) }
    var formattedDurationLong: String { String(format: "%02d:%02d.%02d", Int(self) / 60, Int(self) % 60, Int((self.truncatingRemainder(dividingBy: 1)) * 100)) }
}

// MARK: - 10. ANALYSIS & TRANSCRIPT VIEWS
struct AnalysisMainView: View {
    @EnvironmentObject var model: VoiceMemosModel
    @State private var showSourcesSheet = false
    @State private var isExporting = false
    @State private var documentToExport: CSVDocument?
    
    var body: some View {
        NavigationStack(path: $model.navigationPath) {
            VStack(spacing: 0) {
                // Header Area
                ZStack(alignment: .top) {
                    
                    // 1. LEADING: Export Button
                    HStack {
                        Menu {
                            Button(action: {
                                documentToExport = model.generateCSVExport()
                                isExporting = true
                            }) {
                                Label("Export csv", systemImage: "doc.text")
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                        }
                        Spacer()
                    }
                    .foregroundColor(.blue)
                    .padding(.leading, 16)
                    .padding(.top, 10)
                    
                    // 2. CENTER: Title & Segmented Control
                    VStack {
                        Text("Analysis").font(.headline).padding(.top, 8)
                        
                        // FIX: Use the Native Wrapper.
                        // This bypasses SwiftUI's layout glitches and guarantees the slide animation.
                        NativeSegmentedControl(selection: $model.analysisTabSelection)
                            .frame(width: 250) // Standard width looks best
                            .padding(.vertical, 8)
                    }
                    
                    // 3. TRAILING: Action Buttons
                    HStack(spacing: 16) {
                        if model.analysisTabSelection == .chat && !model.chatHistory.isEmpty {
                            Button(action: { model.resetChat() }) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.title2)
                            }
                        }
                        
                        Button(action: { showSourcesSheet = true }) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.title2)
                        }
                    }
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
                    .padding(.top, 10)
                }
                .background(Color(UIColor.systemGroupedBackground))
                
                // Content Area
                if !model.recordings.isEmpty {
                    Group {
                        switch model.analysisTabSelection {
                        case .chat: AnalysisChatView()
                        case .code: AnalysisCodeView()
                        }
                    }
                    .background(Color(UIColor.systemGroupedBackground))
                } else {
                    ContentUnavailableView("No Recordings", systemImage: "doc.text.magnifyingglass", description: Text("Create a recording to start analysis."))
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Recording.self) { recording in
                TranscriptView(recording: recording)
            }
            .sheet(isPresented: $showSourcesSheet) {
                AnalysisSourcesSheet()
                    .environmentObject(model)
            }
            .fileExporter(
                isPresented: $isExporting,
                document: documentToExport,
                contentType: .commaSeparatedText,
                defaultFilename: generateExportFilename()
            ) { result in
                if case .failure(let error) = result {
                    print("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func generateExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ddMMyyyy"
        let dateStr = formatter.string(from: Date())
        return "coded-segments-\(dateStr)"
    }
}

struct AnalysisSourcesSheet: View {
    @EnvironmentObject var model: VoiceMemosModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    SourceRow(
                        icon: "waveform",
                        label: "All Recordings",
                        count: model.recordings.count,
                        state: model.getSelectionState(folder: nil),
                        action: { model.toggleBatchSelection(folder: nil) }
                    )
                }
                
                if !model.userFolders.isEmpty {
                    Section(header: Text("My Folders")) {
                        ForEach(model.userFolders, id: \.self) { folder in
                            SourceRow(
                                icon: "folder",
                                label: folder,
                                count: model.countForFolder(folder),
                                state: model.getSelectionState(folder: folder),
                                action: { model.toggleBatchSelection(folder: folder) }
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Analysis Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Text("Done")
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct AnalysisCodeView: View {
    @EnvironmentObject var model: VoiceMemosModel
    @State private var isAddingTheme = false
    @State private var newThemeName = ""
    
    var body: some View {
        List {
            
            
            Section(header: Text("My Themes")) {
                Button(action: { isAddingTheme = true }) {
                    Text("Add Theme")
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.themes) { theme in
                    NavigationLink(destination: ThemeDetailView(filter: .specific(theme)).environmentObject(model)) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                                .frame(width: 24)
                            
                            Text(theme.name)
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            let count = countTags(for: theme.id)
                            Text("\(count)")
                                .foregroundColor(.secondary) // Native style
                        }
                    }
                }
                .onDelete { indexSet in
                    indexSet.map { model.themes[$0] }.forEach { theme in
                        if let idx = model.themes.firstIndex(where: { $0.id == theme.id }) {
                            model.themes.remove(at: idx)
                        }
                    }
                    model.saveThemes()
                }
            }
            
            // MARK: - 3. Data Section
            Section {
                NavigationLink(destination: ThemeDetailView(filter: .uncategorized).environmentObject(model)) {
                    HStack {
                        Image(systemName: "questionmark.folder")
                            .foregroundColor(.orange)
                            .frame(width: 24)
                        
                        Text("Uncategorized Codes")
                        
                        Spacer()
                        
                        Text("\(countTags(for: nil))")
                            .foregroundColor(.secondary)
                    }
                }
                
                // All Segments
                NavigationLink(destination: ThemeDetailView(filter: .all).environmentObject(model)) {
                    HStack {
                        Image(systemName: "number")
                            .foregroundColor(.gray)
                            .frame(width: 24)
                        
                        Text("All Coded Segments")
                        
                        Spacer()
                        
                        let totalCount = model.recordings.reduce(0) { total, rec in
                            total + rec.tags.values.reduce(0) { $0 + $1.count }
                        }
                        
                        Text("\(totalCount)")
                            .foregroundColor(.secondary) // Native style
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .alert("New Theme", isPresented: $isAddingTheme) {
            TextField("Theme Name", text: $newThemeName)
            Button("Cancel", role: .cancel) { newThemeName = "" }
            Button("Save") {
                if !newThemeName.isEmpty {
                    model.addTheme(name: newThemeName)
                    newThemeName = ""
                }
            }
        } message: {
            Text("Enter a name for your new theme.")
        }
        .onAppear {
            model.triggerDebouncedReload()
        }
    }
    
    private func countTags(for themeID: UUID?) -> Int {
        return model.recordings.reduce(0) { total, rec in
            total + rec.tags.values.flatMap { $0 }.filter { $0.themeID == themeID }.count
        }
    }
}

struct ThemeDetailView: View {
    enum Filter: Equatable {
        case all
        case uncategorized
        case specific(Theme)
        
        var title: String {
            switch self {
            case .all: return "All Codes"
            case .uncategorized: return "Uncategorized"
            case .specific(let t): return t.name
            }
        }
    }
    
    let filter: Filter
    @EnvironmentObject var model: VoiceMemosModel
    @State private var editingSegment: CodedSegment?
    
    // Struct to hold temporary data for the list
    struct CodedSegment: Identifiable {
        var id: String { "\(recordingID.uuidString)_\(timestamp)" }
        let recordingID: UUID
        let recordingName: String
        let timestamp: TimeInterval
        let text: String
        let tags: [Tag]
        let recordingDate: Date
    }
    
    // Compute the list of segments based on the current filter
    var aggregatedSegments: [CodedSegment] {
        var results: [CodedSegment] = []
        let regex = VoiceMemosModel.timestampRegex
        
        for recording in model.recordings {
            guard let transcript = recording.transcript, !recording.tags.isEmpty else { continue }
            
            let lines = transcript.components(separatedBy: "\n").filter { !$0.isEmpty }
            
            for line in lines {
                var startTime: TimeInterval = 0
                if let regex = regex,
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let r1 = Range(match.range(at: 1), in: line)!
                    let r2 = Range(match.range(at: 2), in: line)!
                    if let min = Double(line[r1]), let sec = Double(line[r2]) {
                        startTime = (min * 60) + sec
                    }
                }
                
                // Use the string key to find tags
                let key = String(startTime)
                guard let tagsForLine = recording.tags[key], !tagsForLine.isEmpty else { continue }
                
                let relevantTags: [Tag]
                switch filter {
                case .all: relevantTags = tagsForLine
                case .uncategorized: relevantTags = tagsForLine.filter { $0.themeID == nil }
                case .specific(let theme): relevantTags = tagsForLine.filter { $0.themeID == theme.id }
                }
                
                if !relevantTags.isEmpty {
                    results.append(CodedSegment(
                        recordingID: recording.id,
                        recordingName: recording.name,
                        timestamp: startTime,
                        text: line,
                        tags: relevantTags,
                        recordingDate: recording.date
                    ))
                }
            }
        }
        
        return results.sorted {
            if $0.recordingDate != $1.recordingDate {
                return $0.recordingDate > $1.recordingDate
            }
            return $0.timestamp < $1.timestamp
        }
    }
    
    var body: some View {
        List {
            if aggregatedSegments.isEmpty {
                ContentUnavailableView(
                    "No Segments Found",
                    systemImage: "tag.slash",
                    description: Text(emptyDescription)
                )
            } else {
                ForEach(aggregatedSegments) { segment in
                    // EXTRACTED SUBVIEW TO FIX COMPILER ERROR
                    ThemeSegmentRow(segment: segment)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingSegment = segment
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(filter.title)
        .sheet(item: $editingSegment) { item in
            sheetContent(item: item)
        }
    }
    
    @ViewBuilder
    func sheetContent(item: CodedSegment) -> some View {
        if let index = model.recordings.firstIndex(where: { $0.id == item.recordingID }) {
            
            let binding = Binding<TranscriptSegment>(
                get: {
                    let key = String(item.timestamp)
                    let currentTags = model.recordings[index].tags[key] ?? []
                    
                    return TranscriptSegment(
                        id: UUID(),
                        startTime: item.timestamp,
                        endTime: item.timestamp + 60,
                        text: item.text,
                        tags: currentTags
                    )
                },
                set: { newSegment in
                    // This calls the model's update function, which saves to disk
                    model.updateSegmentTags(
                        recordingID: item.recordingID,
                        startTime: item.timestamp,
                        tags: newSegment.tags
                    )
                }
            )
            
            TaggingSheet(
                segment: binding,
                recordingID: item.recordingID,
                recordingName: item.recordingName
            )
            .environmentObject(model)
            .frame(minWidth: 350, minHeight: 500)
        }
    }
    
    var emptyDescription: String {
        switch filter {
        case .all: return "Start tagging your transcripts to see them here."
        case .uncategorized: return "All your codes have been assigned to a theme."
        case .specific: return "Apply this theme to a code to see results here."
        }
    }
}

// MARK: - EXTRACTED SUBVIEWS (Fixes Complexity)

struct ThemeSegmentRow: View {
    let segment: ThemeDetailView.CodedSegment
    @EnvironmentObject var model: VoiceMemosModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(segment.recordingName)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTime(segment.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(4)
            }
            
            Text(segment.text)
                .font(.body)
                .lineSpacing(4)
            
            FlowLayout(spacing: 4) {
                ForEach(segment.tags) { tag in
                    TagPill(tag: tag)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    func formatTime(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct TagPill: View {
    let tag: Tag
    @EnvironmentObject var model: VoiceMemosModel
    
    var body: some View {
        HStack(spacing: 4) {
            if tag.isAttribute,
               let typeID = tag.attributeTypeID,
               let type = model.attributeTypes.first(where: { $0.id == typeID }),
               !type.symbol.isEmpty {
                Text(type.symbol).font(.caption2)
            }
            
            Text(tag.text)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(uiColor: .systemGray5)))
        .foregroundColor(Color.tagColors.indices.contains(tag.colorIndex) ? Color.tagColors[tag.colorIndex] : .blue)
    }
}

struct TranscriptView: View {
    let recording: Recording
    @EnvironmentObject var model: VoiceMemosModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(recording.name).font(.largeTitle).bold().padding(.bottom, 8)
                    ForEach(Array(recording.sentenceSegments.enumerated()), id: \.offset) { index, segment in
                        let citationIndex = index + 1
                        let isHighlighted = model.activeCitation?.index == citationIndex
                        Text(segment).font(.body).lineSpacing(6).padding(4).frame(maxWidth: .infinity, alignment: .leading).background(isHighlighted ? Color.purple.opacity(0.2) : Color.clear).cornerRadius(4).id(citationIndex).overlay(Group { if isHighlighted { CitationPopoverView(citationIndex: citationIndex, text: segment) { withAnimation { model.activeCitation = nil } }.offset(y: citationIndex == 1 ? 120 : -120) } }, alignment: .center).zIndex(isHighlighted ? 1 : 0)
                    }
                }.padding().padding(.top, 60)
            }.onAppear { if let active = model.activeCitation { withAnimation { proxy.scrollTo(active.index, anchor: .center) } } }
        }.navigationBarTitleDisplayMode(.inline)
    }
}

struct CitationPopoverView: View {
    let citationIndex: Int
    let text: String
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "sparkles").foregroundColor(.primary); Text("Source guide").font(.caption).fontWeight(.bold).foregroundColor(.primary); Spacer(); Button(action: onClose) { Image(systemName: "xmark").font(.caption).foregroundColor(.gray) } }
            HStack(alignment: .top) { Text("\(citationIndex)").font(.caption2).bold().foregroundColor(.white).frame(width: 20, height: 20).background(Color.blue).clipShape(Circle()); Text("\"\(text.prefix(100))...\"").font(.caption).foregroundColor(.primary).lineLimit(3) }
        }.padding().frame(width: 260).background(Color(UIColor.secondarySystemGroupedBackground)).cornerRadius(12).shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
    }
}

struct AnalysisSourcesView: View {
    @EnvironmentObject var model: VoiceMemosModel
    
    var body: some View {
        List {
            // MARK: - All Recordings Section
            Section {
                SourceRow(
                    icon: "waveform",
                    label: "All Recordings",
                    count: model.recordings.count,
                    state: model.getSelectionState(folder: nil),
                    action: { model.toggleBatchSelection(folder: nil) }
                )
            }
            
            // MARK: - Folders Section
            if !model.userFolders.isEmpty {
                Section(header: Text("My Folders")) {
                    ForEach(model.userFolders, id: \.self) { folder in
                        SourceRow(
                            icon: "folder",
                            label: folder,
                            count: model.countForFolder(folder),
                            state: model.getSelectionState(folder: folder),
                            action: { model.toggleBatchSelection(folder: folder) }
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// Helper View for Consistent Rows
struct SourceRow: View {
    let icon: String
    let label: String
    let count: Int
    let state: VoiceMemosModel.SelectionState
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .frame(width: 24)
                
                Text(label)
                    .font(.body)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 4)
                
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundColor(state == .none ? .gray.opacity(0.3) : .blue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain) // Prevents list row highlighting issues
    }
    var iconName: String {
        switch state {
        case .all: return "checkmark.circle.fill" // Full Selection
        case .some: return "minus.circle"    // Indeterminate (Partial/Orphans)
        case .none: return "circle"               // Empty
        }
    }
}

struct CitationCardView: View {
    let citation: Citation
    let citationNumber: Int
    
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject var model: VoiceMemosModel
    var onClose: () -> Void
    var onViewSource: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(citationNumber)")
                    .font(.caption).bold()
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(Circle())
                Text("\(formatTimestamp(citation.startTime)) • \(citation.speaker)")
                    .font(.caption).fontWeight(.bold).foregroundColor(.blue)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").foregroundColor(.secondary).padding(8)
                        .background(Color.gray.opacity(0.1)).clipShape(Circle())
                }
            }
            
            Text("\"\(citation.text)\"")
                .font(.system(size: 16))
                .italic()
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
            
            Divider()
            
            HStack {
                Button(action: {
                    if let rec = model.recordings.first(where: { $0.id == citation.recordingID }) {
                        model.playbackRequest = PlaybackRequest(recording: rec, time: citation.startTime)
                        onClose()
                    }
                }) {
                    HStack { Image(systemName: "doc.text"); Text("View Source") }
                        .font(.subheadline).fontWeight(.medium).foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    if let rec = model.recordings.first(where: { $0.id == citation.recordingID }) {
                        // Check if we are currently playing this specific recording
                        if player.currentRecordingId == rec.id && player.isPlaying {
                            player.pause()
                        } else {
                            // If resuming same recording, use current time. If new, use citation start time.
                            let startTime = (player.currentRecordingId == rec.id) ? player.currentTime : citation.startTime
                            player.play(url: model.getFileUrl(for: rec), recordingId: rec.id, startTime: startTime)
                        }
                    }
                }) {
                    // Dynamic Label based on state
                    let isPlayingThis = player.currentRecordingId == citation.recordingID && player.isPlaying
                    HStack {
                        Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                        Text(isPlayingThis ? "Pause" : "Play Audio")
                    }
                    .font(.subheadline).fontWeight(.bold).foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        .padding(.horizontal)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    func formatTimestamp(_ time: TimeInterval) -> String { String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60) }
}

struct AttributedChatMessage: View {
    let text: String
    let isUser: Bool
    let onCitationTap: (Int, Int) -> Void
    
    var body: some View {
        Group {
            if text == "LOADING_ANIMATION" {
                ThinkingAnimation()
                    .padding(14)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(18)
            } else {
                Text(makeAttributedString())
                    .padding(14)
                    .background(isUser ? Color.blue : Color(UIColor.secondarySystemBackground))
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(18)
                // FIX: Explicitly use (handler: { ... }) to help the compiler
                    .environment(\.openURL, OpenURLAction(handler: { url in
                        if url.scheme == "citation",
                           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let idStr = components.host,
                           let id = Int(idStr) {
                            
                            let displayNum = Int(components.queryItems?.first(where: { $0.name == "display" })?.value ?? "0") ?? 0
                            
                            onCitationTap(id, displayNum)
                            return .handled
                        }
                        return .systemAction
                    }))
            }
        }
    }
    
    private func makeAttributedString() -> AttributedString {
        var output = AttributedString("")
        
        var baseContainer = AttributeContainer()
        baseContainer.font = .body
        baseContainer.foregroundColor = isUser ? .white : .primary
        
        let pattern = "\\[([\\d,\\s]+)\\]"
        let nsString = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AttributedString(text, attributes: baseContainer)
        }
        
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        
        var displayMap: [String: Int] = [:]
        var nextIndex = 1
        
        for match in matches {
            let content = nsString.substring(with: match.range(at: 1))
            let ids = content.components(separatedBy: ",")
            for id in ids {
                let trimmed = id.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && displayMap[trimmed] == nil {
                    displayMap[trimmed] = nextIndex
                    nextIndex += 1
                }
            }
        }
        
        var lastLocation = 0
        
        for match in matches {
            let rangeBefore = NSRange(location: lastLocation, length: match.range.location - lastLocation)
            if rangeBefore.length > 0 {
                let textSegment = nsString.substring(with: rangeBefore)
                output.append(AttributedString(textSegment, attributes: baseContainer))
            }
            
            let contentRange = match.range(at: 1)
            let content = nsString.substring(with: contentRange)
            let numbers = content.components(separatedBy: ",")
            
            for (index, numStr) in numbers.enumerated() {
                let trimmed = numStr.trimmingCharacters(in: .whitespaces)
                
                if let displayNum = displayMap[trimmed] {
                    var linkStr = AttributedString("[\(displayNum)]")
                    
                    linkStr.font = .body.bold()
                    linkStr.foregroundColor = isUser ? .white : .blue
                    
                    if let url = URL(string: "citation://\(trimmed)?display=\(displayNum)") {
                        linkStr.link = url
                    }
                    
                    output.append(linkStr)
                    
                    if index < numbers.count - 1 {
                        output.append(AttributedString(", ", attributes: baseContainer))
                    }
                }
            }
            
            lastLocation = match.range.location + match.range.length
        }
        
        if lastLocation < nsString.length {
            let remainingRange = NSRange(location: lastLocation, length: nsString.length - lastLocation)
            let remainingText = nsString.substring(with: remainingRange)
            output.append(AttributedString(remainingText, attributes: baseContainer))
        }
        
        return output
    }
}

extension Array where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

struct ChatHistoryView: View {
    let history: [ChatMessage]
    let onCitationTap: (Int, Int) -> Void
    let onSummarize: () -> Void
    let hasSelection: Bool
    
    @Binding var scrollID: UUID?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if history.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ask about selected recordings").font(.title2).bold()
                        Button(action: onSummarize) {
                            Text("Summarize these recordings")
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemBackground))
                                .foregroundColor(.blue)
                                .cornerRadius(10)
                        }
                    }.padding()
                }
                LazyVStack(spacing: 16) {
                    ForEach(history) { msg in
                        HStack {
                            if msg.role == .user { Spacer() }
                            AttributedChatMessage(text: msg.text, isUser: msg.role == .user, onCitationTap: onCitationTap)
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: msg.role == .user ? .trailing : .leading)
                            if msg.role == .model { Spacer() }
                        }
                        .padding(.horizontal)
                        .id(msg.id)
                    }
                }
                .scrollTargetLayout()
            }
            .padding(.bottom, 80)
            .padding(.top, 10)
        }
        .scrollPosition(id: $scrollID)
        .scrollDismissesKeyboard(.interactively)
    }
}

struct AnalysisChatView: View {
    @EnvironmentObject var model: VoiceMemosModel
    @StateObject var player = AudioPlayer() // Local player for chat context
    @State private var input = ""
    @State private var selectedCitation: Citation?
    @State private var selectedCitationNumber: Int = 0
    let service = GeminiService()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack {
                ChatHistoryView(
                    history: model.chatHistory,
                    onCitationTap: { index, displayNum in
                        // 1. Get the citation data
                        if let citation = model.getCitation(for: index) {
                            
                            // 2. Trigger the UI Highlight (The Card)
                            withAnimation {
                                selectedCitation = citation
                                selectedCitationNumber = displayNum
                            }
                        }
                    },
                    onSummarize: {
                        sendMessage("Summarize these recordings")
                    },
                    hasSelection: !model.selectedRecordingIDs.isEmpty,
                    scrollID: $model.chatScrollID
                )
                
                Spacer()
                
                // Input Bar
                HStack {
                    TextField("Ask AI...", text: $input)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(20)
                        .onSubmit { sendMessage(input) }
                    Button(action: { sendMessage(input) }) {
                        Image(systemName: "arrow.up.circle.fill").font(.largeTitle)
                    }
                }
                .padding()
                .background(.bar)
            }
            
            // The Citation Card (The Highlight UI)
            if let citation = selectedCitation {
                CitationCardView(
                    citation: citation, citationNumber: selectedCitationNumber,
                    player: player,
                    onClose: {
                        withAnimation { selectedCitation = nil }
                        player.stop()
                    },
                    onViewSource: {
                        // Logic to jump to the full transcript view
                        withAnimation { selectedCitation = nil }
                        player.stop() // Stop local player so full player can take over
                        if let rec = model.recordings.first(where: { $0.id == citation.recordingID }) {
                            DispatchQueue.main.async {
                                model.playbackRequest = PlaybackRequest(recording: rec, time: citation.startTime)
                            }
                        }
                    }
                )
                // Add padding so it doesn't sit behind the keyboard/input bar
                .padding(.bottom, 80)
            }
        }
        .onDisappear {
            player.stop()
        }
    }
    
    func sendMessage(_ text: String) {
        guard !text.isEmpty else { return }
        
        // 1. Validation
        if model.selectedRecordingIDs.isEmpty {
            model.chatHistory.append(ChatMessage(role: .model, text: "Please select at least one recording in the Sources tab."))
            return
        }
        
        let ctx = model.combinedTranscriptContext
        let validText = ctx.components(separatedBy: "\n").filter { !$0.contains("--- SOURCE:") && !$0.contains("No text...") }.joined()
        if validText.isEmpty {
            model.chatHistory.append(ChatMessage(role: .model, text: "The selected recordings do not have transcripts yet. Please transcribe them first."))
            return
        }
        
        // 2. Add User Message
        model.chatHistory.append(ChatMessage(role: .user, text: text))
        input = ""
        
        // 3. Add Placeholder WITH Animation Flag
        // We set it to "LOADING_ANIMATION" so the ThinkingView appears immediately
        model.chatHistory.append(ChatMessage(role: .model, text: "LOADING_ANIMATION", isLoading: true))
        
        // 4. Start Streaming
        Task {
            do {
                // We pass dropLast() so we don't send "LOADING_ANIMATION" to the AI as context
                let stream = service.streamChat(history: model.chatHistory.dropLast(), context: ctx)
                
                for try await chunk in stream {
                    await MainActor.run {
                        // Update the very last message (which is our placeholder)
                        if let index = model.chatHistory.indices.last {
                            var currentText = model.chatHistory[index].text
                            
                            // --- THE FIX ---
                            // If it still says "LOADING_ANIMATION", clear it before adding the first word.
                            if currentText == "LOADING_ANIMATION" {
                                currentText = ""
                            }
                            
                            model.chatHistory[index] = ChatMessage(
                                role: .model,
                                text: currentText + chunk,
                                isLoading: false // Stop loading state once data arrives
                            )
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    // If error, replace animation with error text
                    if let index = model.chatHistory.indices.last {
                        model.chatHistory[index] = ChatMessage(role: .model, text: "Error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

// MARK: - RECORDING ROW & SWIPEABLE ROW (MUST BE TOP LEVEL)

struct RecordingRow: View {
    let recording: Recording
    let audioURL: URL
    let isExpanded: Bool
    let isRenaming: Bool
    @ObservedObject var player: AudioPlayer
    
    let onTap: () -> Void
    let onRename: () -> Void
    let onCommitRename: (String) -> Void
    let onDelete: () -> Void
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onMove: () -> Void
    
    @State private var editableName = ""
    @FocusState private var isFocused: Bool
    @State private var isRotating = false
    
    var isCurrentPlayerItem: Bool { player.currentRecordingId == recording.id }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            if isExpanded {
                expandedControlView
            }
        }
        .clipped()
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left Content (Name/Date)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if isRenaming {
                        TextField("Name", text: $editableName)
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.plain)
                            .focused($isFocused)
                            .onSubmit { onCommitRename(editableName) }
                            .onAppear { editableName = recording.name; isFocused = true }
                    } else {
                        Text(recording.name).font(.body).fontWeight(.semibold).lineLimit(1)
                    }
                }
                HStack {
                    Text(recording.relativeDateString).font(.subheadline).foregroundColor(.secondary)
                    if recording.isFavorite { Image(systemName: "heart.fill").font(.subheadline).foregroundColor(.red) }
                    Spacer()
                    if !isExpanded {
                        Text(recording.duration.formattedDuration)
                            .font(.subheadline).foregroundColor(.secondary)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if isRenaming { onCommitRename(editableName) } else { onTap() } }
            
            // Right Menu
            if isExpanded {
                menuView
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemBackground))
        .zIndex(1)
    }
    
    private var menuView: some View {
        Menu {
            ShareLink(item: audioURL) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(action: onEdit) { Label("View Transcript", systemImage: "doc.text") }
            Button(action: onMove) { Label("Move", systemImage: "folder") }
            Button(action: onToggleFavorite) {
                Label(recording.isFavorite ? "Unfavorite" : "Favorite", systemImage: recording.isFavorite ? "heart.slash" : "heart")
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 22))
                .foregroundColor(.blue)
                .frame(width: 44, height: 40, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .highPriorityGesture(TapGesture())
        .padding(.leading, 8)
    }
    
    private var expandedControlView: some View {
        VStack(spacing: 16) {
            ScrubberBar(
                current: Binding(get: { isCurrentPlayerItem ? player.currentTime : 0 }, set: { player.seek(to: $0) }),
                total: recording.duration
            )
            
            HStack {
                Text(formatTime(isCurrentPlayerItem ? player.currentTime : 0))
                Spacer()
                Text("-" + formatTime(recording.duration - (isCurrentPlayerItem ? player.currentTime : 0)))
            }
            .font(.caption).foregroundColor(.secondary).monospacedDigit()
            
            HStack {
                Button(action: onEdit) { Image(systemName: "waveform").font(.system(size: 22)) }
                    .buttonStyle(BorderlessButtonStyle())
                    .foregroundColor(.accentColor)
                
                statusBadge
                
                Spacer()
                
                playbackButtons
                
                Spacer()
                
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 22)) }
                    .buttonStyle(BorderlessButtonStyle())
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.bottom, 14)
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemBackground))
        .zIndex(0)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity.animation(.linear(duration: 0.15))
        ))
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        if recording.isQueued {
            Spacer().frame(width: 8)
            HStack(spacing: 4) {
                Image(systemName: "wifi.slash")
                Text("Queued")
            }
            .font(.caption2)
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(4)
        } else if recording.isTranscribing {
            Spacer().frame(width: 8)
            HStack(spacing: 4) {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .rotationEffect(.degrees(isRotating ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isRotating)
                    .onAppear { isRotating = true }
                Text("Processing")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(2)
        } else if recording.transcript == nil || recording.transcript?.isEmpty == true {
            Spacer().frame(width: 8)
            Text("No Transcript")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(2)
        }
    }
    
    private var playbackButtons: some View {
        Group {
            Button(action: { player.seek(to: player.currentTime - 15) }) {
                Image(systemName: "gobackward.15").font(.title2)
            }
            .buttonStyle(BorderlessButtonStyle())
            .foregroundColor(.primary)
            
            Spacer()
            
            Button(action: onPlay) {
                Image(systemName: isCurrentPlayerItem && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
            }
            .buttonStyle(BorderlessButtonStyle())
            .foregroundColor(.primary)
            
            Spacer()
            
            Button(action: { player.seek(to: player.currentTime + 15) }) {
                Image(systemName: "goforward.15").font(.title2)
            }
            .buttonStyle(BorderlessButtonStyle())
            .foregroundColor(.primary)
        }
    }
    
    func formatTime(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct SwipeableRow<Content: View>: View {
    let onDelete: () -> Void
    let content: Content
    
    init(onDelete: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDelete = onDelete
        self.content = content()
    }
    
    @State private var offset: CGFloat = 0
    @State private var isSwiped: Bool = false
    
    var body: some View {
        ZStack(alignment: .trailing) {
            deleteButton
            
            content
                .background(Color(UIColor.systemBackground))
                .offset(x: offset)
                .gesture(dragGesture) // Extracted Gesture
                .onTapGesture {
                    if isSwiped {
                        withAnimation {
                            offset = 0
                            isSwiped = false
                        }
                    }
                }
                .zIndex(1)
        }
    }
    
    private var deleteButton: some View {
        Group {
            if offset < 0 {
                Button(action: { withAnimation { onDelete() } }) {
                    ZStack {
                        Color.red
                        Image(systemName: "trash.fill")
                            .foregroundColor(.white)
                            .font(.title3)
                    }
                    .frame(width: 80)
                }
                .zIndex(0)
            }
        }
    }
    
    // Explicitly defining the gesture helps the compiler significantly
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { gesture in
                if gesture.translation.width < 0 {
                    offset = gesture.translation.width
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.15, dampingFraction: 0.7)) {
                    if offset < -60 {
                        offset = -80
                        isSwiped = true
                    } else {
                        offset = 0
                        isSwiped = false
                    }
                }
            }
    }
}

// MARK: - NATIVE SEGMENTED CONTROL WRAPPER
struct NativeSegmentedControl: UIViewRepresentable {
    @Binding var selection: AnalysisTab
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> UISegmentedControl {
        let items = AnalysisTab.allCases.map { $0.rawValue }
        let control = UISegmentedControl(items: items)
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        return control
    }
    
    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        if let index = AnalysisTab.allCases.firstIndex(of: selection) {
            if uiView.selectedSegmentIndex != index {
                uiView.selectedSegmentIndex = index
            }        }
    }
    
    class Coordinator: NSObject {
        var parent: NativeSegmentedControl
        
        init(_ parent: NativeSegmentedControl) {
            self.parent = parent
        }
        
        @objc func valueChanged(_ sender: UISegmentedControl) {
            let index = sender.selectedSegmentIndex
            if index < AnalysisTab.allCases.count {
                // We wrap this in an animation block to ensure the SwiftUI view below
                // transitions smoothly while the native control handles its own slide.
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.parent.selection = AnalysisTab.allCases[index]
                }
            }
        }
    }
}
