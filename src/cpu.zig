const std = @import("std");

const Cpu = @This();

pub const Error = error{InvalidOpcode};

pub const StepResult = struct {
    cycles: u8,
};

pub const Flag = struct {
    pub const z: u8 = 0x80;
    pub const n: u8 = 0x40;
    pub const h: u8 = 0x20;
    pub const c: u8 = 0x10;
};

a: u8 = 0,
f: u8 = 0,
b: u8 = 0,
c: u8 = 0,
d: u8 = 0,
e: u8 = 0,
h: u8 = 0,
l: u8 = 0,
sp: u16 = 0,
pc: u16 = 0,
cycles: u64 = 0,
ime: bool = false,
ime_scheduled: bool = false,
ime_pending: bool = false,
halted: bool = false,
stopped: bool = false,
halt_bug: bool = false,
interrupt_pending: bool = false,
step_elapsed_cycles: u8 = 0,

pub fn reset(self: *Cpu) void {
    self.* = .{};
}

pub fn step(self: *Cpu, bus: anytype, interrupt_enable: u8, interrupt_flags: *u8) Error!StepResult {
    self.step_elapsed_cycles = 0;
    const pending = interrupt_enable & interrupt_flags.* & 0x1f;
    self.interrupt_pending = pending != 0;
    if (pending != 0) {
        self.halted = false;
        self.stopped = false;
        if (self.ime) return .{ .cycles = self.serviceInterrupt(bus, interrupt_flags) };
    }

    if (self.halted or self.stopped) {
        self.tick(bus, 4);
        self.cycles += 4;
        return .{ .cycles = 4 };
    }

    const initial_pc = self.pc;
    const opcode = self.fetch(bus);
    const used = self.execute(bus, opcode) catch |err| {
        self.pc = initial_pc;
        return err;
    };
    self.tickRemainder(bus, used);
    self.advanceIme();
    self.f &= 0xf0;
    self.cycles += used;
    return .{ .cycles = used };
}

fn serviceInterrupt(self: *Cpu, bus: anytype, interrupt_flags: *u8) u8 {
    self.ime = false;
    self.ime_scheduled = false;
    self.ime_pending = false;

    const pc = self.pc;
    self.tick(bus, 8);
    self.sp -%= 1;
    self.writeBus(bus, self.sp, @truncate(pc >> 8));

    const enabled_after_high_push = bus.read(0xffff) & interrupt_flags.* & 0x1f;
    if (enabled_after_high_push == 0) {
        self.pc = 0;
        self.tickRemainder(bus, 20);
        self.cycles += 20;
        return 20;
    }

    const index: u3 = @intCast(@ctz(enabled_after_high_push));
    self.sp -%= 1;
    self.writeBus(bus, self.sp, @truncate(pc));
    interrupt_flags.* &= ~(@as(u8, 1) << index);
    self.pc = 0x40 + @as(u16, index) * 8;
    self.tickRemainder(bus, 20);
    self.cycles += 20;
    return 20;
}

fn advanceIme(self: *Cpu) void {
    if (self.ime_pending) {
        self.ime = true;
        self.ime_pending = false;
    }
    if (self.ime_scheduled) {
        self.ime_scheduled = false;
        self.ime_pending = true;
    }
}

