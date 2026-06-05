const Bus = @This();

ptr: *anyopaque,
read_fn: *const fn (*anyopaque, u16) u8,
write_fn: *const fn (*anyopaque, u16, u8) void,

pub fn init(ptr: anytype) Bus {
    const Pointer = @TypeOf(ptr);
    const info = @typeInfo(Pointer);
    if (info != .pointer) @compileError("Bus.init expects a pointer");
    const Child = info.pointer.child;

    const VTable = struct {
        fn read(raw: *anyopaque, address: u16) u8 {
            const self: Pointer = @ptrCast(@alignCast(raw));
            return Child.read(self, address);
        }

        fn write(raw: *anyopaque, address: u16, value: u8) void {
            const self: Pointer = @ptrCast(@alignCast(raw));
            Child.write(self, address, value);
        }
    };

    return .{
        .ptr = ptr,
        .read_fn = VTable.read,
        .write_fn = VTable.write,
    };
}

pub fn read(self: Bus, address: u16) u8 {
    return self.read_fn(self.ptr, address);
}

pub fn write(self: Bus, address: u16, value: u8) void {
    self.write_fn(self.ptr, address, value);
}
