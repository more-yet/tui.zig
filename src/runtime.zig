const posix = @import("runtime/posix.zig");

pub const Event = posix.Event;
pub const InputTimeouts = posix.InputTimeouts;
pub const Notifier = posix.Notifier;
pub const Options = posix.Options;
pub const Posix = posix.Posix;
pub const PollInterest = posix.PollInterest;
pub const PollSlot = posix.PollSlot;
pub const PollSource = posix.PollSource;
pub const ReadyEvent = posix.ReadyEvent;
pub const requiredPollSlots = posix.requiredPollSlots;
pub const ResizeSource = posix.ResizeSource;
pub const Signal = posix.Signal;
pub const SignalOptions = posix.SignalOptions;
pub const SignalSource = posix.SignalSource;
pub const TimerChange = posix.TimerChange;
pub const TimerEvent = posix.TimerEvent;
pub const TimerId = posix.TimerId;
pub const TimerSlot = posix.TimerSlot;

test {
    _ = posix;
}