fn execute(self: *Cpu, bus: anytype, opcode: u8) Error!u8 {
    const x = opcode >> 6;
    const y = (opcode >> 3) & 7;
    const z = opcode & 7;
    const p = y >> 1;
    const q = y & 1;

    return switch (x) {
        0 => switch (z) {
            0 => switch (y) {
                0 => 4,
                1 => blk: {
                    const address = self.fetch16(bus);
                    self.writeBus(bus, address, @truncate(self.sp));
                    self.writeBus(bus, address +% 1, @truncate(self.sp >> 8));
                    break :blk 20;
                },
                2 => blk: {
                    _ = self.fetch(bus);
                    self.stopped = true;
                    break :blk 4;
                },
                3 => blk: {
                    self.jr(self.fetch(bus));
                    break :blk 12;
                },
                4...7 => blk: {
                    const offset = self.fetch(bus);
                    if (self.condition(y - 4)) {
                        self.jr(offset);
                        break :blk 12;
                    }
                    break :blk 8;
                },
                else => unreachable,
            },
            1 => if (q == 0) blk: {
                self.setRp(p, self.fetch16(bus));
                break :blk 12;
            } else blk: {
                self.addHl(self.getRp(p));
                break :blk 8;
            },
            2 => blk: {
                const address = switch (p) {
                    0 => self.bc(),
                    1 => self.de(),
                    2, 3 => self.hl(),
                    else => unreachable,
                };
                if (q == 0) {
                    self.writeBus(bus, address, self.a);
                } else {
                    self.a = self.readBus(bus, address);
                }
                if (p == 2) self.setHl(address +% 1);
                if (p == 3) self.setHl(address -% 1);
                break :blk 8;
            },
            3 => blk: {
                if (q == 0) self.setRp(p, self.getRp(p) +% 1) else self.setRp(p, self.getRp(p) -% 1);
                break :blk 8;
            },
            4 => blk: {
                const value = self.readR(bus, y);
                self.writeR(bus, y, self.inc8(value));
                break :blk if (y == 6) 12 else 4;
            },
            5 => blk: {
                const value = self.readR(bus, y);
                self.writeR(bus, y, self.dec8(value));
                break :blk if (y == 6) 12 else 4;
            },
            6 => blk: {
                self.writeR(bus, y, self.fetch(bus));
                break :blk if (y == 6) 12 else 8;
            },
            7 => switch (y) {
                0 => blk: {
                    self.a = self.rlc(self.a, false);
                    break :blk 4;
                },
                1 => blk: {
                    self.a = self.rrc(self.a, false);
                    break :blk 4;
                },
                2 => blk: {
                    self.a = self.rl(self.a, false);
                    break :blk 4;
                },
                3 => blk: {
                    self.a = self.rr(self.a, false);
                    break :blk 4;
                },
                4 => blk: {
                    self.daa();
                    break :blk 4;
                },
                5 => blk: {
                    self.a = ~self.a;
                    self.setFlag(Flag.n, true);
                    self.setFlag(Flag.h, true);
                    break :blk 4;
                },
                6 => blk: {
                    self.setFlag(Flag.n, false);
                    self.setFlag(Flag.h, false);
                    self.setFlag(Flag.c, true);
                    break :blk 4;
                },
                7 => blk: {
                    self.setFlag(Flag.n, false);
                    self.setFlag(Flag.h, false);
                    self.setFlag(Flag.c, !self.flag(Flag.c));
                    break :blk 4;
                },
                else => unreachable,
            },
            else => unreachable,
        },
        1 => blk: {
            if (y == 6 and z == 6) {
                if (!self.ime and self.interrupt_pending) {
                    self.halt_bug = true;
                } else {
                    self.halted = true;
                }
                break :blk 4;
            }
            self.writeR(bus, y, self.readR(bus, z));
            break :blk if (y == 6 or z == 6) 8 else 4;
        },
        2 => blk: {
            self.alu(y, self.readR(bus, z));
            break :blk if (z == 6) 8 else 4;
        },
        3 => switch (z) {
            0 => switch (y) {
                0...3 => blk: {
                    if (self.condition(y)) {
                        self.pc = self.pop16(bus);
                        break :blk 20;
                    }
                    break :blk 8;
                },
                4 => blk: {
                    self.writeBus(bus, 0xff00 | @as(u16, self.fetch(bus)), self.a);
                    break :blk 12;
                },
                5 => blk: {
                    const offset = self.fetch(bus);
                    self.sp = self.addSpOffset(offset);
                    break :blk 16;
                },
                6 => blk: {
                    self.a = self.readBus(bus, 0xff00 | @as(u16, self.fetch(bus)));
                    break :blk 12;
                },
                7 => blk: {
                    const offset = self.fetch(bus);
                    self.setHl(self.addSpOffset(offset));
                    break :blk 12;
                },
                else => unreachable,
            },
            1 => if (q == 0) blk: {
                self.setRp2(p, self.pop16(bus));
                break :blk 12;
            } else switch (p) {
                0 => blk: {
                    self.pc = self.pop16(bus);
                    break :blk 16;
                },
                1 => blk: {
                    self.pc = self.pop16(bus);
                    self.ime = true;
                    self.ime_scheduled = false;
                    self.ime_pending = false;
                    break :blk 16;
                },
                2 => blk: {
                    self.pc = self.hl();
                    break :blk 4;
                },
                3 => blk: {
                    self.sp = self.hl();
                    break :blk 8;
                },
                else => unreachable,
            },
            2 => switch (y) {
                0...3 => blk: {
                    const address = self.fetch16(bus);
                    if (self.condition(y)) {
                        self.pc = address;
                        break :blk 16;
                    }
                    break :blk 12;
                },
                4 => blk: {
                    self.writeBus(bus, 0xff00 | @as(u16, self.c), self.a);
                    break :blk 8;
                },
                5 => blk: {
                    self.writeBus(bus, self.fetch16(bus), self.a);
                    break :blk 16;
                },
                6 => blk: {
                    self.a = self.readBus(bus, 0xff00 | @as(u16, self.c));
                    break :blk 8;
                },
                7 => blk: {
                    self.a = self.readBus(bus, self.fetch16(bus));
                    break :blk 16;
                },
                else => unreachable,
            },
            3 => switch (y) {
                0 => blk: {
                    self.pc = self.fetch16(bus);
                    break :blk 16;
                },
                1 => self.executeCb(bus, self.fetch(bus)),
                6 => blk: {
                    self.ime = false;
                    self.ime_scheduled = false;
                    self.ime_pending = false;
                    break :blk 4;
                },
                7 => blk: {
                    self.ime_scheduled = true;
                    break :blk 4;
                },
                else => Error.InvalidOpcode,
            },
            4 => if (y < 4) blk: {
                const address = self.fetch16(bus);
                if (self.condition(y)) {
                    self.push16(bus, self.pc);
                    self.pc = address;
                    break :blk 24;
                }
                break :blk 12;
            } else Error.InvalidOpcode,
            5 => if (q == 0) blk: {
                self.push16(bus, self.getRp2(p));
                break :blk 16;
            } else if (p == 0) blk: {
                const address = self.fetch16(bus);
                self.push16(bus, self.pc);
                self.pc = address;
                break :blk 24;
            } else Error.InvalidOpcode,
            6 => blk: {
                self.alu(y, self.fetch(bus));
                break :blk 8;
            },
            7 => blk: {
                self.push16(bus, self.pc);
                self.pc = @as(u16, y) * 8;
                break :blk 16;
            },
            else => unreachable,
        },
        else => unreachable,
    };
}

