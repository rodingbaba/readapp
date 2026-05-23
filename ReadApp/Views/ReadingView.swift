import SwiftUI
import UIKit

private struct ReaderPosition: Hashable {
    let chapterIndex: Int
    let paragraphIndex: Int
}

private enum ReaderScrollTarget: Hashable {
    case chapter(Int)
    case paragraph(Int, Int)
}

private struct ReaderChapter: Identifiable, Equatable {
    let index: Int
    let title: String
    let paragraphs: [String]

    var id: Int { index }
    var text: String { paragraphs.joined(separator: "\n") }
}

private struct ReaderParagraphFrame: Equatable {
    let chapterIndex: Int
    let paragraphIndex: Int
    let minY: CGFloat
    let maxY: CGFloat
}

private struct ReaderParagraphFrameKey: PreferenceKey {
    static var defaultValue: [ReaderParagraphFrame] = []

    static func reduce(value: inout [ReaderParagraphFrame], nextValue: () -> [ReaderParagraphFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private enum ReaderTextTools {
    static func readableParagraphs(from rawText: String) -> [String] {
        let text = clean(rawText)
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !paragraphs.isEmpty {
            return paragraphs
        }

        let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? [] : [fallback]
    }

    private static func clean(_ rawText: String) -> String {
        var text = rawText
        text = replace(pattern: "<(br|BR)\\s*/?>", in: text, with: "\n")
        text = replace(pattern: "</(p|P|div|DIV|h[1-6]|H[1-6]|li|LI)>", in: text, with: "\n")
        text = replace(pattern: "<(script|style|svg)[^>]*>.*?</\\1>", in: text, with: "", options: [.caseInsensitive, .dotMatchesLineSeparators])
        text = replace(pattern: "<img[^>]*>", in: text, with: "", options: [.caseInsensitive])
        text = replace(pattern: "<[^>]+>", in: text, with: "")

        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&#160;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&apos;", "'")
        ]

        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }

        return text
    }

    private static func replace(
        pattern: String,
        in text: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

struct ReadingView: View {
    let book: Book

    @EnvironmentObject private var apiService: APIService
    @StateObject private var ttsManager = TTSManager.shared
    @StateObject private var preferences = UserPreferences.shared

    @State private var chapters: [BookChapter] = []
    @State private var loadedChapters: [ReaderChapter] = []
    @State private var loadingChapterIndices: Set<Int> = []
    @State private var loadTasks: [Int: Task<Void, Never>] = [:]
    @State private var saveTask: Task<Void, Never>?

    @State private var currentChapterIndex: Int
    @State private var visiblePosition: ReaderPosition
    @State private var pendingScrollPosition: ReaderPosition?
    @State private var pendingScrollAnchor: UnitPoint = .top
    @State private var lastTTSPosition: ReaderPosition?

    @State private var readerSessionID = UUID()
    @State private var isBootstrapping = false
    @State private var showChapterList = false
    @State private var showControls = true
    @State private var errorMessage: String?
    @State private var scrollProxy: ScrollViewProxy?
    @State private var shouldRestoreAfterTTSStop = true
    @State private var readerViewportHeight: CGFloat = 0
    @State private var visibleParagraphFrames: [ReaderPosition: ReaderParagraphFrame] = [:]
    @State private var pendingScrollRetryCount = 0
    @State private var pendingScrollGeneration = 0

    init(book: Book) {
        self.book = book
        let initialIndex = max(book.durChapterIndex ?? 0, 0)
        _currentChapterIndex = State(initialValue: initialIndex)
        _visiblePosition = State(initialValue: ReaderPosition(chapterIndex: initialIndex, paragraphIndex: 0))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            readerScrollView

            if showControls {
                Group {
                    if ttsManager.isPlaying {
                        TTSControlBar(
                            ttsManager: ttsManager,
                            currentChapterIndex: currentChapterIndex,
                            chaptersCount: chapters.count,
                            onPreviousChapter: previousChapter,
                            onNextChapter: nextChapter,
                            onShowChapterList: { showChapterList = true }
                        )
                    } else {
                        NormalControlBar(
                            currentChapterIndex: currentChapterIndex,
                            chaptersCount: chapters.count,
                            onPreviousChapter: previousChapter,
                            onNextChapter: nextChapter,
                            onShowChapterList: { showChapterList = true },
                            onToggleTTS: toggleTTS
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isBootstrapping {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("加载中...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .navigationTitle(book.name ?? "阅读")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(!showControls)
        .statusBar(hidden: !showControls)
        .task {
            await bootstrapReader()
        }
        .sheet(isPresented: $showChapterList) {
            ChapterListView(
                chapters: chapters,
                currentIndex: currentChapterIndex,
                onSelectChapter: { index in
                    shouldRestoreAfterTTSStop = false
                    if ttsManager.isPlaying {
                        ttsManager.stop()
                    }
                    jumpTo(position: ReaderPosition(chapterIndex: index, paragraphIndex: 0), resetIfMissing: true)
                    showChapterList = false
                }
            )
        }
        .alert(
            "错误",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: preferences.infiniteScrollReadingEnabled) { _ in
            resetLoadedFlow(around: visiblePosition)
        }
        .onChange(of: ttsManager.currentSentenceIndex) { paragraphIndex in
            guard ttsManager.isPlaying else { return }
            let position = ReaderPosition(
                chapterIndex: ttsManager.currentChapterIndex,
                paragraphIndex: max(paragraphIndex, 0)
            )
            lastTTSPosition = position
            ensureLoaded(for: position, resetIfMissing: false)
            queueScroll(to: position, anchor: .center)
        }
        .onChange(of: ttsManager.isPlaying) { isPlaying in
            if isPlaying {
                showControls = true
                scrollToCurrentTTSPosition()
            } else {
                showControls = true
                restoreAfterTTSStopIfNeeded()
            }
        }
        .onDisappear {
            saveProgressImmediately(visiblePosition)
            clearPendingScroll()
            cancelLoadTasks()
            saveTask?.cancel()
        }
    }

    private var readerScrollView: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if loadedChapters.isEmpty && !isBootstrapping {
                            Text("暂无正文")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, minHeight: viewport.size.height * 0.6)
                        }

                        ForEach(loadedChapters) { chapter in
                            ReaderChapterSection(
                                chapter: chapter,
                                fontSize: preferences.fontSize,
                                lineSpacing: preferences.lineSpacing,
                                ttsChapterIndex: ttsManager.isPlaying ? ttsManager.currentChapterIndex : nil,
                                ttsParagraphIndex: ttsManager.isPlaying ? ttsManager.currentSentenceIndex : nil,
                                preloadedParagraphIndices: ttsManager.isPlaying && ttsManager.currentChapterIndex == chapter.index
                                    ? ttsManager.preloadedIndices
                                    : [],
                                resumedPosition: lastTTSPosition,
                                onLastParagraphVisible: { chapterIndex in
                                    loadFollowingChapterIfNeeded(after: chapterIndex)
                                }
                            )
                        }

                        if isLoadingAfterLastChapter {
                            HStack {
                                Spacer()
                                ProgressView("加载后续章节...")
                                    .font(.caption)
                                Spacer()
                            }
                            .padding(.vertical, 14)
                        }

                        Color.clear
                            .frame(height: max(viewport.size.height * 0.75, 320))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                }
                .coordinateSpace(name: "reader-scroll")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: bottomContentInset)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                    }
                )
                .onPreferenceChange(ReaderParagraphFrameKey.self) { frames in
                    visibleParagraphFrames = framesByPosition(frames)
                    updateVisiblePosition(from: frames, viewportHeight: viewport.size.height)
                    finishPendingScrollIfVisible()
                }
                .onAppear {
                    readerViewportHeight = viewport.size.height
                    scrollProxy = proxy
                    attemptPendingScroll(animated: false)
                }
                .onChange(of: viewport.size.height) { height in
                    readerViewportHeight = height
                    finishPendingScrollIfVisible()
                }
            }
        }
    }

    private var bottomContentInset: CGFloat {
        guard showControls else {
            return 24
        }

        return ttsManager.isPlaying ? 170 : 104
    }

    private var isLoadingAfterLastChapter: Bool {
        guard let lastIndex = loadedChapters.last?.index else { return false }
        return loadingChapterIndices.contains(lastIndex + 1)
    }

    private func bootstrapReader() async {
        guard !isBootstrapping, chapters.isEmpty else { return }

        await MainActor.run {
            isBootstrapping = true
            errorMessage = nil
        }

        do {
            let fetchedChapters = try await apiService.fetchChapterList(
                bookUrl: book.bookUrl ?? "",
                bookSourceUrl: book.origin
            )

            let metadataIndex = resolveInitialChapterIndex(
                preferredIndex: currentChapterIndex,
                preferredTitle: book.durChapterTitle,
                in: fetchedChapters
            )

            let bookUrl = book.bookUrl ?? ""
            let localProgress = preferences.getReadingProgress(bookUrl: bookUrl)
            let ttsProgress = preferences.getTTSProgress(bookUrl: bookUrl)

            let candidateIndices = [
                metadataIndex,
                localProgress?.chapterIndex ?? -1,
                ttsProgress?.chapterIndex ?? -1
            ].filter { $0 >= 0 && $0 < fetchedChapters.count }
            let startIndex = candidateIndices.max() ?? metadataIndex

            await MainActor.run {
                chapters = fetchedChapters
                currentChapterIndex = startIndex
                visiblePosition = ReaderPosition(chapterIndex: startIndex, paragraphIndex: 0)
            }

            guard !fetchedChapters.isEmpty else {
                await MainActor.run {
                    isBootstrapping = false
                    errorMessage = "没有可阅读的章节"
                }
                return
            }

            let chapter = try await fetchReaderChapter(index: startIndex)

            await MainActor.run {
                loadedChapters = [chapter]

                let paragraphCount = max(chapter.paragraphs.count, 1)

                let localParagraph: Int? = (localProgress?.chapterIndex == startIndex)
                    ? min(max(localProgress?.paragraphIndex ?? 0, 0), paragraphCount - 1)
                    : nil
                let ttsParagraph: Int? = (ttsProgress?.chapterIndex == startIndex)
                    ? min(max(ttsProgress?.sentenceIndex ?? 0, 0), paragraphCount - 1)
                    : nil

                if let ttsParagraph {
                    lastTTSPosition = ReaderPosition(chapterIndex: startIndex, paragraphIndex: ttsParagraph)
                }

                let metadataParagraph: Int? = {
                    guard metadataIndex == startIndex, let pos = book.durChapterPos, pos > 0 else { return nil }
                    let ratio = pos > 1 ? min(pos / 100, 1) : min(pos, 1)
                    return min(Int((Double(paragraphCount - 1) * ratio).rounded()), paragraphCount - 1)
                }()

                let farthestParagraph = [localParagraph, ttsParagraph, metadataParagraph]
                    .compactMap { $0 }
                    .max() ?? 0
                let focusPosition = ReaderPosition(chapterIndex: startIndex, paragraphIndex: farthestParagraph)

                let centerOnTTS = ttsParagraph != nil && farthestParagraph == ttsParagraph

                currentChapterIndex = focusPosition.chapterIndex
                visiblePosition = focusPosition
                isBootstrapping = false
                queueScroll(to: focusPosition, anchor: centerOnTTS ? .center : .top)
                loadFollowingChapterIfNeeded(after: startIndex)
                saveProgressImmediately(focusPosition)
            }
        } catch {
            await MainActor.run {
                isBootstrapping = false
                errorMessage = "加载阅读内容失败: \(error.localizedDescription)"
            }
        }
    }

    private func fetchReaderChapter(index: Int) async throws -> ReaderChapter {
        guard index >= 0, index < chapters.count else {
            throw NSError(domain: "ReadingView", code: 404, userInfo: [NSLocalizedDescriptionKey: "章节不存在"])
        }

        let content = try await apiService.fetchChapterContent(
            bookUrl: book.bookUrl ?? "",
            bookSourceUrl: book.origin,
            index: index,
            bookName: book.name
        )

        let paragraphs = ReaderTextTools.readableParagraphs(from: content)
        return ReaderChapter(
            index: index,
            title: chapters[index].title,
            paragraphs: paragraphs.isEmpty ? ["章节内容为空"] : paragraphs
        )
    }

    private func ensureLoaded(for position: ReaderPosition, resetIfMissing: Bool) {
        guard position.chapterIndex >= 0, position.chapterIndex < chapters.count else { return }

        if loadedChapters.contains(where: { $0.index == position.chapterIndex }) {
            keepOnlyChapterIfNeeded(position.chapterIndex)
            loadFollowingChapterIfNeeded(after: position.chapterIndex)
            return
        }

        if resetIfMissing || !preferences.infiniteScrollReadingEnabled {
            resetLoadedFlow(around: position)
        } else {
            loadChapterIfNeeded(position.chapterIndex)
        }
    }

    private func resetLoadedFlow(around position: ReaderPosition) {
        guard !chapters.isEmpty else { return }

        cancelLoadTasks()
        readerSessionID = UUID()
        loadedChapters = []
        loadingChapterIndices = []
        currentChapterIndex = position.chapterIndex
        visiblePosition = position
        pendingScrollPosition = position
        pendingScrollAnchor = .top
        pendingScrollRetryCount = 0
        pendingScrollGeneration += 1
        loadChapterIfNeeded(position.chapterIndex)
    }

    private func loadChapterIfNeeded(_ index: Int) {
        guard index >= 0, index < chapters.count else { return }
        guard !loadedChapters.contains(where: { $0.index == index }) else { return }
        guard !loadingChapterIndices.contains(index) else { return }

        let sessionID = readerSessionID
        loadingChapterIndices.insert(index)

        let task = Task {
            do {
                let chapter = try await fetchReaderChapter(index: index)

                await MainActor.run {
                    guard sessionID == readerSessionID else { return }
                    if preferences.infiniteScrollReadingEnabled {
                        insertLoadedChapter(chapter)
                    } else {
                        loadedChapters = [chapter]
                    }
                    loadingChapterIndices.remove(index)
                    loadTasks.removeValue(forKey: index)
                    attemptPendingScroll(animated: true)

                    if chapter.index == currentChapterIndex {
                        loadFollowingChapterIfNeeded(after: chapter.index)
                    }
                }
            } catch {
                await MainActor.run {
                    guard sessionID == readerSessionID else { return }
                    loadingChapterIndices.remove(index)
                    loadTasks.removeValue(forKey: index)
                    errorMessage = "加载章节失败: \(error.localizedDescription)"
                }
            }
        }

        loadTasks[index] = task
    }

    private func insertLoadedChapter(_ chapter: ReaderChapter) {
        var next = loadedChapters.filter { $0.index != chapter.index }
        next.append(chapter)
        loadedChapters = next.sorted { $0.index < $1.index }
    }

    private func keepOnlyChapterIfNeeded(_ chapterIndex: Int) {
        guard !preferences.infiniteScrollReadingEnabled else { return }
        guard loadedChapters.count != 1 || loadedChapters.first?.index != chapterIndex else { return }
        loadedChapters = loadedChapters.filter { $0.index == chapterIndex }
    }

    private func loadFollowingChapterIfNeeded(after chapterIndex: Int) {
        guard preferences.infiniteScrollReadingEnabled else { return }
        let nextIndex = chapterIndex + 1
        guard nextIndex >= 0, nextIndex < chapters.count else { return }
        loadChapterIfNeeded(nextIndex)
    }

    private func updateVisiblePosition(from frames: [ReaderParagraphFrame], viewportHeight: CGFloat) {
        guard !frames.isEmpty else { return }

        let readingLine = min(max(viewportHeight * 0.32, 96), max(viewportHeight - 96, 96))
        let sortedFrames = frames.sorted {
            if $0.chapterIndex == $1.chapterIndex {
                return $0.paragraphIndex < $1.paragraphIndex
            }
            return $0.chapterIndex < $1.chapterIndex
        }

        let candidate = sortedFrames.first(where: { $0.minY <= readingLine && $0.maxY >= readingLine })
            ?? sortedFrames.last(where: { $0.minY <= readingLine })
            ?? sortedFrames.first

        guard let frame = candidate else { return }
        let position = ReaderPosition(chapterIndex: frame.chapterIndex, paragraphIndex: frame.paragraphIndex)
        guard position != visiblePosition else { return }

        visiblePosition = position
        if currentChapterIndex != position.chapterIndex {
            currentChapterIndex = position.chapterIndex
            loadFollowingChapterIfNeeded(after: position.chapterIndex)
        }

        scheduleProgressSave(position)
    }

    private func previousChapter() {
        if ttsManager.isPlaying {
            ttsManager.previousChapter()
            return
        }

        guard currentChapterIndex > 0 else { return }
        jumpTo(position: ReaderPosition(chapterIndex: currentChapterIndex - 1, paragraphIndex: 0), resetIfMissing: true)
    }

    private func nextChapter() {
        if ttsManager.isPlaying {
            ttsManager.nextChapter()
            return
        }

        guard currentChapterIndex < chapters.count - 1 else { return }
        jumpTo(
            position: ReaderPosition(chapterIndex: currentChapterIndex + 1, paragraphIndex: 0),
            resetIfMissing: !preferences.infiniteScrollReadingEnabled
        )
    }

    private func jumpTo(position: ReaderPosition, resetIfMissing: Bool, anchor: UnitPoint = .top) {
        guard position.chapterIndex >= 0, position.chapterIndex < chapters.count else { return }

        currentChapterIndex = position.chapterIndex
        visiblePosition = position
        ensureLoaded(for: position, resetIfMissing: resetIfMissing)
        pendingScrollPosition = position
        pendingScrollAnchor = anchor
        pendingScrollRetryCount = 0
        pendingScrollGeneration += 1
        loadFollowingChapterIfNeeded(after: position.chapterIndex)
        attemptPendingScroll(animated: true)
        scheduleProgressSave(position)
    }

    private func toggleTTS() {
        if ttsManager.isPlaying {
            ttsManager.isPaused ? ttsManager.resume() : ttsManager.pause()
            return
        }

        startTTS()
    }

    private func startTTS() {
        guard let chapter = loadedChapters.first(where: { $0.index == currentChapterIndex }) else {
            ensureLoaded(for: visiblePosition, resetIfMissing: false)
            return
        }

        showControls = true
        shouldRestoreAfterTTSStop = true

        ttsManager.startReading(
            text: chapter.text,
            chapters: chapters,
            currentIndex: currentChapterIndex,
            bookUrl: book.bookUrl ?? "",
            bookSourceUrl: book.origin,
            bookTitle: book.name ?? "未知书名",
            coverUrl: book.displayCoverUrl
        ) { newIndex in
            let position = ReaderPosition(chapterIndex: newIndex, paragraphIndex: 0)
            currentChapterIndex = newIndex
            visiblePosition = position
            lastTTSPosition = position
            ensureLoaded(for: position, resetIfMissing: false)
            queueScroll(to: position, anchor: .top)
            saveProgressImmediately(position)
        }
    }

    private func restoreAfterTTSStopIfNeeded() {
        guard shouldRestoreAfterTTSStop else {
            shouldRestoreAfterTTSStop = true
            return
        }

        guard let bookUrl = book.bookUrl,
              let progress = preferences.getTTSProgress(bookUrl: bookUrl) else {
            return
        }

        let position = ReaderPosition(
            chapterIndex: progress.chapterIndex,
            paragraphIndex: progress.sentenceIndex
        )
        lastTTSPosition = position
        jumpTo(position: position, resetIfMissing: false, anchor: .center)
    }

    private func scrollToCurrentTTSPosition() {
        let position = ReaderPosition(
            chapterIndex: ttsManager.currentChapterIndex,
            paragraphIndex: max(ttsManager.currentSentenceIndex, 0)
        )
        lastTTSPosition = position
        ensureLoaded(for: position, resetIfMissing: false)
        queueScroll(to: position, anchor: .center)
    }

    private func queueScroll(to position: ReaderPosition, anchor: UnitPoint = .top) {
        pendingScrollPosition = position
        pendingScrollAnchor = anchor
        pendingScrollRetryCount = 0
        pendingScrollGeneration += 1
        attemptPendingScroll(animated: true)
    }

    private func attemptPendingScroll(animated: Bool) {
        guard let position = pendingScrollPosition,
              let proxy = scrollProxy,
              let chapter = loadedChapters.first(where: { $0.index == position.chapterIndex }) else {
            return
        }

        let paragraphIndex = min(max(position.paragraphIndex, 0), max(chapter.paragraphs.count - 1, 0))
        let target: ReaderScrollTarget = chapter.paragraphs.isEmpty
            ? .chapter(position.chapterIndex)
            : .paragraph(position.chapterIndex, paragraphIndex)
        let anchor = effectiveScrollAnchor(for: pendingScrollAnchor)
        let generation = pendingScrollGeneration
        let attempt = pendingScrollRetryCount

        pendingScrollRetryCount += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.06 : 0.16)) {
            guard pendingScrollGeneration == generation,
                  pendingScrollPosition == position else {
                return
            }

            if animated && attempt == 0 {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(target, anchor: anchor)
                }
            } else {
                proxy.scrollTo(target, anchor: anchor)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard pendingScrollGeneration == generation,
                      pendingScrollPosition == position else {
                    return
                }

                if finishPendingScrollIfVisible() {
                    return
                }

                guard pendingScrollRetryCount < 14 else {
                    clearPendingScroll()
                    return
                }

                attemptPendingScroll(animated: false)
            }
        }
    }

    @discardableResult
    private func finishPendingScrollIfVisible() -> Bool {
        guard let position = pendingScrollPosition,
              targetIsSettled(position) else {
            return false
        }

        clearPendingScroll()
        return true
    }

    private func targetIsSettled(_ position: ReaderPosition) -> Bool {
        guard let frame = visibleParagraphFrames[position] else {
            return false
        }

        let visibleTop: CGFloat = 8
        let visibleBottom = max(readerViewportHeight - bottomContentInset, visibleTop + 96)
        let visibleCenter = (visibleTop + visibleBottom) / 2

        if pendingScrollAnchor == .center {
            return (frame.minY...frame.maxY).contains(visibleCenter)
                || abs(((frame.minY + frame.maxY) / 2) - visibleCenter) < 80
        }

        if pendingScrollAnchor == .top {
            return abs(frame.minY - visibleTop) < 80
                || (frame.minY <= visibleTop && frame.maxY > visibleTop + 80)
        }

        return frame.maxY > visibleTop && frame.minY < visibleBottom
    }

    private func effectiveScrollAnchor(for anchor: UnitPoint) -> UnitPoint {
        guard showControls, anchor == .center, readerViewportHeight > 0 else {
            return anchor
        }

        let visibleTop: CGFloat = 8
        let visibleBottom = max(readerViewportHeight - bottomContentInset, visibleTop + 96)
        let visibleCenter = (visibleTop + visibleBottom) / 2
        let y = min(max(visibleCenter / readerViewportHeight, 0.18), 0.50)
        return UnitPoint(x: 0.5, y: y)
    }

    private func clearPendingScroll() {
        pendingScrollPosition = nil
        pendingScrollRetryCount = 0
        pendingScrollGeneration += 1
    }

    private func framesByPosition(_ frames: [ReaderParagraphFrame]) -> [ReaderPosition: ReaderParagraphFrame] {
        var result: [ReaderPosition: ReaderParagraphFrame] = [:]
        for frame in frames {
            result[ReaderPosition(chapterIndex: frame.chapterIndex, paragraphIndex: frame.paragraphIndex)] = frame
        }
        return result
    }

    private func preferredStartPosition(for chapter: ReaderChapter) -> ReaderPosition {
        let bookUrl = book.bookUrl ?? ""
        let paragraphCount = max(chapter.paragraphs.count, 1)

        if let local = preferences.getReadingProgress(bookUrl: bookUrl),
           local.chapterIndex == chapter.index {
            return ReaderPosition(
                chapterIndex: local.chapterIndex,
                paragraphIndex: min(max(local.paragraphIndex, 0), paragraphCount - 1)
            )
        }

        if let tts = preferences.getTTSProgress(bookUrl: bookUrl),
           tts.chapterIndex == chapter.index {
            return ReaderPosition(
                chapterIndex: tts.chapterIndex,
                paragraphIndex: min(max(tts.sentenceIndex, 0), paragraphCount - 1)
            )
        }

        if let pos = book.durChapterPos, pos > 0 {
            let ratio = pos > 1 ? min(pos / 100, 1) : min(pos, 1)
            let paragraphIndex = min(Int((Double(paragraphCount - 1) * ratio).rounded()), paragraphCount - 1)
            return ReaderPosition(chapterIndex: chapter.index, paragraphIndex: paragraphIndex)
        }

        return ReaderPosition(chapterIndex: chapter.index, paragraphIndex: 0)
    }

    private func scheduleProgressSave(_ position: ReaderPosition) {
        guard position.chapterIndex >= 0, position.chapterIndex < chapters.count else { return }
        guard let bookUrl = book.bookUrl else { return }

        preferences.saveReadingProgress(
            bookUrl: bookUrl,
            chapterIndex: position.chapterIndex,
            paragraphIndex: position.paragraphIndex
        )

        let title = chapters[position.chapterIndex].title
        let pos = normalizedParagraphPosition(position)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await apiService.saveBookProgress(
                    bookUrl: bookUrl,
                    index: position.chapterIndex,
                    pos: pos,
                    title: title
                )
            } catch {
                LogManager.shared.log("保存阅读进度失败: \(error.localizedDescription)", category: "阅读")
            }
        }
    }

    private func saveProgressImmediately(_ position: ReaderPosition) {
        guard position.chapterIndex >= 0, position.chapterIndex < chapters.count else { return }
        guard let bookUrl = book.bookUrl else { return }

        preferences.saveReadingProgress(
            bookUrl: bookUrl,
            chapterIndex: position.chapterIndex,
            paragraphIndex: position.paragraphIndex
        )

        let title = chapters[position.chapterIndex].title
        let pos = normalizedParagraphPosition(position)
        Task {
            do {
                try await apiService.saveBookProgress(
                    bookUrl: bookUrl,
                    index: position.chapterIndex,
                    pos: pos,
                    title: title
                )
            } catch {
                LogManager.shared.log("保存阅读进度失败: \(error.localizedDescription)", category: "阅读")
            }
        }
    }

    private func normalizedParagraphPosition(_ position: ReaderPosition) -> Double {
        guard let chapter = loadedChapters.first(where: { $0.index == position.chapterIndex }),
              chapter.paragraphs.count > 1 else {
            return 0
        }

        let clamped = min(max(position.paragraphIndex, 0), chapter.paragraphs.count - 1)
        return Double(clamped) / Double(chapter.paragraphs.count - 1)
    }

    private func resolveInitialChapterIndex(
        preferredIndex: Int,
        preferredTitle: String?,
        in chapters: [BookChapter]
    ) -> Int {
        guard !chapters.isEmpty else { return 0 }

        let clampedIndex = min(max(preferredIndex, 0), chapters.count - 1)
        guard let title = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return clampedIndex
        }

        let normalizedTitle = normalizeChapterTitle(title)
        let nearby = [clampedIndex, clampedIndex + 1, clampedIndex - 1]

        for index in nearby where index >= 0 && index < chapters.count {
            if normalizeChapterTitle(chapters[index].title) == normalizedTitle {
                return index
            }
        }

        if let exact = chapters.firstIndex(where: { normalizeChapterTitle($0.title) == normalizedTitle }) {
            return exact
        }

        return clampedIndex
    }

    private func normalizeChapterTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelLoadTasks() {
        for task in loadTasks.values {
            task.cancel()
        }
        loadTasks = [:]
    }
}

