//! Bounded client-side support for the Kitty graphics protocol.
//!
//! Commands contain only wire metadata. `Sender` borrows caller-owned payload
//! or local-name bytes until completion/cancellation, exposes one stable output
//! suffix, and performs no I/O, allocation, compression, or decoding. Accepted
//! output is not proof of terminal execution; correlate borrowed `kitty.Reply`
//! values and retain local resources until the terminal has read them.

pub const kitty = @import("graphics/kitty.zig");
pub const Sender = @import("graphics/sender.zig").Sender;
pub const SenderLimits = @import("graphics/sender.zig").Limits;
pub const SenderData = @import("graphics/sender.zig").Data;
pub const placeholder = @import("graphics/placeholder.zig");
