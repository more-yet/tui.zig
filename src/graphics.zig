//! Kitty graphics encoding; the caller supplies payloads and writes output.
//! Keep local files/shared memory alive until a correlated terminal reply.

pub const kitty = @import("graphics/kitty.zig");
pub const Sender = @import("graphics/sender.zig").Sender;
pub const SenderLimits = @import("graphics/sender.zig").Limits;
pub const SenderData = @import("graphics/sender.zig").Data;
pub const placeholder = @import("graphics/placeholder.zig");
