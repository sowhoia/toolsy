import Foundation
import ToolsyEngine

let usage = """
    usage: toolsy-mod validate <folder | file.toolsymod | manifest.json>
           toolsy-mod pack <folder> [-o <file.toolsymod>]
    """

func absolute(_ argument: String) -> URL {
    URL(filePath: argument, relativeTo: .currentDirectory()).absoluteURL.standardizedFileURL
}

func exit(printing message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "validate" where arguments.count == 2:
        let manifest = try await ModPackage.validate(absolute(arguments[1]))
        print("OK \(manifest.id) \(manifest.version)")
    case "pack" where arguments.count == 2 || (arguments.count == 4 && arguments[2] == "-o"):
        let folder = absolute(arguments[1])
        let archive = if arguments.count == 4 {
            absolute(arguments[3])
        } else {
            absolute("\(try await ModPackage.validate(folder).id).toolsymod")
        }
        let manifest = try await ModPackage.pack(folder, to: archive)
        print("OK \(manifest.id) \(manifest.version) \(archive.path(percentEncoded: false))")
    default:
        exit(printing: usage, status: 2)
    }
} catch {
    exit(printing: error.localizedDescription, status: 1)
}
