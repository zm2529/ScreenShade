import Foundation

let command = CommandLine.arguments.dropFirst().first ?? "restore"
guard command == "restore" || command == "toggle" else {
    fputs("Usage: swift scripts/control.swift restore|toggle\n", stderr)
    exit(64)
}
DistributedNotificationCenter.default().postNotificationName(.init("local.ScreenShade.\(command)"),
                                                            object: nil, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
