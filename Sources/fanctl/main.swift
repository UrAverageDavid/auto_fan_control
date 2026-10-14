import Foundation
import FanCore
import FanHardware

let args = Array(CommandLine.arguments.dropFirst())
// A separate process returns fans to automatic if commissioning exits, hangs, or is interrupted.
// No arbitrary operations or sensor keys are accepted by this watchdog.
if args.first == "--commission-watchdog" {
    guard geteuid() == 0 else { exit(1) }
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    do {
        let hardware = try SMCHardware()
        try FileHandle.standardOutput.write(contentsOf: Data([1]))
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            let ready = poll(&descriptor, 1, 5000)
            if ready <= 0 { break }
            var buffer = [UInt8](repeating: 0, count: 32)
            if read(STDIN_FILENO, &buffer, buffer.count) <= 0 { break }
        }
        try hardware.restoreAutomatic()
        exit(0)
    } catch { fputs("Commissioning watchdog could not verify automatic restoration: \(error.localizedDescription)\n", stderr); exit(1) }
}
do {
    let lock = (args.first == "validate" || args.first == "restore") ? try HardwareLock() : nil
    defer { withExtendedLifetime(lock) {} }
    let hardware = try SMCHardware()
    switch args.first ?? "doctor" {
    case "doctor":
        for (key, value) in try hardware.diagnostic().sorted(by: { $0.key < $1.key }) { print("\(key): \(value)") }
        print("Read-only discovery complete. Temperature keys are candidates, not verified CPU/GPU mappings.")
    case "restore":
        try hardware.restoreAutomatic(); print("Apple automatic fan mode verified.")
    case "validate":
        signal(SIGPIPE, SIG_IGN)
        guard args.count == 5, args[1] == "--cpu", args[3] == "--gpu" else {
            throw FanError.invalid("Usage: sudo fanctl validate --cpu KEY1,KEY2 --gpu KEY3,KEY4")
        }
        print("Testing maximum fan response for up to 20 seconds, then restoring Apple Automatic.")
        let watchdog = Process(), heartbeat = Pipe(), readiness = Pipe()
        watchdog.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        watchdog.arguments = ["--commission-watchdog"]; watchdog.standardInput = heartbeat; watchdog.standardOutput = readiness
        try watchdog.run()
        heartbeat.fileHandleForReading.closeFile()
        defer { heartbeat.fileHandleForWriting.closeFile(); watchdog.waitUntilExit() }
        readiness.fileHandleForWriting.closeFile()
        guard readiness.fileHandleForReading.readData(ofLength: 1) == Data([1]) else { throw FanError.hardware("Commissioning watchdog could not start.") }
        readiness.fileHandleForReading.closeFile()
        let record = try hardware.validateHardware(cpu: args[2].split(separator: ",").map(String.init), gpu: args[4].split(separator: ",").map(String.init)) {
            guard watchdog.isRunning else { throw FanError.hardware("Commissioning watchdog stopped unexpectedly.") }
            try heartbeat.fileHandleForWriting.write(contentsOf: Data([1]))
        }
        heartbeat.fileHandleForWriting.closeFile(); watchdog.waitUntilExit()
        guard watchdog.terminationStatus == 0 else { throw FanError.hardware("Watchdog could not verify automatic restoration.") }
        try FileManager.default.createDirectory(at: ValidationRecord.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: ValidationRecord.url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0], ofItemAtPath: ValidationRecord.url.path)
        print("Hardware validated; automatic restoration verified. Restart the helper to load the validation record.")
    default: throw FanError.invalid("Commands: doctor, restore, validate --cpu KEYS --gpu KEYS")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
