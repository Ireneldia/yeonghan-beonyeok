import AppKit
import PDFKit
import CoreText

nonisolated struct PDFAnchor: Codable, Equatable, Sendable {
    var pageIndex: Int
    var text: String
    var rects: [CGRect]
    var isSentence: Bool = false

}

nonisolated struct PDFWordNote: Equatable, Sendable {
    var anchor: PDFAnchor
    var meaning: String
    var colorHex: String = AnnotationColor.defaultHex
}

/// Stored anchors always use the original PDF page coordinates, independent of zoom and rotation.
nonisolated struct PDFPageGeometry: Sendable {
    let bounds: CGRect
    let pageToVisual: CGAffineTransform
    let size: CGSize

    init(bounds: CGRect, rotation: Int) {
        self.bounds = bounds
        switch (rotation % 360 + 360) % 360 {
        case 90:
            pageToVisual = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -bounds.minY, ty: bounds.maxX)
            size = CGSize(width: bounds.height, height: bounds.width)
        case 180:
            pageToVisual = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: bounds.maxX, ty: bounds.maxY)
            size = bounds.size
        case 270:
            pageToVisual = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bounds.maxY, ty: -bounds.minX)
            size = CGSize(width: bounds.height, height: bounds.width)
        default:
            pageToVisual = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            size = bounds.size
        }
    }

    func expandedBounds(footerHeight: CGFloat) -> CGRect {
        CGRect(x: 0, y: -footerHeight, width: size.width, height: size.height + footerHeight)
            .applying(pageToVisual.inverted())
    }
}

