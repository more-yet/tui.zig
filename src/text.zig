pub const unicode_version = @import("text/unicode_17.zig").version;
pub const GraphemeIterator = @import("text/grapheme.zig").Iterator;
pub const Grapheme = @import("text/grapheme.zig").Cluster;
pub const WidthProfile = @import("text/grapheme.zig").WidthProfile;
pub const max_grapheme_bytes = @import("text/grapheme.zig").max_cluster_bytes;
pub const graphemeWidth = @import("text/grapheme.zig").width;
pub const TextAlignment = @import("text/line.zig").Alignment;
pub const TextOverflow = @import("text/line.zig").Overflow;
pub const LineOptions = @import("text/line.zig").Options;
pub const LineLayout = @import("text/line.zig").Layout;
pub const LineBreakBoundary = @import("text/line_break.zig").Boundary;
pub const LineBreakIterator = @import("text/line_break.zig").Iterator;
pub const LineBreakKind = @import("text/line_break.zig").Kind;
pub const WordBreakBoundary = @import("text/word_break.zig").Boundary;
pub const WordBreakIterator = @import("text/word_break.zig").Iterator;
pub const measureLine = @import("text/line.zig").measure;
pub const layoutLine = @import("text/line.zig").layout;
pub const WrapIterator = @import("text/wrap.zig").Iterator;
pub const WrappedLine = @import("text/wrap.zig").Line;
pub const WrapError = @import("text/wrap.zig").Error;

test {
    _ = @import("text/grapheme.zig");
    _ = @import("text/line.zig");
    _ = @import("text/line_break.zig");
    _ = @import("text/word_break.zig");
    _ = @import("text/wrap.zig");
}
