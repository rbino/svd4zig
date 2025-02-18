const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const fmt = std.fmt;
const warn = std.log.warn;

const svd = @import("svd.zig");

var line_buffer: [1024 * 1024]u8 = undefined;

const register_def =
    \\pub fn Register(comptime R: type) type {
    \\    return RegisterRW(R, R);
    \\}
    \\
    \\pub fn RegisterRW(comptime Read: type, comptime Write: type) type {
    \\    return struct {
    \\        raw_ptr: *volatile u32,
    \\
    \\        const Self = @This();
    \\
    \\        pub fn init(address: usize) Self {
    \\            const ptr: *volatile u32 = @ptrFromInt(address);
    \\            return Self{ .raw_ptr = ptr };
    \\        }
    \\
    \\        pub fn initRange(address: usize, comptime dim_increment: usize, comptime num_registers: usize) [num_registers]Self {
    \\            var registers: [num_registers]Self = undefined;
    \\            var i: usize = 0;
    \\            while (i < num_registers) : (i += 1) {
    \\                registers[i] = Self.init(address + (i * dim_increment));
    \\            }
    \\            return registers;
    \\        }
    \\
    \\        pub fn read(self: Self) Read {
    \\            return @bitCast(self.raw_ptr.*);
    \\        }
    \\
    \\        pub fn write(self: Self, value: Write) void {
    \\            // Forcing the alignment is a workaround for stores through
    \\            // volatile pointers generating multiple loads and stores.
    \\            // This is necessary for LLVM to generate code that can successfully
    \\            // modify MMIO registers that only allow word-sized stores.
    \\            // https://github.com/ziglang/zig/issues/8981#issuecomment-854911077
    \\            const aligned: Write align(4) = value;
    \\            const ptr: *const u32 = @ptrCast(&aligned);
    \\            self.raw_ptr.* = ptr.*;
    \\        }
    \\
    \\        pub fn modify(self: Self, new_value: anytype) void {
    \\            if (Read != Write) {
    \\                @compileError("Can't modify because read and write types for this register aren't the same.");
    \\            }
    \\            var old_value = self.read();
    \\            const info = @typeInfo(@TypeOf(new_value));
    \\            inline for (info.Struct.fields) |field| {
    \\                @field(old_value, field.name) = @field(new_value, field.name);
    \\            }
    \\            self.write(old_value);
    \\        }
    \\
    \\        pub fn read_raw(self: Self) u32 {
    \\            return self.raw_ptr.*;
    \\        }
    \\
    \\        pub fn write_raw(self: Self, value: u32) void {
    \\            self.raw_ptr.* = value;
    \\        }
    \\
    \\        pub fn default_read_value(_: Self) Read {
    \\            return Read{};
    \\        }
    \\
    \\        pub fn default_write_value(_: Self) Write {
    \\            return Write{};
    \\        }
    \\    };
    \\}
    \\
