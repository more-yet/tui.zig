const posix = @import("subprocess/posix.zig");

pub const Command = posix.Command;
pub const Exit = posix.Exit;
pub const PtyOptions = posix.PtyOptions;
pub const PtyProcess = posix.PtyProcess;
pub const ReadResult = posix.ReadResult;
pub const SpawnStorage = posix.SpawnStorage;
pub const WaitEvent = posix.WaitEvent;
pub const WriteResult = posix.WriteResult;

test {
    _ = posix;
}