nonisolated struct PDFNoteLayout: Sendable {
    struct Label: Sendable {
        var text: String
        var rect: CGRect
        var footer: Bool
        var fontSize: CGFloat = 8
        var color: AnnotationColor = .defaultColor
        var outlineGray: CGFloat?
        var baseline: CGPoint?
    }

    struct Underline: Sendable {
        var rect: CGRect
        var color: AnnotationColor
        var outlineGray: CGFloat?
    }

    let geometry: PDFPageGeometry
    var labels: [Label] = []
    var underlines: [Underline] = []
    var footerHeight: CGFloat = 0

    init(page: PDFPage, notes: [PDFWordNote]) {
        geometry = PDFPageGeometry(bounds: page.bounds(for: .cropBox), rotation: page.rotation)
        guard !notes.isEmpty else { return }
        let pageRect = CGRect(origin: .zero, size: geometry.size)
        // Amortize one bounded 2x snapshot across several notes; isolated notes and
        // oversized pages retain the bounded per-region rendering path below.
        let snapshot = notes.count >= 4 ? Self.bitmap(pageRect, on: page)?.makeImage() : nil
        var pending: [(PDFWordNote, AnnotationColor, String, CGRect)] = []
        for note in notes {
            let color = AnnotationColor(hex: note.colorHex) ?? .defaultColor
            let meaning = note.meaning.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let anchors = note.anchor.rects.filter {
                !$0.isEmpty && !$0.isInfinite && !$0.isNull && geometry.bounds.intersects($0)
            }.map { $0.applying(geometry.pageToVisual) }.map { rect in
                let bottom = Self.inkBottom(in: rect, on: page)
                return CGRect(x: rect.minX, y: bottom, width: rect.width, height: rect.maxY - bottom)
            }
            guard !meaning.isEmpty, let source = anchors.min(by: { $0.minY < $1.minY }) else { continue }
            underlines += anchors.map { rect in
                let below = CGRect(x: rect.minX, y: rect.minY - 1.1, width: rect.width, height: 0.4)
                let outline = Self.uniformBackground(in: below, on: page, snapshot: snapshot)
                    .flatMap { Self.outline(for: color, background: $0) }
                return Underline(rect: rect, color: color, outlineGray: outline)
            }
            pending.append((note, color, meaning, source))
        }
        let underlineBounds = underlines.map { CGRect(x: $0.rect.minX, y: $0.rect.minY - 1, width: $0.rect.width, height: 1) }
        for (note, color, meaning, source) in pending {
            var placed = false
            for fontSize: CGFloat in [8, 7] {
                let width = max(24, min(220, geometry.size.width - 24))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: meaning, attributes: Self.attributes(footer: false, fontSize: fontSize)))
                let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                // Short terms need only their painted glyph height, not a paragraph's extra leading.
                let tight = !note.anchor.isSentence && !ink.isEmpty && ink.width <= width
                let size = tight ? ink.size : Self.textSize(meaning, width: width, footer: false, fontSize: fontSize)
                let positions = tight ? [source.midX - size.width / 2, source.maxX - size.width, source.minX]
                    : [source.midX - size.width / 2]
                for x in positions {
                    let inline = CGRect(x: x,
                                        y: source.minY - size.height - (tight ? 1.5 : 0.5),
                                        width: size.width, height: size.height)
                    guard pageRect.insetBy(dx: 8, dy: 8).contains(inline),
                          !labels.contains(where: { $0.rect.intersects(inline.insetBy(dx: -2, dy: -0.5)) }),
                          !underlineBounds.contains(where: { $0.intersects(inline.insetBy(dx: -0.5, dy: -0.5)) }),
                          let background = Self.uniformBackground(in: inline, on: page, snapshot: snapshot) else { continue }
                    labels.append(Label(text: meaning, rect: inline, footer: false, fontSize: fontSize,
                                        color: color, outlineGray: Self.outline(for: color, background: background),
                                        baseline: tight ? CGPoint(x: inline.minX - ink.minX, y: inline.minY - ink.minY) : nil))
                    placed = true
                    break
                }
                if placed { break }
            }
            if !placed {
                let sourceText = note.anchor.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let text = "\(sourceText) — \(meaning)"
                let size = Self.textSize(text, width: max(24, geometry.size.width - 32), footer: true, fontSize: 9)
                if footerHeight == 0 { footerHeight = 12 }
                footerHeight += size.height + 5
                labels.append(Label(text: text,
                                    rect: CGRect(x: 16, y: -footerHeight, width: geometry.size.width - 32, height: size.height),
                                    footer: true, fontSize: 9, color: color,
                                    outlineGray: Self.outline(for: color, background: pow((0.975 + 0.055) / 1.055, 2.4))))
            }
        }
        if footerHeight > 0 { footerHeight += 10 }
    }

    private static func attributes(footer: Bool, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = footer ? .left : .center
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph]
    }

    private static func textSize(_ text: String, width: CGFloat, footer: Bool, fontSize: CGFloat) -> CGSize {
        let string = NSAttributedString(string: text, attributes: attributes(footer: footer, fontSize: fontSize))
        let setter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                              CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: min(width, ceil(size.width) + 2), height: ceil(size.height))
    }

    private static func bitmap(_ rect: CGRect, on page: PDFPage, snapshot: CGImage? = nil) -> CGContext? {
        guard !rect.isInfinite, !rect.isNull, rect.width > 0, rect.height > 0, rect.width <= 2048, rect.height <= 2048,
              rect.width * rect.height <= 1_048_576 else { return nil }
        let width = max(1, Int(ceil(rect.width * 2)))
        let height = max(1, Int(ceil(rect.height * 2)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              context.data != nil else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        if let snapshot {
            context.interpolationQuality = .none
            context.draw(snapshot, in: CGRect(x: 0, y: 0,
                                             width: CGFloat(snapshot.width) / 2, height: CGFloat(snapshot.height) / 2))
        } else { page.draw(with: .cropBox, to: context) }
        return context
    }

    private static func raster(_ rect: CGRect, on page: PDFPage, snapshot: CGImage?) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let context = bitmap(rect, on: page, snapshot: snapshot), let data = context.data else { return nil }
        let width = context.width, height = context.height
        return withExtendedLifetime(context) {
            (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)), width, height)
        }
    }

    /// PDF font boxes include empty descender space; use the painted word's bottom edge instead.
    private static func inkBottom(in rect: CGRect, on page: PDFPage) -> CGFloat {
        guard let bitmap = raster(rect, on: page, snapshot: nil) else { return rect.minY }
        let bottomRow = (bitmap.height - 1) * bitmap.width * 4
        let background = (0..<3).map { channel in
            (0..<bitmap.width).map { bitmap.pixels[bottomRow + $0 * 4 + channel] }.sorted()[bitmap.width / 2]
        }
        for row in 0..<bitmap.height {
            let offset = (bitmap.height - 1 - row) * bitmap.width * 4
            if (0..<bitmap.width).contains(where: { x in
                (0..<3).contains { abs(Int(bitmap.pixels[offset + x * 4 + $0]) - Int(background[$0])) > 12 }
            }) { return rect.minY + CGFloat(row) / 2 }
        }
        return rect.minY
    }

    /// A flat background of any color is free space. Edges, letters, and diagrams reject placement.
    /// Returns the sampled background's relative luminance for annotation contrast.
    private static func uniformBackground(in rect: CGRect, on page: PDFPage, snapshot: CGImage?) -> Double? {
        let region = rect.insetBy(dx: -0.5, dy: -0.5)
        if let snapshot {
            // A snapshot has a fixed pixel grid. Keep the original region rendering near
            // antialiased edges, where a subpixel shift can change the placement decision.
            if let bitmap = raster(region.insetBy(dx: -0.5, dy: -0.5), on: page, snapshot: snapshot),
               let background = background(in: bitmap, tolerance: 0) { return background }
            // Reject only strong interior contrast; the exact probe handles thin edges.
            if region.width > 2, region.height > 2,
               let bitmap = raster(region.insetBy(dx: 1, dy: 1), on: page, snapshot: snapshot),
               background(in: bitmap, tolerance: 48) == nil { return nil }
        }
        guard let bitmap = raster(region, on: page, snapshot: nil) else { return nil }
        return background(in: bitmap, tolerance: 12)
    }

    private static func background(in bitmap: (pixels: [UInt8], width: Int, height: Int), tolerance: Int) -> Double? {
        var minimum = [255, 255, 255], maximum = [0, 0, 0]
        for pixel in stride(from: 0, to: bitmap.pixels.count, by: 4) {
            for channel in 0..<3 {
                let value = Int(bitmap.pixels[pixel + channel])
                minimum[channel] = min(minimum[channel], value)
                maximum[channel] = max(maximum[channel], value)
                if maximum[channel] - minimum[channel] > tolerance { return nil }
            }
        }
        let linear = (0..<3).map { channel -> Double in
            let value = Double(minimum[channel] + maximum[channel]) / 510
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        return luminance
    }

    private static func outline(for color: AnnotationColor, background: Double) -> CGFloat? {
        let foreground = color.luminance
        let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
        return contrast < 4.5 ? (background < 0.179 ? 1 : 0) : nil
    }

    /// The context uses normalized, unrotated-on-screen PDF points, with the original bottom at y = 0.
    func draw(in context: CGContext, textAsPaths: Bool = false) {
        context.saveGState()
        if footerHeight > 0 {
            context.setFillColor(CGColor(gray: 0.975, alpha: 1))
            context.fill(CGRect(x: 0, y: -footerHeight, width: geometry.size.width, height: footerHeight))
            context.setStrokeColor(CGColor(gray: 0.80, alpha: 1))
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: 16, y: -5))
            context.addLine(to: CGPoint(x: geometry.size.width - 16, y: -5))
            context.strokePath()
        }
        for underline in underlines {
            let rect = underline.rect
            // Keep both the colored stroke and its contrast edge below the source ink.
            let y = rect.minY - 0.5
            if let gray = underline.outlineGray {
                context.setStrokeColor(CGColor(gray: gray, alpha: 1))
                context.setLineWidth(0.95)
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.strokePath()
            }
            context.setStrokeColor(underline.color.cgColor)
            context.setLineWidth(0.65)
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
        }
        context.textMatrix = .identity
        context.setTextDrawingMode(.fill)
        context.setAlpha(1)
        for label in labels {
            var attributes = Self.attributes(footer: label.footer, fontSize: label.fontSize)
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = label.color.cgColor
            if let gray = label.outlineGray {
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: gray, alpha: 1)
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -3.0
            }
            let text = NSAttributedString(string: label.text, attributes: attributes)
            if let baseline = label.baseline {
                let line = CTLineCreateWithAttributedString(text)
                if textAsPaths { Self.drawPaths(line, at: baseline, label: label, in: context) }
                else {
                    context.textPosition = baseline
                    CTLineDraw(line, context)
                }
            } else {
                let setter = CTFramesetterCreateWithAttributedString(text)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: label.rect, transform: nil), nil)
                if textAsPaths {
                    let lines = CTFrameGetLines(frame) as! [CTLine]
                    var origins = [CGPoint](repeating: .zero, count: lines.count)
                    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                    for (line, origin) in zip(lines, origins) {
                        Self.drawPaths(line, at: CGPoint(x: label.rect.minX + origin.x, y: label.rect.minY + origin.y), label: label, in: context)
                    }
                } else { CTFrameDraw(frame, context) }
            }
        }
        context.restoreGState()
    }

    /// PDFKit's generated text appearances can omit embedded font stream lengths.
    /// Keep the shaped glyphs as vectors; the annotation's contents retains the text.
    private static func drawPaths(_ line: CTLine, at origin: CGPoint, label: Label, in context: CGContext) {
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                    var transform = CTRunGetTextMatrix(run)
                    transform.tx += origin.x + position.x
                    transform.ty += origin.y + position.y
                    path.addPath(outline, transform: transform)
                } else {
                    var glyph = glyph
                    if !CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1).isEmpty {
                        // Color glyphs have no outline. Rasterize only this line, at up to 6x.
                        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).insetBy(dx: -1, dy: -1)
                        let scale = min(6, sqrt(1_048_576 / max(1, bounds.width * bounds.height)))
                        guard let bitmap = CGContext(data: nil, width: max(1, Int(ceil(bounds.width * scale))),
                                                     height: max(1, Int(ceil(bounds.height * scale))), bitsPerComponent: 8,
                                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                        bitmap.scaleBy(x: scale, y: scale)
                        bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
                        bitmap.textPosition = .zero
                        CTLineDraw(line, bitmap)
                        if let image = bitmap.makeImage() {
                            context.draw(image, in: bounds.offsetBy(dx: origin.x, dy: origin.y))
                        }
                        return
                    }
                }
            }
        }
        context.setFillColor(label.color.cgColor)
        context.addPath(path)
        if let gray = label.outlineGray {
            context.setStrokeColor(CGColor(gray: gray, alpha: 1))
            context.setLineWidth(label.fontSize * 0.03)
            context.drawPath(using: .fillStroke)
        } else { context.fillPath() }
    }
}

