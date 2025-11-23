const std = @import("std");
const bits = @import("bits.zig");
const Cpu = @import("cpu.zig").Cpu;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.args();
    defer args.deinit();

    _ = args.skip();
    const path = args.next();
    if (path == null){
        std.debug.print("No argument provided\n", .{});
        return;
    }

    const file = try std.fs.cwd().openFile(path.?, .{});
    defer file.close();

    const stat = try file.stat();
    const buf: []u8 = try file.readToEndAlloc(allocator, stat.size);
    var cpu = Cpu.init(buf);
    try cpu.run();
}
