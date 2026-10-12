import CoreAudio
import Foundation

struct CoreAudioError: Error, LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? {
        let fourCC = withUnsafeBytes(of: status.bigEndian) { b in
            b.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(decoding: b, as: UTF8.self))'" : ""
        }
        return "\(what) failed (OSStatus \(status)\(fourCC))"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(what: what(), status: status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    func address(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T>(_ selector: AudioObjectPropertySelector, default value: T,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var v = value
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &v), "read '\(selector.fourCC)'")
        return v
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var s: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &s), "read '\(selector.fourCC)'")
        return (s?.takeRetainedValue() as String?) ?? ""
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector, of _: T.Type,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "size '\(selector.fourCC)'")
        let n = Int(size) / MemoryLayout<T>.stride
        guard n > 0 else { return [] }
        let buf = UnsafeMutablePointer<T>.allocate(capacity: n)
        defer { buf.deallocate() }
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buf), "read '\(selector.fourCC)'")
        return Array(UnsafeBufferPointer(start: buf, count: n))
    }

    func write<T>(_ selector: AudioObjectPropertySelector, _ value: T) throws {
        var addr = address(selector)
        var v = value
        try check(AudioObjectSetPropertyData(self, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v),
                  "write '\(selector.fourCC)'")
    }

    /// Total channels across all streams in `scope`.
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID.unknown)
    }

    static func setDefaultOutputDevice(_ id: AudioDeviceID) throws {
        try AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, id)
    }

    /// First device with output channels whose name contains `fragment` (case-insensitive).
    static func outputDevice(nameContaining fragment: String) -> AudioDeviceID? {
        let all = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self)) ?? []
        return all.first { d in
            let name = (try? d.readString(kAudioObjectPropertyName)) ?? ""
            return name.localizedCaseInsensitiveContains(fragment) && d.channelCount(scope: kAudioObjectPropertyScopeOutput) > 0
        }
    }

    var deviceName: String { (try? readString(kAudioObjectPropertyName)) ?? "device \(self)" }

    /// Core Audio process objects whose bundle ID starts with `prefix`.
    static func processObjects(bundlePrefix prefix: String) -> [(id: AudioObjectID, bundleID: String)] {
        let all = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? []
        return all.compactMap { obj in
            guard let bid = try? obj.readString(kAudioProcessPropertyBundleID), bid.hasPrefix(prefix) else { return nil }
            return (obj, bid)
        }
    }
}

extension UInt32 {
    var fourCC: String {
        let bytes = withUnsafeBytes(of: bigEndian) { Array($0) }
        return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(self)
    }
}
