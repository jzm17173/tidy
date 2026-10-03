import Vision

/// 识别出的一行文本（详设 §2.7）
struct RecognizedTextLine: Equatable {
    let text: String
    /// Vision 归一化边界框（左下原点，0–1）
    let boundingBox: CGRect
    /// 逐字符框（归一化，与 text 的 Character 一一对应）；字符框不可用（旋转文本等）时为空，退化为整行选择
    let charBoxes: [CGRect]

    init(text: String, boundingBox: CGRect, charBoxes: [CGRect] = []) {
        self.text = text
        self.boundingBox = boundingBox
        self.charBoxes = charBoxes
    }
}

/// 划选端点：line = 行下标，char = 行内字符插入位（0...text.count）
struct TextPosition: Equatable, Comparable {
    let line: Int
    let char: Int

    static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.line, lhs.char) < (rhs.line, rhs.char)
    }
}

/// 字符级划选（详设 §2.7）：锚点与光标两点规范化为 start ≤ end；start == end 视为无选择
struct TextSelection: Equatable {
    let start: TextPosition
    let end: TextPosition

    var isEmpty: Bool { start == end }

    init(anchor: TextPosition, caret: TextPosition) {
        start = min(anchor, caret)
        end = max(anchor, caret)
    }
}

/// 图片文本识别（详设 §2.7）：Vision OCR，识别是增强能力——失败/无文本一律返回空，不阻塞浏览。
enum TextRecognizer {
    /// 识别静态图中的文本行（含逐字符框），按阅读顺序（自上而下、同行自左而右）排列
    static func recognize(image: CGImage) async -> [RecognizedTextLine] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            guard (try? handler.perform([request])) != nil,
                  let results = request.results else { return [] }
            return results.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedTextLine(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    charBoxes: charBoxes(of: candidate)
                )
            }
            .sorted { lhs, rhs in
                // Vision 左下原点：maxY 大 = 更靠上；同带（行高一半内）按 minX 排
                if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > min(lhs.boundingBox.height, rhs.boundingBox.height) / 2 {
                    return lhs.boundingBox.maxY > rhs.boundingBox.maxY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
        }.value
    }

    /// 逐字符框（`VNRecognizedText.boundingBox(for:)`，与预览.app 同一数据源）；
    /// 任一字符取不到（或数量对不上）→ 返回空，该行退化为整行选择
    private static func charBoxes(of candidate: VNRecognizedText) -> [CGRect] {
        let text = candidate.string
        var boxes: [CGRect] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            guard let quad = try? candidate.boundingBox(for: index..<next) else { return [] }
            boxes.append(quad.boundingBox)
            index = next
        }
        return boxes.count == text.count ? boxes : []
    }

    /// 复制全部：按行拼接
    static func fullText(of lines: [RecognizedTextLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// 划选区间内的文本：首尾行按字符截取，中间行整行，行间换行拼接
    static func selectedText(from lines: [RecognizedTextLine], selection: TextSelection) -> String {
        guard !selection.isEmpty else { return "" }
        var parts: [String] = []
        for lineIndex in selection.start.line...selection.end.line where lines.indices.contains(lineIndex) {
            let text = lines[lineIndex].text
            let lo = lineIndex == selection.start.line ? selection.start.char : 0
            let hi = lineIndex == selection.end.line ? selection.end.char : text.count
            guard lo < hi, hi <= text.count else { continue }
            parts.append(String(text[text.index(text.startIndex, offsetBy: lo)..<text.index(text.startIndex, offsetBy: hi)]))
        }
        return parts.joined(separator: "\n")
    }

    /// Vision 归一化坐标（左下原点）→ 图片文档坐标（左上原点，y 向下）
    static func docRect(for box: CGRect, in docSize: CGSize) -> CGRect {
        CGRect(
            x: box.minX * docSize.width,
            y: (1 - box.maxY) * docSize.height,
            width: box.width * docSize.width,
            height: box.height * docSize.height
        )
    }
}
