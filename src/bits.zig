const std = @import("std");
pub fn slice(comptime Input: type, comptime Output: type, number: Input, offset: u4) Output {
    comptime {
        const inputInfo = @typeInfo(Input);
        std.debug.assert(inputInfo == .int);
        std.debug.assert(inputInfo.int.signedness == .unsigned);

        const outputInfo = @typeInfo(Output);
        std.debug.assert(outputInfo == .int);
        std.debug.assert(outputInfo.int.signedness == .unsigned);

        std.debug.assert(inputInfo.int.bits >= outputInfo.int.bits);
    }

    const inputBits = @typeInfo(Input).int.bits;
    const outputBits = @typeInfo(Output).int.bits;

    const casted: u64 = @intCast(number);
    const shifted: u64 = casted << offset;
    const result = shifted >> (inputBits - outputBits);

    return @truncate(result);
}
