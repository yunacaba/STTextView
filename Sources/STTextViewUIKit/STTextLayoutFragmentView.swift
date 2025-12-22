//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

import UIKit
import CoreGraphics
import STTextKitPlus
import STTextViewCommon
#if USE_LAYERS_FOR_GLYPHS
import CoreTextSwift
#endif

final class STTextLayoutFragmentView: UIView {
    private let layoutFragment: NSTextLayoutFragment
    private var layoutStateObservation: NSKeyValueObservation?

    init(layoutFragment: NSTextLayoutFragment, frame: CGRect) {
        self.layoutFragment = layoutFragment
        super.init(frame: frame)
        isOpaque = false

        layoutStateObservation = layoutFragment.observe(\.state, options: [.new, .initial]) { [weak self] layoutFragment, change in
            if layoutFragment.state == .layoutAvailable {
                self?.layoutAttachmentView()
                self?.layoutStateObservation = nil
            }
        }
#if USE_LAYERS_FOR_GLYPHS
        layoutGlyphLayers()
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateLayerContentScale()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLayerContentScale()
    }

    private func updateLayerContentScale() {
        let newScale = window?.screen.scale ?? UIScreen.main.scale
        layer.contentsScale = newScale
        layer.sublayers?.forEach { $0.contentsScale = newScale }
    }

#if !USE_LAYERS_FOR_GLYPHS
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        context.saveGState()
        super.draw(rect)
        // Draw backgrounds first (behind text)
        drawAnnotationBackgrounds(rect, in: context)
        layoutFragment.draw(at: .zero, in: context)
        // TODO: drawSpellCheckerAttributes(dirtyRect, in: context)
        // Draw underlines after text
        drawAnnotationUnderlines(rect, in: context)
        context.restoreGState()
    }
#endif

#if USE_LAYERS_FOR_GLYPHS
    private func layoutGlyphLayers() {
        // layout each character on separate layer, so it can be animable
        for textLineFragment in layoutFragment.textLineFragments {
            let lineAttributedString = textLineFragment.attributedString.attributedSubstring(from: textLineFragment.characterRange)

            for run in lineAttributedString.line().glyphRuns() {
                let glyphs = run.glyphs()
                let glyphPositions = run.glyphPositions()
                let boundingRects = run.font.boundingRects(of: glyphs)
                for idx in 0..<run.glyphsCount {
                    let glyph = glyphs[idx]
                    let glyphPosition = glyphPositions[idx]
                    let boundingRect = boundingRects[idx]
                    let glyphLayer = GlyphLayer(font: run.font, color: run.attributes[.foregroundColor] as? UIColor ?? UIColor.label, glyph: glyph)

                    glyphLayer.frame = CGRect(
                        x: textLineFragment.typographicBounds.origin.x + glyphPosition.x,
                        y: textLineFragment.typographicBounds.origin.y + glyphPosition.y,
                        width: boundingRect.maxX,
                        height: textLineFragment.typographicBounds.height
                    )

                    glyphLayer.bounds.origin.y -= textLineFragment.typographicBounds.height - textLineFragment.glyphOrigin.y

                    layer.addSublayer(glyphLayer)
                    glyphLayer.setNeedsDisplay()

                    // Exmaple animation
                    //do {
                    //     let animation1 = CABasicAnimation(keyPath: "transform.translation.x")
                    //     animation1.fromValue = Double.random(in: -2...0)
                    //     animation1.toValue = Double.random(in: 0...2)
                    //     animation1.timingFunction = .init(name: .easeInEaseOut)
                    //
                    //     let animation2 = CABasicAnimation(keyPath: "transform.translation.y")
                    //     animation2.fromValue = Double.random(in: -2...0)
                    //     animation2.toValue = Double.random(in: 0...1)
                    //     animation2.timingFunction = .init(name: .linear)
                    //
                    //     let animation3 = CABasicAnimation(keyPath: "transform.rotation.y")
                    //     animation3.fromValue = Double.random(in: -(30 * .pi / 180)...0)
                    //     animation3.toValue = Double.random(in: 0...(30 * .pi / 180))
                    //     animation3.timingFunction = .init(name: .linear)
                    //
                    //     let animation4 = CABasicAnimation(keyPath: "transform.rotation.z")
                    //     animation4.fromValue = Double.random(in: -(15 * .pi / 180)...0)
                    //     animation4.toValue = Double.random(in: 0...(15 * .pi / 180))
                    //     animation4.timingFunction = .init(name: .linear)
                    //
                    //     let groupAnimation = CAAnimationGroup()
                    //     groupAnimation.duration = Double.random(in: 1..<2)
                    //     groupAnimation.animations = [animation1, animation2, animation3, animation4]
                    //     groupAnimation.isRemovedOnCompletion = false
                    //     groupAnimation.autoreverses = true
                    //     groupAnimation.repeatCount = .greatestFiniteMagnitude
                    //     glyphLayer.add(groupAnimation, forKey: "itsmine")
                    // }
                }
            }
        }
    }
