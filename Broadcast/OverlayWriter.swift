import Foundation

/// Gửi nội dung chữ nổi cho tiến trình HUD qua tín hiệu hệ thống (notify):
/// - tín hiệu chính: [63] hiện | [52..62] vị trí y (‰ chiều cao) | [0..11] số thứ tự
/// - 160 tín hiệu phụ, mỗi cái 8 byte: chữ UTF-8 (dòng đầu = tiêu đề), ô 0 = độ dài.
enum OverlayWriter {
    private static let name = "com.quangduongcuoc.overlay"
    static let textSlots = 160
    private static var token: Int32 = {
        var t: Int32 = 0
        notify_register_check(name, &t)
        return t
    }()
    private static var textTokens: [Int32] = (0..<textSlots).map { i in
        var t: Int32 = 0
        notify_register_check("\(name).t\(i)", &t)
        return t
    }
    private static var seq: UInt64 = 0

    /// `y`: mép dưới địa chỉ điểm đến (tỉ lệ chiều cao màn hình, 0 = mép trên).
    static func show(y: CGFloat, text: String) { send(show: true, y: y, text: text) }
    static func hide() { send(show: false, y: 0, text: "") }

    private static func send(show: Bool, y: CGFloat, text: String) {
        var bytes = Array(text.utf8.prefix((textSlots - 1) * 8))
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() } // không cắt giữa ký tự
        notify_set_state(textTokens[0], UInt64(bytes.count))
        let used = (bytes.count + 7) / 8
        for slot in 1...max(used, 1) where slot < textSlots {
            var v: UInt64 = 0
            for k in 0..<8 {
                let i = (slot - 1) * 8 + k
                if i < bytes.count { v |= UInt64(bytes[i]) << (8 * UInt64(k)) }
            }
            notify_set_state(textTokens[slot], v)
        }
        seq = (seq + 1) & 0xFFF
        var v: UInt64 = seq
        v |= (UInt64(min(max(y * 1000, 0), 2047)) & 0x7FF) << 52
        if show { v |= 1 << 63 }
        notify_set_state(token, v)
        notify_post(name)
    }
}
