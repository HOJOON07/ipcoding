import CoreAudio
import Foundation

/// 입력 오디오 장치 열거·UID 해석 (태스크 3.3, TDD §3.2 "설정에서 고정 장치 선택").
/// 저장은 부팅 간 영속인 UID로, 사용 시점에 AudioDeviceID로 해석한다
/// (AudioDeviceID는 세션마다 바뀔 수 있는 휘발 값 — 2026-07 조사).
enum AudioInputDevices {

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// 입력 스트림(채널 > 0)을 가진 장치만 열거. 설정 UI 표시용.
    static func enumerate() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: id, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// 저장된 UID → 현재 AudioDeviceID. 장치가 없으면 nil (시스템 기본 폴백 신호).
    /// kAudioHardwarePropertyTranslateUIDToDevice는 부재 시 에러가 아니라
    /// kAudioObjectUnknown(0)을 반환한다 (SDK 헤더 명시).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer,
                &dataSize, &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    // MARK: - 내부

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }
        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listPointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, listPointer) == noErr
        else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            listPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        of id: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
