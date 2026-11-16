import Foundation
import ToolsyHelperXPC
import ToolsyShared

/// Where the installer puts things and which tools it calls. Production uses `.production`; tests
/// point the paths at a scratch directory and substitute `launchctl` and `chown`.
struct InstallLayout: Sendable, Equatable {
    var helper: String
    var plist: String
    var store: String
    var label: String
    var bundleIdentifier: String
    /// launchd domain the job is loaded into.
    var domain: String
    var launchctl: String
    var chown: String

    static let production = InstallLayout(
        helper: HelperConstants.installedHelper.path(percentEncoded: false),
        plist: HelperConstants.launchdPlist.path(percentEncoded: false),
        store: HelperConstants.store.path(percentEncoded: false),
        label: HelperConstants.label,
        bundleIdentifier: ToolsyPaths.bundleIdentifier,
        domain: "system",
        launchctl: "/bin/launchctl",
        chown: "/usr/sbin/chown"
    )
}

/// The shell commands run as root through the administrator prompt. The script bodies are constants;
/// the layout is prepended as quoted assignments and the inputs arrive as positional arguments,
/// so nothing is ever interpolated into script text.
enum InstallScript {
    static let installBody = #"""
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        umask 022
        source_helper=$1
        cdhash=$2
        client_uid=$3
        # The app validated both already; this script runs as root, so check again.
        case $cdhash in *[!0-9a-f]*) echo "invalid code hash" >&2; exit 64 ;; esac
        [ ${#cdhash} -eq 40 ] || { echo "invalid code hash" >&2; exit 64; }
        case $client_uid in ''|*[!0-9]*) echo "invalid user id" >&2; exit 64 ;; esac

        # Every file is written next to its final path and renamed into place: a running helper is
        # never overwritten in place and nobody reads half a file.
        place() { # <mode> <temporary> <final>
            "$chown" root:wheel "$2"
            /bin/chmod "$1" "$2"
            /bin/mv -f "$2" "$3"
        }

        /bin/mkdir -p "${helper%/*}" "${plist%/*}"
        /bin/cp "$source_helper" "$helper.new"
        place 0755 "$helper.new" "$helper"

        /bin/mkdir -p "$store"
        "$chown" root:wheel "$store"
        /bin/chmod 0755 "$store"
        printf 'cdhash H"%s"' "$cdhash" > "$store/client-requirement.new"
        place 0644 "$store/client-requirement.new" "$store/client-requirement"
        printf '%s' "$client_uid" > "$store/client-user.new"
        place 0644 "$store/client-user.new" "$store/client-user"

        /bin/cat > "$plist.new" <<PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>$label</string>
            <key>MachServices</key>
            <dict>
                <key>$label</key>
                <true/>
            </dict>
            <key>ProgramArguments</key>
            <array>
                <string>$helper</string>
            </array>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>$bundle_id</string>
            </array>
        </dict>
        </plist>
        PLIST
        place 0644 "$plist.new" "$plist"

        "$launchctl" bootout "$domain/$label" 2>/dev/null || true
        # launchd can still be letting go of the old job right after bootout; bootstrap then fails briefly.
        attempt=1
        until "$launchctl" bootstrap "$domain" "$plist"; do
            [ "$attempt" -lt 5 ] || exit 1
            attempt=$((attempt + 1))
            sleep 1
        done
        """#

    static let removalBody = #"""
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        "$launchctl" bootout "$domain/$label" 2>/dev/null || true
        /bin/rm -f "$plist" "$helper"
        /bin/rm -rf "$store"
        """#

    /// Installs or updates the helper for the app with `cdhash` run by the user `clientUID`; running it
    /// again is harmless.
    static func installCommand(layout: InstallLayout, bundledHelper: URL, cdhash: String, clientUID: uid_t) throws -> String {
        let source = bundledHelper.path(percentEncoded: false)
        guard source.hasPrefix("/"), !containsControlCharacters(source) else {
            throw PrivilegedError.rejected("The bundled helper path is not usable: \(source)")
        }
        guard cdhash.wholeMatch(of: /[0-9a-f]{40}/) != nil else {
            throw PrivilegedError.rejected("Invalid code directory hash: \(cdhash)")
        }
        return try command(installBody, layout: layout, arguments: [source, cdhash, String(clientUID)])
    }

    /// Removes everything `installCommand` creates, for when the helper cannot remove itself.
    static func removalCommand(layout: InstallLayout) throws -> String {
        try command(removalBody, layout: layout, arguments: [])
    }

    private static func command(_ body: String, layout: InstallLayout, arguments: [String]) throws -> String {
        let assignments = [
            ("helper", layout.helper), ("plist", layout.plist), ("store", layout.store), ("label", layout.label),
            ("bundle_id", layout.bundleIdentifier), ("domain", layout.domain), ("launchctl", layout.launchctl),
            ("chown", layout.chown),
        ]
        // The values end up in the plist as they are, so they must not need XML escaping.
        for (name, value) in assignments where value.isEmpty || containsControlCharacters(value) || value.contains(where: "&<>".contains) {
            throw PrivilegedError.rejected("Invalid installer setting \(name): \(value)")
        }
        let script = assignments.map { "\($0.0)=\(shellQuoted($0.1))\n" }.joined() + body + "\n"
        return (["/bin/sh", "-c", shellQuoted(script), "toolsy-installer"] + arguments.map(shellQuoted)).joined(separator: " ")
    }

    /// One shell word with exactly the characters of `value`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacing("'", with: #"'\''"#) + "'"
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
