import SwiftUI
import Combine
import PDFKit
import os

struct NativePDFReader: View {
    let url: URL
    let notes: [PDFWordNote]
    var initialPage: Int = 0
    var navigationAnchor: PDFAnchor? = nil
    var navigationRequestID: Int = 0
    let onSelection: (PDFAnchor) -> Void
    let onPageChanged: (Int) -> Void

    @StateObject private var reader = PDFReaderController()
    @State private var pageInput = "1"

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                controls(compact: false)
                controls(compact: true)
            }
            .frame(maxWidth: .infinity)
            ZStack {
                PDFReaderCanvas(reader: reader)
                if let error = reader.error {
                    ContentUnavailableView("PDF를 열 수 없습니다", systemImage: "doc.questionmark", description: Text(error))
                        .background(.background)
                }
            }
        }
        .onAppear { configure() }
        .onChange(of: url) { _, _ in configure() }
        .onChange(of: notes) { _, updated in reader.apply(notes: updated) }
        .onChange(of: reader.pageIndex) { _, page in pageInput = String(page + 1) }
        .onChange(of: navigationRequestID) { _, _ in if let navigationAnchor { reader.navigate(to: navigationAnchor) } }
    }

    private var modePicker: some View {
        Picker("읽기 방식", selection: Binding(get: { reader.displayMode }, set: { reader.setDisplayMode($0) })) {
            Text("단일 페이지").tag(PDFDisplayMode.singlePage)
            Text("연속으로 단일 페이지").tag(PDFDisplayMode.singlePageContinuous)
            Text("두 페이지").tag(PDFDisplayMode.twoUp)
            Text("연속으로 두 페이지").tag(PDFDisplayMode.twoUpContinuous)
        }.labelsHidden()
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            modePicker.pickerStyle(.menu).frame(width: 160)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                control("chevron.left", label: "이전 페이지") { reader.go(to: reader.pageIndex - 1) }
                    .disabled(reader.pageIndex == 0)
                TextField("페이지", text: $pageInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 38)
                    .onSubmit {
                        if let page = Int(pageInput) { reader.go(to: max(page, 1) - 1) }
                        pageInput = String(reader.pageIndex + 1)
                    }
                Text("/ \(reader.pageCount)").monospacedDigit().foregroundStyle(.secondary).fixedSize()
                control("chevron.right", label: "다음 페이지") { reader.go(to: reader.pageIndex + 1) }
                    .disabled(reader.pageIndex + 1 >= reader.pageCount)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                control("minus.magnifyingglass", label: "축소") { reader.zoom(by: 1 / 1.2) }
                if !compact { Text(reader.zoomLabel).monospacedDigit().frame(width: 40) }
                control("plus.magnifyingglass", label: "확대") { reader.zoom(by: 1.2) }
                control("arrow.up.left.and.arrow.down.right", label: "창 크기에 맞추기") { reader.fit() }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .help(label).accessibilityLabel(label)
    }

    private func configure() {
        reader.onSelection = onSelection
        reader.onPageChanged = onPageChanged
        reader.open(url: url, notes: notes, initialPage: initialPage)
        if let navigationAnchor { reader.navigate(to: navigationAnchor) }
    }
}

private struct PDFReaderCanvas: NSViewRepresentable {
    let reader: PDFReaderController
    func makeNSView(context: Context) -> AnnotatedPDFView { reader.view }
    func updateNSView(_ nsView: AnnotatedPDFView, context: Context) {}
}

@MainActor
private final class PDFReaderController: NSObject, ObservableObject {
    @Published var pageIndex = 0
    @Published var pageCount = 0
    @Published var zoomLabel = "100%"
    @Published private(set) var displayMode = PDFDisplayMode.singlePageContinuous
    @Published var error: String?
    let view = AnnotatedPDFView()
    var onSelection: ((PDFAnchor) -> Void)?
    var onPageChanged: ((Int) -> Void)?

    private var url: URL?
    private var originalBounds: [(media: CGRect, crop: CGRect)] = []
    private var lastNotes: [PDFWordNote] = []
    private var eventMonitor: Any?
    private var mouseDown: CGPoint?

