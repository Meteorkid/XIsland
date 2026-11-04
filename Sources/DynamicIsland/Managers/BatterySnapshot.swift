import Foundation
import IOKit.ps

/// 电池状态读取（best effort）。台式机或读取失败时返回 nil，此时策略不做低电量暂停。
enum BatterySnapshot {
    static func read() -> (percent: Int?, isCharging: Bool) {
        guard let infoBlob = IOPSCopyPowerSourcesInfo() else { return (nil, false) }
        let info = infoBlob.takeRetainedValue()
        guard let listBlob = IOPSCopyPowerSourcesList(info) else { return (nil, false) }
        let list = listBlob.takeRetainedValue()
        let sources = list as [AnyObject]

        for source in sources {
            guard let descBlob = IOPSGetPowerSourceDescription(info, source) else { continue }
            guard let description = descBlob.takeUnretainedValue() as? [String: Any] else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let maximum = description[kIOPSMaxCapacityKey] as? Int
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            guard let current, let maximum, maximum > 0 else { continue }
            return (current * 100 / maximum, charging)
        }
        return (nil, false)
    }
}
