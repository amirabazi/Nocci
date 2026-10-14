import AppKit
import SwiftUI
import Combine
import Charts
import UniformTypeIdentifiers

final class HistoryModel: ObservableObject {
    @Published private(set) var recording: Bool
    @Published private(set) var retention: Int
    @Published var provider = "claude" { didSet { reload() } }
    @Published var window = "session" { didSet { reload() } }
    @Published var rangeDays = 1 { didSet { reload() } }
    @Published private(set) var rows: [HistorySample] = []
    @Published private(set) var points: [HistorySample] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var clearing = false
    @Published private(set) var rangeEnd = Date()
    /// The rows are each bucket's extremes rather than every reading.
    @Published private(set) var simplified = false
    @Published private(set) var exporting = false
    @Published private(set) var exportNotice: String?
    let queue = DispatchQueue(label: "com.github.amirabazi.nocci.history", qos: .utility)
    private let store: HistoryStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private var started: Date
    private var epochs = ["claude": UUID().uuidString, "codex": UUID().uuidString]
    private var presentWindows: [String: Set<String>] = [:]
    private var observations = Set<AnyCancellable>()
    private var request = UUID()
    private var historyWindow: NSWindow?
    var visible = false

    init(usage: UsageModel, defaults: UserDefaults = .standard,
         directory: URL = Storage.directory.appendingPathComponent("History", isDirectory: true),
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now; self.store = HistoryStore(directory: directory)
        recording = defaults.bool(forKey: "history.recording")
        let saved = defaults.integer(forKey: "history.retentionDays")
        retention = [7,30,90].contains(saved) ? saved : 30
        started = defaults.object(forKey: "history.started") as? Date ?? now()
        // Use the published payload: @Published sends before the property itself changes.
        usage.$claude.sink { [weak self, weak usage] snapshot in
            guard let usage else { return }
            self?.receive(snapshot, provider: "claude", live: !usage.demo && usage.preferences.showClaude)
        }.store(in: &observations)
        usage.$codex.sink { [weak self, weak usage] snapshot in
            guard let usage else { return }
            self?.receive(snapshot, provider: "codex", live: !usage.demo && usage.preferences.showCodex)
        }.store(in: &observations)
        usage.$demo.removeDuplicates().sink { [weak self] _ in self?.newEpochs() }.store(in: &observations)
        usage.$preferences.map { [$0.showClaude, $0.showCodex] }.removeDuplicates()
            .sink { [weak self] _ in self?.newEpochs() }.store(in: &observations)
        usage.$codexMessage.removeDuplicates().sink { [weak self] message in
            if !message.isEmpty { self?.epochs["codex"] = UUID().uuidString }
        }.store(in: &observations)
        usage.$claudeConnection.map { $0.isConfigured }.removeDuplicates().sink { [weak self] _ in
            self?.epochs["claude"] = UUID().uuidString
        }.store(in: &observations)
        let days = retention, date = now()
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.store.prune(days: days, now: date) }
            catch { self.report(error) }
        }
    }
    func setRecording(_ enabled: Bool) {
        guard recording != enabled else { return }
        recording = enabled; defaults.set(enabled, forKey: "history.recording"); newEpochs()
        // The footer shows one line; a pause must not stay hidden behind an old export notice.
        exportNotice = nil
        if enabled { started = now(); defaults.set(started, forKey: "history.started") }
        else { queue.async { [weak self] in self?.store.close() } }
        reload()
    }
    /// The chart's ranges, up to what is kept.
    var ranges: [Int] { [1, 7, 30, 90].filter { $0 <= max(7, retention) } }
    /// Ranges past a week read each 30th of a day's extremes (15 minutes for
    /// 30 days, 45 for 90), which keeps them well under the query limit.
    static func bucket(days: Int) -> TimeInterval? { days > 7 ? Double(days) * 30 : nil }
    func setRetention(_ days: Int) {
        guard [7,30,90].contains(days) else { return }
        retention = days; defaults.set(days, forKey: "history.retentionDays")
        if rangeDays > days { rangeDays = days }
        let date = now()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.store.prune(days: days, now: date, force: true)
                DispatchQueue.main.async { self.reload() }
            } catch { self.report(error) }
        }
    }
    private func newEpochs() {
        epochs = ["claude": UUID().uuidString, "codex": UUID().uuidString]; presentWindows = [:]
    }
    private func receive(_ snapshot: UsageSnapshot?, provider: String, live: Bool) {
        guard live, let snapshot else { epochs[provider] = UUID().uuidString; return }
        let windows = Set(snapshot.windows.map { $0.resolvedKind.rawValue })
        if let previous = presentWindows[provider], previous != windows { epochs[provider] = UUID().uuidString }
        presentWindows[provider] = windows
        guard recording, !clearing else { return }
        let epoch = epochs[provider]!, date = now(), since = started, days = retention
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.store.record(snapshot, provider: provider, epoch: epoch, now: date, since: since)
                try self.store.prune(days: days, now: date)
                DispatchQueue.main.async { if self.visible { self.reload() } }
            } catch { self.report(error) }
        }
    }
    private func report(_ failure: Error) {
        DispatchQueue.main.async { self.error = failure.localizedDescription; self.loading = false }
    }
    func reload() {
        let token = UUID(); request = token
        let provider = self.provider, window = self.window, end = now()
        let start = end.addingTimeInterval(-Double(rangeDays) * 86400), bucket = Self.bucket(days: rangeDays)
        loading = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.store.query(provider: provider, window: window, since: start, until: end, bucket: bucket) }
            DispatchQueue.main.async {
                guard self.request == token else { return }
                self.loading = false
                switch result {
                case .success(let rows):
                    self.rows = rows; self.points = HistoryPlot.points(rows); self.rangeEnd = end; self.error = nil
                    self.simplified = bucket != nil
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }
    func clearConfirmed() {
        guard !clearing else { return }
        clearing = true; request = UUID(); newEpochs()
        started = now(); defaults.set(started, forKey: "history.started")
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.store.clear() }
            DispatchQueue.main.async {
                self.clearing = false
                switch result {
                case .success: self.rows = []; self.points = []; self.error = nil; self.reload()
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }
    func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear all usage history?"
        alert.informativeText = "This permanently deletes recorded history for Claude and Codex on this Mac. Live usage and provider connections are kept. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear History")
        guard let historyWindow else { return }
        alert.beginSheetModal(for: historyWindow) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.clearConfirmed() }
        }
    }
    /// Every retained sample, all providers and quotas, to a file the user
    /// picks. Waits behind any recording or clearing on the history queue.
    func chooseExport() {
        guard let historyWindow, !exporting, !clearing else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Nocci usage history.csv"
        panel.message = "Exports every sample Nocci keeps, for both providers and both quotas. Times are in UTC."
        panel.beginSheetModal(for: historyWindow) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.export(to: url)
        }
    }
    func export(to url: URL) {
        guard !exporting else { return }
        exporting = true; exportNotice = nil
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.store.exportCSV(to: url) }
            DispatchQueue.main.async {
                self.exporting = false
                switch result {
                case .success(let count):
                    self.exportNotice = "Exported \(count) sample\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
                case .failure(let failure):
                    self.exportNotice = "Export failed. \(failure.localizedDescription)"
                }
            }
        }
    }
    func hide() {
        historyWindow?.orderOut(nil)
        visible = false
    }
    func show() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x:0,y:0,width:720,height:540),
                                  styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "Usage History"; window.minSize = NSSize(width: 720, height: 540)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(model: self))
            window.center(); historyWindow = window
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { [weak self] _ in self?.visible = false }.store(in: &observations)
        }
        visible = true; reload()
        historyWindow?.deminiaturize(nil); historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    var summary: String {
        guard let latest = rows.last else { return "No observations in this range." }
        let low = rows.map(\.used).min()!, high = rows.map(\.used).max()!
        let count = simplified ? "simplified to \(rows.count) points" : "\(rows.count) samples"
        return "Latest: \(Int(latest.used.rounded()))% used · Observed range: \(Int(low.rounded()))–\(Int(high.rounded()))% · \(count)"
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage History").font(.title2.bold())
                    Text("Sampled subscription usage · stored only on this Mac").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Record history", isOn: Binding(get: { model.recording }, set: { model.setRecording($0) }))
                    .toggleStyle(.switch).fixedSize().disabled(model.clearing)
            }
            HStack {
                Picker("Provider", selection: $model.provider) {
                    Text("Claude").tag("claude"); Text("Codex").tag("codex")
                }.frame(width: 165)
                Picker("Quota", selection: $model.window) {
                    Text("Session").tag("session"); Text("Weekly").tag("weekly")
                }.frame(width: 165)
                Spacer()
                Picker("Range", selection: $model.rangeDays) {
                    ForEach(model.ranges, id: \.self) { days in Text(days == 1 ? "24 hours" : "\(days) days").tag(days) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Time range").fixedSize()
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 10) {
                    Label("History unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { model.reload() }
                }.frame(maxWidth: .infinity, minHeight: 230, alignment: .leading)
            } else if model.rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(model.recording ? "Waiting for fresh usage" : "Your history starts here").font(.headline)
                    Text(model.recording ? "New provider readings will appear here. Claude updates when Claude Code sends usage. Sample data is never recorded."
                         : "Enable Record history to save future observations. Past usage is not imported. Pausing recording keeps existing history until it expires.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 450)
                }.frame(maxWidth: .infinity, minHeight: 230)
            } else {
                Chart(model.points) { point in
                    LineMark(x: .value("Time", point.captured), y: .value("Used", point.used), series: .value("Period", point.segment))
                        .foregroundStyle(model.provider == "claude" ? Color.orange : Color.accentColor).interpolationMethod(.linear)
                    PointMark(x: .value("Time", point.captured), y: .value("Used", point.used))
                        .foregroundStyle(model.provider == "claude" ? Color.orange : Color.accentColor).symbolSize(8)
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: model.rangeEnd.addingTimeInterval(-Double(model.rangeDays) * 86400)...model.rangeEnd)
                .chartYAxisLabel("Allowance used (%)").chartLegend(.hidden).frame(minHeight: 230)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.provider.capitalized) \(model.window) subscription usage history")
                .accessibilityValue(model.summary)
            }
            HStack {
                Text(model.summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload history").accessibilityLabel("Reload history").disabled(model.loading || model.clearing)
            }
            Text("Percentages show observed allowance used, not tokens, cost or total daily consumption. Gaps and separate periods are not connected. Charts may simplify dense observations.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Picker("Keep history", selection: Binding(get: { model.retention }, set: { model.setRetention($0) })) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }.frame(width: 190).disabled(model.clearing)
                Spacer()
                if let notice = model.exportNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if !model.recording {
                    Text("Recording paused").font(.callout).foregroundStyle(.secondary)
                }
                Button("Export CSV…") { model.chooseExport() }.disabled(model.clearing || model.exporting)
                    .help("Save every kept sample as a spreadsheet file")
                Button("Clear History…") { model.confirmClear() }.disabled(model.clearing || model.exporting)
            }
        }.padding(24).frame(minWidth: 672, minHeight: 480)
    }
}