#endif

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutAttachmentView()
    }

    private func layoutAttachmentView() {
        for attachmentViewProvider in layoutFragment.textAttachmentViewProviders {
            guard let attachmentView = attachmentViewProvider.view else {
                continue
            }

            let layoutFragment = layoutFragment.frameForTextAttachment(at: attachmentViewProvider.location)
            let viewOrig = layoutFragment.origin
            attachmentView.frame.origin = viewOrig
            if attachmentView.superview == nil {
                addSubview(attachmentView)
            }
        }
    }

    private func findParentTextView() -> STTextView? {
        var currentView: UIView? = self
        while let parentView = currentView?.superview {
            if let textView = parentView as? STTextView {
                return textView
            }
            currentView = parentView
        }
        return nil
    }

    // MARK: - Annotation Drawing

    /// Shared logic for getting decorations that intersect this fragment.
    /// The block receives (decoration, frame, decorationIndex) where index is for alternating styles.
    private func enumerateAnnotationSegments(
        matching filter: (STAnnotationStyle) -> Bool,
        in dirtyRect: CGRect,
        using block: (STAnnotationDecoration, CGRect, Int) -> Void
    ) {
        guard let textLayoutManager = layoutFragment.textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager,
              let textView = findParentTextView(),
              !textView.annotationDecorations.isEmpty else {
            return
        }

        // Get the fragment's range in the document
        let fragmentRange = layoutFragment.rangeInElement

        // Convert fragment range to NSRange for comparison
        let documentRange = textContentManager.documentRange
        let fragmentStart = textContentManager.offset(from: documentRange.location, to: fragmentRange.location)
        let fragmentEnd = textContentManager.offset(from: documentRange.location, to: fragmentRange.endLocation)
        let fragmentNSRange = NSRange(location: fragmentStart, length: fragmentEnd - fragmentStart)

        // Decorations are sorted by range.location, so we can exit early
        var decorationIndex = 0
        for decoration in textView.annotationDecorations {
            // Early exit: if decoration starts after fragment ends, no more can intersect
            if decoration.range.location >= fragmentNSRange.location + fragmentNSRange.length {
                break
            }

            // Filter by style type
            guard filter(decoration.style) else { continue }

            // Check if this decoration intersects with the fragment's range
            let intersectionRange = NSIntersectionRange(fragmentNSRange, decoration.range)
            guard intersectionRange.length > 0 else {
                decorationIndex += 1
                continue
            }

            // Convert NSRange back to NSTextRange for the intersection
            guard let startLocation = textContentManager.location(documentRange.location, offsetBy: intersectionRange.location),
                  let endLocation = textContentManager.location(startLocation, offsetBy: intersectionRange.length),
                  let textRange = NSTextRange(location: startLocation, end: endLocation) else {
                decorationIndex += 1
                continue
            }

            let currentIndex = decorationIndex

            // Get the frame for this text segment
            textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segmentFrame, _, _ in
                // Convert to fragment-local coordinates
                let localFrame = CGRect(
                    x: segmentFrame.origin.x,
                    y: segmentFrame.origin.y - layoutFragment.layoutFragmentFrame.origin.y,
                    width: segmentFrame.width,
                    height: segmentFrame.height
                )

                // Only process if visible
                guard localFrame.intersects(dirtyRect) else {
                    return true
                }

                block(decoration, localFrame, currentIndex)
                return true
            }

            decorationIndex += 1
        }
    }

    private func drawAnnotationBackgrounds(_ dirtyRect: CGRect, in context: CGContext) {
        context.saveGState()

        enumerateAnnotationSegments(matching: { $0 == .background }, in: dirtyRect) { decoration, localFrame, _ in
            context.setFillColor(decoration.color.cgColor)
            let bgRect = localFrame.insetBy(dx: 0, dy: -1)
            let path = UIBezierPath(roundedRect: bgRect, cornerRadius: decoration.thickness)
            path.fill()
        }

        context.restoreGState()
    }

    private func drawAnnotationUnderlines(_ dirtyRect: CGRect, in context: CGContext) {
        context.saveGState()

        let underlineOffset: CGFloat = 2
        let thickness: CGFloat = 1.5
        let markerSize: CGFloat = 5

        enumerateAnnotationSegments(matching: { $0 != .background }, in: dirtyRect) { decoration, localFrame, _ in
            let underlineY = localFrame.maxY + underlineOffset

            // Draw solid underline
            context.setStrokeColor(decoration.color.cgColor)
            context.setLineWidth(thickness)
            context.move(to: CGPoint(x: localFrame.minX, y: underlineY))
            context.addLine(to: CGPoint(x: localFrame.maxX, y: underlineY))
            context.strokePath()

            // Draw marker at the start based on marker type
            context.setFillColor(decoration.color.cgColor)
            let markerX = localFrame.minX
            let markerY = underlineY

            switch decoration.marker {
            case .circle:
                let rect = CGRect(
                    x: markerX - markerSize / 2,
                    y: markerY - markerSize / 2,
                    width: markerSize,
                    height: markerSize
                )
                context.fillEllipse(in: rect)

            case .square:
                let rect = CGRect(
                    x: markerX - markerSize / 2,
                    y: markerY - markerSize / 2,
                    width: markerSize,
                    height: markerSize
                )
                context.fill(rect)

            case .triangle:
                let halfSize = markerSize / 2
                context.move(to: CGPoint(x: markerX - halfSize, y: markerY - halfSize))
                context.addLine(to: CGPoint(x: markerX + halfSize, y: markerY))
                context.addLine(to: CGPoint(x: markerX - halfSize, y: markerY + halfSize))
                context.closePath()
                context.fillPath()

            case .diamond:
                let halfSize = markerSize / 2
                context.move(to: CGPoint(x: markerX, y: markerY - halfSize))
                context.addLine(to: CGPoint(x: markerX + halfSize, y: markerY))
                context.addLine(to: CGPoint(x: markerX, y: markerY + halfSize))
                context.addLine(to: CGPoint(x: markerX - halfSize, y: markerY))
                context.closePath()
                context.fillPath()
            }
        }

        context.restoreGState()
    }
}

#if USE_LAYERS_FOR_GLYPHS
private class GlyphLayer: CALayer {
    let color: UIColor
    let font: CTFont
    let glyph: CGGlyph

    init(font: CTFont, color: UIColor, glyph: CGGlyph) {
        self.font = font
        self.glyph = glyph
        self.color = color
        super.init()

        isGeometryFlipped = true
    }

    override func draw(in ctx: CGContext) {
        super.draw(in: ctx)

        ctx.setFillColor(color.cgColor)
        font.draw(glyphs: [glyph], at: [.zero], in: ctx)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
