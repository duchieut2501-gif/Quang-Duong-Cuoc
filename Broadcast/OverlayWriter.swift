import Foundation


/// Gửi nội dung chữ nổi cho tiến trình HUD theo 2 đường:
/// 1) file JSON ở chỗ chung (nếu iOS cho ghi), có đủ chữ;
/// 2) tín hiệu hệ thống mang 64 bit số liệu (luôn đi được), HUD tự dựng chữ.
enum OverlayWriter {
    private static let name = "com.quangduongcuoc.overlay"
    private static let sharedURL = URL(fileURLWithPath: "/var/mobile/Library/Caches/com.quangduongcuoc.overlay.json")
    private static var token: Int32 = {
        var t: Int32 = 0
        notify_register_check(name, &t)
        return t
    }()
    private static var seq: UInt64 = 0
    /// Chữ "Đón: …\nTrả: …" gửi qua 40 tín hiệu phụ, mỗi tín hiệu 8 byte (ô 0 = độ dài).
    static let textSlots = 40
    private static var textTokens: [Int32] = (0..<textSlots).map { i in
        var t: Int32 = 0
        notify_register_check("\(name).t\(i)", &t)
        return t
    }

    private static func sendText(_ text: String) {
        var bytes = Array(text.utf8.prefix((textSlots - 1) * 8))
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() } // không cắt giữa ký tự
        notify_set_state(textTokens[0], UInt64(bytes.count))
        for slot in 1..<textSlots {
            var v: UInt64 = 0
            for k in 0..<8 {
                let i = (slot - 1) * 8 + k
                if i < bytes.count { v |= UInt64(bytes[i]) << (8 * UInt64(k)) }
            }
            notify_set_state(textTokens[slot], v)
        }
    }

    /// `y`: mép dưới địa chỉ điểm đến (tỉ lệ chiều cao màn hình, 0 = mép trên).
    /// `stage`: 0 đang tính, 1 ước tính, 2 chính xác, 3 lỗi.
    static func show(y: CGFloat, stage: Int, meters: Double, seconds: Double, title: String, sub: String) {
        send(show: true, y: y, stage: stage, meters: meters, seconds: seconds,
             json: ["show": true, "y": Double(y), "title": title, "sub": sub])
    }

    static func hide() { send(show: false, y: 0, stage: 0, meters: 0, seconds: 0, json: ["show": false]) }

    private static func send(show: Bool, y: CGFloat, stage: Int, meters: Double, seconds: Double, json: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: json) {
            try? d.write(to: sharedURL, options: .atomic)
        }
        sendText(show ? (json["sub"] as? String ?? "") : "")
        // Bố cục 64 bit: [63] hiện | [52..62] y‰ | [50..51] giai đoạn | [36..49] phút | [12..35] đơn vị 10 m | [0..11] số thứ tự
        seq = (seq + 1) & 0xFFF
        var v: UInt64 = seq
        v |= (UInt64(min(max(meters / 10, 0), 16_777_215)) & 0xFFFFFF) << 12
        v |= (UInt64(min(max(seconds / 60, 0), 16_383)) & 0x3FFF) << 36
        v |= (UInt64(stage) & 0x3) << 50
        v |= (UInt64(min(max(y * 1000, 0), 2047)) & 0x7FF) << 52
        if show { v |= 1 << 63 }
        notify_set_state(token, v)
        notify_post(name)
    }
}