;

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);

    _ = args.next(); // skip application name
    // Note memory will be freed on exit since using arena

    const file_name = args.next() orelse return error.MandatoryFilenameArgumentNotGiven;
    const file = try std.fs.cwd().openFile(file_name, .{});

    const stream = &file.reader();

    var state = SvdParseState.Device;
    var dev = try svd.Device.init(allocator);
    var cur_interrupt: svd.Interrupt = undefined;
    while (try stream.readUntilDelimiterOrEof(&line_buffer, '\n')) |line| {
        const chunk = getChunk(line) orelse continue;

        switch (state) {
            .Device => {
                if (ascii.eqlIgnoreCase(chunk.tag, "/device")) {
                    state = .Finished;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "name")) {
                    if (chunk.data) |data| {
                        try dev.name.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "version")) {
                    if (chunk.data) |data| {
                        try dev.version.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "description")) {
                    if (chunk.data) |data| {
                        try dev.description.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "cpu")) {
                    const cpu = try svd.Cpu.init(allocator);
                    dev.cpu = cpu;
                    state = .Cpu;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "addressUnitBits")) {
                    if (chunk.data) |data| {
                        dev.address_unit_bits = fmt.parseInt(u32, data, 10) catch null;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "width")) {
                    if (chunk.data) |data| {
                        dev.max_bit_width = fmt.parseInt(u32, data, 10) catch null;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "size")) {
                    if (chunk.data) |data| {
                        dev.reg_default_size = fmt.parseInt(u32, data, 10) catch null;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "resetValue")) {
                    if (chunk.data) |data| {
                        dev.reg_default_reset_value = fmt.parseInt(u32, data, 10) catch null;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "resetMask")) {
                    if (chunk.data) |data| {
                        dev.reg_default_reset_mask = fmt.parseInt(u32, data, 10) catch null;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "peripherals")) {
                    state = .Peripherals;
                }
            },
            .Cpu => {
                if (ascii.eqlIgnoreCase(chunk.tag, "/cpu")) {
                    state = .Device;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "name")) {
                    if (chunk.data) |data| {
                        try dev.cpu.?.name.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "revision")) {
                    if (chunk.data) |data| {
                        try dev.cpu.?.revision.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "endian")) {
                    if (chunk.data) |data| {
                        try dev.cpu.?.endian.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "mpuPresent")) {
                    if (chunk.data) |data| {
                        dev.cpu.?.mpu_present = textToBool(data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "fpuPresent")) {
                    if (chunk.data) |data| {
                        dev.cpu.?.fpu_present = textToBool(data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "nvicPrioBits")) {
                    if (chunk.data) |data| {
                        dev.cpu.?.nvic_prio_bits = fmt.parseInt(u32, data, 10) catch null;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "vendorSystickConfig")) {
                    if (chunk.data) |data| {
                        dev.cpu.?.vendor_systick_config = textToBool(data);
                    }
                }
            },
            .Peripherals => {
                if (ascii.eqlIgnoreCase(chunk.tag, "/peripherals")) {
                    state = .Device;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "peripheral")) {
                    if (chunk.derivedFrom) |derivedFrom| {
                        for (dev.peripherals.items) |periph_being_checked| {
                            if (mem.eql(u8, periph_being_checked.name.items, derivedFrom)) {
                                try dev.peripherals.append(try periph_being_checked.copy(allocator));
                                state = .Peripheral;
                                break;
                            }
                        }
                    } else {
                        const periph = try svd.Peripheral.init(allocator);
                        try dev.peripherals.append(periph);
                        state = .Peripheral;
                    }
                }
            },
            .Peripheral => {
                var cur_periph = &dev.peripherals.items[dev.peripherals.items.len - 1];
                if (ascii.eqlIgnoreCase(chunk.tag, "/peripheral")) {
                    state = .Peripherals;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "name")) {
                    if (chunk.data) |data| {
                        // periph could be copy, must update periph name in sub-fields
                        try cur_periph.name.replaceRange(0, cur_periph.name.items.len, data);
                        for (cur_periph.registers.items) |*reg| {
                            try reg.periph_containing.replaceRange(0, reg.periph_containing.items.len, data);
                            for (reg.fields.items) |*field| {
                                try field.periph.replaceRange(0, field.periph.items.len, data);
                            }
                        }
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "description")) {
                    if (chunk.data) |data| {
                        try cur_periph.description.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "groupName")) {
                    if (chunk.data) |data| {
                        try cur_periph.group_name.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "baseAddress")) {
                    if (chunk.data) |data| {
                        cur_periph.base_address = parseHexLiteral(data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "addressBlock")) {
                    if (cur_periph.address_block) |_| {
                        // do nothing
                    } else {
                        const block = try svd.AddressBlock.init(allocator);
                        cur_periph.address_block = block;
                    }
                    state = .AddressBlock;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "interrupt")) {
                    cur_interrupt = try svd.Interrupt.init(allocator);
                    state = .Interrupt;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "registers")) {
                    state = .Registers;
                }
            },
            .AddressBlock => {
                var cur_periph = &dev.peripherals.items[dev.peripherals.items.len - 1];
                var address_block = &cur_periph.address_block.?;
                if (ascii.eqlIgnoreCase(chunk.tag, "/addressBlock")) {
                    state = .Peripheral;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "offset")) {
                    if (chunk.data) |data| {
                        address_block.offset = parseHexLiteral(data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "size")) {
                    if (chunk.data) |data| {
                        address_block.size = parseHexLiteral(data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "usage")) {
                    if (chunk.data) |data| {
                        try address_block.usage.insertSlice(0, data);
                    }
                }
            },
            .Interrupt => {
                if (ascii.eqlIgnoreCase(chunk.tag, "/interrupt")) {
                    if (cur_interrupt.value) |value| {
                        // If we find a duplicate interrupt, deinit the old one
                        if (try dev.interrupts.fetchPut(value, cur_interrupt)) |old_entry| {
                            var old_interrupt = old_entry.value;
                            const old_name = old_interrupt.name.items;
                            const cur_name = cur_interrupt.name.items;
                            if (!mem.eql(u8, old_name, cur_name)) {
                                warn(
                                    \\ Found duplicate interrupt values with different names: {s} and {s}
                                    \\ The latter will be discarded.
                                    \\
                                , .{
                                    cur_name,
                                    old_name,
                                });
                            }
                            old_interrupt.deinit();
                        }
                    }
                    state = .Peripheral;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "name")) {
                    if (chunk.data) |data| {
                        try cur_interrupt.name.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "description")) {
                    if (chunk.data) |data| {
                        try cur_interrupt.description.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "value")) {
                    if (chunk.data) |data| {
                        cur_interrupt.value = fmt.parseInt(u32, data, 10) catch null;
                    }
                }
            },
            .Registers => {
                var cur_periph = &dev.peripherals.items[dev.peripherals.items.len - 1];
                if (ascii.eqlIgnoreCase(chunk.tag, "/registers")) {
                    state = .Peripheral;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "register")) {
                    const reset_value = dev.reg_default_reset_value orelse 0;
                    const size = dev.reg_default_size orelse 32;
                    const register = try svd.Register.init(allocator, cur_periph.name.items, reset_value, size);
                    try cur_periph.registers.append(register);
                    state = .Register;
                }
            },
            .Register => {
                var cur_periph = &dev.peripherals.items[dev.peripherals.items.len - 1];
                var cur_reg = &cur_periph.registers.items[cur_periph.registers.items.len - 1];
                if (ascii.eqlIgnoreCase(chunk.tag, "/register")) {
                    state = .Registers;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "name")) {
                    if (chunk.data) |data| {
                        try cur_reg.name.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "displayName")) {
                    if (chunk.data) |data| {
                        try cur_reg.display_name.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "description")) {
                    if (chunk.data) |data| {
                        try cur_reg.description.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "addressOffset")) {
                    if (chunk.data) |data| {
                        cur_reg.address_offset = parseHexLiteral(data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "size")) {
                    if (chunk.data) |data| {
                        cur_reg.size = parseHexLiteral(data) orelse cur_reg.size;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "access")) {
                    if (chunk.data) |data| {
                        cur_reg.access = parseAccessValue(data) orelse cur_reg.access;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "resetValue")) {
                    if (chunk.data) |data| {
                        cur_reg.reset_value = parseHexLiteral(data) orelse cur_reg.reset_value; // TODO: test orelse break
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "fields")) {
                    state = .Fields;
                }
            },
            .Fields => {
                var cur_periph = &dev.peripherals.items[dev.peripherals.items.len - 1];
                var cur_reg = &cur_periph.registers.items[cur_periph.registers.items.len - 1];
                if (ascii.eqlIgnoreCase(chunk.tag, "/fields")) {
                    state = .Register;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "field")) {
                    const field = try svd.Field.init(allocator, cur_periph.name.items, cur_reg.name.items, cur_reg.reset_value);
                    try cur_reg.fields.append(field);
                    state = .Field;
                }
            },
            .Field => {
                var cur_periph = &dev.peripherals.items[dev.peripherals.items.len - 1];
                var cur_reg = &cur_periph.registers.items[cur_periph.registers.items.len - 1];
                var cur_field = &cur_reg.fields.items[cur_reg.fields.items.len - 1];
                if (ascii.eqlIgnoreCase(chunk.tag, "/field")) {
                    state = .Fields;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "name")) {
                    if (chunk.data) |data| {
                        if (cur_field.name.items.len == 0) {
                            try cur_field.name.insertSlice(0, data);
                        }
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "description")) {
                    if (chunk.data) |data| {
                        try cur_field.description.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "bitOffset")) {
                    if (chunk.data) |data| {
                        cur_field.bit_offset = fmt.parseInt(u32, data, 10) catch null;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "bitWidth")) {
                    if (chunk.data) |data| {
                        cur_field.bit_width = fmt.parseInt(u32, data, 10) catch null;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "bitRange")) {
                    if (chunk.data) |data| {
                        const len = data.len;
                        const s = data[1 .. len - 1];
                        var it = std.mem.split(u8, s, ":");
                        const msb = try fmt.parseInt(u32, it.next() orelse unreachable, 10);
                        const lsb_str = it.next() orelse unreachable;
                        var lsb: u32 = undefined;
                        if (lsb_str.len == 0) {
                            lsb = 0;
                        } else {
                            lsb = try fmt.parseInt(u32, lsb_str, 10);
                        }
                        cur_field.bit_width = (msb - lsb) + 1;
                        cur_field.bit_offset = lsb;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "access")) {
                    if (chunk.data) |data| {
                        cur_field.access = parseAccessValue(data) orelse cur_field.access;
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "enumeratedValues")) {
                    state = .FieldEnum;
                }
            },
            .FieldEnum => {
                var cur_periph = &dev.peripherals.items[dev.peripherals.items.len - 1];
                var cur_reg = &cur_periph.registers.items[cur_periph.registers.items.len - 1];
                var cur_field = &cur_reg.fields.items[cur_reg.fields.items.len - 1];
                if (ascii.eqlIgnoreCase(chunk.tag, "/enumeratedValues")) {
                    state = .Field;
                } else if (ascii.eqlIgnoreCase(chunk.tag, "enumeratedValue")) {
                    const enum_field = try svd.EnumField.init(allocator);
                    try cur_field.enum_fields.append(enum_field);
                } else if (ascii.eqlIgnoreCase(chunk.tag, "name")) {
                    var cur_enum = &cur_field.enum_fields.items[cur_field.enum_fields.items.len - 1];
                    if (chunk.data) |data| {
                        try cur_enum.name.insertSlice(0, data);
                    }
                } else if (ascii.eqlIgnoreCase(chunk.tag, "value")) {
                    var cur_enum = &cur_field.enum_fields.items[cur_field.enum_fields.items.len - 1];
                    if (chunk.data) |data| {
                        cur_enum.value = try fmt.parseInt(u32, data, 0);
                    }
                }
            },
            .Finished => {
                // wait for EOF
            },
        }
    }
    if (state == .Finished) {
        try std.io.getStdOut().writer().print("{s}\n", .{register_def});
        try std.io.getStdOut().writer().print("{}\n", .{dev});
    } else {
        return error.InvalidXML;
    }
}

