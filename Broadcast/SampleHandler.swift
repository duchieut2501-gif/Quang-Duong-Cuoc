import ReplayKit
import CoreImage

/// Chạy nền khi bật "phát màn hình": lấy mẫu khung hình, thấy màn hình báo cuốc thì đọc và báo.
class SampleHandler: RPBroadcastSampleHandler {
    private let reader = TripReader()
    private let queue = DispatchQueue(label: "trip.reader")
    private var busy = false
    private var lastCheck = Date.distantPast
    private var lastTrip: TripText?
    private var lastTripAt = Date.distantPast
    private var lastDiagAt = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        DispatchQueue.main.async { LocationTracker.shared.start() }
        TripDistance.notify("Quãng Đường đang chạy", "Giữ màn hình luôn sáng để app không bị tắt.")
    }

    override func broadcastFinished() {
        DispatchQueue.main.async { LocationTracker.shared.stop() }
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, !busy, Date().timeIntervalSince(lastCheck) > 0.4,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastCheck = Date()
        busy = true
        let img = CIImage(cvPixelBuffer: pb)
        queue.async { [self] in
            defer { busy = false }
            let m = reader.findMarkers(img)
            let t = m.flatMap { reader.readText(img, $0) }
            // Đã thấy nút Nhận chuyến mà vẫn hỏng ở bước sau: báo lý do (tối đa 5 giây/lần).
            if t == nil, reader.diag != "no-button", reader.diag != "button",
               Date().timeIntervalSince(lastDiagAt) > 5 {
                lastDiagAt = Date()
                TripDistance.notify("Quãng Đường: chưa đọc được cuốc", reader.diag)
            }
            // Cùng một cuốc thì chỉ xử lý 1 lần.
            guard let t else { return }
            if t == lastTrip, Date().timeIntervalSince(lastTripAt) < 120 { return }
            lastTrip = t
            lastTripAt = Date()
            Task { await TripDistance.run(t) { TripDistance.notify($0, $1) } }
        }
    }
}
