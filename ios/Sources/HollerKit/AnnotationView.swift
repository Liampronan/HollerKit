import SwiftUI

#if canImport(PencilKit) && canImport(UIKit)
import PencilKit
import UIKit

struct AnnotationEditorScreen: View {
    var image: BugReportImage
    var onSave: (UIImage) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTool: AnnotationTool = .pen
    @State private var penColor: AnnotationColor = .lagoon
    @State private var redactionColor: AnnotationColor = .graphite
    @State private var drawing = PKDrawing()
    @State private var redactionRects: [RedactionMark] = []
    @State private var selectedRedactionIndex: Int?
    @State private var activeRedactionRect: CGRect?
    @State private var history: [AnnotationHistoryItem] = []
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.06)

                GeometryReader { proxy in
                    let imageFrame = image.image.size.aspectFitFrame(in: proxy.size, inset: 16)

                    ZStack {
                        Image(uiImage: image.image)
                            .resizable()
                            .frame(width: imageFrame.width, height: imageFrame.height)

                        AnnotationCanvasView(
                            drawing: $drawing,
                            history: $history,
                            tool: AnnotationTool.pen.pencilKitTool(color: penColor),
                            isEnabled: selectedTool != .redact
                        )
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .onAppear {
                            canvasSize = imageFrame.size
                        }
                        .onChange(of: imageFrame.size) { newSize in
                            canvasSize = newSize
                        }

                        if selectedTool == .redact {
                            RedactionEditLayer(
                                imageSize: imageFrame.size,
                                redactionRects: $redactionRects,
                                selectedIndex: $selectedRedactionIndex,
                                activeRect: $activeRedactionRect,
                                redactionColor: redactionColor,
                                pushHistory: {
                                    history.append(.redactions(redactionRects))
                                },
                                onCommit: { rect in
                                    history.append(.redactions(redactionRects))
                                    redactionRects.append(RedactionMark(rect: rect, color: redactionColor))
                                    selectedRedactionIndex = redactionRects.indices.last
                                }
                            )
                            .frame(width: imageFrame.width, height: imageFrame.height)
                        } else {
                            RedactionDisplayLayer(rects: redactionRects)
                                .frame(width: imageFrame.width, height: imageFrame.height)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                }
            }

            AnnotationToolbar(
                selectedTool: $selectedTool,
                selectedColor: selectedToolColor,
                undo: {
                    undoLastChange()
                }
            )
        }
        .navigationTitle("Annotate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    let renderedImage = AnnotationRenderer.render(
                        baseImage: image.image,
                        drawing: drawing,
                        redactionRects: redactionRects,
                        canvasSize: canvasSize
                    )
                    onSave(renderedImage)
                    dismiss()
                }
            }
        }
        .accessibilityIdentifier("HollerKitAnnotationEditor")
    }

    private func undoLastChange() {
        guard let item = history.popLast() else { return }

        switch item {
        case .drawing(let previousDrawing):
            drawing = previousDrawing
        case .redactions(let previousRects):
            redactionRects = previousRects
            selectedRedactionIndex = previousRects.indices.last
        }
    }

    private var selectedToolColor: Binding<AnnotationColor> {
        Binding {
            selectedTool == .pen ? penColor : redactionColor
        } set: { newColor in
            if selectedTool == .pen {
                penColor = newColor
            } else {
                redactionColor = newColor
                if let selectedRedactionIndex,
                   redactionRects.indices.contains(selectedRedactionIndex),
                   redactionRects[selectedRedactionIndex].color != newColor {
                    history.append(.redactions(redactionRects))
                    redactionRects[selectedRedactionIndex].color = newColor
                }
            }
        }
    }
}

private struct AnnotationToolbar: View {
    @Binding var selectedTool: AnnotationTool
    @Binding var selectedColor: AnnotationColor
    var undo: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button {
                        selectedTool = tool
                    } label: {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 42, height: 38)
                            .background {
                                if selectedTool == tool {
                                    LinearGradient(
                                        colors: [
                                            Color(uiColor: .systemTeal).opacity(0.18),
                                            Color(uiColor: .systemIndigo).opacity(0.14)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tool.title)
                }

                ColorSelector(selectedColor: $selectedColor)

                Spacer()

                Button(action: undo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground).opacity(0.96),
                    Color(uiColor: .systemTeal).opacity(0.08),
                    Color(uiColor: .systemIndigo).opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(.regularMaterial.opacity(0.72))
        }
    }
}

