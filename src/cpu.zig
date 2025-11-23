const std = @import("std");
const font = @import("font.zig").font;
const bits = @import("bits.zig");
const raylib = @import("raylib");

const Allocator = std.mem.Allocator;
const log = std.log;

const characters_offset: u8 = 0x050;
const program_offset: u12 = 0x200;

const CpuError = error{
    UnknownInstruction,
};

const display_width = 64;
const display_height = 32;
const scale = 12;

pub const Cpu = struct {
    // Memory
    ram: [4096]u8,
    stack: [16]u16,

    // Specific registers
    sp: u8,
    pc: u16,
    i: u16,
    delay_timer: u8,
    sound_timer: u8,

    // General registers
    v0: u8,
    v1: u8,
    v2: u8,
    v3: u8,
    v4: u8,
    v5: u8,
    v6: u8,
    v7: u8,
    v8: u8,
    v9: u8,
    va: u8,
    vb: u8,
    vc: u8,
    vd: u8,
    ve: u8,
    vf: u8,

    // Other
    display: [display_height][display_width]bool,

    pub fn init(program: []const u8) Cpu {
        var self = std.mem.zeroes(Cpu);
        self.ram[characters_offset .. characters_offset + font.len].* = font;
        @memcpy(self.ram[program_offset .. program_offset + program.len], program);
        self.pc = program_offset;
        return self;
    }

    pub fn run(self: *Cpu) !void {
        raylib.initWindow(64 * scale, 32 * scale, "Chip-8");
        defer raylib.closeWindow();

        while (!raylib.windowShouldClose()) {
            const instruction = self.fetch();
            try self.decodeExecute(instruction);


            raylib.beginDrawing();
            for (0..display_height) |i| {
                for (0..display_width) |j| {
                    const iCasted: i32 = @intCast(i);
                    const jCasted: i32 = @intCast(j);
                    const color = if (self.display[i][j]) raylib.Color.white else raylib.Color.black;
                    raylib.drawRectangle(jCasted * scale, iCasted * scale, scale, scale, color);
                }
            }
            raylib.endDrawing();

            std.Thread.sleep(std.time.ns_per_ms * 500);
        }
    }

    fn getRegister(self: *Cpu, reg: u4) *u8 {
        return switch (reg) {
            0x0 => &self.v0,
            0x1 => &self.v1,
            0x2 => &self.v2,
            0x3 => &self.v3,
            0x4 => &self.v4,
            0x5 => &self.v5,
            0x6 => &self.v6,
            0x7 => &self.v7,
            0x8 => &self.v8,
            0x9 => &self.v9,
            0xa => &self.va,
            0xb => &self.vb,
            0xc => &self.vc,
            0xd => &self.vd,
            0xe => &self.ve,
            0xf => &self.vf,
        };
    }

    fn getRegisterValue(self: *Cpu, reg: u4) u8 {
        return self.getRegister(reg).*;
    }

    // Fetch/Decode/Execute
    fn fetch(self: *Cpu) u16 {
        const first: u16 = @intCast(self.ram[self.pc]);
        const second = self.ram[self.pc + 1];
        const value = (first << 8) + second;
        self.pc += 2;
        log.info("FETCH: 0x{X} at 0x{X} | PC: 0x{X}", .{ value, self.pc - 2, self.pc });
        return value;
    }

    fn sliceInstruction(comptime T: type, instruction: u16, offset: u4) T {
        return bits.slice(u16, T, instruction, offset);
    }

    fn decodeExecute(self: *Cpu, instruction: u16) !void {
        const instructionId = sliceInstruction(u4, instruction, 0);
        switch (instructionId) {
            0x0 => {
                if (sliceInstruction(u12, instruction, 4) != 0x0e0) {
                    log.err("Reached unknown instruction: 0x{X}", .{instruction});
                    return CpuError.UnknownInstruction;
                }
                self.instClearScreen();
            },
            0x1 => self.instJump(sliceInstruction(u12, instruction, 4)),
            0x6 => self.instSet(sliceInstruction(u4, instruction, 4), sliceInstruction(u8, instruction, 8)),
            0x7 => self.instAdd(sliceInstruction(u4, instruction, 4), sliceInstruction(u8, instruction, 8)),
            0xA => self.instSetIndex(sliceInstruction(u12, instruction, 4)),
            0xD => self.instDraw(sliceInstruction(u4, instruction, 4), sliceInstruction(u4, instruction, 8), sliceInstruction(u4, instruction, 12)),
            else => {
                log.err("Reached unknown instruction: 0x{X}", .{instruction});
                return CpuError.UnknownInstruction;
            },
        }
    }

    // Instructions
    fn instClearScreen(self: *Cpu) void {
        for (self.display) |row| {
            @memset(@constCast(&row), false);
        }
    }

    fn instJump(self: *Cpu, dest: u16) void {
        self.pc = dest;
    }

    fn instSet(self: *Cpu, reg: u4, value: u8) void {
        const register = self.getRegister(reg);
        register.* = value;
    }

    fn instAdd(self: *Cpu, reg: u4, value: u8) void {
        const register = self.getRegister(reg);
        register.* += value;
    }

    fn instSetIndex(self: *Cpu, value: u16) void {
        self.i = value;
    }

    fn instDraw(self: *Cpu, regX: u4, regY: u4, height: u4) void {
        const regXValue = self.getRegisterValue(regX);
        const regYValue = self.getRegisterValue(regY);
        const x = regXValue % 64;
        const y = regYValue % 32;
        self.vf = 0;

        for (0..height) |i| {
            if (y + i >= 32) {
                break;
            }

            const value = self.ram[self.i + i];
            for (0..8) |j| {
                if (x + j >= 64) {
                    break;
                }

                const on: u1 = bits.slice(u8, u1, value, @intCast(j));
                if (on == 0) {
                    continue;
                }

                const currentPixel = &self.display[y + i][x + j];
                if (currentPixel.* == false) {
                    currentPixel.* = true;
                } else {
                    currentPixel.* = false;
                    self.vf = 1;
                }
            }
        }
    }
};
