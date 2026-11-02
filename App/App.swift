import SwiftUI
import PhotosUI
import ReplayKit
import UserNotifications
import CoreLocation

final class LocAsk: NSObject, CLLocationManagerDelegate {
    static let shared = LocAsk()
    let lm = CLLocationManager()
    var onChange: ((CLAuthorizationStatus) -> Void)?
    override init() { super.init(); lm.delegate = self }
    func ask() { lm.requestAlwaysAuthorization() }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { onChange?(m.authorizationStatus) }
}

/// Điểm vào là Overlay/main.mm (để cùng file app chạy được tiến trình chữ nổi).
@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = UIHostingController(rootView: ContentView())
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

/// Nút hệ thống để bật/tắt "phát màn hình" sang extension của app.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        v.preferredExtension = "com.quangduongcuoc.app.broadcast"
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {}
}

struct ContentView: View {
    @State private var notifOK = false
    @State private var testResult = ""
    @State private var showPicker = false
    @State private var locOK = false
    @State private var overlayOn = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Bước 1")) {
                    Button(notifOK ? "✅ Đã cho phép thông báo" : "Cho phép thông báo") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                            DispatchQueue.main.async { notifOK = ok }
                        }
                    }
                }
                Section(header: Text("Vị trí"),
                        footer: Text("Giúp tìm đúng điểm đón (điểm đón luôn ở gần xe). Nên chọn \"Luôn luôn\".")) {
                    Button(locOK ? "✅ Đã cho phép vị trí" : "Cho phép vị trí") { LocAsk.shared.ask() }
                }
                Section(header: Text("Chữ nổi trên màn hình"),
                        footer: Text("Hiện quãng đường ngay dưới địa chỉ điểm đến (cách khoảng 8 mm). Chữ không cản bấm \"Nhận chuyến\".")) {
                    Toggle("Bật chữ nổi", isOn: Binding(get: { overlayOn }, set: { v in
                        overlayOn = v
                        DispatchQueue.global().async { SetOverlayEnabled(v) }
                    }))
                }
                Section(header: Text("Bước 2 — Bật đọc màn hình"),
                        footer: Text("Bấm biểu tượng, chọn \"Quãng Đường\" rồi \"Bắt đầu phát\". Sau đó mở app Xanh SM. Khi có cuốc, thông báo quãng đường đón → trả sẽ hiện ở mép trên. Tắt bằng cách bấm chấm đỏ trên thanh trạng thái.")) {
                    HStack {
                        Spacer()
                        BroadcastButton().frame(width: 60, height: 60)
                        Spacer()
                    }
                }
                Section(header: Text("Thử bằng ảnh chụp màn hình báo cuốc")) {
                    Button("Chọn ảnh") { showPicker = true }
                    if !testResult.isEmpty { Text(testResult).font(.callout) }
                }
            }
            .navigationTitle("Quãng Đường Cuốc")
        }
        .sheet(isPresented: $showPicker) { ImagePicker { test($0) } }
        .onAppear {
            LocAsk.shared.onChange = { st in DispatchQueue.main.async { locOK = st == .authorizedAlways || st == .authorizedWhenInUse } }
            LocAsk.shared.onChange?(LocAsk.shared.lm.authorizationStatus)
            DispatchQueue.global().async {
                let on = IsOverlayEnabled()
                DispatchQueue.main.async { overlayOn = on }
            }
            UNUserNotificationCenter.current().getNotificationSettings { s in
                DispatchQueue.main.async { notifOK = s.authorizationStatus == .authorized }
            }
        }
    }

    private func test(_ ui: UIImage) {
        testResult = "Đang đọc…"
        DispatchQueue.global().async {
            guard let cg = ui.cgImage, let t = TripReader().read(CIImage(cgImage: cg)) else {
                DispatchQueue.main.async { testResult = "Không nhận ra màn hình báo cuốc." }
                return
            }
            let read = "Đọc được:\nĐón: \(t.pickupTitle) | \(t.pickupDetail)\nTrả: \(t.dropoffTitle) | \(t.dropoffDetail)"
            DispatchQueue.main.async { testResult = read }
            Task {
                await TripDistance.run(t) { title, body in
                    DispatchQueue.main.async { testResult = "\(title)\n\(body)\n\n\(read)" }
                }
            }
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let done: (UIImage) -> Void
    func makeCoordinator() -> Coord { Coord(done) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var c = PHPickerConfiguration()
        c.filter = .images
        let p = PHPickerViewController(configuration: c)
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ v: PHPickerViewController, context: Context) {}
    final class Coord: NSObject, PHPickerViewControllerDelegate {
        let done: (UIImage) -> Void
        init(_ d: @escaping (UIImage) -> Void) { done = d }
        func picker(_ p: PHPickerViewController, didFinishPicking r: [PHPickerResult]) {
            p.dismiss(animated: true)
            r.first?.itemProvider.loadObject(ofClass: UIImage.self) { img, _ in
                if let i = img as? UIImage { DispatchQueue.main.async { self.done(i) } }
            }
        }
    }
}
