import Foundation
import ToolsyEngine
import ToolsyShared

/// `new`: writes a mod folder from a `StarterTemplate`, all at once or not at all.
struct NewCommand {
    let id: String
    let name: String
    let template: StarterTemplate
    let folder: URL

    init(_ arguments: Arguments) throws(UsageError) {
        id = try arguments.positionals(1...1, "the id of the new mod")[0]
        guard ModManifest.isValidID(id) else {
            throw UsageError(message: "\"\(id)\" is not a mod id: use 1-64 lowercase letters, digits, \".\", \"_\" or \"-\", starting and ending with a letter or digit", command: "new")
        }
        let templateName = arguments.value("--template") ?? StarterTemplate.basic.rawValue
        guard let template = StarterTemplate(rawValue: templateName) else {
            let names = StarterTemplate.allCases.map(\.rawValue).joined(separator: ", ")
            throw UsageError(message: "there is no template \"\(templateName)\"; choose one of \(names)", command: "new")
        }
        self.template = template
        name = arguments.value("--name") ?? Self.name(from: id)
        // The rule ModManifest.validate applies to `name`.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else {
            throw UsageError(message: "--name must be 1-80 characters", command: "new")
        }
        folder = absolute(arguments.value("-o") ?? id)
    }

    /// "keep-awake" → "Keep awake".
    static func name(from id: String) -> String {
        let words = id.replacing(/[._-]+/, with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    func run() throws -> Int32 {
        let files = FileManager.default
        let path = folder.path(percentEncoded: false)
        guard !files.fileExists(atPath: path) else {
            throw EngineError("\(path) already exists; choose another folder with -o")
        }
        let parent = folder.deletingLastPathComponent()
        guard files.fileExists(atPath: parent.path(percentEncoded: false)) else {
            throw EngineError("\(parent.path(percentEncoded: false)) does not exist")
        }
        // Written beside the target and renamed into place, so a failure leaves nothing half-written.
        let staging = parent.appending(path: ".\(folder.lastPathComponent)-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? files.removeItem(at: staging) } // Already moved away on success; on failure only clutter remains.
        let written = template.files(id: id, name: name)
        for file in written {
            let url = staging.appending(path: file.path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.contents.utf8).write(to: url)
            try files.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path(percentEncoded: false))
        }
        try files.moveItem(at: staging, to: folder)
        print("OK \(id) \(path)")
        for file in written {
            print("  \(file.path)")
        }
        print("Next: toolsy-mod validate \(path), then see its README.md")
        return 0
    }
}