/// A tight appearance region leaves the original page's text and link hit targets available.
nonisolated private final class PDFNoteAppearance: PDFAnnotation {
    private let layout: PDFNoteLayout

    init(rect: CGRect, layout: PDFNoteLayout, contents: String?) {
        self.layout = layout
        super.init(bounds: rect.applying(layout.geometry.pageToVisual.inverted()), forType: .stamp, withProperties: nil)
        self.contents = contents
        border = nil
        shouldDisplay = true
        shouldPrint = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        // PDFKit supplies a context relative to the display box, including during AP serialization.
        if let page {
            let origin = page.bounds(for: box).origin
            context.translateBy(x: -origin.x, y: -origin.y)
        }
        context.clip(to: bounds)
        context.concatenate(layout.geometry.pageToVisual.inverted())
        layout.draw(in: context, textAsPaths: true)
        context.restoreGState()
    }
}

nonisolated enum PDFExportError: LocalizedError {
    case unreadable, sameFile, cannotCreate

    var errorDescription: String? {
        switch self {
        case .unreadable: "PDF를 열 수 없습니다. 암호화 여부와 파일을 확인해 주세요."
        case .sameFile: "원본을 보존하려면 다른 파일 이름으로 내보내 주세요."
        case .cannotCreate: "PDF를 저장할 수 없습니다. 저장 위치를 확인해 주세요."
        }
    }
}

