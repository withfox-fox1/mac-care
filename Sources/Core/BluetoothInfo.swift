import Foundation
import IOBluetooth

/// 接続中の Bluetooth デバイスの表示用情報
struct BluetoothDeviceInfo: Equatable, Identifiable {
    var name: String
    var symbol: String
    /// 残量（%）。左右独立型は小さい方
    var battery: Int?
    var id: String { name }
}

/// 1 台分の残量（%）。未取得は nil
struct BluetoothLevels: Codable, Equatable {
    var single: Int?
    var left: Int?
    var right: Int?
    var minimum: Int? { [single, left, right].compactMap { $0 }.min() }
}

/// 残量は IOBluetoothDevice の非公開プロパティから取得する。
/// 同一プロセス内ではプロセス起動時の値が更新されず、再接続後は 0 のままになる（BluetoothMeter で実測）。
/// そのため取得のたびに自分自身を `--dump-battery` 付きで別プロセス起動し、最新値を JSON で受け取る。
/// 取得できない場合は残量を表示しないだけで動作は継続する。読み取り専用。
enum BluetoothInfo {
    static let dumpArgument = "--dump-battery"

    /// 子プロセス側: 接続中デバイスの残量を {アドレス: BluetoothLevels} の JSON で標準出力へ書く
    static func dump() {
        var result: [String: BluetoothLevels] = [:]
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where d.isConnected() {
            func level(_ key: String) -> Int? {
                guard d.responds(to: NSSelectorFromString(key)),
                      let v = d.value(forKey: key) as? Int, v > 0, v <= 100 else { return nil }
                return v
            }
            guard let a = d.addressString else { continue }
            let l = BluetoothLevels(single: level("batteryPercentSingle"), left: level("batteryPercentLeft"),
                                    right: level("batteryPercentRight"))
            if l.minimum != nil { result[a] = l }
        }
        if let data = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(data) }
    }

    static func parse(_ data: Data) -> [String: BluetoothLevels] {
        (try? JSONDecoder().decode([String: BluetoothLevels].self, from: data)) ?? [:]
    }

    /// 親プロセス側: 子プロセスで残量を読む（5 秒で打ち切り）
    static func readLevels() async -> [String: BluetoothLevels] {
        guard let path = Bundle.main.executablePath else { return [:] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = [dumpArgument]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: [:]); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: parse(data))
            }
        }
    }

    static func symbol(name: String, major: Int) -> String {
        let lower = name.lowercased()
        switch major {
        case kBluetoothDeviceClassMajorAudio: return lower.contains("airpods") ? "airpods" : "headphones"
        case kBluetoothDeviceClassMajorPeripheral:
            if lower.contains("controller") || lower.contains("dualsense") || lower.contains("dualshock") { return "gamecontroller.fill" }
            if lower.contains("mouse") || lower.contains("trackpad") { return "computermouse.fill" }
            return "keyboard"
        case kBluetoothDeviceClassMajorPhone: return "iphone"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    /// 接続中のデバイス一覧（残量は levels から補う）
    static func connected(levels: [String: BluetoothLevels]) -> [BluetoothDeviceInfo] {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).filter { $0.isConnected() }.map { d in
            let name = d.name ?? d.addressString ?? "不明なデバイス"
            return BluetoothDeviceInfo(name: name, symbol: symbol(name: name, major: Int(d.deviceClassMajor)),
                                       battery: d.addressString.flatMap { levels[$0]?.minimum })
        }
    }
}
