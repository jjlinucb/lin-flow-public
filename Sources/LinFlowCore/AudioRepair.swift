import Foundation

/// When the Mac's audio daemon, coreaudiod, wedges, nothing on the machine can open a
/// microphone. On 2026-09-30 it happened after an input switch during a meeting note: first
/// 9 s of digital zeros from the built-in mic, then every press failed with avfaudio error
/// 1937010544 ('stop', kAudioHardwareNotRunningError), and a fresh engine per take did not
/// help. `sudo killall coreaudiod` fixed it at once. Lin Flow cannot run that itself, since it
/// needs John's password, so it recognises the state and hands him the command.
public enum AudioRepair {
    /// 'stop': the audio hardware is not running.
    public static let notRunningCode = 1_937_010_544

    public static func isStuck(_ error: Error) -> Bool {
        (error as NSError).code == notRunningCode
    }

    /// Counts takes in a row that came back as pure digital silence. One can be a muted
    /// headset; two in a row, with the rest of the app working, is how the wedge began.
    public struct SilentStreak {
        public private(set) var count = 0
        public init() {}
        /// Returns true on the take that makes the streak long enough to call it stuck.
        public mutating func record(dead: Bool) -> Bool {
            count = dead ? count + 1 : 0
            return count == 2
        }
    }

    public static let script = """
    #!/bin/bash
    echo "Restarting the Mac's audio for Lin Flow."
    echo "Type your Mac password and press Enter. It stays hidden as you type."
    if sudo killall coreaudiod; then
      echo "Done. Press the talk key and try again. You can close this window."
    else
      echo "That did not work. Restarting the Mac fixes it too."
    fi

    """

    /// Writes the script as an executable `.command` file, which Terminal opens and runs.
    @discardableResult
    public static func writeScript(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("Restart Mac audio.command")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