fn executeCb(self: *Cpu, bus: anytype, opcode: u8) u8 {
    const x = opcode >> 6;
    const y = (opcode >> 3) & 7;
    const z = opcode & 7;
    const value = self.readR(bus, z);

    switch (x) {
        0 => {
            const result = switch (y) {
                0 => self.rlc(value, true),
                1 => self.rrc(value, true),
                2 => self.rl(value, true),
                3 => self.rr(value, true),
                4 => self.sla(value),
                5 => self.sra(value),
                6 => self.swap(value),
                7 => self.srl(value),
                else => unreachable,
            };
            self.writeR(bus, z, result);
        },
        1 => {
            self.setFlag(Flag.z, (value & (@as(u8, 1) << @intCast(y))) == 0);
            self.setFlag(Flag.n, false);
            self.setFlag(Flag.h, true);
        },
        2 => self.writeR(bus, z, value & ~(@as(u8, 1) << @intCast(y))),
        3 => self.writeR(bus, z, value | (@as(u8, 1) << @intCast(y))),
        else => unreachable,
    }
    return if (z == 6) (if (x == 1) 12 else 16) else 8;
}

fn fetch(self: *Cpu, bus: anytype) u8 {
    const value = self.readBus(bus, self.pc);
    if (self.halt_bug) {
        self.halt_bug = false;
    } else {
        self.pc +%= 1;
    }
    return value;
}