private struct ReaderChapterSection: View {
    let chapter: ReaderChapter
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let ttsChapterIndex: Int?
    let ttsParagraphIndex: Int?
    let preloadedParagraphIndices: Set<Int>
    let resumedPosition: ReaderPosition?
    let onLastParagraphVisible: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: max(fontSize * 0.82, 12)) {
            Text(chapter.title)
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
                .id(ReaderScrollTarget.chapter(chapter.index))

            ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { item in
                paragraphView(text: item.element, paragraphIndex: item.offset)
                    .id(ReaderScrollTarget.paragraph(chapter.index, item.offset))
                    .background(
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named("reader-scroll"))
                            Color.clear.preference(
                                key: ReaderParagraphFrameKey.self,
                                value: [
                                    ReaderParagraphFrame(
                                        chapterIndex: chapter.index,
                                        paragraphIndex: item.offset,
                                        minY: frame.minY,
                                        maxY: frame.maxY
                                    )
                                ]
                            )
                        }
                    )
                    .onAppear {
                        if item.offset == chapter.paragraphs.count - 1 {
                            onLastParagraphVisible(chapter.index)
                        }
                    }
            }
        }
    }

    private func paragraphView(text: String, paragraphIndex: Int) -> some View {
        let isTTSActive = ttsChapterIndex == chapter.index && ttsParagraphIndex == paragraphIndex
        let isTTSPreloaded = ttsChapterIndex == chapter.index
            && preloadedParagraphIndices.contains(paragraphIndex)
            && paragraphIndex > (ttsParagraphIndex ?? -1)
        let isResumePoint = resumedPosition == ReaderPosition(chapterIndex: chapter.index, paragraphIndex: paragraphIndex)

        let tint = paragraphTint(isTTSActive: isTTSActive, isTTSPreloaded: isTTSPreloaded, isResumePoint: isResumePoint)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return Text("　　" + text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: fontSize))
            .lineSpacing(lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .modifier(ParagraphGlassBackground(tint: tint, shape: shape))
            .animation(.easeInOut(duration: 0.22), value: isTTSActive)
            .animation(.easeInOut(duration: 0.22), value: preloadedParagraphIndices.count)
    }

    private func paragraphTint(isTTSActive: Bool, isTTSPreloaded: Bool, isResumePoint: Bool) -> LiquidGlassTint? {
        if isTTSActive { return .accent }
        if isTTSPreloaded { return .success }
        if isResumePoint { return .warning }
        return nil
    }
}

