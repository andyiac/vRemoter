import CoreGraphics
import Foundation

enum InputTriggerKey: String, CaseIterable, Identifiable {
    case option
    case command
    case control
    case shift
    case function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: "Option (⌥)"
        case .command: "Command (⌘)"
        case .control: "Control (⌃)"
        case .shift: "Shift (⇧)"
        case .function: "Fn / Globe"
        }
    }

    var keyCodes: Set<Int64> {
        switch self {
        case .option: [0x3A, 0x3D]
        case .command: [0x37, 0x36]
        case .control: [0x3B, 0x3E]
        case .shift: [0x38, 0x3C]
        case .function: [0x3F]
        }
    }

    var primaryKeyCode: CGKeyCode {
        CGKeyCode(keyCodes.min() ?? 0x3A)
    }

    var flag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .command: .maskCommand
        case .control: .maskControl
        case .shift: .maskShift
        case .function: .maskSecondaryFn
        }
    }
}

enum Key {
    /// Lets the event tap distinguish vRemoter-generated events from physical
    /// keyboards, Bluetooth buttons, and external remappers.
    static let syntheticMarker: Int64 = 0x4D_49_52_42 // "MIRB"

    static func triggerDown(
        _ trigger: InputTriggerKey = AppStorage.effectiveInputTriggerKey
    ) {
        post(trigger: trigger, keyDown: true)
    }

    static func triggerUp(
        _ trigger: InputTriggerKey = AppStorage.effectiveInputTriggerKey
    ) {
        post(trigger: trigger, keyDown: false)
    }

    /// One deliberate voice toggle for the selected input method.
    ///
    /// Doubao uses a short modifier click for its toggle mode. WeChat 2.0+
    /// uses a hands-free shortcut (modifier + Space by default), so the same
    /// remote gesture is translated into that chord instead.
    static func triggerTap(
        _ trigger: InputTriggerKey = AppStorage.effectiveInputTriggerKey,
        completion: (() -> Void)? = nil
    ) {
        switch AppStorage.inputMethodTarget.voiceTriggerStyle {
        case .singleModifierTap:
            triggerDown(trigger)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                triggerUp(trigger)
                completion?()
            }

        case .handsFreeChord:
            postHandsFreeChord(modifier: trigger, completion: completion)
        }
    }

    /// WeChat Input Method's hands-free mode is opened and closed by the same
    /// shortcut. The default is Fn + Space; the user must keep WeChat's
    /// hands-free shortcut in sync with the modifier selected in vRemoter.
    private static func postHandsFreeChord(
        modifier: InputTriggerKey,
        completion: (() -> Void)?
    ) {
        post(
            keyCode: modifier.primaryKeyCode,
            flags: modifier.flag,
            keyDown: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            post(keyCode: 0x31, flags: modifier.flag, keyDown: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                post(keyCode: 0x31, flags: modifier.flag, keyDown: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    post(
                        keyCode: modifier.primaryKeyCode,
                        flags: [],
                        keyDown: false
                    )
                    print(
                        "[KEY] synthetic \(modifier.title) + Space " +
                        "hands-free toggle"
                    )
                    completion?()
                }
            }
        }
    }

    private static func post(
        trigger: InputTriggerKey,
        keyDown: Bool
    ) {
        post(
            keyCode: trigger.primaryKeyCode,
            flags: keyDown ? trigger.flag : [],
            keyDown: keyDown
        )
    }

    private static func post(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        keyDown: Bool
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
        print(
            "[KEY] synthetic keyCode=0x" +
            String(keyCode, radix: 16) +
            " " +
            (keyDown ? "DOWN" : "UP") +
            " flags=0x" + String(flags.rawValue, radix: 16)
        )
    }
}