nonisolated enum PDFExporter {
    static func export(source: URL, notes: [PDFWordNote], destination: URL) throws {
        try Task.checkCancellation()
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL
        else { throw PDFExportError.sameFile }
        guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0
        else { throw PDFExportError.unreadable }
        let manager = FileManager.default
        let replacement = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: replacement) }
        let staged = replacement.appendingPathComponent("export.pdf")
        try write(document: document, notes: notes, to: staged)
        try Task.checkCancellation()
        // Verify the staged document before replacing an existing file.
        let handle = try FileHandle(forReadingFrom: staged)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: length > 128 ? length - 128 : 0)
        let trailer = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        guard trailer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%%EOF"),
              let output = CGPDFDocument(staged as CFURL), output.numberOfPages == document.pageCount else {
            throw PDFExportError.cannotCreate
        }
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            guard (try destination.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw PDFExportError.cannotCreate }
            _ = try manager.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else { try manager.moveItem(at: staged, to: destination) }
    }

    private static func write(document: PDFDocument, notes: [PDFWordNote], to destination: URL) throws {
        let grouped = Dictionary(grouping: notes, by: { $0.anchor.pageIndex })
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let notes = grouped[index], !notes.isEmpty else { continue }
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw PDFExportError.unreadable }
                let layout = PDFNoteLayout(page: page, notes: notes)
                if layout.footerHeight > 0 {
                    let expanded = layout.geometry.expandedBounds(footerHeight: layout.footerHeight)
                    page.setBounds(page.bounds(for: .mediaBox).union(expanded), for: .mediaBox)
                    page.setBounds(expanded, for: .cropBox)
                }
                let originals = page.annotations
                originals.forEach(page.removeAnnotation)
                for underline in layout.underlines {
                    var part = layout
                    part.labels = []; part.underlines = [underline]; part.footerHeight = 0
                    let rect = CGRect(x: underline.rect.minX - 0.5, y: underline.rect.minY - 1.25,
                                      width: underline.rect.width + 1, height: 1.5)
                    page.addAnnotation(PDFNoteAppearance(rect: rect, layout: part, contents: nil))
                }
                for label in layout.labels where !label.footer {
                    var part = layout
                    part.labels = [label]; part.underlines = []; part.footerHeight = 0
                    page.addAnnotation(PDFNoteAppearance(rect: label.rect.insetBy(dx: -1, dy: -1), layout: part, contents: label.text))
                }
                if layout.footerHeight > 0 {
                    var part = layout
                    part.labels = layout.labels.filter(\.footer); part.underlines = []
                    let rect = CGRect(x: 0, y: -layout.footerHeight, width: layout.geometry.size.width, height: layout.footerHeight)
                    page.addAnnotation(PDFNoteAppearance(rect: rect, layout: part, contents: part.labels.map(\.text).joined(separator: "\n")))
                }
                // Retain the original annotation order and keep interactive links/comments above our marks.
                originals.forEach(page.addAnnotation)
            }
        }
        try Task.checkCancellation()
        guard document.write(to: destination) else { throw PDFExportError.cannotCreate }
    }
}
