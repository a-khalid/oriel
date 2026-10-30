import Foundation
@preconcurrency import Virtualization

/// What this Mac can give to guests, and sensible defaults for first-time users.
public enum HostResources {
    /// Memory kept back for macOS itself so the host stays responsive.
    static let hostMemoryReserve: UInt64 = 4 * .gibibyte

    public static var cpuCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    public static var allowedCPUCount: ClosedRange<Int> {
        let lower = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, 1)
        let upper = max(min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, cpuCount), lower)
        return lower...upper
    }

    public static var allowedMemorySize: ClosedRange<UInt64> {
        let lower = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, 2 * .gibibyte)
        let usable = physicalMemory > hostMemoryReserve * 2 ? physicalMemory - hostMemoryReserve : physicalMemory / 2
        let upper = max(min(VZVirtualMachineConfiguration.maximumAllowedMemorySize, usable), lower)
        return lower...upper
    }

    public static func recommendedCPUCount(for os: GuestOS) -> Int {
        clamp(max(cpuCount / 2, os == .linux ? 2 : 4))
    }

    public static func recommendedMemorySize(for os: GuestOS) -> UInt64 {
        let target: UInt64 = os == .linux ? 4 * .gibibyte : 8 * .gibibyte
        return clamp(min(target, physicalMemory / 2))
    }

    public static func clamp(_ count: Int) -> Int {
        min(max(count, allowedCPUCount.lowerBound), allowedCPUCount.upperBound)
    }

    /// Clamps and rounds down to a whole MiB, which Virtualization.framework requires.
    public static func clamp(_ size: UInt64) -> UInt64 {
        let clamped = min(max(size, allowedMemorySize.lowerBound), allowedMemorySize.upperBound)
        return clamped / .mebibyte * .mebibyte
    }
}
