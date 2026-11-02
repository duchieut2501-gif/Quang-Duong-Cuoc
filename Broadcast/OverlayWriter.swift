import Foundation

/// Ghi nội dung chữ nổi ra file trong thư mục của extension rồi báo cho tiến trình HUD đọc.
enum OverlayWriter {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("overlay.json")
    }()

    /// `y`: mép dưới địa chỉ điểm đến, tính theo tỉ lệ chiều cao màn hình (0 = mép trên).
    static func show(y: CGFloat, title: String, sub: String) {
        write(["show": true, "y": Double(y), "title": title, "sub": sub])
    }

    private static var warned = false

    static func hide() { write(["show": false]) }

    private static func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        do { try d.write(to: url, options: .atomic) } catch {
            if !warned { warned = true; TripDistance.notify("Chữ nổi: không ghi được dữ liệu", error.localizedDescription) }
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.quangduongcuoc.overlay" as CFString), nil, nil, true)
    }
}
