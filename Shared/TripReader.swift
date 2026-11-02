import CoreImage
import Vision

/// Địa chỉ đọc được từ màn hình báo cuốc của app tài xế.
struct TripText: Equatable {
    var pickupTitle: String
    var pickupDetail: String
    var dropoffTitle: String
    var dropoffDetail: String
}

/// Nhận diện màn hình báo cuốc (Xanh SM) và đọc 2 địa chỉ.
/// Bố cục: chấm đen = điểm đón, chấm vàng = điểm đến, cùng nằm ở cột x ≈ 6,3% chiều rộng;
/// nút "Nhận chuyến" màu xanh ngọc ở đáy màn hình.
final class TripReader {
    private let ctx = CIContext(options: [.useSoftwareRenderer: false])
    private let smallW = 200

    struct Markers { let pickupTop: CGFloat; let dropoffTop: CGFloat } // tỉ lệ từ mép trên

    /// Kiểm tra nhanh bằng vài điểm ảnh (rẻ, chạy mỗi khung hình được lấy mẫu).
    func findMarkers(_ image: CIImage) -> Markers? {
        let ext = image.extent
        guard ext.width > 0, ext.height > ext.width else { return nil } // chỉ màn hình dọc
        let scale = CGFloat(smallW) / ext.width
        let h = Int(ext.height * scale)
        let small = image.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var buf = [UInt8](repeating: 0, count: smallW * h * 4)
        ctx.render(small, toBitmap: &buf, rowBytes: smallW * 4,
                   bounds: CGRect(x: 0, y: 0, width: smallW, height: h),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // Hàng 0 của bitmap là mép trên màn hình.
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * smallW + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
        // 1) Nút "Nhận chuyến" xanh ngọc ở đáy.
        var teal = false
        for fy in stride(from: 0.93, through: 0.975, by: 0.007) {
            let (r, g, b) = px(smallW / 2, Int(Double(h) * fy))
            if r < 130, g > 120, b > 130, g - r > 45 { teal = true; break }
        }
        guard teal else { return nil }
        // 2) Chấm vàng (điểm đến) và chấm đen (điểm đón) trên cột biểu tượng.
        // Chấm đen = vùng tối gần nhất phía trên chấm vàng (bỏ qua chữ "0.32km" ở trên).
        var yellow: Int?, black: Int?, lastDark = -10
        for y in Int(Double(h) * 0.2)..<Int(Double(h) * 0.85) {
            for x in (Int(Double(smallW) * 0.05))...(Int(Double(smallW) * 0.077)) {
                let (r, g, b) = px(x, y)
                if r > 200, g > 140, b < 120 { yellow = y; break }
                if r + g + b < 150 {
                    if y - lastDark > 3 { black = y }
                    lastDark = y
                    break
                }
            }
            if yellow != nil { break }
        }
        guard let yy = yellow, let by = black, yy > by else { return nil }
        return Markers(pickupTop: CGFloat(by) / CGFloat(h), dropoffTop: CGFloat(yy) / CGFloat(h))
    }

    /// Đọc chữ (OCR) trong vùng 2 địa chỉ.
    func readText(_ image: CIImage, _ m: Markers) -> TripText? {
        let ext = image.extent
        let topF = max(0, m.pickupTop - 0.015)
        let botF = min(1, m.dropoffTop + 0.2)
        // CIImage gốc toạ độ ở góc dưới-trái.
        let crop = CGRect(x: ext.minX + ext.width * 0.09, y: ext.minY + ext.height * (1 - botF),
                          width: ext.width * 0.88, height: ext.height * (botF - topF))
        let img = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        if let langs = try? req.supportedRecognitionLanguages(), langs.contains("vi-VN") {
            req.recognitionLanguages = ["vi-VN"]
        }
        do { try VNImageRequestHandler(ciImage: img, options: [:]).perform([req]) } catch { return nil }

        struct Line { let text: String; let top: CGFloat; let height: CGFloat }
        let span = botF - topF
        let lines: [Line] = (req.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                  !t.isEmpty else { return nil }
            let b = o.boundingBox
            return Line(text: t, top: topF + (1 - b.maxY) * span, height: b.height * span)
        }.sorted { $0.top < $1.top }

        let pick = lines.filter { $0.top < m.dropoffTop - 0.006 }
        var drop: [Line] = []
        for l in lines where l.top >= m.dropoffTop - 0.006 {
            if let last = drop.last, l.top - last.top > 0.045 { break } // hết khối địa chỉ
            drop.append(l)
        }
        func split(_ ls: [Line]) -> (String, String) {
            guard let maxH = ls.map(\.height).max() else { return ("", "") }
            // Dòng tiêu đề in đậm, chữ to hơn dòng địa chỉ chi tiết.
            let title = ls.filter { $0.height >= maxH * 0.88 }.map(\.text).joined(separator: " ")
            let detail = ls.filter { $0.height < maxH * 0.88 }.map(\.text).joined(separator: " ")
            return (title, detail)
        }
        let (pt, pd) = split(pick), (dt, dd) = split(drop)
        guard !pt.isEmpty || !pd.isEmpty, !dt.isEmpty || !dd.isEmpty else { return nil }
        return TripText(pickupTitle: pt, pickupDetail: pd, dropoffTitle: dt, dropoffDetail: dd)
    }

    func read(_ image: CIImage) -> TripText? {
        guard let m = findMarkers(image) else { return nil }
        return readText(image, m)
    }
}
