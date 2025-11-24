import AVFoundation
import Foundation
import Network
import ReplayKit
import Speech
import SwiftUI

#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// MARK: - 1. CONFIG & API
let API_KEY = "" // Enter your Gemini API Key here
let MODEL_NAME = "gemini-3-pro-preview"

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
    func presentedSubitemAt(_ oldURL: URL, didMoveTo newURL: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        onChange()
        completionHandler(nil)
    }
}

// MARK: - 4. MODELS
struct Recording: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    let date: Date
    var duration: TimeInterval
    var fileName: String
    var transcript: String?
    var isFavorite: Bool = false
    var folderName: String? = nil
    
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
    case sources = "Sources"
}

struct EditConfig: Identifiable {
    let id = UUID()
    let recording: Recording
    var showTranscriptInitially: Bool
}

struct TranscriptSegment: Identifiable, Equatable {
    let id = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
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
            performGeminiTranscription(job: job)
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
            performGeminiTranscription(job: job)
        }
        pendingJobs.removeAll()
    }
    
    private func performGeminiTranscription(job: PendingJob) {
        guard let audioData = try? Data(contentsOf: job.url) else {
            job.onError("Could not read audio file.")
            return
        }
        
        let base64Audio = audioData.base64EncodedString()
        var apiKey = UserDefaults.standard.string(forKey: "GEMINI_API_KEY") ?? ""
        if apiKey.isEmpty { apiKey = API_KEY }
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(MODEL_NAME):generateContent?key=\(apiKey)") else {
            job.onError("Invalid URL")
            return
        }
        
        var prompt = "Transcribe this audio file verbatim.\n"
        prompt += "FORMATTING REQUIREMENTS:\n"
        prompt += "1. Use the format: `[MM:SS] Speaker Name: Text`.\n"
        prompt += "2. Timestamps must be based on total elapsed time from the start (00:00).\n"
        prompt += "3. Do not use Markdown formatting (no bold, no italics).\n"
        
        if !job.context.isEmpty {
            prompt += "\nCONTEXT PROVIDED BY USER:\n"
            prompt += "\"\(job.context)\"\n"
            prompt += "INSTRUCTION: Use the context above to identify specific speakers (e.g. assign names like 'Joshua', 'Zach' based on the voices). If a name is not known, use 'Speaker 1', 'Speaker 2', etc."
        } else {
            prompt += "INSTRUCTION: Identify distinct speakers as 'Speaker 1', 'Speaker 2', etc."
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
        
        print("🚀 Sending to Gemini (\(MODEL_NAME))...")
        URLSession.shared.dataTask(with: request) { data, response, error in
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

// MARK: - 6. GEMINI AI SERVICE (CHAT)
class GeminiService {
    func analyzeChat(history: [ChatMessage], context: String) async -> String {
        var apiKey = UserDefaults.standard.string(forKey: "GEMINI_API_KEY") ?? ""
        if apiKey.isEmpty { apiKey = API_KEY }
        guard !apiKey.isEmpty else { return "⚠️ API Key Missing. Check Settings." }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(MODEL_NAME):generateContent?key=\(apiKey)") else { return "Error: Invalid URL" }
        
        var apiContents: [[String: Any]] = []
        let systemContext = """
        You are an AI assistant. Context:
        
        \(context)
        
        INSTRUCTION: The source text is already strictly numbered with tags like [1], [2], etc.
        When citing sources, YOU MUST USE THESE EXACT EXISTING NUMBERS.
        DO NOT count sentences yourself.
        DO NOT invent new numbers.
        If you see text labeled "[15]", cite it as [15].
        
        FORMATTING RULES:
        - Output PLAIN TEXT ONLY.
        - DO NOT use Markdown (no bold **, no italics *, no headers #).
        - Do not use bullet points or lists, just use plain paragraphs.
        """
        
        for (index, msg) in history.enumerated() {
            if msg.isLoading { continue }
            var textToSend = msg.text
            if index == 0 && msg.role == .user { textToSend = systemContext + "\n\nUSER QUESTION: " + msg.text }
            apiContents.append(["role": msg.role == .user ? "user" : "model", "parts": [["text": textToSend]]])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["contents": apiContents])
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                return text
            } else { return "Failed to parse response." }
        } catch { return "Network error: \(error.localizedDescription)" }
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
    
    static let timestampRegex = try? NSRegularExpression(pattern: "\\[(\\d{2}):(\\d{2})\\]")
    
    @AppStorage("storageBookmarkData") private var storageBookmarkData: Data?
    private var customStorageURL: URL?
    private var directoryMonitor: DirectoryMonitor?
    
    init() {
        restoreStorageAccess()
        setupMonitor()
        loadExistingRecordings()
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
        
        for rec in selectedRecs {
            // 1. Assign a number to the Header (Matches your app's logic)
            globalIndex += 1
            context += "[\(globalIndex)] --- SOURCE: \(rec.name) ---\n"
            
            // 2. Assign a number to every transcript line
            let segments = rec.sentenceSegments
            for segment in segments {
                globalIndex += 1
                // Inject the [N] tag directly into the text the AI reads
                context += "[\(globalIndex)] \(segment)\n"
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
    
    private func getRootURL() -> URL {
        if let folder = customStorageURL, (try? folder.checkResourceIsReachable()) == true {
            return folder
        }
        return FileHelper.getDocumentsDirectory()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.loadExistingRecordings()
            }
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
    
    // MARK: - RETRY LOGIC
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
    
    func setCustomStorageLocation(_ url: URL) {
        customStorageURL?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else { return }
        
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            storageBookmarkData = data
            customStorageURL = url
            setupMonitor()
            loadExistingRecordings()
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
        
        // --- UPDATED LOADING LOGIC ---
        // We removed the 'fileExists' check because it often fails on external drives.
        // Now we just attempt to read it directly.
        do {
            diskTranscript = try String(contentsOf: txtURL)
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
            
            // Only use existing memory-state if we are actively processing
            if isTranscribingState || isEnhancingState {
                transcriptToUse = existing.transcript
            }
        }
        
        return Recording(
            id: idToUse,
            // Clean name for display
            name: fileName.replacingOccurrences(of: ".m4a", with: "")
                .replacingOccurrences(of: ".mp3", with: "")
                .replacingOccurrences(of: ".wav", with: ""),
            date: date,
            duration: duration,
            fileName: fileName,
            transcript: transcriptToUse,
            isFavorite: false,
            folderName: folder,
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
    
    @discardableResult
    func saveNewRecording(fileName: String, duration: TimeInterval, folder: String?) -> UUID {
        self.suppressReloads = true
        
        let tempSourceURL = FileHelper.getFileURL(for: fileName)
        let root = getRootURL()
        var destDir = root
        if let f = folder { destDir = root.appendingPathComponent(f, isDirectory: true) }
        
        let baseName = "New Recording \(recordings.count + 1)"
        var name = baseName
        var counter = 1
        var destURL = destDir.appendingPathComponent("\(name).m4a")
        while FileManager.default.fileExists(atPath: destURL.path) {
            name = "\(baseName) \(counter)"
            destURL = destDir.appendingPathComponent("\(name).m4a")
            counter += 1
        }
        let uniqueFileName = destURL.lastPathComponent
        
        do {
            if customStorageURL != nil { _ = root.startAccessingSecurityScopedResource() }
            try FileManager.default.moveItem(at: tempSourceURL, to: destURL)
        } catch {
            resetStorageLocation()
            let localDest = FileHelper.getFileURL(for: uniqueFileName)
            try? FileManager.default.moveItem(at: tempSourceURL, to: localDest)
        }
        
        let newID = UUID()
        
        let newRec = Recording(id: newID, name: baseName, date: Date(), duration: duration, fileName: uniqueFileName, transcript: nil, folderName: folder, isTranscribing: true)
        
        withAnimation { recordings.insert(newRec, at: 0) }
        
        runTranscription(for: uniqueFileName, folder: folder, context: "", isEnhancing: false)
        
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
        if let folder = customStorageURL { _ = folder.startAccessingSecurityScopedResource() }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: txtUrl)
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
    
    // In VoiceMemosModel.swift
    
    func getCitation(for index: Int) -> Citation? {
        
        let selectedRecs = sortedSelectedRecordings
        
        // We simulate the loop to see exactly where the index falls
        var remainingIndex = index - 1 // Convert 1-based citation to 0-based math
        var globalCounter = 0
        
        for rec in selectedRecs {
            let segments = rec.sentenceSegments
            // Your logic counts the "Header" as 1 index, plus the segments
            let countInRecording = segments.count + 1
            
            let rangeStart = globalCounter + 1
            let rangeEnd = globalCounter + countInRecording
            
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
class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    // MARK: - PUBLISHED STATE
    @Published var isRecording = false
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
    
    // MARK: - MAC SPECIFIC PROPERTIES
    private var assetWriter: AVAssetWriter?
    private var audioMicInput: AVAssetWriterInput?
    private var audioAppInput: AVAssetWriterInput?
    private var isWritingStarted = false
    private var startTime: CMTime = .invalid
    // Serial queue to protect the writer from crashing when two inputs arrive at once
    private let writerQueue = DispatchQueue(label: "com.yourapp.writerQueue")
    
#if targetEnvironment(macCatalyst)
    private var scStream: SCStream?
    private var micSession: AVCaptureSession?
    private var scOutputHandler: SCKOutputHandler?
#endif
    
    // MARK: - iOS SPECIFIC PROPERTIES
    private var iosRecorder: AVAudioRecorder?
    
    // MARK: - PUBLIC API
    
    func startRecording() {
        self.recordingDuration = 0
        self.audioSamples = Array(repeating: 0.1, count: 50)
        self.isWritingStarted = false
        self.startTime = .invalid
        
        let rawFileName = "temp_raw.m4a" // Note: For video/screen this usually needs to be .mov or .mp4 if using video writer
        // Since we are using AVAssetWriter for Audio only on Mac, .m4a is fine.
        
        let url = FileHelper.getFileURL(for: rawFileName)
        self.lastSavedURL = url
        try? FileManager.default.removeItem(at: url)
        
        // Start Background Task (Crucial for iOS Lock Screen)
        self.backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        
#if targetEnvironment(macCatalyst)
        setupMacEngine(url: url)
#else
        setupiOSEngine(url: url)
        startLiveActivity()
#endif
    }
    
    func stopRecording(completion: @escaping (String?, TimeInterval) -> Void) {
        let finalDuration = self.recordingDuration
        self.timer?.invalidate()
        
        let finishClosure: () -> Void = {
            DispatchQueue.main.async {
                self.isRecording = false
                guard let rawURL = self.lastSavedURL else {
                    completion(nil, 0)
                    self.endBackgroundTask()
                    return
                }
                
                let finalName = self.renameToFinal(url: rawURL)
                completion(finalName, finalDuration)
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
    
    // MARK: - HELPER METHODS
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    func renameToFinal(url: URL) -> String {
        let dateStr = Date().formatted(date: .numeric, time: .shortened)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        let newName = "Meeting \(dateStr).m4a"
        let newURL = FileHelper.getFileURL(for: newName)
        try? FileManager.default.moveItem(at: url, to: newURL)
        return newName
    }
    
    // MARK: - AUDIO MIXER
    // This takes the 2-track file (Mic + System) and flattens it into a 1-track file
    // MARK: - AUDIO MIXER (FIXED)
    private func mixAudioTracks(sourceURL: URL, completion: @escaping (URL?) -> Void) {
        let composition = AVMutableComposition()
        let asset = AVURLAsset(url: sourceURL)
        
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                print("🎛️ Found \(tracks.count) audio tracks to mix.")
                
                if tracks.isEmpty {
                    completion(sourceURL)
                    return
                }
                
                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                
                // FIX: Loop through sources and create a NEW lane for EACH one.
                // Previously we tried to put them all in one lane, which caused overwriting.
                for track in tracks {
                    let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try compositionTrack?.insertTimeRange(timeRange, of: track, at: .zero)
                }
                
                // Export
                let mixedURL = FileHelper.getFileURL(for: "mixed_final.m4a")
                try? FileManager.default.removeItem(at: mixedURL)
                
                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                    print("❌ Could not create export session")
                    completion(sourceURL)
                    return
                }
                
                exportSession.outputURL = mixedURL
                exportSession.outputFileType = .m4a
                
                await exportSession.export()
                
                if exportSession.status == .completed {
                    try? FileManager.default.removeItem(at: sourceURL) // Cleanup raw file
                    print("✅ Mixing Success")
                    completion(mixedURL)
                } else {
                    print("❌ Export Failed: \(String(describing: exportSession.error))")
                    completion(sourceURL)
                }
            } catch {
                print("❌ Mixer Critical Error: \(error)")
                completion(sourceURL)
            }
        }
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                self.recordingDuration += 0.05
                self.updateMeters()
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    private func updateMeters() {
        var level: CGFloat = 0.1
#if targetEnvironment(macCatalyst)
        level = CGFloat.random(in: 0.1...0.5) // Simulated on Mac
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
    
    // MARK: - 🖥️ MAC ENGINE
    
#if targetEnvironment(macCatalyst)
    private func setupMacEngine(url: URL) {
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch { print("Writer init failed: \(error)"); return }
        
        // Standard 48kHz Audio Settings
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]
        
        // Track 1: Microphone
        audioMicInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioMicInput?.expectsMediaDataInRealTime = true
        
        // Track 2: System Audio
        audioAppInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioAppInput?.expectsMediaDataInRealTime = true
        
        if let w = assetWriter {
            if w.canAdd(audioMicInput!) { w.add(audioMicInput!) }
            if w.canAdd(audioAppInput!) { w.add(audioAppInput!) }
        }
        
        startMacCapture()
    }
    
    private func startMacCapture() {
        Task {
            // 1. Start Microphone (AVCaptureSession)
            //    We ask for permission first!
            if await AVCaptureDevice.requestAccess(for: .audio) {
                self.micSession = AVCaptureSession()
                if let mic = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: mic) {
                    if micSession!.canAddInput(input) { micSession!.addInput(input) }
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "micQueue"))
                    if micSession!.canAddOutput(output) { micSession!.addOutput(output) }
                }
                DispatchQueue.global(qos: .userInitiated).async { self.micSession?.startRunning() }
            } else {
                print("⚠️ Microphone access denied on Mac")
            }
            
            // 2. Start System Audio (ScreenCaptureKit)
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else { return }
                
                // Filter: Capture everything on the display
                // We EXCLUDE our own app to prevent feedback loops if we play the audio back
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                
                let config = SCStreamConfiguration()
                // CRITICAL SETTINGS
                config.capturesAudio = true
                config.sampleRate = 48000 // Must match writer
                config.excludesCurrentProcessAudio = false // Set to FALSE if you want to record your own app's sounds
                config.channelCount = 1
                
                // Even for audio-only, width/height must be set to avoid errors
                config.width = 100
                config.height = 100
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                
                self.scStream = SCStream(filter: filter, configuration: config, delegate: nil)
                self.scOutputHandler = SCKOutputHandler(parent: self)
                
                // We only care about .audio here
                try await self.scStream?.addStreamOutput(self.scOutputHandler!, type: .audio, sampleHandlerQueue: DispatchQueue(label: "scAudioQueue"))
                
                try await self.scStream?.startCapture()
                
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.startTimer()
                }
                print("✅ Mac Recording Started (Mic + System)")
            } catch {
                print("❌ SCKit Error: \(error)")
            }
        }
    }
    
#if targetEnvironment(macCatalyst)
    private func stopMacEngine(completion: @escaping () -> Void) {
        Task {
            // 1. Stop Capture
            try? await scStream?.stopCapture()
            micSession?.stopRunning()
            self.scOutputHandler = nil
            
            // 2. Finish Writing the Raw File
            if let writer = assetWriter, writer.status == .writing {
                audioMicInput?.markAsFinished()
                audioAppInput?.markAsFinished()
                await writer.finishWriting()
            }
            
            // 3. MIX THE AUDIO (The Fix)
            // We take the 2-track file and mix it down to 1 track so you can hear both
            if let rawURL = self.lastSavedURL {
                self.mixAudioTracks(sourceURL: rawURL) { mixedURL in
                    // Update the lastSavedURL to point to the new mixed file
                    if let url = mixedURL {
                        self.lastSavedURL = url
                    }
                    completion()
                }
            } else {
                completion()
            }
        }
    }
#endif
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        Task { @MainActor in
            self.processBuffer(sampleBuffer, isMic: true)
        }
    }
    
    private class SCKOutputHandler: NSObject, SCStreamOutput {
        weak var parent: AudioRecorder?
        init(parent: AudioRecorder) { self.parent = parent }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            // ONLY process audio buffers
            guard type == .audio else { return }
            Task { @MainActor in
                self.parent?.processBuffer(sampleBuffer, isMic: false)
            }
        }
    }
    
    // Consolidated Writer
    private func processBuffer(_ buffer: CMSampleBuffer, isMic: Bool) {
        guard let writer = assetWriter else { return }
        
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Sync Start Time
            if !self.isWritingStarted {
                writer.startWriting()
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                writer.startSession(atSourceTime: pts)
                self.startTime = pts
                self.isWritingStarted = true
            }
            
            if writer.status == .writing {
                let input = isMic ? self.audioMicInput : self.audioAppInput
                if let input = input, input.isReadyForMoreMediaData {
                    input.append(buffer)
                }
            }
        }
    }
#endif
    
    // MARK: - 📱 iOS ENGINE
    
    private func setupiOSEngine(url: URL) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP
            ])
            try session.setActive(true)
            
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            iosRecorder = try AVAudioRecorder(url: url, settings: settings)
            iosRecorder?.isMeteringEnabled = true
            
            if iosRecorder?.record() == true {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.startTimer()
                }
            }
            setupInterruptionObserver()
        } catch {
            print("iOS Setup Error: \(error)")
        }
    }
    
    private func stopiOSEngine(completion: @escaping () -> Void) {
        iosRecorder?.stop()
        iosRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        completion()
    }
    
    private func setupInterruptionObserver() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let self = self, let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            
            if type == .ended {
                try? AVAudioSession.sharedInstance().setActive(true)
                self.iosRecorder?.record()
            }
        }
    }
    
    // MARK: - LIVE ACTIVITY HELPERS
    
    private func startLiveActivity() {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        let attributes = RecordingAttributes(recordingName: "New Recording")
        let state = RecordingAttributes.ContentState(recordingStartDate: Date())
        
        do {
            self.currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            print("✅ Live Activity Started")
        } catch {
            print("❌ Failed to start Live Activity: \(error)")
        }
#endif
    }
    
    private func stopLiveActivity() {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard let activity = currentActivity else { return }
        
        let finalState = RecordingAttributes.ContentState(recordingStartDate: Date())
        
        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            self.currentActivity = nil
            print("🛑 Live Activity Ended")
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
            // FIX: We added options here.
            // 1. .allowBluetoothA2DP: Keeps it on your AirPods/Mac.
            // 2. .mixWithOthers: Ensures hitting "Play" doesn't kill your Zoom meeting audio if it's still running.
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
        
        // Optional: You can deactivate the session here to let other apps take over fully,
        // but keeping it active usually prevents audio blips.
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let p = self.audioPlayer {
                withAnimation(.linear(duration: 0.1)) {
                    self.currentTime = p.currentTime
                }
            }
        }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
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
        .sheet(item: $model.playbackRequest, onDismiss: {
            // STOP audio when dismissed
            globalPlayer.stop()
        }) { request in
            RecordingDetailSheet(
                recording: request.recording,
                showTranscriptInitially: true,
                player: globalPlayer,
                model: model,
                initialSeekTime: request.time
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
            } else {
                // STOP BUTTON (Updated for Async)
                Button(action: {
                    // Pass a closure to handle the save when it finishes
                    recorder.stopRecording { fileName, duration in
                        if let name = fileName {
                            let newID = model.saveNewRecording(fileName: name, duration: duration, folder: activeFolder)
                            
                            withAnimation {
                                expandedRecordingId = newID
                            }
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
        .sheet(item: $editConfig) { c in
            RecordingDetailSheet(recording: c.recording, showTranscriptInitially: c.showTranscriptInitially, player: player, model: model)
                .presentationDetents([.large, .medium], selection: $sheetDetent)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $moveConfig) { rec in
            FolderSelectionSheet(isMoving: true, recording: rec)
        }
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
    
    // State to hold parsed segments
    @State private var transcriptSegments: [TranscriptSegment] = []
    
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
    
    // Calculate which segment is currently active based on player time
    var activeSegmentId: UUID? {
        guard isCurrentPlayerItem else { return nil }
        // Find the segment where currentTime is between start and (start + 5 or next start)
        return transcriptSegments.first { segment in
            player.currentTime >= segment.startTime && player.currentTime < segment.endTime
        }?.id
    }
    
    var body: some View {
        NavigationStack {
            if let recording = liveRecording {
                VStack(spacing: 0) {
                    
                    // MARK: - HEADER
                    VStack(spacing: 0) {
                        HStack {
                            if let t = recording.transcript, t.hasPrefix("Failed:") {
                                Button(action: {
                                    model.retryTranscription(recording: recording)
                                }) {
                                    Text("Retry")
                                        .fontWeight(.medium) // Medium size/weight requested
                                        .foregroundColor(.blue)
                                }
                                .padding(.leading, 20)
                                .padding(.top, 20)
                            }
                            Spacer()
                            Button(action: {
                                if !recording.isEnhancing && !recording.isTranscribing {
                                    showEnhanceSheet = true
                                }
                            }) {
                                HStack(spacing: 6) {
                                    if recording.isEnhancing {
                                        Image(systemName: "arrow.trianglehead.2.clockwise")
                                            .rotationEffect(.degrees(isRotating ? 360 : 0))
                                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isRotating)
                                            .onAppear { isRotating = true }
                                        Text("Enhancing...")
                                    } else {
                                        Image(systemName: "sparkles")
                                        Text("Enhance")
                                    }
                                }
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.purple.opacity(0.1))
                                .foregroundColor(.purple)
                                .cornerRadius(20)
                            }
                            .disabled(recording.isEnhancing || recording.isTranscribing)
                            .padding(.top, 20)
                            .padding(.trailing, 20)
                        }
                        
                        Spacer().frame(height: 10)
                        
                        VStack(spacing: 4) {
                            Text(recording.name).font(.headline)
                            Text(recording.duration.formatted()).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.bottom, 15)
                    }
                    .background(Color(UIColor.systemBackground))
                    .zIndex(1)
                    
                    // MARK: - CONTENT AREA
                    ZStack(alignment: .bottom) {
                        
                        if isShowingTranscript {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        if recording.isEnhancing {
                                            TranscriptSkeleton()
                                        } else if transcriptSegments.isEmpty {
                                            // Fallback for unparsed text or text without timestamps
                                            Text(recording.transcript ?? "Transcript pending or unavailable.")
                                                .font(.body)
                                                .lineSpacing(6)
                                                .padding()
                                        } else {
                                            // RENDER PARSED SEGMENTS
                                            ForEach(transcriptSegments) { segment in
                                                let isActive = activeSegmentId == segment.id
                                                
                                                Text(segment.text)
                                                    .font(.body)
                                                    .lineSpacing(6)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 8)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .fill(isActive ? Color.yellow.opacity(0.3) : Color.clear)
                                                            .animation(.easeInOut(duration: 0.3), value: isActive)
                                                    )
                                                    .id(segment.id)
                                                    .onTapGesture {
                                                        // Tap text to jump audio to that time
                                                        if isCurrentPlayerItem {
                                                            player.seek(to: segment.startTime)
                                                        } else {
                                                            let url = model.getFileUrl(for: recording)
                                                            player.play(url: url, recordingId: recording.id, startTime: segment.startTime)
                                                        }
                                                    }
                                            }
                                        }
                                    }
                                    .padding(.top, 20)
                                    .padding(.bottom, 220) // Clearance for controls
                                }
                                // Auto-scroll logic
                                .onChange(of: activeSegmentId) { newId in
                                    if let id = newId {
                                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                            proxy.scrollTo(id, anchor: .center)
                                        }
                                    }
                                }
                                .onAppear {
                                    if let seekTime = initialSeekTime {
                                        parseTranscript(recording.transcript)
                                        let url = model.getFileUrl(for: recording)
                                        player.play(url: url, recordingId: recording.id, startTime: seekTime)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            if let segment = transcriptSegments.first(where: { seekTime >= $0.startTime && seekTime < $0.endTime }) {
                                                withAnimation { proxy.scrollTo(segment.id, anchor: .center) }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // MARK: - LIVE WAVEFORM
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
                        
                        // MARK: - BOTTOM CONTROLS
                        VStack(spacing: 0) {
                            Divider()
                            
                            VStack(spacing: 20) {
                                // Scrubber
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
                                
                                // Buttons
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
                                
                                // View Toggle
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
                }
                .navigationBarHidden(true)
                .onAppear {
                    isShowingTranscript = true
                    parseTranscript(recording.transcript)
                }
                .onChange(of: recording.transcript) { newText in
                    parseTranscript(newText)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 24))
                .ignoresSafeArea(edges: .bottom)
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
            } else {
                Text("Recording not found")
            }
        }
    }
    
    // MARK: - Parsing Logic
    func parseTranscript(_ text: String?) {
        guard let text = text, !text.isEmpty else {
            self.transcriptSegments = []
            return
        }
        
        // This splits by the logic used in Transcriber: [MM:SS] Speaker: Text
        // It assumes new lines separate segments.
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        var segments: [TranscriptSegment] = []
        
        // Regex to find [00:00]
        let regex = VoiceMemosModel.timestampRegex
        
        for i in 0..<lines.count {
            let line = lines[i]
            var startTime: TimeInterval = 0
            
            // Extract time
            if let regex = regex,
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                
                let range1 = Range(match.range(at: 1), in: line)!
                let range2 = Range(match.range(at: 2), in: line)!
                
                if let min = Double(line[range1]), let sec = Double(line[range2]) {
                    startTime = (min * 60) + sec
                }
            } else {
                // Approximate time if regex fails (fallback)
                // If it's the first line, 0. If following lines, add 2 seconds arbitrarily
                startTime = segments.last?.endTime ?? 0
            }
            
            // Look ahead to find end time, or assume ~5 seconds duration if it's the last one
            // In a real app, you'd use the next line's start time as this line's end time
            let endTime: TimeInterval
            if i + 1 < lines.count {
                // Peek next line logic would be better here, but for simplicity:
                // We will calculate exact end times in a second pass, or just rely on the 'next start'
                // For now, let's set it to distant future, and we fix it in the list construction
                endTime = startTime + 60 // placeholder
            } else {
                endTime = startTime + 60
            }
            
            segments.append(TranscriptSegment(startTime: startTime, endTime: endTime, text: line))
        }
        
        // Fix end times: A segment ends when the next one begins
        for i in 0..<segments.count {
            if i < segments.count - 1 {
                segments[i] = TranscriptSegment(
                    startTime: segments[i].startTime,
                    endTime: segments[i+1].startTime,
                    text: segments[i].text
                )
            } else {
                // Last segment gets a generous 30 seconds or max duration
                segments[i] = TranscriptSegment(
                    startTime: segments[i].startTime,
                    endTime: segments[i].startTime + 30,
                    text: segments[i].text
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
            .onChange(of: dictation.text) { newValue in
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

extension TimeInterval {
    var formattedDuration: String { String(format: "%02d:%02d", Int(self) / 60, Int(self) % 60) }
    var formattedDurationLong: String { String(format: "%02d:%02d.%02d", Int(self) / 60, Int(self) % 60, Int((self.truncatingRemainder(dividingBy: 1)) * 100)) }
}

// MARK: - 10. ANALYSIS & TRANSCRIPT VIEWS
struct AnalysisMainView: View {
    @EnvironmentObject var model: VoiceMemosModel
    var body: some View {
        NavigationStack(path: $model.navigationPath) {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    VStack {
                        Text("Analysis").font(.headline).padding(.top, 8)
                        Picker("Tab", selection: $model.analysisTabSelection) {
                            ForEach(AnalysisTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
                        }.pickerStyle(.segmented).padding()
                    }
                    if model.analysisTabSelection == .chat && !model.chatHistory.isEmpty {
                        Button(action: { model.resetChat() }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title).foregroundColor(.blue).padding(.trailing, 16)
                        }
                    }
                }.background(Color(UIColor.systemGroupedBackground))
                
                if !model.recordings.isEmpty {
                    Group {
                        switch model.analysisTabSelection {
                        case .chat: AnalysisChatView()
                        case .sources: AnalysisSourcesView()
                        }
                    }.background(Color(UIColor.systemGroupedBackground))
                } else {
                    ContentUnavailableView("No Recordings", systemImage: "doc.text.magnifyingglass", description: Text("Create a recording to start analysis."))
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Recording.self) { recording in
                TranscriptView(recording: recording)
            }
        }
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
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject var model: VoiceMemosModel
    var onClose: () -> Void
    var onViewSource: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
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
                        player.play(url: model.getFileUrl(for: rec), recordingId: rec.id, startTime: citation.startTime)
                    }
                }) {
                    HStack { Image(systemName: "play.fill"); Text("Play Audio") }
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
    let onCitationTap: (Int) -> Void
    
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
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "citation", let index = Int(url.host ?? "") {
                            onCitationTap(index)
                            return .handled
                        }
                        return .systemAction
                    })
            }
        }
    }
    
    private func makeAttributedString() -> AttributedString {
        var output = AttributedString("")
        
        // 1. Define the styling for the base text
        var baseContainer = AttributeContainer()
        baseContainer.font = .body
        baseContainer.foregroundColor = isUser ? .white : .primary
        
        // 2. Regex to find [1] or [1, 2]
        // We use NSString logic for reliable range finding
        let pattern = "\\[([\\d,\\s]+)\\]"
        let nsString = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AttributedString(text, attributes: baseContainer)
        }
        
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        
        var lastLocation = 0
        
        for match in matches {
            // A. Append the plain text BEFORE the citation
            let rangeBefore = NSRange(location: lastLocation, length: match.range.location - lastLocation)
            if rangeBefore.length > 0 {
                let textSegment = nsString.substring(with: rangeBefore)
                output.append(AttributedString(textSegment, attributes: baseContainer))
            }
            
            // B. Process the citation itself (e.g., "[1, 3]")
            let contentRange = match.range(at: 1)
            let content = nsString.substring(with: contentRange)
            let numbers = content.components(separatedBy: ",")
            
            // Create the clickable links
            for (index, numStr) in numbers.enumerated() {
                let trimmed = numStr.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    // Create a styled string: "[ 1 ]"
                    // We add spaces to make it easier to tap
                    var linkStr = AttributedString("[\(trimmed)]")
                    
                    // Apply styling
                    linkStr.font = .body.bold()
                    linkStr.foregroundColor = isUser ? .white : .blue
                    // Apply the Link attribute directly
                    if let url = URL(string: "citation://\(trimmed)") {
                        linkStr.link = url
                    }
                    
                    output.append(linkStr)
                    
                    // Add a comma if it's not the last number
                    if index < numbers.count - 1 {
                        output.append(AttributedString(", ", attributes: baseContainer))
                    }
                }
            }
            
            lastLocation = match.range.location + match.range.length
        }
        
        // C. Append any remaining text after the last citation
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
    let onCitationTap: (Int) -> Void
    let onSummarize: () -> Void
    let hasSelection: Bool
    
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
                ForEach(history) { msg in
                    HStack {
                        if msg.role == .user { Spacer() }
                        AttributedChatMessage(text: msg.text, isUser: msg.role == .user, onCitationTap: onCitationTap)
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: msg.role == .user ? .trailing : .leading)
                        if msg.role == .model { Spacer() }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 80)
        }
    }
}

