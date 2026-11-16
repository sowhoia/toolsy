import AppKit

let options = LaunchOptions(arguments: CommandLine.arguments)

// A second launch (Finder, `open`, Spotlight) only asks the running instance to show its panel.
if SingleInstance.handOffToRunningInstance() {
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate(options: options)
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
