//
//  CPUInfoProvider.swift
//  HIDTransmitter
//
//  Created by Maxime Bokobza on 04/11/2023.
//

import Foundation

protocol CPUInfoProviderConvertible {

    func setup()
    func coreUsages() -> [CPUInfoProvider.CoreUsage]

}

class CPUInfoProvider: CPUInfoProviderConvertible {

    private var numCPUs: uint = 0

    private var cpuInfo: processor_info_array_t! // TODO: not force unwrap
    private var prevCpuInfo: processor_info_array_t?
    private var numCpuInfo: mach_msg_type_number_t = 0
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private let CPUUsageLock = NSLock()

    struct CoreUsage {
        let inUse: Int32
        let total: Int32

        var percentValue: UInt8 {
            guard total > 0 else { return 0 }

            let value = Float(inUse) / Float(total)
            return UInt8(round(value * 100))
        }
    }

    func setup() {
        let mibKeys = [CTL_HW, HW_NCPU]
        // sysctl Swift usage credit Matt Gallagher: https://github.com/mattgallagher/CwlUtils/blob/master/Sources/CwlUtils/CwlSysctl.swift
        mibKeys.withUnsafeBufferPointer() { mib in
            var sizeOfNumCPUs: size_t = MemoryLayout<uint>.size
            let status = sysctl(processor_info_array_t(mutating: mib.baseAddress), 2, &numCPUs, &sizeOfNumCPUs, nil, 0)
            if status != 0 {
                numCPUs = 1
            }
        }
    }

    func coreUsages() -> [CoreUsage] {
        guard numCPUs > 0 else { return [] }

        var numCPUsU: natural_t = 0
        let err: kern_return_t = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo)

        guard err == KERN_SUCCESS else { return [] }

        let coreUsages = buildCoreUsages()

        if let prevCpuInfo {
            // vm_deallocate Swift usage credit rsfinn: https://stackoverflow.com/a/48630296/1033581
            let prevCpuInfoSize: size_t = MemoryLayout<integer_t>.stride * Int(numPrevCpuInfo)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevCpuInfoSize))
        }

        prevCpuInfo = cpuInfo
        numPrevCpuInfo = numCpuInfo

        // TODO: Put above host_processor_info instead
        cpuInfo = nil
        numCpuInfo = 0

        return coreUsages
    }

    private func buildCoreUsages() -> [CoreUsage] {
        var coreUsages: [CoreUsage] = []

        CPUUsageLock.lock()

        for i in 0 ..< Int32(numCPUs) {
            var inUse: Int32 = 0
            var total: Int32

            let userIndex = Int(CPU_STATE_MAX * i + CPU_STATE_USER)
            let systemIndex = Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)
            let niceIndex = Int(CPU_STATE_MAX * i + CPU_STATE_NICE)
            let idleIndex = Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)

            let inUseIndexes = [userIndex, systemIndex, niceIndex]

            inUseIndexes.forEach { inUse += cpuInfo[$0] }

            if let prevCpuInfo {
                inUseIndexes.forEach { inUse -= prevCpuInfo[$0] }
            }

            total = inUse + cpuInfo[idleIndex]

            if let prevCpuInfo {
                total -= prevCpuInfo[idleIndex]
            }

            coreUsages.append(CoreUsage(inUse: inUse, total: total))
        }

        CPUUsageLock.unlock()

        return coreUsages
    }

}
