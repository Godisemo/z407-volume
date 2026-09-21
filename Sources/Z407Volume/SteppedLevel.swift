import Foundation

/// A speaker setting the Z407 can only step, never report. The level is counted from the steps
/// actually written, persisted across launches, and shown on a menu slider.
@MainActor
final class SteppedLevel {
    let name: String
    let view: LevelSliderView
    private let up: Z407.Command
    private let down: Z407.Command
    private let levelKey: String
    private let stepsKey: String
    private let defaultSteps: Int
    private let defaults = UserDefaults.standard

    init(name: String, up: Z407.Command, down: Z407.Command, levelKey: String, stepsKey: String,
         defaultSteps: Int, symbols: (low: String, high: String)) {
        self.name = name
        self.up = up
        self.down = down
        self.levelKey = levelKey
        self.stepsKey = stepsKey
        self.defaultSteps = defaultSteps
        view = LevelSliderView(title: name, lowSymbol: symbols.low, highSymbol: symbols.high)
    }

    /// Steps from minimum to maximum; override with `defaults write io.github.godisemo.z407-volume <stepsKey> -int N`.
    var steps: Int { max(1, defaults.object(forKey: stepsKey) as? Int ?? defaultSteps) }

    var level: Int {
        get { min(steps, defaults.object(forKey: levelKey) as? Int ?? steps / 2) }
        set { defaults.set(newValue, forKey: levelKey) }
    }

    func refreshView() {
        view.show(level: level, steps: steps)
    }

    /// Updates the estimate if `command` is one of this level's steps.
    func track(_ command: Z407.Command) {
        switch command {
        case up: level = min(steps, level + 1)
        case down: level = max(0, level - 1)
        default: return
        }
        refreshView()
    }

    /// Where the estimate lands once the `pending` commands are written.
    func projected(after pending: [Z407.Command]) -> Int {
        pending.reduce(level) { level, command in
            switch command {
            case up: min(steps, level + 1)
            case down: max(0, level - 1)
            default: level
            }
        }
    }

    /// Steps that take the speaker from the projected estimate to `target`.
    func commands(toReach target: Int, pending: [Z407.Command]) -> [Z407.Command] {
        let delta = target - projected(after: pending)
        Diagnostics.record("\(name) slider: \(level) → \(target) (\(delta > 0 ? "+" : "")\(delta) steps)")
        return Array(repeating: delta > 0 ? up : down, count: abs(delta))
    }

    /// The floor is the only level that can be known: step past it, then back up to the estimate.
    func resyncCommands() -> [Z407.Command] {
        Diagnostics.record("Re-syncing \(name.lowercased()): down to zero, back up to \(level)")
        return Array(repeating: down, count: steps + 5) + Array(repeating: up, count: level)
    }
}