private struct ColorSelector: View {
    @Binding var selectedColor: AnnotationColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnnotationColor.allCases) { color in
                Button {
                    selectedColor = color
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 24, height: 24)
                        .overlay {
                            Circle()
                                .stroke(selectedColor == color ? Color.primary : Color.secondary.opacity(0.28), lineWidth: selectedColor == color ? 2 : 1)
                        }
                        .overlay {
                            if selectedColor == color {
                                Circle()
                                    .stroke(Color(uiColor: .systemBackground), lineWidth: 1)
                                    .padding(3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.title)
            }
        }
    }
}

private struct AnnotationCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var history: [AnnotationHistoryItem]
    var tool: PKTool
    var isEnabled: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = context.coordinator
        canvasView.tool = tool
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
        uiView.tool = tool
        uiView.isUserInteractionEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing, history: $history)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing
        @Binding var history: [AnnotationHistoryItem]

        init(drawing: Binding<PKDrawing>, history: Binding<[AnnotationHistoryItem]>) {
            _drawing = drawing
            _history = history
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if canvasView.drawing.strokes.count > drawing.strokes.count {
                history.append(.drawing(drawing))
            }
            drawing = canvasView.drawing
        }
    }
}

private struct RedactionDisplayLayer: View {
    var rects: [RedactionMark]

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(rects.enumerated()), id: \.offset) { _, mark in
                Rectangle()
                    .fill(mark.color.color)
                    .frame(
                        width: proxy.size.width * mark.rect.width,
                        height: proxy.size.height * mark.rect.height
                    )
                    .position(
                        x: proxy.size.width * mark.rect.midX,
                        y: proxy.size.height * mark.rect.midY
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RedactionEditLayer: View {
    var imageSize: CGSize
    @Binding var redactionRects: [RedactionMark]
    @Binding var selectedIndex: Int?
    @Binding var activeRect: CGRect?
    var redactionColor: AnnotationColor
    var pushHistory: () -> Void
    var onCommit: (CGRect) -> Void
    @State private var dragStartRect: CGRect?
    @State private var resizeStartRect: CGRect?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            selectedIndex = nil
                            activeRect = normalizedRect(from: value.startLocation, to: value.location)
                        }
                        .onEnded { value in
                            let rect = normalizedRect(from: value.startLocation, to: value.location)
                            activeRect = nil
                            if rect.width > 0.02 && rect.height > 0.02 {
                                onCommit(rect)
                            }
                        }
                )

            RedactionDisplayLayer(rects: previewMarks)

            ForEach(Array(redactionRects.indices), id: \.self) { index in
                let rect = redactionRects[index].rect

                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(
                        width: imageSize.width * rect.width,
                        height: imageSize.height * rect.height
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if selectedIndex == index {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 18, height: 18)
                                .overlay {
                                    Circle()
                                        .stroke(.white, lineWidth: 2)
                                }
                                .offset(x: 8, y: 8)
                                .gesture(resizeGesture(for: index))
                        }
                    }
                    .overlay {
                        if selectedIndex == index {
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 2)
                        }
                    }
                    .position(
                        x: imageSize.width * rect.midX,
                        y: imageSize.height * rect.midY
                    )
                    .onTapGesture {
                        selectedIndex = index
                    }
                    .gesture(moveGesture(for: index))
            }
        }
    }

    private var previewMarks: [RedactionMark] {
        if let activeRect {
            return redactionRects + [RedactionMark(rect: activeRect, color: redactionColor)]
        }

        return redactionRects
    }

    private func moveGesture(for index: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                selectedIndex = index
                if dragStartRect == nil {
                    pushHistory()
                    dragStartRect = redactionRects[index].rect
                }

                guard let dragStartRect else { return }
                redactionRects[index].rect = dragStartRect.moved(
                    by: value.translation,
                    in: imageSize
                )
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private func resizeGesture(for index: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                selectedIndex = index
                if resizeStartRect == nil {
                    pushHistory()
                    resizeStartRect = redactionRects[index].rect
                }

                guard let resizeStartRect else { return }
                redactionRects[index].rect = resizeStartRect.resized(
                    by: value.translation,
                    in: imageSize
                )
            }
            .onEnded { _ in
                resizeStartRect = nil
            }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let minX = min(start.x, end.x).clamped(to: 0...imageSize.width)
        let minY = min(start.y, end.y).clamped(to: 0...imageSize.height)
        let maxX = max(start.x, end.x).clamped(to: 0...imageSize.width)
        let maxY = max(start.y, end.y).clamped(to: 0...imageSize.height)

        return CGRect(
            x: minX / imageSize.width,
            y: minY / imageSize.height,
            width: (maxX - minX) / imageSize.width,
            height: (maxY - minY) / imageSize.height
        )
    }
}

