import Cocoa

@main struct StandbyVerificationTests {
    static func main() throws {
        // The last power write and deadline recovery must enter their serial queue in that order.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let submitted = DispatchSemaphore(value: 0)
        let recovered = DispatchSemaphore(value: 0)
        let eventLock = NSLock()
        var events: [String] = []
        let orderedDeadline = WakeDeadline(seconds: 0.1) {
            eventLock.lock(); events.append("restore"); eventLock.unlock()
            recovered.signal()
        }
        DispatchQueue.global().async {
            precondition(orderedDeadline.performIfActive {
                entered.signal()
                precondition(release.wait(timeout: .now() + 2) == .success)
                eventLock.lock(); events.append("dim"); eventLock.unlock()
            })
            submitted.signal()
        }
        precondition(entered.wait(timeout: .now() + 2) == .success)
        precondition(recovered.wait(timeout: .now() + 0.2) == .timedOut,
                     "Deadline recovery cannot overtake a power write being submitted")
        release.signal()
        precondition(submitted.wait(timeout: .now() + 2) == .success)
        precondition(recovered.wait(timeout: .now() + 2) == .success)
        precondition(events == ["dim", "restore"])
        precondition(!orderedDeadline.performIfActive { fatalError("A late fallback write crossed the wake deadline") })
        orderedDeadline.cancel()

        guard let display = DisplayIdentity.connected().first else { fatalError("Tests require an active display identity") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenshade-verification-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper.py")
        let state = directory.appendingPathComponent("state.json")
        let journal = directory.appendingPathComponent("recovery.json")
        let fixture = """
        #!/usr/bin/env python3
        import json,sys,time
        from pathlib import Path
        base=Path(__file__).parent
        state=base/'state.json'
        s=json.loads(state.read_text())
        command=sys.argv[1]
        with (base/'commands').open('a') as log: log.write(' '.join(sys.argv[1:])+'\\n')
        if command=='set-power':
            value=int(sys.argv[3])
            if value!=1:
                records=json.loads((base/'recovery.json').read_text())
                assert records[0]['power']==1 and records[0]['value']==40
                (base/'entered-write').touch()
                time.sleep(s.get('delay',0))
            if s.get('wakeFailure') and value==1: sys.exit(68)
            if value==1 or value in s.get('supported',[2,4]): s['power']=value
        elif command=='set': s['brightness']=int(sys.argv[3])
        elif command=='read-power':
            if s.get('wakeFailure') and s['power']!=1: sys.exit(67)
            print(json.dumps({'current':s['power'],'maximum':5}))
        elif command=='read': print(json.dumps({'current':s['brightness'],'maximum':100}))
        else: sys.exit(64)
        state.write_text(json.dumps(s))
        """
        try fixture.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        func setState(_ extra: [String: Any] = [:]) throws {
            var value: [String: Any] = ["power": 1, "brightness": 40]
            value.merge(extra) { _, new in new }
            try JSONSerialization.data(withJSONObject: value).write(to: state)
            try Data("[]".utf8).write(to: journal)
            try Data().write(to: directory.appendingPathComponent("commands"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("entered-write"))
        }
        func readState() -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any] }
        func entries() -> [[String: Any]] { try! JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [[String: Any]] }
        func waitUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "Verification timed out")
        }
        func assertRestored() {
            precondition(readState()["power"] as? Int == 1 && readState()["brightness"] as? Int == 40)
            precondition(entries().isEmpty, "Confirmed recovery must clear its journal")
        }
        let baseline = StandbySnapshot(layout: HardwareStandby.currentLayout(), windows: [1: CGRect(x: 1, y: 2, width: 100, height: 100)])
        let brightness = Brightness(journal: journal, helper: helper)

        // A passing electrical check always restores before requesting human confirmation.
        try setState()
        let verifier = StandbyVerification(brightness: brightness, holdDuration: 0.05, timeout: 6, snapshot: { baseline })
        var result: StandbyVerification.Result?
        precondition(verifier.start(display) { result = $0 })
        precondition(verifier.isRunning)
        precondition(!verifier.start(display) { _ in fatalError("Concurrent test accepted") })
        waitUntil { result != nil }
        precondition(!verifier.isRunning && result!.mode == 4 && result!.needsConfirmation,
                     "Expected recovered mode 4; mode=\(String(describing: result!.mode)), message=\(result!.message), errors=\(result!.recoveryErrors.count)")
        assertRestored()

        // An ignored power-off state falls back to standby only after restoring mode 4.
        try setState(["supported": [2]])
        let fallback = StandbyVerification(brightness: brightness, holdDuration: 0.05, timeout: 10, snapshot: { baseline })
        result = nil
        fallback.start(display) { result = $0 }
        waitUntil { result != nil }
        precondition(result!.mode == 2 && result!.needsConfirmation)
        let commands = try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
            .split(separator: "\n")
        let writes = commands.filter { $0.hasPrefix("set-power ") }.map { $0.split(separator: " ").last! }
        precondition(writes == ["4", "1", "1", "2", "1"], "Each attempt must recover before the next attempt")
        precondition(!commands.contains { $0.hasPrefix("set ") && $0.hasSuffix(" 0") },
                     "Optional verification must not dim an unsupported display before trying another power mode")
        assertRestored()

        // Cancel during a helper write, then reuse the controller: no late callback may leak into the new run.
        try setState(["delay": 0.4])
        var completionCount = 0
        result = nil
        verifier.start(display) { completionCount += 1; result = $0 }
        waitUntil { FileManager.default.fileExists(atPath: directory.appendingPathComponent("entered-write").path) }
        verifier.cancel(reason: "cancelled by test")
        waitUntil { result != nil }
        precondition(result!.cancelled && !result!.needsConfirmation && completionCount == 1)
        assertRestored()
        try setState()
        result = nil
        verifier.start(display) { completionCount += 1; result = $0 }
        waitUntil { result != nil }
        precondition(result!.needsConfirmation && completionCount == 2)
        assertRestored()

        // The independent deadline requests wake even while a write is still in flight.
        try setState(["delay": 1.5])
        let timed = StandbyVerification(brightness: brightness, holdDuration: 0.05, timeout: 1, snapshot: { baseline })
        result = nil
        timed.start(display) { result = $0 }
        waitUntil { result != nil }
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("entered-write").path),
                     "The deadline test must exercise a power write already in flight")
        precondition(!result!.needsConfirmation && result!.mode == nil)
        assertRestored()

        // System dialogs and closed windows are allowed; moving an existing window is not.
        precondition(StandbySnapshot.tracksWindow(layer: 0, ownerPolicy: .regular))
        precondition(!StandbySnapshot.tracksWindow(layer: 0, ownerPolicy: .accessory))
        precondition(!StandbySnapshot.tracksWindow(layer: 0, ownerPolicy: .prohibited))
        precondition(!StandbySnapshot.tracksWindow(layer: 1, ownerPolicy: .regular))
        let changedWindows = StandbySnapshot(layout: baseline.layout, windows: [1: CGRect(x: 20, y: 2, width: 100, height: 100)])
        precondition(StandbySnapshot(layout: baseline.layout, windows: [2: .zero]).change(from: baseline) == nil)
        precondition(StandbySnapshot(layout: baseline.layout, windows: [:], windowsAvailable: false)
            .change(from: baseline) != nil, "Unavailable window evidence must never count as a passed layout check")
        precondition(changedWindows.change(from: baseline) != nil)
        precondition(StandbySnapshot(layout: [], windows: baseline.windows).change(from: baseline) != nil)
        try setState()
        var samples = 0
        let moved = StandbyVerification(brightness: brightness, holdDuration: 0.05, timeout: 6, snapshot: {
            samples += 1
            return samples == 1 ? baseline : changedWindows
        })
        result = nil
        moved.start(display) { result = $0 }
        waitUntil { result != nil }
        precondition(!result!.needsConfirmation && result!.mode == nil)
        assertRestored()

        // A failed wake can never be accepted and keeps a durable recovery journal.
        try setState(["wakeFailure": true])
        let failedWake = StandbyVerification(brightness: brightness, holdDuration: 0.05, timeout: 10, snapshot: { baseline })
        result = nil
        failedWake.start(display) { result = $0 }
        waitUntil { result != nil }
        precondition(!result!.needsConfirmation && !result!.recoveryErrors.isEmpty && !entries().isEmpty)
        print("Standby verification: timed wake, fallback, cancellation, deadline, desktop stability and failed recovery passed")
    }
}
