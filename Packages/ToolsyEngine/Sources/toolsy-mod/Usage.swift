/// What `help` prints. Each command's text starts with its synopsis, which usage errors repeat.
enum Usage {
    static let commands = ["new", "validate", "run", "preview", "pack", "help"]

    static let overview = """
        usage: toolsy-mod <command> [<arguments>]

        Writes, checks, runs and packs Toolsy mods. The format is specified in MOD_FORMAT.md.

          new <id>                 start a mod from a template that works as it is
          validate <mod>           check a mod as installing it does, and point out likely mistakes
          run <folder> <command>   run one command of a mod as Toolsy does and report what it did
          preview <folder>         print what the mod's page and widgets show for a state
          pack <folder>            check a mod folder and pack it into a .toolsymod file
          help [<command>]         explain a command

        Exit status: 0 success, 1 the mod or the run failed, 2 the tool was used wrongly.
        """

    static func synopsis(of command: String) -> String {
        String(text(of: command).prefix { $0 != "\n" })
    }

    static func text(of command: String) -> String {
        switch command {
        case "new": """
            usage: toolsy-mod new <id> [--template basic|switch|service|widget] [--name <name>] [-o <folder>]

            Writes a new mod folder that validates and works as it is: mod.json, its scripts (POSIX sh,
            macOS tools only) and a README.md that says how to try it. Refuses to overwrite anything.

              <id>              the mod's id: 1-64 of a-z 0-9 . _ -, starting and ending with a letter or digit
              --template        basic    a page with a value kept fresh by refresh, a stepper setting, a button (default)
                                switch   enable / disable a lasting effect, with refresh reporting the real state
                                service  a long-running service feeding a chart and the status
                                widget   a dashboard widget with a gauge and detail, system events, a notification
              --name <name>     the display name (default: made from the id)
              -o <folder>       where to write the mod (default: ./<id>)
            """
        case "validate": """
            usage: toolsy-mod validate <folder | file.toolsymod | manifest.json> [--json]

            Runs every check installing the mod runs. Prints "OK <id> <version>" on standard output, or the
            error naming the offending field on standard error. Warnings (valid, but almost always a mistake)
            follow on standard error, one per line after "warning: "; they never change the exit status.

              --json    print one JSON object instead:
                        {"ok": true, "id", "version", "name", "commands", "privilegedCommands", "widgets",
                         "languages", "warnings"} or {"ok": false, "error"}
            """
        case "run": """
            usage: toolsy-mod run <folder> <command> [--state <json>] [--key <key>] [--value <json>] [--event <event>] [--locale <code>] [--data <folder>] [--for <seconds>] [--as-user] [--json]

            Validates the mod, runs one of its commands the way Toolsy does (environment, working directory,
            standard input, timeout) and reports the exit status, the duration, what standard output is to
            Toolsy (a patch, the captured text, or why it is ignored), the error Toolsy would show, and
            standard error. Exit status 1 when the command fails or times out.

              --state <json>    a JSON object merged over the mod's starting state (its settings plus
                                "enabled": false); null removes a key
              --key <key>       the state key of the control that starts the command (TOOLSY_KEY); when an
                                input binds it, --value is stored under it first, as the control does
              --value <json>    the control's new value or the button's value (TOOLSY_VALUE), as JSON: 7, true, '"text"'
              --event <event>   TOOLSY_EVENT: enable, disable, uninstall, refresh, service, command, launch, wake,
                                network or power (default: service for the service, command otherwise)
              --locale <code>   TOOLSY_LOCALE, a BCP 47 code such as ru or en-us (default: the language Toolsy shows the mod in on this Mac)
              --data <folder>   TOOLSY_DATA_DIR (default: a new temporary folder, removed afterwards)
              --for <seconds>   how long the service runs before it is stopped (default 5); service only
              --as-user         run a privileged command as you, not root, with root's environment; never as root
              --json            print the report as one JSON object
            """
        case "preview": """
            usage: toolsy-mod preview <folder> [--state <json>] [--language <code>]

            Validates the mod and prints, as an indented outline, what its page and widgets show for a state:
            every control with its rendered text and bound value, [hidden] where its "when" is false,
            [disabled], and each widget's title, value and gauge or chart. Runs no command. Also takes a
            .toolsymod file or a lone manifest.

              --state <json>     a JSON object merged over the mod's starting state (its settings plus
                                 "enabled": false); null removes a key
              --language <code>  show the mod through its localization table for this language, as Toolsy
                                 does for a user whose first language it is
            """
        case "pack": """
            usage: toolsy-mod pack <folder> [-o <file.toolsymod>]

            Validates the folder and writes it as a .toolsymod archive (default: ./<id>.toolsymod), without
            .DS_Store files and with executable bits kept. Prints "OK <id> <version> <archive>".
            """
        case "help": """
            usage: toolsy-mod help [<command>]

            Explains a command: \(commands.dropLast().joined(separator: ", ")). Without one, lists them.
            """
        default: overview
        }
    }
}
