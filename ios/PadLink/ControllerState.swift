import Foundation

/// Button bitmask. Values match the XInput / XUSB layout so the PC side can
/// pass them straight through to the virtual Xbox 360 controller.
struct Buttons: OptionSet, Hashable {
    let rawValue: UInt16

    static let dpadUp        = Buttons(rawValue: 0x0001)
    static let dpadDown      = Buttons(rawValue: 0x0002)
    static let dpadLeft      = Buttons(rawValue: 0x0004)
    static let dpadRight     = Buttons(rawValue: 0x0008)
    static let start         = Buttons(rawValue: 0x0010)
    static let back          = Buttons(rawValue: 0x0020)
    static let leftThumb     = Buttons(rawValue: 0x0040)
    static let rightThumb    = Buttons(rawValue: 0x0080)
    static let leftShoulder  = Buttons(rawValue: 0x0100)
    static let rightShoulder = Buttons(rawValue: 0x0200)
    static let guide         = Buttons(rawValue: 0x0400)
    static let a             = Buttons(rawValue: 0x1000)
    static let b             = Buttons(rawValue: 0x2000)
    static let x             = Buttons(rawValue: 0x4000)
    static let y             = Buttons(rawValue: 0x8000)
}

/// Full controller snapshot. Sticks are -1...1 (Y up = +1), triggers 0...1.
struct ControllerState: Equatable {
    var buttons: Buttons = []
    var lx: Float = 0
    var ly: Float = 0
    var rx: Float = 0
    var ry: Float = 0
    var lt: Float = 0
    var rt: Float = 0
}

/// Wire format (JSON over UDP). The server is keyed on "t".
struct StatePacket: Encodable {
    var t = "s"
    let sid: UInt32
    let q: UInt32
    let b: UInt16
    let lx: Float
    let ly: Float
    let rx: Float
    let ry: Float
    let lt: Float
    let rt: Float

    init(session: UInt32, seq: UInt32, state s: ControllerState) {
        sid = session
        q = seq
        b = s.buttons.rawValue
        lx = s.lx; ly = s.ly
        rx = s.rx; ry = s.ry
        lt = s.lt; rt = s.rt
    }
}
