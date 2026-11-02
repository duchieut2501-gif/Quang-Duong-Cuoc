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
                    current = nil; currentMarkers = nil; tripID += 1
                    OverlayWriter.hide()
                }
                return
            }
            misses = 0
            // Cùng cuốc vẫn đang hiện: không đọc chữ lại (tiết kiệm pin), trừ khi đã quá 3 giây.
            if let c = currentMarkers, abs(c.dropoffTop - m.dropoffTop) < 0.01,
               abs(c.pickupTop - m.pickupTop) < 0.01, Date().timeIntervalSince(lastReadAt) < 3 { return }

            guard let t = reader.readText(img, m) else {
                if Date().timeIntervalSince(lastDiagAt) > 5 {
                    lastDiagAt = Date()
                    TripDistance.notify("Quãng Đường: chưa đọc được cuốc", reader.diag)
                }
                return
            }
            lastReadAt = Date()
            currentMarkers = m
            if t == current { return }
            current = t
            tripID += 1
            let id = tripID
            let y = reader.lastDropoffBottom
            OverlayWriter.show(y: y, stage: 0, meters: 0, seconds: 0, title: "Đang tính quãng đường…", sub: "")
            Task {
                await TripDistance.run(t) { [weak self] title, body in
                    guard let self else { return }
                    self.queue.async {
                        guard id == self.tripID else { return }   // cuốc đã đổi
                        let i = TripDistance.lastInfo
                        OverlayWriter.show(y: y, stage: i.stage, meters: i.meters, seconds: i.seconds,
                                           title: title, sub: body)
                        if !title.contains("ước tính") { TripDistance.notify(title, body) }
                    }
                }
            }
        }
    }
}