private struct ParagraphGlassBackground: ViewModifier {
    let tint: LiquidGlassTint?
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if let tint {
            content.liquidGlass(tint: tint, in: shape)
        } else {
            content
        }
    }
}

struct ChapterListView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    let onSelectChapter: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isReversed = false
    @State private var searchText = ""

    private var displayedChapters: [(offset: Int, element: BookChapter)] {
        let items = Array(chapters.enumerated())
        let filtered: [(offset: Int, element: BookChapter)]
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { $0.element.title.localizedCaseInsensitiveContains(trimmed) }
        }
        return isReversed ? Array(filtered.reversed()) : filtered
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.10),
                            Color(UIColor.systemBackground),
                            Color.purple.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(displayedChapters, id: \.element.id) { item in
                                chapterRow(item: item)
                                    .id(item.offset)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .liquidGlassContainer(spacing: 6)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        searchBar
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .padding(.bottom, 10)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(UIColor.systemBackground).opacity(0.85),
                                        Color(UIColor.systemBackground).opacity(0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .ignoresSafeArea(edges: .top)
                            )
                    }
                }
                .navigationTitle("目录（共\(chapters.count)章）")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isReversed.toggle()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(currentIndex, anchor: .center)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isReversed ? "arrow.up" : "arrow.down")
                                Text(isReversed ? "倒序" : "正序")
                            }
                            .font(.subheadline.weight(.semibold))
                            .fixedSize()
                        }
                        .tint(.blue)
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.subheadline.weight(.bold))
                        }
                        .tint(.primary)
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        proxy.scrollTo(currentIndex, anchor: .center)
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索章节", text: $searchText)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(in: Capsule())
    }

    private func chapterRow(item: (offset: Int, element: BookChapter)) -> some View {
        let isCurrent = item.offset == currentIndex
        return Button {
            onSelectChapter(item.offset)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if isCurrent {
                    Image(systemName: "book.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.blue)
                        .frame(width: 22, height: 22)
                }

                Text(item.element.title)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundColor(isCurrent ? .blue : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                if isCurrent {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ChapterRowGlass(isCurrent: isCurrent))
        }
        .buttonStyle(.plain)
    }
}

private struct ChapterRowGlass: ViewModifier {
    let isCurrent: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if isCurrent {
            content.liquidGlass(tint: .accent, in: shape)
        } else {
            content.liquidGlass(in: shape)
        }
    }
}

