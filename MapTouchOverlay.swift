import UIKit

final class MapTouchOverlay: UIView {
    enum Mode { case none, draw, erase }
    var mode: Mode = .none {
        didSet { isUserInteractionEnabled = (mode != .none) }
    }

    // Callbacks fire on every move; we pass screen-space points
    var onDrawPoint: ((CGPoint) -> Void)?
    var onErasePoint: ((CGPoint) -> Void)?
    var onStrokeEnded: (() -> Void)?

    private var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false // only on in draw/erase
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        isDragging = true
        let p = t.location(in: self)
        routePoint(p)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDragging, let t = touches.first else { return }
        let p = t.location(in: self)
        routePoint(p)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDragging = false
        onStrokeEnded?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDragging = false
        onStrokeEnded?()
    }

    private func routePoint(_ p: CGPoint) {
        switch mode {
        case .draw:  onDrawPoint?(p)
        case .erase: onErasePoint?(p)
        case .none:  break
        }
    }
}
