import AppKit

/// Menu item view: an estimated speaker level with a slider to change it.
final class LevelSliderView: NSView {
    var onSet: ((Int) -> Void)?
    /// −1 or +1, from clicking the low or high icon.
    var onStep: ((Int) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)

    private let title: String

    init(title: String, lowSymbol: String, highSymbol: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        slider.isContinuous = false
        slider.target = self
        slider.action = #selector(sliderMoved)

        let low = stepButton(lowSymbol, "\(title) down", #selector(stepDown))
        let high = stepButton(highSymbol, "\(title) up", #selector(stepUp))
        let row = NSStackView(views: [low, slider, high])
        row.spacing = 6
        let column = NSStackView(views: [label, row])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(level: Int, steps: Int) {
        label.stringValue = "\(title) (estimated): \(level) / \(steps)"
        slider.maxValue = Double(steps)
        slider.integerValue = level
    }

    private func stepButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                              target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        return button
    }

    @objc private func stepDown() { onStep?(-1) }
    @objc private func stepUp() { onStep?(1) }

    @objc private func sliderMoved() {
        onSet?(Int(slider.doubleValue.rounded()))
    }
}
