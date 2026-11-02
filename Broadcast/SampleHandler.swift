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

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        TripDistance.notify("Quãng Đường đang chạy", "Sẽ báo quãng đường đón → trả khi có cuốc.")
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, !busy, Date().timeIntervalSince(lastCheck) > 0.4,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastCheck = Date()
        busy = true
        let img = CIImage(cvPixelBuffer: pb)
        queue.async { [self] in
            defer { busy = false }
            guard let m = reader.findMarkers(img) else { return }
            // Cùng một cuốc thì chỉ xử lý 1 lần.
            guard let t = reader.readText(img, m) else { return }
            if t == lastTrip, Date().timeIntervalSince(lastTripAt) < 120 { return }
            lastTrip = t
            lastTripAt = Date()
            Task { await TripDistance.run(t) { TripDistance.notify($0, $1) } }
        }
    }
}