fn readBus(self: *Cpu, bus: anytype, address: u16) u8 {
    const value = bus.read(address);
    self.tick(bus, 4);
    return value;
}

fn writeBus(self: *Cpu, bus: anytype, address: u16, value: u8) void {
    bus.write(address, value);
    self.tick(bus, 4);
}

fn tickRemainder(self: *Cpu, bus: anytype, total_cycles: u8) void {
    if (total_cycles > self.step_elapsed_cycles) self.tick(bus, total_cycles - self.step_elapsed_cycles);
}

fn tick(self: *Cpu, bus: anytype, cycles: u8) void {
    self.step_elapsed_cycles += cycles;
    const BusType = @TypeOf(bus);
    const BusChild = switch (@typeInfo(BusType)) {
        .pointer => |pointer| pointer.child,
        else => BusType,
    };
    if (comptime @hasDecl(BusChild, "tick")) bus.tick(cycles);
}

fn fetch16(self: *Cpu, bus: anytype) u16 {
    const low = self.fetch(bus);
    const high = self.fetch(bus);
    return @as(u16, low) | (@as(u16, high) << 8);
}

fn readR(self: *Cpu, bus: anytype, index: u8) u8 {
    return switch (index) {
        0 => self.b,
        1 => self.c,
        2 => self.d,
        3 => self.e,
        4 => self.h,
        5 => self.l,
        6 => self.readBus(bus, self.hl()),
        7 => self.a,
        else => unreachable,
    };
}

fn writeR(self: *Cpu, bus: anytype, index: u8, value: u8) void {
    switch (index) {
        0 => self.b = value,
        1 => self.c = value,
        2 => self.d = value,
        3 => self.e = value,
        4 => self.h = value,
        5 => self.l = value,
        6 => self.writeBus(bus, self.hl(), value),
        7 => self.a = value,
        else => unreachable,
    }
}

fn alu(self: *Cpu, operation: u8, value: u8) void {
    switch (operation) {
        0 => self.a = self.add8(self.a, value, false),
        1 => self.a = self.add8(self.a, value, self.flag(Flag.c)),
        2 => self.a = self.sub8(self.a, value, false),
        3 => self.a = self.sub8(self.a, value, self.flag(Flag.c)),
        4 => {
            self.a &= value;
            self.setZnhc(self.a == 0, false, true, false);
        },
        5 => {
            self.a ^= value;
            self.setZnhc(self.a == 0, false, false, false);
        },
        6 => {
            self.a |= value;
            self.setZnhc(self.a == 0, false, false, false);
        },
        7 => _ = self.sub8(self.a, value, false),
        else => unreachable,
    }
}

fn add8(self: *Cpu, left: u8, right: u8, with_carry: bool) u8 {
    const carry: u16 = @intFromBool(with_carry);
    const sum = @as(u16, left) + right + carry;
    const result: u8 = @truncate(sum);
    self.setZnhc(
        result == 0,
        false,
        (@as(u16, left & 0x0f) + (right & 0x0f) + carry) > 0x0f,
        sum > 0xff,
    );
    return result;
}

fn sub8(self: *Cpu, left: u8, right: u8, with_carry: bool) u8 {
    const carry: u16 = @intFromBool(with_carry);
    const rhs = @as(u16, right) + carry;
    const result = left -% @as(u8, @truncate(rhs));
    self.setZnhc(
        result == 0,
        true,
        @as(u16, left & 0x0f) < @as(u16, right & 0x0f) + carry,
        @as(u16, left) < rhs,
    );
    return result;
}

fn inc8(self: *Cpu, value: u8) u8 {
    const result = value +% 1;
    self.setFlag(Flag.z, result == 0);
    self.setFlag(Flag.n, false);
    self.setFlag(Flag.h, (value & 0x0f) == 0x0f);
    return result;
}

