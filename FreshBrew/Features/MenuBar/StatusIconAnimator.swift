import AppKit
import QuartzCore
import Symbols

@MainActor
final class StatusIconAnimator {
    private weak var button: NSStatusBarButton?
    private let animatedImageView = PassThroughImageView()
    private var currentActivity: MenuBarModel.Activity?

    init(button: NSStatusBarButton) {
        self.button = button

        button.imageScaling = .scaleProportionallyDown
        animatedImageView.translatesAutoresizingMaskIntoConstraints = false
        animatedImageView.imageScaling = .scaleProportionallyDown
        animatedImageView.contentTintColor = .labelColor
        animatedImageView.wantsLayer = true
        animatedImageView.isHidden = true
        button.addSubview(animatedImageView)

        NSLayoutConstraint.activate([
            animatedImageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            animatedImageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            animatedImageView.widthAnchor.constraint(equalToConstant: 16),
            animatedImageView.heightAnchor.constraint(equalToConstant: 16)
        ])

        setActivity(.idle)
    }

    func setActivity(_ activity: MenuBarModel.Activity) {
        guard activity != currentActivity else { return }
        currentActivity = activity
        stopAnimation()

        switch activity {
        case .checking:
            showAnimatedSymbol("arrow.triangle.2.circlepath", weight: .regular)
            startCheckingAnimation()
        case .updating:
            showAnimatedSymbol("arrow.down", weight: .semibold)
            startUpdatingAnimation()
        case .idle, .cleaning:
            showIdleIcon()
        }
    }

    func stop() {
        stopAnimation()
        animatedImageView.removeFromSuperview()
        currentActivity = nil
    }

    private func showIdleIcon() {
        animatedImageView.isHidden = true
        let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button?.image = image ?? symbol("leaf.fill", weight: .regular)
    }

    private func showAnimatedSymbol(_ name: String, weight: NSFont.Weight) {
        button?.image = nil
        animatedImageView.image = symbol(name, weight: weight)
        animatedImageView.isHidden = false
        button?.layoutSubtreeIfNeeded()
    }

    private func symbol(_ name: String, weight: NSFont.Weight) -> NSImage? {
        let baseImage = NSImage(
            systemSymbolName: name,
            accessibilityDescription: AppIdentity.displayName
        )
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: weight)
        let image = baseImage?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func startCheckingAnimation() {
        if #available(macOS 15.0, *) {
            animatedImageView.addSymbolEffect(
                .rotate.wholeSymbol.clockwise,
                options: .repeat(.continuous).speed(1.5),
                animated: true
            )
            return
        }

        // The system rotate effect is unavailable on macOS 14. Keep the
        // fallback confined to the fixed square image view rather than the
        // status bar button so the status item itself never orbits.
        guard let layer = animatedImageView.layer else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 0.9
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        layer.add(rotation, forKey: "freshbrew.checking.rotation")
    }

    private func startUpdatingAnimation() {
        guard let layer = animatedImageView.layer else { return }

        let movement = CABasicAnimation(keyPath: "transform.translation.y")
        // AppKit view coordinates are bottom-up here. Negative-to-positive Y
        // produces the intended top-to-bottom movement as rendered by Core
        // Animation in the status item.
        movement.fromValue = -4
        movement.toValue = 4
        movement.duration = 0.9

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0]
        opacity.keyTimes = [0, 0.15, 0.8, 1]
        opacity.duration = 0.9

        let group = CAAnimationGroup()
        group.animations = [movement, opacity]
        group.duration = 0.9
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "freshbrew.updating.download")
    }

    private func stopAnimation() {
        animatedImageView.removeAllSymbolEffects(animated: false)
        animatedImageView.layer?.removeAllAnimations()
        animatedImageView.layer?.opacity = 1
        animatedImageView.layer?.setAffineTransform(.identity)
    }
}

private final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
