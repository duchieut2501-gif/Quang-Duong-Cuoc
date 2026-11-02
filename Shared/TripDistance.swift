import CoreLocation
import MapKit
import UserNotifications

/// Tìm vị trí 2 địa chỉ bằng Apple Maps, tính quãng đường và gửi thông báo nổi.
enum TripDistance {
    private static let vnRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 18.5, longitude: 106.0),
        span: MKCoordinateSpan(latitudeDelta: 16, longitudeDelta: 10))

    struct Place { let item: MKMapItem; let query: String }

    static func search(_ q: String) async -> MKMapItem? {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = q
        r.region = vnRegion
        return try? await MKLocalSearch(request: r).start().mapItems.first
    }

    static func geocode(_ q: String) async -> MKMapItem? {
        guard let p = try? await CLGeocoder().geocodeAddressString(q, in: nil,
                                preferredLocale: Locale(identifier: "vi_VN")).first else { return nil }
        return MKMapItem(placemark: MKPlacemark(placemark: p))
    }

    /// Thử lần lượt: tiêu đề + chi tiết, chỉ tiêu đề, chỉ chi tiết.
    static func locate(title: String, detail: String) async -> Place? {
        let t = title, d = detail
        var tries: [String] = []
        if !t.isEmpty && !d.isEmpty { tries.append("\(t), \(d)") }
        if !t.isEmpty { tries.append("\(t), Việt Nam") }
        if !d.isEmpty { tries.append(d) }
        for q in tries {
            if let i = await search(q) { return Place(item: i, query: q) }
        }
        for q in tries {
            if let i = await geocode(q) { return Place(item: i, query: q) }
        }
        return nil
    }

    static func fmtKm(_ m: CLLocationDistance) -> String {
        let km = m / 1000
        return km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
    }

    static func fmtTime(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) giờ \(m % 60) phút" : "\(m) phút"
    }

    static func name(_ p: Place) -> String {
        let pm = p.item.placemark
        return [p.item.name, pm.subAdministrativeArea ?? pm.locality, pm.administrativeArea]
            .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ", ")
    }

    /// Chạy toàn bộ: gửi số ước tính trước, rồi cập nhật số theo đường đi thật.
    /// `update` nhận nội dung (tiêu đề, thân) mỗi khi có kết quả mới.
    static func run(_ t: TripText, update: @escaping (String, String) -> Void) async {
        async let a = locate(title: t.pickupTitle, detail: t.pickupDetail)
        async let b = locate(title: t.dropoffTitle, detail: t.dropoffDetail)
        guard let p = await a, let d = await b else {
            update("Đón → Trả: không tìm được vị trí",
                   "Đón: \(t.pickupTitle)\nTrả: \(t.dropoffTitle)")
            return
        }
        let names = "Đón: \(name(p))\nTrả: \(name(d))"
        let line = p.item.placemark.location!.distance(from: d.item.placemark.location!)
        update("Đón → Trả ≈ \(fmtKm(line * 1.3)) (ước tính)", names)

        let r = MKDirections.Request()
        r.source = p.item
        r.destination = d.item
        r.transportType = .automobile
        if let route = try? await MKDirections(request: r).calculate().routes.first {
            update("Đón → Trả: \(fmtKm(route.distance)) • \(fmtTime(route.expectedTravelTime))", names)
        }
    }

    static func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if #available(iOS 15.0, *) { c.interruptionLevel = .timeSensitive }
        // Cùng mã => thông báo mới thay thế thông báo cũ.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "trip", content: c, trigger: nil))
    }
}