fn dec8(self: *Cpu, value: u8) u8 {
    const result = value -% 1;
    self.setFlag(Flag.z, result == 0);
    self.setFlag(Flag.n, true);
    self.setFlag(Flag.h, (value & 0x0f) == 0);
    return result;
}

fn addHl(self: *Cpu, value: u16) void {
    const current = self.hl();
    const sum = @as(u32, current) + value;
    self.setFlag(Flag.n, false);
    self.setFlag(Flag.h, (@as(u32, current & 0x0fff) + (value & 0x0fff)) > 0x0fff);
    self.setFlag(Flag.c, sum > 0xffff);
    self.setHl(@truncate(sum));
}

fn addSpOffset(self: *Cpu, raw: u8) u16 {
    const offset: i8 = @bitCast(raw);
    const result = self.sp +% @as(u16, @bitCast(@as(i16, offset)));
    self.setZnhc(false, false, ((self.sp ^ @as(u16, raw) ^ result) & 0x10) != 0, ((self.sp ^ @as(u16, raw) ^ result) & 0x100) != 0);
    return result;
}

fn daa(self: *Cpu) void {
    var correction: u8 = 0;
    var carry = self.flag(Flag.c);
    if (!self.flag(Flag.n)) {
        if (self.flag(Flag.h) or (self.a & 0x0f) > 9) correction |= 0x06;
        if (carry or self.a > 0x99) {
            correction |= 0x60;
            carry = true;
        }
        self.a +%= correction;
    } else {
        if (self.flag(Flag.h)) correction |= 0x06;
        if (carry) correction |= 0x60;
        self.a -%= correction;
    }
    self.setFlag(Flag.z, self.a == 0);
    self.setFlag(Flag.h, false);
    self.setFlag(Flag.c, carry);
}

fn rlc(self: *Cpu, value: u8, set_zero: bool) u8 {
    const carry = (value & 0x80) != 0;
    const result = (value << 1) | @as(u8, @intFromBool(carry));
    self.setZnhc(set_zero and result == 0, false, false, carry);
    return result;
}

fn rrc(self: *Cpu, value: u8, set_zero: bool) u8 {
    const carry = (value & 1) != 0;
    const result = (value >> 1) | (if (carry) @as(u8, 0x80) else 0);
    self.setZnhc(set_zero and result == 0, false, false, carry);
    return result;
}

fn rl(self: *Cpu, value: u8, set_zero: bool) u8 {
    const old_carry = self.flag(Flag.c);
    const carry = (value & 0x80) != 0;
    const result = (value << 1) | @as(u8, @intFromBool(old_carry));
    self.setZnhc(set_zero and result == 0, false, false, carry);
    return result;
}

fn rr(self: *Cpu, value: u8, set_zero: bool) u8 {
    const old_carry = self.flag(Flag.c);
    const carry = (value & 1) != 0;
    const result = (value >> 1) | (if (old_carry) @as(u8, 0x80) else 0);
    self.setZnhc(set_zero and result == 0, false, false, carry);
    return result;
}

fn sla(self: *Cpu, value: u8) u8 {
    const result = value << 1;
    self.setZnhc(result == 0, false, false, (value & 0x80) != 0);
    return result;
}

fn sra(self: *Cpu, value: u8) u8 {
    const result = (value >> 1) | (value & 0x80);
    self.setZnhc(result == 0, false, false, (value & 1) != 0);
    return result;
}

fn swap(self: *Cpu, value: u8) u8 {
    const result = (value << 4) | (value >> 4);
    self.setZnhc(result == 0, false, false, false);
    return result;
}

fn srl(self: *Cpu, value: u8) u8 {
    const result = value >> 1;
    self.setZnhc(result == 0, false, false, (value & 1) != 0);
    return result;
}

fn jr(self: *Cpu, raw: u8) void {
    const offset: i8 = @bitCast(raw);
    self.pc +%= @as(u16, @bitCast(@as(i16, offset)));
}

fn condition(self: *const Cpu, index: u8) bool {
    return switch (index) {
        0 => !self.flag(Flag.z),
        1 => self.flag(Flag.z),
        2 => !self.flag(Flag.c),
        3 => self.flag(Flag.c),
        else => unreachable,
    };
}