    override init() {
        super.init()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displayBox = .cropBox
        view.autoScales = true
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 6
        view.backgroundColor = .clear
        view.setAccessibilityLabel("PDF 원문. 단어를 클릭하거나 표현·문장을 드래그하여 선택하세요.")
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(displayModeChanged), name: .PDFViewDisplayModeChanged, object: view)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .magnify]) { [weak self] event in
            if self?.magnify(event) == true { return nil }
            self?.handle(event)
            return event
        }
    }

    isolated deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    func open(url: URL, notes: [PDFWordNote], initialPage: Int) {
        guard self.url != url else { apply(notes: notes); return }
        self.url = url
        error = nil
        view.noteLayouts.withLock { $0 = [:] }
        originalBounds = []
        lastNotes = []
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            view.document = nil
            pageCount = 0
            error = "파일이 손상되었거나 암호로 잠겨 있습니다. 잠금을 해제한 PDF를 가져와 주세요."
            return
        }
        originalBounds = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return (page.bounds(for: .mediaBox), page.bounds(for: .cropBox))
        }
        view.document = document
        pageCount = document.pageCount
        apply(notes: notes, force: true)
        go(to: initialPage)
        fit()
    }

    func apply(notes: [PDFWordNote], force: Bool = false) {
        guard force || notes != lastNotes, let document = view.document else { return }
        let destination = view.currentDestination
        let grouped = Dictionary(grouping: notes, by: { $0.anchor.pageIndex })
        let previous = Dictionary(grouping: lastNotes, by: { $0.anchor.pageIndex })
        for index in Set(grouped.keys).union(previous.keys) {
            guard originalBounds.indices.contains(index), let page = document.page(at: index) else { continue }
            if !force && grouped[index] == previous[index] { continue }
            let original = originalBounds[index]
            page.setBounds(original.media, for: .mediaBox)
            page.setBounds(original.crop, for: .cropBox)
            if let pageNotes = grouped[index], !pageNotes.isEmpty {
                let layout = PDFNoteLayout(page: page, notes: pageNotes)
                view.noteLayouts.withLock { $0[index] = layout }
                let expanded = layout.geometry.expandedBounds(footerHeight: layout.footerHeight)
                page.setBounds(original.media.union(expanded), for: .mediaBox)
                page.setBounds(expanded, for: .cropBox)
            } else {
                view.noteLayouts.withLock { $0[index] = nil }
            }
            view.annotationsChanged(on: page)
        }
        lastNotes = notes
        view.layoutDocumentView()
        view.needsDisplay = true
        if let destination { view.go(to: destination) }
    }

    func go(to index: Int) {
        guard let document = view.document,
              let page = document.page(at: min(max(0, index), document.pageCount - 1)) else { return }
        view.go(to: page)
        pageChanged()
    }

    func zoom(by factor: CGFloat) {
        view.setUserScale(view.scaleFactor * factor)
        scaleChanged()
    }

    func navigate(to anchor: PDFAnchor) {
        guard let document = view.document, (0..<document.pageCount).contains(anchor.pageIndex),
              let page = document.page(at: anchor.pageIndex), !anchor.rects.isEmpty else { return }
        let bounds = anchor.rects.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty else { return }
        view.go(to: bounds.insetBy(dx: -8, dy: -30), on: page)
        if let selection = page.selection(for: bounds) { view.setCurrentSelection(selection, animate: false) }
    }

    func fit() { view.autoScales = true; scaleChanged() }

    func setDisplayMode(_ mode: PDFDisplayMode) {
        guard view.displayMode != mode else { return }
        view.displayMode = mode
    }

    @objc private func displayModeChanged() {
        if displayMode != view.displayMode { displayMode = view.displayMode }
    }

    @objc private func pageChanged() {
        guard let document = view.document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        pageIndex = index
        onPageChanged?(index)
    }

    @objc private func scaleChanged() { zoomLabel = "\(Int((view.scaleFactor * 100).rounded()))%" }

    private func magnify(_ event: NSEvent) -> Bool {
        guard event.type == .magnify, event.window === view.window, view.document != nil,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return false }
        view.magnify(with: event)
        return true
    }

    private func handle(_ event: NSEvent) {
        guard event.window === view.window else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown {
            mouseDown = nil
            if view.bounds.contains(point), let document = view.document,
               let page = view.page(for: point, nearest: false) {
                let index = document.index(for: page)
                if originalBounds.indices.contains(index), originalBounds[index].crop.contains(view.convert(point, to: page)) {
                    mouseDown = point
                }
            }
        } else if event.type == .leftMouseUp, let start = mouseDown {
            mouseDown = nil
            let isClick = hypot(point.x - start.x, point.y - start.y) < 4
            let source = url
            // Native PDFKit finishes updating its selection after the local monitor returns the event.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.url == source, self.view.window != nil else { return }
                self.finishSelection(at: point, wordClick: isClick)
            }
        }
    }

    private func finishSelection(at point: CGPoint, wordClick: Bool) {
        guard let document = view.document else { return }
        if wordClick {
            guard let page = view.page(for: point, nearest: false) else { return }
            let pagePoint = view.convert(point, to: page)
            let index = document.index(for: page)
            let characterIndex = page.characterIndex(at: pagePoint)
            guard originalBounds.indices.contains(index), originalBounds[index].crop.contains(pagePoint),
                  page.annotation(at: pagePoint)?.type != "Link",
                  characterIndex != NSNotFound, characterIndex >= 0, characterIndex < page.numberOfCharacters,
                  // Both word selection and character lookup can snap to nearby text outside its glyph bounds.
                  page.characterBounds(at: characterIndex).contains(pagePoint),
                  let character = page.selection(for: NSRange(location: characterIndex, length: 1))?.string,
                  !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let word = page.selectionForWord(at: pagePoint) else { return }
            view.setCurrentSelection(word, animate: false)
        }
        guard let selection = view.currentSelection, let page = selection.pages.first else { return }
        let index = document.index(for: page)
        guard originalBounds.indices.contains(index) else { return }
        let lines = selection.selectionsByLine().filter {
            $0.pages.contains(page) && originalBounds[index].crop.contains($0.bounds(for: page))
        }
        let text = lines.compactMap(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let rects = lines.map { $0.bounds(for: page) }.filter { !$0.isEmpty && !$0.isNull }
        guard !text.isEmpty, !rects.isEmpty else { return }
        onSelection?(PDFAnchor(pageIndex: index, text: text, rects: rects,
                               isSentence: TextSelectionClassifier.isSentence(text)))
    }
}