const SvdParseState = enum {
    Device,
    Cpu,
    Peripherals,
    Peripheral,
    AddressBlock,
    Interrupt,
    Registers,
    Register,
    Fields,
    Field,
    FieldEnum,
    Finished,
};

const XmlChunk = struct {
    tag: []const u8,
    data: ?[]const u8,
    derivedFrom: ?[]const u8,
};

fn getChunk(line: []const u8) ?XmlChunk {
    var chunk = XmlChunk{
        .tag = undefined,
        .data = null,
        .derivedFrom = null,
    };

    const trimmed = mem.trim(u8, line, " \n");
    var toker = mem.tokenize(u8, trimmed, "<>"); //" =\n<>\"");

    if (toker.next()) |maybe_tag| {
        var tag_toker = mem.tokenize(u8, maybe_tag, " =\"");
        chunk.tag = tag_toker.next() orelse return null;
        if (tag_toker.next()) |maybe_tag_property| {
            if (ascii.eqlIgnoreCase(maybe_tag_property, "derivedFrom")) {
                chunk.derivedFrom = tag_toker.next();
            }
        }
    } else {
        return null;
    }

    if (toker.next()) |chunk_data| {
        chunk.data = chunk_data;
    }

    return chunk;
}

test "getChunk" {
    const valid_xml = "  <name>STM32F7x7</name>  \n";
    const expected_chunk = XmlChunk{ .tag = "name", .data = "STM32F7x7", .derivedFrom = null };

    const chunk = getChunk(valid_xml).?;
    std.testing.expectEqualSlices(u8, chunk.tag, expected_chunk.tag);
    std.testing.expectEqualSlices(u8, chunk.data.?, expected_chunk.data.?);

    const no_data_xml = "  <name> \n";
    const expected_no_data_chunk = XmlChunk{ .tag = "name", .data = null, .derivedFrom = null };
    const no_data_chunk = getChunk(no_data_xml).?;
    std.testing.expectEqualSlices(u8, no_data_chunk.tag, expected_no_data_chunk.tag);
    std.testing.expectEqual(no_data_chunk.data, expected_no_data_chunk.data);

    const comments_xml = "<description>Auxiliary Cache Control register</description>";
    const expected_comments_chunk = XmlChunk{ .tag = "description", .data = "Auxiliary Cache Control register", .derivedFrom = null };
    const comments_chunk = getChunk(comments_xml).?;
    std.testing.expectEqualSlices(u8, comments_chunk.tag, expected_comments_chunk.tag);
    std.testing.expectEqualSlices(u8, comments_chunk.data.?, expected_comments_chunk.data.?);

    const derived = "   <peripheral derivedFrom=\"TIM10\">";
    const expected_derived_chunk = XmlChunk{ .tag = "peripheral", .data = null, .derivedFrom = "TIM10" };
    const derived_chunk = getChunk(derived).?;
    std.testing.expectEqualSlices(u8, derived_chunk.tag, expected_derived_chunk.tag);
    std.testing.expectEqualSlices(u8, derived_chunk.derivedFrom.?, expected_derived_chunk.derivedFrom.?);
    std.testing.expectEqual(derived_chunk.data, expected_derived_chunk.data);
}

fn textToBool(data: []const u8) ?bool {
    if (ascii.eqlIgnoreCase(data, "true")) {
        return true;
    } else if (ascii.eqlIgnoreCase(data, "false")) {
        return false;
    } else {
        return null;
    }
}

fn parseHexLiteral(data: []const u8) ?u32 {
    if (data.len <= 2) return null;
    return fmt.parseInt(u32, data[2..], 16) catch null;
}

fn parseAccessValue(data: []const u8) ?svd.Access {
    if (ascii.eqlIgnoreCase(data, "read-write")) {
        return .ReadWrite;
    } else if (ascii.eqlIgnoreCase(data, "read-only")) {
        return .ReadOnly;
    } else if (ascii.eqlIgnoreCase(data, "write-only")) {
        return .WriteOnly;
    }
    return null;
}