fn push16(self: *Cpu, bus: anytype, value: u16) void {
    self.sp -%= 1;
    self.writeBus(bus, self.sp, @truncate(value >> 8));
    self.sp -%= 1;
    self.writeBus(bus, self.sp, @truncate(value));
}

fn pop16(self: *Cpu, bus: anytype) u16 {
    const low = self.readBus(bus, self.sp);
    self.sp +%= 1;
    const high = self.readBus(bus, self.sp);
    self.sp +%= 1;
    return @as(u16, low) | (@as(u16, high) << 8);
}

fn getRp(self: *const Cpu, index: u8) u16 {
    return switch (index) {
        0 => self.bc(),
        1 => self.de(),
        2 => self.hl(),
        3 => self.sp,
        else => unreachable,
    };
}

fn setRp(self: *Cpu, index: u8, value: u16) void {
    switch (index) {
        0 => self.setBc(value),
        1 => self.setDe(value),
        2 => self.setHl(value),
        3 => self.sp = value,
        else => unreachable,
    }
}

fn getRp2(self: *const Cpu, index: u8) u16 {
    return switch (index) {
        0 => self.bc(),
        1 => self.de(),
        2 => self.hl(),
        3 => (@as(u16, self.a) << 8) | self.f,
        else => unreachable,
    };
}

fn setRp2(self: *Cpu, index: u8, value: u16) void {
    switch (index) {
        0 => self.setBc(value),
        1 => self.setDe(value),
        2 => self.setHl(value),
        3 => {
            self.a = @truncate(value >> 8);
            self.f = @as(u8, @truncate(value)) & 0xf0;
        },
        else => unreachable,
    }
}

fn bc(self: *const Cpu) u16 {
    return (@as(u16, self.b) << 8) | self.c;
}

fn de(self: *const Cpu) u16 {
    return (@as(u16, self.d) << 8) | self.e;
}

fn hl(self: *const Cpu) u16 {
    return (@as(u16, self.h) << 8) | self.l;
}

fn setBc(self: *Cpu, value: u16) void {
    self.b = @truncate(value >> 8);
    self.c = @truncate(value);
}

fn setDe(self: *Cpu, value: u16) void {
    self.d = @truncate(value >> 8);
    self.e = @truncate(value);
}

fn setHl(self: *Cpu, value: u16) void {
    self.h = @truncate(value >> 8);
    self.l = @truncate(value);
}

fn flag(self: *const Cpu, mask: u8) bool {
    return (self.f & mask) != 0;
}

fn setFlag(self: *Cpu, mask: u8, enabled: bool) void {
    if (enabled) self.f |= mask else self.f &= ~mask;
}

fn setZnhc(self: *Cpu, z: bool, n: bool, h: bool, c: bool) void {
    self.f = (if (z) Flag.z else 0) |
        (if (n) Flag.n else 0) |
        (if (h) Flag.h else 0) |
        (if (c) Flag.c else 0);
}

const TestMemory = struct {
    data: [65536]u8 = [_]u8{0} ** 65536,
    ticked_cycles: u16 = 0,

    pub fn read(self: *@This(), address: u16) u8 {
        return self.data[address];
    }

    pub fn write(self: *@This(), address: u16, value: u8) void {
        self.data[address] = value;
    }

    pub fn tick(self: *@This(), cycles: u8) void {
        self.ticked_cycles += cycles;
    }
};

test "executes arithmetic, memory, CB, call, and return instructions" {
    var memory = TestMemory{};
    var cpu = Cpu{ .sp = 0xfffe };
    var interrupt_flags: u8 = 0;
    const program = [_]u8{
        0x3e, 0x0f, // LD A,$0f
        0xc6, 0x01, // ADD A,$01
        0x21, 0x00, 0xc0, // LD HL,$c000
        0x77, // LD (HL),A
        0xcb, 0x37, // SWAP A
        0xcd, 0x10, 0x00, // CALL $0010
    };
    @memcpy(memory.data[0..program.len], &program);
    memory.data[0x10] = 0x3c;
    memory.data[0x11] = 0xc9;

    var i: usize = 0;
    while (i < 8) : (i += 1) _ = try cpu.step(&memory, 0, &interrupt_flags);

    try std.testing.expectEqual(@as(u8, 0x02), cpu.a);
    try std.testing.expectEqual(@as(u8, 0x10), memory.data[0xc000]);
    try std.testing.expectEqual(@as(u16, 0x000d), cpu.pc);
}