private final class AnnotatedPDFView: PDFView {
    override func magnify(with event: NSEvent) {
        guard event.magnification.isFinite else { return }
        setUserScale(scaleFactor * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    func setUserScale(_ value: CGFloat, at point: CGPoint? = nil) {
        guard value.isFinite else { return }
        let previousScale = scaleFactor
        let target = min(6, max(0.2, value))
        var destination = currentDestination
        if let point, let current = destination, let page = current.page,
           self.page(for: point, nearest: false) === page {
            let anchor = convert(point, to: page)
            let ratio = previousScale / target
            destination = PDFDestination(page: page, at: CGPoint(x: anchor.x + (current.point.x - anchor.x) * ratio,
                                                               y: anchor.y + (current.point.y - anchor.y) * ratio))
        }
        // PDFKit resets its limits during auto-fit; restore manual zoom limits for both inputs.
        minScaleFactor = 0.2
        maxScaleFactor = 6
        autoScales = false
        scaleFactor = target
        if let destination { destination.zoom = target; go(to: destination) }
    }

    // PDFKit renders tiles on worker queues; publish immutable layouts under a short lock.
    nonisolated let noteLayouts = OSAllocatedUnfairLock(initialState: [Int: PDFNoteLayout]())

    nonisolated override func drawPagePost(_ page: PDFPage, to context: CGContext) {
        guard let document = page.document else { return }
        let index = document.index(for: page)
        guard let layout = noteLayouts.withLock({ $0[index] }) else { return }
        context.saveGState()
        page.transform(context, for: .cropBox)
        context.concatenate(layout.geometry.pageToVisual.inverted())
        layout.draw(in: context)
        context.restoreGState()
    }
}
