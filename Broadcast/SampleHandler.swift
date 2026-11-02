import ReplayKit
import CoreImage

/// Chạy nền khi bật "phát màn hình": lấy mẫu khung hình, thấy màn hình báo cuốc thì đọc,
/// hiện chữ nổi dưới địa chỉ điểm đến và gửi một thông báo kết quả.
class SampleHandler: RPBroadcastSampleHandler {
    private let reader = TripReader()
    private let queue = DispatchQueue(label: "trip.reader")
    private var busy = false
    private var lastCheck = Date.distantPast
    private var lastDiagAt = Date.distantPast

    // Cuốc đang hiện trên màn hình
    private var current: TripText?
    private var currentMarkers: TripReader.Markers?
    private var lastReadAt = Date.distantPast
    private var tripID = 0
    private var misses = 0
    // Các lần tìm của cuốc hiện tại (mỗi lần 1 dòng)
    private let maxAttempts = 5
    private var attempts = 0
    private var lines: [String] = []
    private var notified = false
    private var y: CGFloat = 0.5

    private func push() {
        OverlayWriter.show(y: y, text: "Đón → Trả (đã tìm \(lines.count)/\(maxAttempts) lần)\n" + lines.joined(separator: "\n"))
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        DispatchQueue.main.async { LocationTracker.shared.start() }
        OverlayWriter.hide()
        TripDistance.notify("Quãng Đường đang chạy", "Giữ màn hình luôn sáng để app không bị tắt.")
    }

    override func broadcastFinished() {
        OverlayWriter.hide()
        DispatchQueue.main.async { LocationTracker.shared.stop() }
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, !busy, Date().timeIntervalSince(lastCheck) > 0.35,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastCheck = Date()
        busy = true
        let img = CIImage(cvPixelBuffer: pb)
        queue.async { [self] in
            defer { busy = false }
            guard let m = reader.findMarkers(img) else {
                // Màn hình báo cuốc biến mất (2 lần liên tiếp) -> ẩn chữ nổi.
                misses += 1
                if misses == 2, current != nil {
                    current = nil; currentMarkers = nil; tripID += 1; attempts = 0; lines = []
                    OverlayWriter.hide()
                }
                return
            }
            misses = 0
            // Đã đủ 5 lần tìm cho cuốc này: không đọc lại nữa (tiết kiệm pin), trừ khi cuốc đổi vị trí.
            let sameSpot = currentMarkers.map { abs($0.dropoffTop - m.dropoffTop) < 0.01 && abs($0.pickupTop - m.pickupTop) < 0.01 } ?? false
            if sameSpot && (attempts >= maxAttempts || Date().timeIntervalSince(lastReadAt) < 1.0) { return }

            guard let t = reader.readText(img, m) else {
                if Date().timeIntervalSince(lastDiagAt) > 5 {
                    lastDiagAt = Date()
                    TripDistance.notify("Quãng Đường: chưa đọc được cuốc", reader.diag)
                }
                return
            }
            lastReadAt = Date()
            // Cuốc mới -> xoá danh sách kết quả cũ.
            if !sameSpot || current.map({ !$0.sameTrip(t) }) ?? true {
                tripID += 1
                attempts = 0
                lines = []
                notified = false
                y = reader.lastDropoffBottom
            }
            currentMarkers = m
            current = t
            guard attempts < maxAttempts else { return }
            // Mỗi lần tìm thêm 1 dòng bên dưới (tối đa 5 dòng).
            let idx = attempts
            attempts += 1
            lines.append("\(idx + 1)) đang tìm…")
            push()
            let id = tripID
            Task {
                await TripDistance.run(t) { [weak self] title, body in
                    guard let self else { return }
                    self.queue.async {
                        guard id == self.tripID, idx < self.lines.count else { return }   // cuốc đã đổi
                        let km = title.replacingOccurrences(of: "Đón → Trả: ", with: "")
                            .replacingOccurrences(of: "Đón → Trả ", with: "")
                        let names = body.replacingOccurrences(of: "\n", with: "  |  ")
                        self.lines[idx] = "\(idx + 1)) \(km)\n    \(names)"
                        self.push()
                        if !self.notified, !title.contains("ước tính") {
                            self.notified = true
                            TripDistance.notify(title, body)
                        }
                    }
                }
            }
        }
    }
}