struct TTSControlBar: View {
    @ObservedObject var ttsManager: TTSManager
    let currentChapterIndex: Int
    let chaptersCount: Int
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onShowChapterList: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                GlassIconButton(
                    systemImage: "arrow.backward",
                    title: "上一段",
                    tint: .accent,
                    isDisabled: ttsManager.currentSentenceIndex <= 0
                ) { ttsManager.previousSentence() }

                Spacer(minLength: 0)

                VStack(spacing: 2) {
                    Text("段落进度")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(min(ttsManager.currentSentenceIndex + 1, max(ttsManager.totalSentences, 1))) / \(max(ttsManager.totalSentences, 1))")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .liquidGlass(in: Capsule())

                Spacer(minLength: 0)

                GlassIconButton(
                    systemImage: "arrow.forward",
                    title: "下一段",
                    tint: .accent,
                    isDisabled: ttsManager.currentSentenceIndex >= ttsManager.totalSentences - 1
                ) { ttsManager.nextSentence() }
            }

            HStack(spacing: 10) {
                GlassIconButton(
                    systemImage: "chevron.left",
                    title: "上一章",
                    isDisabled: currentChapterIndex <= 0,
                    action: onPreviousChapter
                )

                GlassIconButton(
                    systemImage: "list.bullet",
                    title: "目录",
                    tint: .accent,
                    action: onShowChapterList
                )

                Spacer(minLength: 0)

                GlassIconButton(
                    systemImage: ttsManager.isPaused ? "play.fill" : "pause.fill",
                    title: ttsManager.isPaused ? "播放" : "暂停",
                    tint: .strongAccent,
                    isProminent: true
                ) {
                    ttsManager.isPaused ? ttsManager.resume() : ttsManager.pause()
                }

                Spacer(minLength: 0)

                GlassIconButton(
                    systemImage: "xmark",
                    title: "退出",
                    tint: .danger
                ) { ttsManager.stop() }

                GlassIconButton(
                    systemImage: "chevron.right",
                    title: "下一章",
                    isDisabled: currentChapterIndex >= chaptersCount - 1,
                    action: onNextChapter
                )
            }
        }
        .padding(.horizontal, 6)
        .liquidGlassContainer(spacing: 10)
    }
}

struct NormalControlBar: View {
    let currentChapterIndex: Int
    let chaptersCount: Int
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onShowChapterList: () -> Void
    let onToggleTTS: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GlassIconButton(
                systemImage: "chevron.left",
                title: "上一章",
                isDisabled: currentChapterIndex <= 0,
                action: onPreviousChapter
            )

            GlassIconButton(
                systemImage: "list.bullet",
                title: "目录",
                tint: .accent,
                action: onShowChapterList
            )

            Spacer(minLength: 0)

            GlassIconButton(
                systemImage: "speaker.wave.2.fill",
                title: "听书",
                tint: .strongAccent,
                isProminent: true,
                action: onToggleTTS
            )

            Spacer(minLength: 0)

            GlassIconButton(
                systemImage: "chevron.right",
                title: "下一章",
                isDisabled: currentChapterIndex >= chaptersCount - 1,
                action: onNextChapter
            )
        }
        .padding(.horizontal, 6)
        .liquidGlassContainer(spacing: 10)
    }
}
