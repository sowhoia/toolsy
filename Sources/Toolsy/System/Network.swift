import Darwin
import Foundation
import SystemConfiguration

/// The interface macOS routes traffic through by default, and its address.
struct NetworkInterface: Equatable {
    var bsdName: String
    var displayName: String
    var address: String?
}

/// Download and upload rates from the 64-bit byte counters of the routing sysctl
/// (`NET_RT_IFLIST2`). Only physical interfaces count: tunnels (VPN `utun`, `ipsec`) carry
/// traffic that also crosses a physical interface, so adding them would count it twice.
final class NetworkSampler {
    private var previous: (counters: [String: Counters], time: ContinuousClock.Instant)?
    private let store = SCDynamicStoreCreate(nil, "Toolsy" as CFString, nil, nil)
    private var displayNames: [String: String]?

    struct Counters {
        var received: UInt64
        var sent: UInt64
    }

    func reset() {
        previous = nil
    }

    /// Bytes per second since the previous call; nil for the first call (the baseline).
    func sample() -> (download: Double, upload: Double)? {
        guard let counters = Self.readCounters() else { return nil }
        let now = ContinuousClock.now
        defer { previous = (counters, now) }
        guard let previous else { return nil }
        let elapsed = (now - previous.time) / .seconds(1)
        guard elapsed > 0 else { return nil }
        var received: UInt64 = 0, sent: UInt64 = 0
        // Interfaces that appeared, vanished or were reset since the last sample add nothing.
        for (name, current) in counters {
            guard let old = previous.counters[name] else { continue }
            received += current.received >= old.received ? current.received - old.received : 0
            sent += current.sent >= old.sent ? current.sent - old.sent : 0
        }
        return (Double(received) / elapsed, Double(sent) / elapsed)
    }

    private static let etherType: UInt8 = 0x06      // IFT_ETHER, also Wi-Fi
    private static let cellularType: UInt8 = 0xFF   // IFT_CELLULAR

    static func readCounters() -> [String: Counters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return nil }
        // Interfaces can appear between the two calls; leave room for a few more.
        length += 4 * MemoryLayout<if_msghdr2>.size
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var counters: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let data = message.ifm_data
                let isUp = message.ifm_flags & IFF_UP != 0 && message.ifm_flags & IFF_LOOPBACK == 0
                guard isUp, data.ifi_type == etherType || data.ifi_type == cellularType,
                      let name = interfaceName(Int32(message.ifm_index)) else { continue }
                counters[name] = Counters(received: data.ifi_ibytes, sent: data.ifi_obytes)
            }
        }
        return counters
    }

    private static func interfaceName(_ index: Int32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        return String(utf8String: name)
    }

    // MARK: Primary interface

    /// The primary interface from the system configuration store, with its localized name
    /// ("Wi-Fi") and IPv4 address (or a global IPv6 address if it has no IPv4).
    func primaryInterface() -> NetworkInterface? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let bsdName = global["PrimaryInterface"] as? String else { return nil }
        if displayNames == nil {
            let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
            displayNames = Dictionary(interfaces.compactMap { interface in
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { return nil }
                return (bsd, name)
            }, uniquingKeysWith: { first, _ in first })
        }
        let isTunnel = ["utun", "ipsec", "ppp"].contains { bsdName.hasPrefix($0) }
        let displayName = displayNames?[bsdName] ?? (isTunnel ? "VPN" : bsdName)
        return NetworkInterface(bsdName: bsdName, displayName: displayName, address: Self.address(of: bsdName))
    }

    private static func address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var ipv6: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                  String(cString: entry.pointee.ifa_name) == interface else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0,
                  let text = String(utf8String: host) else { continue }
            if family == AF_INET { return text }
            if ipv6 == nil, !text.hasPrefix("fe80") { ipv6 = text }
        }
        return ipv6
    }
}