struct AnalysisChatView: View {
    @EnvironmentObject var model: VoiceMemosModel
    @StateObject var player = AudioPlayer()
    @State private var input = ""
    @State private var selectedCitation: Citation?
    let service = GeminiService()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack {
                ChatHistoryView(history: model.chatHistory, onCitationTap: { index in
                    if let citation = model.getCitation(for: index),
                       let rec = model.recordings.first(where: { $0.id == citation.recordingID }) {
                        model.playbackRequest = PlaybackRequest(recording: rec, time: citation.startTime)                    }
                }, onSummarize: {
                    sendMessage("Summarize these recordings")
                }, hasSelection: !model.selectedRecordingIDs.isEmpty)
                Spacer()
                HStack {
                    TextField("Ask AI...", text: $input)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(20)
                        .onSubmit { sendMessage(input)
                        }
                    Button(action: { sendMessage(input) }) {
                        Image(systemName: "arrow.up.circle.fill").font(.largeTitle)
                    }
                }
                .padding()
                .background(.bar)
            }
            
            if let citation = selectedCitation {
                CitationCardView(citation: citation, player: player, onClose: { withAnimation { selectedCitation = nil } }, onViewSource: {
                    withAnimation { selectedCitation = nil }
                    if let rec = model.recordings.first(where: { $0.id == citation.recordingID }) {
                        DispatchQueue.main.async {
                            model.playbackRequest = PlaybackRequest(recording: rec, time: citation.startTime)
                        }
                    }
                })
            }
        }
    }
    
    func sendMessage(_ text: String) {
        guard !text.isEmpty else { return }
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
        model.chatHistory.append(ChatMessage(role: .user, text: text))
        input = ""
        model.chatHistory.append(ChatMessage(role: .model, text: "LOADING_ANIMATION", isLoading: true))
        Task {
            let response = await service.analyzeChat(history: model.chatHistory, context: ctx)
            await MainActor.run {
                model.chatHistory.removeAll(where: { $0.isLoading })
                model.chatHistory.append(ChatMessage(role: .model, text: response))
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
            // HEADER
            HStack(alignment: .top, spacing: 0) {
                
                // 1. Content (Left)
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
                
                // 2. Menu (Right)
                if isExpanded {
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
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Color(UIColor.systemBackground))
            .zIndex(1)
            
            // EXPANDED DRAWER
            if isExpanded {
                VStack(spacing: 16) {
                    ScrubberBar(
                        current: Binding(get: { isCurrentPlayerItem ? player.currentTime : 0 }, set: { player.seek(to: $0) }),
                        total: recording.duration
                    )
                    HStack {
                        Text(formatTime(isCurrentPlayerItem ? player.currentTime : 0))
                        Spacer()
                        Text("-" + formatTime(recording.duration - (isCurrentPlayerItem ? player.currentTime : 0)))
                    }.font(.caption).foregroundColor(.secondary).monospacedDigit()
                    
                    HStack {
                        // Waveform (System Blue)
                        Button(action: onEdit) { Image(systemName: "waveform").font(.system(size: 22)) }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.accentColor)
                        
                        // Processing / Queued Label
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
                        }
                        else if recording.isTranscribing {
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
                        
                        Spacer()
                        Button(action: { player.seek(to: player.currentTime - 15) }) { Image(systemName: "gobackward.15").font(.title2) }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: onPlay) {
                            Image(systemName: isCurrentPlayerItem && player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 40))
                        }.buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: { player.seek(to: player.currentTime + 15) }) { Image(systemName: "goforward.15").font(.title2) }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.primary)
                        Spacer()
                        // Trash (System Blue)
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
        }
        .clipped()
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
            content
                .background(Color(UIColor.systemBackground))
                .offset(x: offset)
                .gesture(
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
                )
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
}