test "services interrupts and implements delayed EI" {
    var memory = TestMemory{};
    var cpu = Cpu{ .sp = 0xfffe };
    var interrupt_flags: u8 = 1;
    memory.data[0] = 0xfb;
    memory.data[1] = 0x00;
    memory.data[0xffff] = 1;

    _ = try cpu.step(&memory, 1, &interrupt_flags);
    try std.testing.expect(!cpu.ime);
    _ = try cpu.step(&memory, 1, &interrupt_flags);
    try std.testing.expect(cpu.ime);
    try std.testing.expectEqual(
        @as(u8, 20),
        (try cpu.step(&memory, 1, &interrupt_flags)).cycles,
    );
    try std.testing.expectEqual(@as(u16, 0x40), cpu.pc);
}

test "machine-cycle hook receives instruction and interrupt timing" {
    var memory = TestMemory{};
    var cpu = Cpu{ .sp = 0xfffe };
    var interrupt_flags: u8 = 0;
    memory.data[0] = 0x00; // NOP
    memory.data[1] = 0xcd; // CALL $0010
    memory.data[2] = 0x10;
    memory.data[3] = 0x00;
    memory.data[0x10] = 0xc9; // RET

    try std.testing.expectEqual(@as(u8, 4), (try cpu.step(&memory, 0, &interrupt_flags)).cycles);
    try std.testing.expectEqual(@as(u16, 4), memory.ticked_cycles);

    memory.ticked_cycles = 0;
    try std.testing.expectEqual(@as(u8, 24), (try cpu.step(&memory, 0, &interrupt_flags)).cycles);
    try std.testing.expectEqual(@as(u16, 24), memory.ticked_cycles);

    memory.ticked_cycles = 0;
    cpu.ime = true;
    interrupt_flags = 0x02;
    memory.data[0xffff] = 0x02;
    try std.testing.expectEqual(@as(u8, 20), (try cpu.step(&memory, 0x02, &interrupt_flags)).cycles);
    try std.testing.expectEqual(@as(u16, 20), memory.ticked_cycles);
}

test "DI cancels pending delayed EI" {
    var memory = TestMemory{};
    var cpu = Cpu{ .sp = 0xfffe };
    var interrupt_flags: u8 = 1;
    memory.data[0] = 0xfb; // EI
    memory.data[1] = 0xf3; // DI
    memory.data[2] = 0x00; // NOP

    _ = try cpu.step(&memory, 1, &interrupt_flags);
    try std.testing.expect(!cpu.ime);
    _ = try cpu.step(&memory, 1, &interrupt_flags);
    try std.testing.expect(!cpu.ime);
    _ = try cpu.step(&memory, 1, &interrupt_flags);
    try std.testing.expect(!cpu.ime);
    try std.testing.expectEqual(@as(u16, 3), cpu.pc);
}

test "interrupt service pushes current PC and clears request" {
    var memory = TestMemory{};
    var cpu = Cpu{ .sp = 0xfffe, .pc = 0x1234, .ime = true };
    var interrupt_flags: u8 = 0x04;
    memory.data[0xffff] = 0x04;

    try std.testing.expectEqual(@as(u8, 20), (try cpu.step(&memory, 0x04, &interrupt_flags)).cycles);
    try std.testing.expectEqual(@as(u16, 0x50), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0xfffc), cpu.sp);
    try std.testing.expectEqual(@as(u8, 0x34), memory.data[0xfffc]);
    try std.testing.expectEqual(@as(u8, 0x12), memory.data[0xfffd]);
    try std.testing.expectEqual(@as(u8, 0), interrupt_flags & 0x04);
    try std.testing.expect(!cpu.ime);
}

