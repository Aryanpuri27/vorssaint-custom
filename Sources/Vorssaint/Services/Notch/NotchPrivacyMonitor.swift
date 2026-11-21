// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AudioToolbox
import Combine
import CoreAudio
import CoreMediaIO
import Foundation

/// Whether any app is using the camera or the microphone right now, read
/// from the system every two seconds while the dots or quiet hours need it.
final class NotchPrivacyMonitor: ObservableObject {
    static let shared = NotchPrivacyMonitor()

    @Published private(set) var cameraInUse = false
    @Published private(set) var microphoneInUse = false
    private var timer: Timer?

    var enabled: Bool { UserDefaults.standard.object(forKey: DefaultsKey.notchPrivacyDots) as? Bool ?? true }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let camera = Self.anyCameraRunning(), microphone = Self.defaultInputRunning()
        if camera != cameraInUse { cameraInUse = camera }
        if microphone != microphoneInUse { microphoneInUse = microphone }
    }

    private static func defaultInputRunning() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static func anyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0
        else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr
        else { return false }
        for device in devices {
            var running: UInt32 = 0
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }
}

/// Quiet: no pop-ups and no shows, during the chosen hours or while the
/// camera is on, which is usually a call.
enum NotchQuiet {
    static var isActive: Bool {
        if NotchPrivacyMonitor.shared.cameraInUse { return true }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.notchQuietHours) else { return false }
        let start = defaults.integer(forKey: DefaultsKey.notchQuietStart), end = defaults.integer(forKey: DefaultsKey.notchQuietEnd)
        let hour = Calendar.current.component(.hour, from: Date())
        return start == end ? false : start < end ? (start..<end).contains(hour) : (hour >= start || hour < end)
    }
}

/// The default output's volume, read and set through Core Audio.
enum NotchSystemVolume {
    private static func device() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                            mScope: kAudioDevicePropertyScopeOutput,
                                                            mElement: kAudioObjectPropertyElementMain)

    static func get() -> Float? {
        guard let device = device() else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = address
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    static func set(_ volume: Float) {
        guard let device = device() else { return }
        var value = Float32(volume)
        var address = address
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
