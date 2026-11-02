import CoreLocation
import MapKit
import UserNotifications

/// Tìm vị trí 2 địa chỉ bằng Apple Maps, tính quãng đường và gửi thông báo nổi.
enum TripDistance {
    struct Place { let item: MKMapItem }

    // MARK: So khớp chữ

    private static let generic: Set<String> = [
        "duong", "ngo", "ngach", "hem", "kiet", "pho", "phuong", "p", "xa", "x", "thon", "xom",
        "thanh", "tinh", "quan", "q", "huyen", "tp", "viet", "so", "to", "khu", "ap"]

    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi"))
    }

    static func words(_ s: String) -> [String] {
        fold(s).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !generic.contains($0) }
    }

    static func tokens(_ s: String) -> Set<String> { Set(words(s)) }

    /// Cặp từ đứng liền nhau, ví dụ "van dinh", "nam du".
    static func bigrams(_ s: String) -> Set<String> {
        let w = words(s)
        var out = Set<String>()
        if w.count >= 2 {
            for i in 0..<(w.count - 1) { out.insert(w[i] + " " + w[i + 1]) }
        }
        return out
    }

    /// Điểm khớp: mỗi từ trùng 1 điểm, mỗi cụm 2 từ liền nhau trùng 2 điểm
    /// (để "Vân Đình" không bị nhầm với "Văn Minh").
    static func textScore(_ want: Set<String>, _ wantPairs: Set<String>, _ item: MKMapItem) -> Double {
        let pm = item.placemark
        let fields = [item.name, pm.subThoroughfare.map { "\($0) \(pm.thoroughfare ?? "")" } ?? pm.thoroughfare,
                      pm.subLocality, pm.locality, pm.subAdministrativeArea].compactMap { $0 }
        let have = fields.reduce(into: Set<String>()) { $0.formUnion(tokens($1)) }
        let havePairs = fields.reduce(into: Set<String>()) { $0.formUnion(bigrams($1)) }
        return Double(want.intersection(have).count) + 2 * Double(wantPairs.intersection(havePairs).count)
    }

    /// "16 Ngách 4 Ngõ 67 Đường Nam Dư" -> "16 Ngách 67/4 Nam Dư" (cách Apple Maps ghi ở Hà Nội)
    static func hanoiStyle(_ t: String) -> String? {
        let pat = #"^(\d+)\s+Ngách\s+(\d+)\s+Ngõ\s+(\d+)\s+(?:Đường\s+|Phố\s+)?(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func g(_ i: Int) -> String { String(t[Range(m.range(at: i), in: t)!]) }
        return "\(g(1)) Ngách \(g(3))/\(g(2)) \(g(4))"
    }

    /// Tên địa điểm trong dòng in đậm: tách theo " - " và ngoặc, bỏ phần là địa chỉ số nhà.
    /// "Cổng 2 (Chùa Láng) - Bệnh viện Nhi Trung ương" -> ["Chùa Láng", "Bệnh viện Nhi Trung ương"]
    static func placeNames(_ title: String) -> [String] {
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "-–()"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.filter { p in
            guard p.count >= 4, let f = p.first, !f.isNumber else { return false }
            let w = words(p)
            if w.isEmpty { return false }
            // Bỏ phần chỉ là "Cổng 2", "Ngõ 5"...
            return !(w.count <= 2 && w.contains { $0.allSatisfy(\.isNumber) })
        }
    }

    /// "Phường Vĩnh Hưng, Thành Phố Hà Nội, Việt Nam" -> "Hà Nội"
    static func city(_ detail: String) -> String? {
        let parts = detail.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && fold($0) != "viet nam" }
        guard var c = parts.last else { return nil }
        for p in ["Thành phố ", "Thành Phố ", "Tỉnh ", "TP. ", "TP "] where c.hasPrefix(p) {
            c = String(c.dropFirst(p.count))
        }
        return c
    }

    // MARK: Tìm kiếm

    static func search(_ q: String, near c: CLLocationCoordinate2D, spanDeg: Double) async -> [MKMapItem] {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = q
        r.region = MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: spanDeg, longitudeDelta: spanDeg))
        return Array(((try? await MKLocalSearch(request: r).start().mapItems) ?? []).prefix(8))
    }

    static func geocode(_ q: String) async -> [MKMapItem] {
        let ps = (try? await CLGeocoder().geocodeAddressString(q, in: nil,
                        preferredLocale: Locale(identifier: "vi_VN"))) ?? []
        return ps.map { MKMapItem(placemark: MKPlacemark(placemark: $0)) }
    }

    /// Chạy song song nhiều câu tìm, chấm điểm: khớp chữ, trừ điểm nếu xa `near` (khi `nearWeight` > 0).
    static func locate(title: String, detail: String, near: CLLocationCoordinate2D,
                       spanDeg: Double, nearWeight: Double, targetKm: Double? = nil) async -> Place? {
        var qs: [String] = []
        let c = city(detail)
        if let h = hanoiStyle(title) { qs.append(c.map { "\(h), \($0)" } ?? h) }
        if !title.isEmpty, let c { qs.append("\(title), \(c)") }
        if !title.isEmpty && !detail.isEmpty { qs.append("\(title), \(detail)") }
        if !title.isEmpty { qs.append(title) }
        if !detail.isEmpty { qs.append(detail) }
        // Tìm thêm theo tên địa điểm (chùa, bệnh viện, trường…): Apple Maps tìm tên tốt hơn số nhà.
        let names = placeNames(title)
        for n in names { qs.append(c.map { "\(n), \($0)" } ?? n) }
        let geoQ = qs.first ?? detail

        let items: [MKMapItem] = await withTaskGroup(of: [MKMapItem].self) { g in
            for q in qs { g.addTask { await search(q, near: near, spanDeg: spanDeg) } }
            g.addTask { await geocode(geoQ) }
            var all: [MKMapItem] = []
            for await r in g { all += r }
            return all
        }
        guard !items.isEmpty else { return nil }
        let want = tokens(title).union(tokens(detail))
        let wantPairs = bigrams(title).union(bigrams(detail))
        let here = CLLocation(latitude: near.latitude, longitude: near.longitude)
        // Chỉ coi là địa chỉ số nhà khi dòng in đậm bắt đầu bằng số (vd. "16 Ngách 4…").
        let wantsStreet = title.first?.isNumber ?? false
        let nameToks = names.map { tokens($0) }.filter { !$0.isEmpty }
        // Nếu không kết quả nào ở gần đúng khoảng cách màn hình báo (vd. đang thử bằng ảnh chụp ở nơi khác)
        // thì bỏ qua tiêu chí khoảng cách.
        let nearest = items.compactMap { $0.placemark.location?.distance(from: here) }.min().map { $0 / 1000 } ?? 1e6
        let targetKm = targetKm.flatMap { nearest <= $0 * 0.8 + 3 ? $0 : nil }
        func score(_ i: MKMapItem) -> Double {
            let km = (i.placemark.location?.distance(from: here) ?? 1e6) / 1000
            var sc = textScore(want, wantPairs, i)
            // Kết quả có tên chứa trọn tên địa điểm (vd. "Chùa Quang Ấm") -> cộng điểm lớn.
            let itemToks = tokens(i.name ?? "")
            if nameToks.contains(where: { $0.isSubset(of: itemToks) }) { sc += 5 }
            // Địa chỉ có số nhà mà kết quả chỉ là cả phường/xã -> trừ điểm.
            if wantsStreet && i.placemark.thoroughfare == nil && i.placemark.subThoroughfare == nil { sc -= 3 }
            if let target = targetKm {
                // Biết khoảng cách xe → điểm đón (theo đường đi): đường chim bay thường ngắn hơn ~20%.
                sc -= 2 * min(abs(km - target * 0.8), 30)
            } else {
                sc -= nearWeight * min(km, 30)
            }
            return sc
        }
        let best = items.max { a, b in score(a) < score(b) }!
        return Place(item: best)
    }

    // MARK: Hiển thị

    static func fmtKm(_ m: CLLocationDistance) -> String {
        // Ví dụ 15,23 km (dấu phẩy kiểu Việt Nam)
        String(format: "%.2f km", m / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func fmtTime(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) giờ \(m % 60) phút" : "\(m) phút"
    }

    static func name(_ p: Place) -> String {
        let pm = p.item.placemark
        return [p.item.name, pm.subLocality, pm.locality ?? pm.administrativeArea]
            .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ", ")
    }

    /// Vị trí hiện tại của máy (nếu đã cho phép), mặc định trung tâm Hà Nội.
    static func currentCoordinate() -> (CLLocationCoordinate2D, Bool) {
        if let l = LocationTracker.shared.last ?? CLLocationManager().location,
           Date().timeIntervalSince(l.timestamp) < 1800 {
            return (l.coordinate, true)
        }
        return (CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542), false)
    }

    /// Số liệu của lần cập nhật gần nhất: giai đoạn (1 ước tính, 2 chính xác, 3 lỗi), mét, giây.
    static var lastInfo: (stage: Int, meters: Double, seconds: Double) = (0, 0, 0)

    /// Chạy toàn bộ: gửi số ước tính trước, rồi cập nhật số theo đường đi thật.
    static func run(_ t: TripText, update: @escaping (String, String) -> Void) async {
        let (me, known) = currentCoordinate()
        // Điểm đón: ở gần xe -> trừ điểm mạnh nếu xa vị trí hiện tại.
        // Tìm điểm đón và điểm trả song song cho nhanh.
        async let pickup = locate(title: t.pickupTitle, detail: t.pickupDetail, near: me,
                                  spanDeg: 0.15, nearWeight: known ? 0.5 : 0.05,
                                  targetKm: known ? t.driverKm : nil)
        async let dropoff = locate(title: t.dropoffTitle, detail: t.dropoffDetail,
                                   near: me, spanDeg: 2, nearWeight: 0)
        let (pOpt, dOpt) = await (pickup, dropoff)
        guard let p = pOpt else {
            lastInfo = (3, 0, 0); update("Đón → Trả: không tìm được điểm đón", t.pickupTitle); return
        }
        guard let d = dOpt else {
            lastInfo = (3, 0, 0); update("Đón → Trả: không tìm được điểm trả", t.dropoffTitle); return
        }
        let names = "Đón: \(name(p))\nTrả: \(name(d))"
        if let a = p.item.placemark.location, let b = d.item.placemark.location {
            lastInfo = (1, a.distance(from: b) * 1.3, 0)
            update("Đón → Trả ≈ \(fmtKm(a.distance(from: b) * 1.3)) (ước tính)", names)
        }
        let r = MKDirections.Request()
        r.source = p.item
        r.destination = d.item
        r.transportType = .automobile
        if let route = try? await MKDirections(request: r).calculate().routes.first {
            lastInfo = (2, route.distance, route.expectedTravelTime)
            update("Đón → Trả: \(fmtKm(route.distance)) • \(fmtTime(route.expectedTravelTime))", names)
        }
    }

    /// Mỗi thông báo một mã mới để iOS hiện bảng nổi; xoá thông báo cũ cho gọn.
    static func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Theo dõi vị trí xe khi đang quét (cần quyền vị trí "Luôn luôn").
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()
    private let lm = CLLocationManager()
    private(set) var last: CLLocation?

    func start() {
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lm.distanceFilter = 100
        lm.startUpdatingLocation()
    }
    func stop() { lm.stopUpdatingLocation() }
    func locationManager(_ m: CLLocationManager, didUpdateLocations ls: [CLLocation]) { last = ls.last }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
