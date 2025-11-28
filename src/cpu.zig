const std = @import("std");
const font = @import("font.zig").font;
const bits = @import("bits.zig");
const raylib = @import("raylib");

const Allocator = std.mem.Allocator;
const log = std.log;

const characters_offset: u8 = 0x050;
const program_offset: u12 = 0x200;

const CpuError = error{ UnknownInstruction, OpCodeError };

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
    random: ?std.Random,

    pub fn init(program: []const u8) !Cpu {
        var self = std.mem.zeroes(Cpu);
        self.ram[characters_offset .. characters_offset + font.len].* = font;
        @memcpy(self.ram[program_offset .. program_offset + program.len], program);
        self.pc = program_offset;

        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        var prgn = std.Random.DefaultPrng.init(seed);
        self.random = prgn.random();

        return self;
    }

    pub fn run(self: *Cpu) !void {
        raylib.initWindow(64 * scale, 32 * scale, "Chip-8");
        defer raylib.closeWindow();

        const timerDelay: f32 = 1.0 / 60.0; // 60hz
        const instructionDelay: f32 = 1.0 / 700.0; // 700hz

        var nextTimerUpdate: f64 = timerDelay;
        var nextInstructionUpdate: f64 = instructionDelay;

        while (!raylib.windowShouldClose()) {
            const time = raylib.getTime();
            if (time >= nextTimerUpdate) {
                if (self.delay_timer > 0) {
                    self.delay_timer -= 1;
                }

                if (self.sound_timer > 0) {
                    self.delay_timer -= 1;
                }

                nextTimerUpdate = time + timerDelay;
            }

            if (time >= nextInstructionUpdate) {
                const instruction = self.fetch();
                try self.decodeExecute(instruction);
                nextInstructionUpdate = time + instructionDelay;
            }

            raylib.beginDrawing();
            for (0..display_height) |i| {
                for (0..display_width) |j| {
                    const iCasted: i32 = @intCast(i);
                    const jCasted: i32 = @intCast(j);
                    const color = if (self.display[i][j]) raylib.Color.white else raylib.Color.black;
                    raylib.drawRectangle(jCasted * scale, iCasted * scale, scale, scale, color);
                }
            }
            // TODO: Add sound
            if (self.sound_timer > 0) {
                raylib.drawText("[PLAYING SOUND]", 5, 5, 20, raylib.Color.white);
            }
            raylib.endDrawing();
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

    fn getKey(keyVal: u4) raylib.KeyboardKey {
        return switch (keyVal) {
            0x0 => raylib.KeyboardKey.x,
            0x1 => raylib.KeyboardKey.one,
            0x2 => raylib.KeyboardKey.two,
            0x3 => raylib.KeyboardKey.three,
            0x4 => raylib.KeyboardKey.q,
            0x5 => raylib.KeyboardKey.w,
            0x6 => raylib.KeyboardKey.e,
            0x7 => raylib.KeyboardKey.a,
            0x8 => raylib.KeyboardKey.s,
            0x9 => raylib.KeyboardKey.d,
            0xa => raylib.KeyboardKey.z,
            0xb => raylib.KeyboardKey.c,
            0xc => raylib.KeyboardKey.four,
            0xd => raylib.KeyboardKey.r,
            0xe => raylib.KeyboardKey.f,
            0xf => raylib.KeyboardKey.v,
        };
    }

    fn isKeyDown(keyVal: u4) bool {
        return raylib.isKeyDown(getKey(keyVal));
    }

    fn getPressedKey() ?u4 {
        for (0..0xF + 1) |i| {
            const val: u4 = @intCast(i);
            if (isKeyDown(@intCast(val))) {
                return val;
            }
        }

        return null;
    }

    fn stackPush(self: *Cpu, value: u16) void {
        self.stack[self.sp] = value;
        self.sp += 1;
    }

    fn stackPop(self: *Cpu) u16 {
        self.sp -= 1;
        return self.stack[self.sp];
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
                const subInstruction = sliceInstruction(u12, instruction, 4);
                switch (subInstruction) {
                    0x0E0 => self.instClearScreen(),
                    0x0EE => self.instReturn(),
                    else => {
                        log.err("Reached unknown instruction: 0x0{X}", .{subInstruction});
                        return CpuError.UnknownInstruction;
                    },
                }
            },
            0x1 => self.instJump(sliceInstruction(u12, instruction, 4)),
            0x2 => self.instCallSubroutine(sliceInstruction(u12, instruction, 4)),
            0x3 => self.instSkipIfEqual(sliceInstruction(u4, instruction, 4), sliceInstruction(u8, instruction, 8)),
            0x4 => self.instSkipIfNotEqual(sliceInstruction(u4, instruction, 4), sliceInstruction(u8, instruction, 8)),
            0x5 => self.instSkipIfRegsEqual(sliceInstruction(u4, instruction, 4), sliceInstruction(u4, instruction, 8)),
            0x6 => self.instSet(sliceInstruction(u4, instruction, 4), sliceInstruction(u8, instruction, 8)),
            0x7 => self.instAdd(sliceInstruction(u4, instruction, 4), sliceInstruction(u8, instruction, 8)),
            0x8 => try self.instLogicAndArithmetic(sliceInstruction(u4, instruction, 4), sliceInstruction(u4, instruction, 8), sliceInstruction(u4, instruction, 12)),
            0x9 => self.instSkipIfRegsNotEqual(sliceInstruction(u4, instruction, 4), sliceInstruction(u4, instruction, 8)),
            0xA => self.instSetIndex(sliceInstruction(u12, instruction, 4)),
            0xB => self.instJumpWithOffset(sliceInstruction(u12, instruction, 4)),
            0xC => self.instRandom(sliceInstruction(u4, instruction, 4), sliceInstruction(u8, instruction, 8)),
            0xD => self.instDraw(sliceInstruction(u4, instruction, 4), sliceInstruction(u4, instruction, 8), sliceInstruction(u4, instruction, 12)),
            0xE => {
                switch (sliceInstruction(u8, instruction, 8)) {
                    0x9E => self.instSkipIfKeyPressed(sliceInstruction(u4, instruction, 4)),
                    0xA1 => self.instSkipIfKeyNotPressed(sliceInstruction(u4, instruction, 4)),
                    else => {
                        log.err("Reached unknown instruction: 0x{X}", .{instruction});
                        return CpuError.UnknownInstruction;
                    },
                }
            },
            0xF => try self.instFInstuctions(sliceInstruction(u4, instruction, 4), sliceInstruction(u8, instruction, 8)),
        }
    }

    // Instructions
    // 00E0
    fn instClearScreen(self: *Cpu) void {
        for (self.display) |row| {
            @memset(@constCast(&row), false);
        }
    }

    // 00EE
    fn instReturn(self: *Cpu) void {
        self.pc = self.stackPop();
    }

    // 1NNN
    fn instJump(self: *Cpu, dest: u16) void {
        self.pc = dest;
    }

    // 2NNN
    fn instCallSubroutine(self: *Cpu, dest: u12) void {
        self.stackPush(self.pc);
        self.pc = dest;
    }

    // 3XNN
    fn instSkipIfEqual(self: *Cpu, reg: u4, value: u8) void {
        const register = self.getRegister(reg);
        if (register.* == value) {
            self.pc += 2;
        }
    }

    // 4XNN
    fn instSkipIfNotEqual(self: *Cpu, reg: u4, value: u8) void {
        const register = self.getRegister(reg);
        if (register.* != value) {
            self.pc += 2;
        }
    }

    // 5XY0
    fn instSkipIfRegsEqual(self: *Cpu, regX: u4, regY: u4) void {
        const registerX = self.getRegister(regX);
        const registerY = self.getRegister(regY);

        if (registerX.* == registerY.*) {
            self.pc += 2;
        }
    }

    //6XNN
    fn instSet(self: *Cpu, reg: u4, value: u8) void {
        const register = self.getRegister(reg);
        register.* = value;
    }

    // 7XNN
    fn instAdd(self: *Cpu, reg: u4, value: u8) void {
        const register = self.getRegister(reg);
        register.* +%= value;
    }

    // 8XYI
    fn instLogicAndArithmetic(self: *Cpu, regX: u4, regY: u4, subInst: u4) !void {
        const registerX = self.getRegister(regX);
        const registerY = self.getRegister(regY);

        switch (subInst) {
            0x0 => {
                registerX.* = registerY.*;
            },
            0x1 => {
                registerX.* |= registerY.*;
            },
            0x2 => {
                registerX.* &= registerY.*;
            },
            0x3 => {
                registerX.* ^= registerY.*;
            },
            0x4 => {
                if (registerX.* +% registerY.* > 255) {
                    self.vf = 1;
                }
                registerX.* +%= registerY.*;
            },
            0x5 => {
                registerX.* -%= registerY.*;
            },
            0x6 => {
                registerX.* = registerY.*;
                const shiftedBit = registerX.* & 0b0000_0001;
                self.vf = shiftedBit;
                registerX.* >>= 1;
            },
            0x7 => {
                if (registerX.* > registerY.*) {
                    registerX.* = 0;
                    return;
                }

                registerX.* = registerY.* - registerX.*;
            },
            0xE => {
                registerX.* = registerY.*;
                const shiftedBit = registerX.* & 0b1000_0000;
                self.vf = shiftedBit;
                registerX.* <<= 1;
            },
            else => {
                log.err("Reached unknown logic/arithmetic instruction: 0x8XY{X}", .{subInst});
                return CpuError.UnknownInstruction;
            },
        }
    }

    // 9XY0
    fn instSkipIfRegsNotEqual(self: *Cpu, regX: u4, regY: u4) void {
        const registerX = self.getRegister(regX);
        const registerY = self.getRegister(regY);

        if (registerX.* != registerY.*) {
            self.pc += 2;
        }
    }

    // ANNN
    fn instSetIndex(self: *Cpu, value: u16) void {
        self.i = value;
    }

    // BNNN (original implementation)
    fn instJumpWithOffset(self: *Cpu, address: u12) void {
        self.pc = address + self.v0;
    }

    // CXNN
    fn instRandom(self: *Cpu, reg: u4, value: u8) void {
        const register = self.getRegister(reg);
        const randomNumber = self.random.?.int(u8);
        register.* = randomNumber & value;
    }

    // DXYN
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

    // EX9E
    fn instSkipIfKeyPressed(self: *Cpu, reg: u4) void {
        const register = self.getRegister(reg);
        std.debug.assert(register.* <= 0xF);

        if (isKeyDown(@intCast(register.*))) {
            self.pc += 2;
        }
    }

    // EXA1
    fn instSkipIfKeyNotPressed(self: *Cpu, reg: u4) void {
        const register = self.getRegister(reg);
        std.debug.assert(register.* <= 0xF);

        if (!isKeyDown(@intCast(register.*))) {
            self.pc += 2;
        }
    }

    // FNNN
    fn instFInstuctions(self: *Cpu, reg: u4, subInst: u8) !void {
        switch (subInst) {
            0x07 => self.instSetToDelayTimer(reg),
            0x15 => self.instSetDelayTimer(reg),
            0x18 => self.instSetSoundTimer(reg),
            0x1E => self.instAddToIndex(reg),
            0x0A => self.instGetKey(reg),
            0x29 => self.instFontCharacter(reg),
            0x33 => self.instDecimalConversion(reg),
            0x55 => self.instStoreMemory(reg),
            0x65 => self.instLoadMemeory(reg),
            else => {
                log.err("Reached unknown F instruction: 0xF{X}{X}", .{ reg, subInst });
                return CpuError.UnknownInstruction;
            },
        }
    }

    // FX07
    fn instSetToDelayTimer(self: *Cpu, reg: u4) void {
        const register = self.getRegister(reg);
        register.* = self.delay_timer;
    }

    // FX15
    fn instSetDelayTimer(self: *Cpu, reg: u4) void {
        const register = self.getRegister(reg);
        self.delay_timer = register.*;
    }

    // FX18
    fn instSetSoundTimer(self: *Cpu, reg: u4) void {
        const register = self.getRegister(reg);
        self.sound_timer = register.*;
    }

    // FXE1
    fn instAddToIndex(self: *Cpu, reg: u4) void {
        const register = self.getRegister(reg);
        self.i += register.*;
        if (self.i < register.*) {
            self.vf = 0x1;
        }
    }

    // FX0A
    fn instGetKey(self: *Cpu, reg: u4) void {
        const pressedKey: ?u4 = getPressedKey();
        if (pressedKey == null) {
            self.pc -= 2;
            return;
        }

        const register = self.getRegister(reg);
        register.* = pressedKey.?;
    }

    // FX0A
    fn instFontCharacter(self: *Cpu, reg: u4) void {
        const register = self.getRegister(reg);
        self.i = self.ram[characters_offset + (5 * register.*)];
    }

    // FX33
    fn instDecimalConversion(self: *Cpu, reg: u4) void {
        const register = self.getRegister(reg);
        const value = register.*;
        const hundreds = value / 100;
        const tens = (value / 10) % 10;
        const ones = value % 10;

        self.ram[self.i] = hundreds;
        self.ram[self.i + 1] = tens;
        self.ram[self.i + 2] = ones;
    }

    // FX55
    fn instStoreMemory(self: *Cpu, reg: u4) void {
        const maxReg: u8 = @intCast(reg);
        for (0..maxReg + 1) |i| {
            const val: u4 = @truncate(i);
            const currentRegister = self.getRegister(val);
            self.ram[self.i + val] = currentRegister.*;
        }
    }

    // FX65
    fn instLoadMemeory(self: *Cpu, reg: u4) void {
        const maxReg: u8 = @intCast(reg);
        for (0..maxReg + 1) |i| {
            const val: u4 = @truncate(i);
            const currentRegister = self.getRegister(val);
            currentRegister.* = self.ram[self.i + val];
        }
    }
};
