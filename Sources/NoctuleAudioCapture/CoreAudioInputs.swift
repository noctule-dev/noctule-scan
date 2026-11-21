// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import CoreAudio
import Foundation
import NoctuleKit

/// The Mac's audio inputs, from Core Audio: every device with input channels, by its UID
/// (`kAudioDevicePropertyDeviceUID`) and name. Reading it lists devices but opens none. Never used
/// in tests, or while `NOCTULE_NO_USB_DETECTION` is set (line-in design §8).
public struct CoreAudioInputs: AudioInputListing {
    public init() {}

    public func inputs() -> [AudioInputDevice] {
        Self.deviceIDs().compactMap { id in
            let channels = Self.inputChannelCount(id)
            guard channels > 0, let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name, channelCount: channels)
        }
    }

    /// The device that has `uid` now, if any.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var qualifier = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer,
                &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Yields whenever a device is added or removed (a `kAudioHardwarePropertyDevices` listener,
    /// removed when the stream ends: its consumer is cancelled or stops reading).
    public static func deviceListChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let queue = DispatchQueue(label: "app.noctule.audio-devices")
        let listener = Listener { _, _ in continuation.yield() }
        var address = devicesAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener.block)
        guard status == noErr else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { _ in
            var address = devicesAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener.block)
        }
        return stream
    }

    /// The block Core Audio calls; removing it needs the same block, so the termination handler keeps it.
    private struct Listener: @unchecked Sendable {
        let block: AudioObjectPropertyListenerBlock
    }

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = devicesAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// A string property (the UID, the name); Core Audio hands over a retained `CFString`.
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif
