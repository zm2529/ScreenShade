import Cocoa

@main struct BrightnessTests {
    static func main() throws {
        guard let display = DisplayIdentity.connected().first else { fatalError("Tests require an active display identity") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenshade-recovery-\(UUID())")
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
        if command=='set-power':
            value=int(sys.argv[3])
            if value!=1:
                records=json.loads((base/'recovery.json').read_text())
                assert records[0]['power']==1 and records[0]['value']==40
                (base/'entered-write').touch()
                time.sleep(s.get('delay',0))
            if s.get('wakeFailure') and value==1: sys.exit(68)
            if not s.get('unsupported'): s['power']=value
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
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("entered-write"))
        }
        func readState() -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any] }
        func entries() -> [[String: Any]] { try! JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [[String: Any]] }
        func awaitResult(_ action: (@escaping ([String]) -> Void) -> Void) -> [String] {
            var result: [String]?
            action { result = $0 }
            let deadline = Date().addingTimeInterval(15)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(result != nil, "Recovery timed out")
            return result!
        }
        let brightness = Brightness(journal: journal, helper: helper)
        try setState()
        let messages = awaitResult { brightness.dim([display], standbyModes: [display.uuid: 4], completion: $0) }
        precondition(messages.contains { $0.contains("已确认电源状态") })
        precondition(readState()["power"] as? Int == 4 && readState()["brightness"] as? Int == 40)
        precondition(entries().first?["power"] as? Int == 1)
        precondition(awaitResult { brightness.restore(completion: $0) }.isEmpty)
        precondition(readState()["power"] as? Int == 1 && readState()["brightness"] as? Int == 40 && entries().isEmpty)

        try setState(["unsupported": true])
        _ = awaitResult { brightness.dim([display], standbyModes: [display.uuid: 4], completion: $0) }
        precondition(readState()["brightness"] as? Int == 0 && entries().first?["power"] == nil)
        precondition(awaitResult { brightness.restore(completion: $0) }.isEmpty)

        // Old brightness-only journals remain readable after an upgrade.
        let old: [[String: Any]] = [["display": ["uuid": display.uuid, "name": display.name, "displayID": display.displayID], "value": 55]]
        try JSONSerialization.data(withJSONObject: old).write(to: journal)
        precondition(awaitResult { brightness.restore(completion: $0) }.isEmpty)
        precondition(readState()["brightness"] as? Int == 55 && entries().isEmpty)

        // Failed wake keeps a durable recovery record for a later launch.
        try setState()
        _ = awaitResult { brightness.dim([display], standbyModes: [display.uuid: 4], completion: $0) }
        var failed = readState(); failed["wakeFailure"] = true
        try JSONSerialization.data(withJSONObject: failed).write(to: state)
        precondition(!awaitResult { brightness.restore(completion: $0) }.isEmpty && !entries().isEmpty)
        failed["wakeFailure"] = false
        try JSONSerialization.data(withJSONObject: failed).write(to: state)
        let restarted = Brightness(journal: journal, helper: helper)
        precondition(awaitResult { restarted.restore(completion: $0) }.isEmpty && entries().isEmpty)

        // Cancel while the write is in flight: the queued restore must wake it.
        try setState(["delay": 0.4])
        var staleCompletion = false
        brightness.dim([display], standbyModes: [display.uuid: 4]) { _ in staleCompletion = true }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("entered-write").path) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("entered-write").path))
        precondition(awaitResult { brightness.restore(completion: $0) }.isEmpty)
        precondition(!staleCompletion && readState()["power"] as? Int == 1 && entries().isEmpty)

        let layout = HardwareStandby.currentLayout()
        let config = HardwareStandby.Configuration(layout: layout, modes: [display.uuid: 4, "unknown": 4])
        precondition(config.validatedModes(for: layout) == [display.uuid: 4])
        precondition(config.validatedModes(for: []) == [:])
        precondition(HardwareStandby.Configuration(layout: layout, modes: [display.uuid: 5]).validatedModes(for: layout).isEmpty)
        let originalSelections = HardwareStandby.selectedDisplays
        defer { HardwareStandby.selectedDisplays = originalSelections }
        HardwareStandby.selectedDisplays = []
        HardwareStandby.setEnabled(true, for: "test-display-a")
        HardwareStandby.setEnabled(true, for: "test-display-b")
        HardwareStandby.setEnabled(false, for: "test-display-a")
        precondition(HardwareStandby.selectedDisplays == ["test-display-b"], "Each display must retain its own selection")
        HardwareStandby.setEnabled(false, for: "test-display-b")
        precondition(HardwareStandby.selectedDisplays.isEmpty)
        print("Standby recovery: persist-before-write, fallback, legacy journal, failed wake, restart, cancellation and layout gates passed")
    }
}
