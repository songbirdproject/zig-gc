const std = @import("std");
const gc = @import("gc");

pub fn main() !void {
    var alloc = gc.allocator();

    // We'll write to the terminal
    var stdout = std.fs.File.stdout().writer(&.{});

    // Compare the output by enabling/disabling
    // gc.disable();

    // Allocate a bunch of stuff and never free it, outputting
    // the heap size along the way. When the GC is enabled,
    // it'll stabilize at a certain size.
    var i: u64 = 0;
    while (i < 10_000_000) : (i += 1) {
        // This is all really ugly but its not idiomatic Zig code so
        // just take this at face value. We're doing weird stuff here
        // to show that we're collecting garbage.
        const p: **u8 = @ptrCast(try alloc.alloc(*u8, @sizeOf(*u8)));
        const q = try alloc.alloc(u8, @sizeOf(u8));
        p.* = @ptrCast(q);
        _ = alloc.resize(q, 2 * @sizeOf(u8));

        if (i % 100_000 == 0) {
            const heap = gc.getStatistics().heapSize();
            try stdout.interface.print("heap size: {d}\n", .{heap});
        }
    }
}
