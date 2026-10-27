#if os(macOS)
import AVFoundation
import CoreAudio
import os

/// Records everything the Mac plays (Zoom, Teams, Meet in a browser…) with a Core Audio process tap.
/// No virtual audio driver needed. Requires macOS 14.2 and the "System Audio Recording" permission,
/// which macOS asks for the first time a tap is created (NSAudioCaptureUsageDescription).
public final class SystemAudioRecorder: @unchecked Sendable {
    private let writer: TrackWriter
    private let ioQueue = DispatchQueue(label: "LocalScribe.SystemAudio", qos: .userInteractive)
    /// Device-change handling must not run on `ioQueue`: AudioDeviceStop waits for the IO block on that queue.
    private let controlQueue = DispatchQueue(label: "LocalScribe.SystemAudio.control")
    private var outputUID: String?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let problemLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Set when the call audio stopped because the output device changed and the rebuild failed.
    public var problem: String? { problemLock.withLock { $0 } }

    public init(writer: TrackWriter) {
        self.writer = writer
    }

    // All state changes happen on `controlQueue` (start, stop and the device-change listener), so they can't interleave.
    public func start() throws {
        try controlQueue.sync { try startLocked() }
    }

    public func stop() {
        controlQueue.sync { stopLocked() }
    }

    private func startLocked() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = tapUUID
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var asbd = AudioStreamBasicDescription()
        try getProperty(tapID, kAudioTapPropertyFormat, &asbd)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw LocalScribeError.audioUnavailable("Unsupported system audio format")
        }
        self.format = format
        try startAggregate()
        listenForOutputDeviceChanges()
    }

    private func stopLocked() {
        if let outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, outputListener)
            self.outputListener = nil
        }
        stopAggregate()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Aggregate device wrapping the tap

    private func startAggregate() throws {
        let outputUID = try Self.defaultOutputUID()
        self.outputUID = outputUID
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LocalScribe System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tapUUID.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create aggregate device")

        guard let format else { return }
        let writer = self.writer
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            writer.append(buffer, hostTime: inputTime.pointee.mHostTime)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start system audio")
    }

    private func stopAggregate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Switching to AirPods or an external display mid-call changes the clock device; rebuild the aggregate on it.
    private func listenForOutputDeviceChanges() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // The notification also fires for our own private aggregate device; only rebuild on a real switch.
            guard let self, self.tapID != kAudioObjectUnknown,
                  let current = try? Self.defaultOutputUID(), current != self.outputUID else { return }
            self.stopAggregate()
            do { try self.startAggregate() } catch {
                self.problemLock.withLock { $0 = "Call audio stopped after the sound output changed: \(error.localizedDescription)" }
            }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        outputListener = listener
    }

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func getProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) throws {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read property \(selector)")
    }

    private static func defaultOutputUID() throws -> String {
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            throw LocalScribeError.audioUnavailable("No audio output device")
        }
        address = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else {
            throw LocalScribeError.audioUnavailable("Could not identify the audio output device")
        }
        return uid.takeRetainedValue() as String
    }

    /// Our own process, excluded from the tap.
    private static func ownProcessObject() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            throw LocalScribeError.audioUnavailable("Could not \(action) (OSStatus \(status))")
        }
    }
}
#endif