test "interrupt dispatch reselects after high PC push writes IE" {
    var memory = TestMemory{};
    var cpu = Cpu{ .sp = 0x0000, .pc = 0x0200, .ime = true };
    var interrupt_flags: u8 = 0x03;
    memory.data[0xffff] = 0x03;

    try std.testing.expectEqual(@as(u8, 20), (try cpu.step(&memory, 0x03, &interrupt_flags)).cycles);
    try std.testing.expectEqual(@as(u16, 0x48), cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x01), interrupt_flags & 0x1f);
    try std.testing.expectEqual(@as(u8, 0x02), memory.data[0xffff]);
}

test "interrupt dispatch cancels if high PC push clears all enabled requests" {
    var memory = TestMemory{};
    var cpu = Cpu{ .sp = 0x0000, .pc = 0x0200, .ime = true };
    var interrupt_flags: u8 = 0x04;
    memory.data[0xffff] = 0x04;

    try std.testing.expectEqual(@as(u8, 20), (try cpu.step(&memory, 0x04, &interrupt_flags)).cycles);
    try std.testing.expectEqual(@as(u16, 0), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0xffff), cpu.sp);
    try std.testing.expectEqual(@as(u8, 0x04), interrupt_flags & 0x1f);
    try std.testing.expectEqual(@as(u8, 0x02), memory.data[0xffff]);
}

test "HALT wakes without servicing when IME is disabled" {
    var memory = TestMemory{};
    var cpu = Cpu{};
    var interrupt_flags: u8 = 0;
    memory.data[0] = 0x76; // HALT
    memory.data[1] = 0x00; // NOP

    _ = try cpu.step(&memory, 0, &interrupt_flags);
    try std.testing.expect(cpu.halted);
    interrupt_flags = 1;
    _ = try cpu.step(&memory, 1, &interrupt_flags);
    try std.testing.expect(!cpu.halted);
    try std.testing.expectEqual(@as(u16, 2), cpu.pc);
    _ = try cpu.step(&memory, 1, &interrupt_flags);
    try std.testing.expectEqual(@as(u16, 3), cpu.pc);
}

test "invalid opcodes do not advance pc" {
    var memory = TestMemory{};
    var cpu = Cpu{};
    var interrupt_flags: u8 = 0;
    memory.data[0] = 0xd3;

    try std.testing.expectError(Error.InvalidOpcode, cpu.step(&memory, 0, &interrupt_flags));
    try std.testing.expectEqual(@as(u16, 0), cpu.pc);
}

test "HALT bug suppresses one program counter increment" {
    var memory = TestMemory{};
    var cpu = Cpu{};
    var interrupt_flags: u8 = 1;
    memory.data[0] = 0x76;
    memory.data[1] = 0x3e;
    memory.data[2] = 0x42;

    _ = try cpu.step(&memory, 1, &interrupt_flags);
    _ = try cpu.step(&memory, 1, &interrupt_flags);

    try std.testing.expectEqual(@as(u8, 0x3e), cpu.a);
    try std.testing.expectEqual(@as(u16, 2), cpu.pc);
}

test "all documented base opcodes decode" {
    const invalid = [_]u8{ 0xd3, 0xdb, 0xdd, 0xe3, 0xe4, 0xeb, 0xec, 0xed, 0xf4, 0xfc, 0xfd };
    var opcode: u16 = 0;
    while (opcode < 256) : (opcode += 1) {
        var memory = TestMemory{};
        var cpu = Cpu{ .sp = 0xfffe };
        var interrupt_flags: u8 = 0;
        memory.data[0] = @truncate(opcode);
        const expected_invalid = std.mem.indexOfScalar(u8, &invalid, @truncate(opcode)) != null;
        if (expected_invalid) {
            try std.testing.expectError(Error.InvalidOpcode, cpu.step(&memory, 0, &interrupt_flags));
        } else {
            _ = try cpu.step(&memory, 0, &interrupt_flags);
        }
    }
}