private enum AnnotationTool: CaseIterable, Identifiable {
    case pen
    case redact

    var id: Self { self }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .redact: return "Redact"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .redact: return "rectangle.fill"
        }
    }

    func pencilKitTool(color: AnnotationColor) -> PKTool {
        switch self {
        case .pen:
            return PKInkingTool(.pen, color: color.uiColor, width: 7)
        case .redact:
            return PKInkingTool(.pen, color: .clear, width: 1)
        }
    }
}

private struct RedactionMark: Equatable {
    var rect: CGRect
    var color: AnnotationColor
}

private enum AnnotationHistoryItem {
    case drawing(PKDrawing)
    case redactions([RedactionMark])
}

private enum AnnotationColor: String, CaseIterable, Identifiable, Equatable {
    case lagoon
    case indigo
    case plum
    case graphite
    case ember

    var id: Self { self }

    var title: String {
        switch self {
        case .lagoon: return "Lagoon"
        case .indigo: return "Indigo"
        case .plum: return "Plum"
        case .graphite: return "Graphite"
        case .ember: return "Ember"
        }
    }

    var color: Color {
        Color(uiColor: uiColor)
    }

    var uiColor: UIColor {
        switch self {
        case .lagoon:
            return UIColor(red: 0.00, green: 0.55, blue: 0.72, alpha: 1.00)
        case .indigo:
            return UIColor(red: 0.31, green: 0.32, blue: 0.78, alpha: 1.00)
        case .plum:
            return UIColor(red: 0.55, green: 0.26, blue: 0.72, alpha: 1.00)
        case .graphite:
            return UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.00)
        case .ember:
            return UIColor(red: 0.88, green: 0.35, blue: 0.18, alpha: 1.00)
        }
    }
}

private enum AnnotationRenderer {
    static func render(
        baseImage: UIImage,
        drawing: PKDrawing,
        redactionRects: [RedactionMark],
        canvasSize: CGSize
    ) -> UIImage {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return baseImage
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = baseImage.scale

        let renderer = UIGraphicsImageRenderer(size: baseImage.size, format: format)
        return renderer.image { context in
            baseImage.draw(in: CGRect(origin: .zero, size: baseImage.size))

            let drawingImage = drawing.image(
                from: CGRect(origin: .zero, size: canvasSize),
                scale: baseImage.scale
            )
            drawingImage.draw(in: CGRect(origin: .zero, size: baseImage.size))

            for mark in redactionRects {
                mark.color.uiColor.setFill()
                context.fill(CGRect(
                    x: mark.rect.minX * baseImage.size.width,
                    y: mark.rect.minY * baseImage.size.height,
                    width: mark.rect.width * baseImage.size.width,
                    height: mark.rect.height * baseImage.size.height
                ))
            }
        }
    }
}

private extension CGSize {
    func aspectFitFrame(in bounds: CGSize, inset: CGFloat) -> CGRect {
        let available = CGSize(
            width: max(bounds.width - inset * 2, 1),
            height: max(bounds.height - inset * 2, 1)
        )

        let scale = min(available.width / width, available.height / height)
        let fittedSize = CGSize(width: width * scale, height: height * scale)

        return CGRect(
            x: (bounds.width - fittedSize.width) / 2,
            y: (bounds.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}

private extension CGRect {
    func moved(by translation: CGSize, in imageSize: CGSize) -> CGRect {
        let dx = translation.width / imageSize.width
        let dy = translation.height / imageSize.height
        return CGRect(
            x: (origin.x + dx).clamped(to: 0...(1 - width)),
            y: (origin.y + dy).clamped(to: 0...(1 - height)),
            width: width,
            height: height
        )
    }

    func resized(by translation: CGSize, in imageSize: CGSize) -> CGRect {
        let dw = translation.width / imageSize.width
        let dh = translation.height / imageSize.height
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: (width + dw).clamped(to: 0.04...(1 - origin.x)),
            height: (height + dh).clamped(to: 0.04...(1 - origin.y))
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
#else
struct AnnotationEditorScreen: View {
    var image: BugReportImage
    var onSave: () -> Void = {}

    var body: some View {
        Text("Annotation is unavailable on this platform.")
    }
}
#endif
