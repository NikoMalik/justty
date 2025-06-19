const std = @import("std");
const util = @import("util.zig");

const assert = std.debug.assert;

pub fn IntegerBitSet(comptime IndexT: type) type {
    const size = (@typeInfo(IndexT).@"enum".fields.len);

    comptime {
        // Determine the bit size of IndexT's backing type
        const index_bits =
            @bitSizeOf(@typeInfo(IndexT).@"enum".tag_type);

        // Validate that size doesn't exceed the maximum index representable by IndexT
        const max_index = (@as(u64, 1) << index_bits) - 1;
        if (size > max_index) {
            @compileError("IndexT is too small to represent all indices for size=" ++
                std.fmt.comptimePrint("{}", .{size}));
        }
    }

    return packed struct {
        const Self = @This();

        /// Number of elements in bit cluster
        pub const bit_length: usize = size;

        /// Type for the bitmask
        pub const MaskInt = std.meta.Int(.unsigned, size);

        /// Type for shift operations, ensuring it can handle IndexT's range
        pub const ShiftInt = std.meta.Int(.unsigned, std.math.log2_int_ceil(usize, size));
        /// The bit mask, as a single integer
        mask: MaskInt,

        /// Creates a bit set with no elements present.
        pub fn initEmpty() Self {
            return .{ .mask = 0 };
        }

        /// Creates a bit set with all elements present.
        pub fn initFull() Self {
            return .{ .mask = ~@as(MaskInt, 0) };
        }

        /// Returns the number of bits in this bit set
        pub inline fn capacity(self: Self) usize {
            _ = self;
            return bit_length;
        }

        /// Returns true if the bit at the specified index is present in the set, false otherwise.
        pub fn isSet(self: Self, index: IndexT) bool {
            return (self.mask & maskBit(index)) != 0;
        }

        /// Returns the total number of set bits in this bit set.
        pub fn count(self: Self) usize {
            return @popCount(self.mask);
        }

        /// Changes the value of the specified bit of the bit set to match the passed boolean.
        pub fn setValue(self: *Self, index: IndexT, value: bool) void {
            assert(@as(usize, @intFromEnum(index)) < bit_length);

            if (MaskInt == u0) return;
            const bit = maskBit(index);
            const new_bit = bit & std.math.boolMask(MaskInt, value);
            self.mask = (self.mask & ~bit) | new_bit;
        }

        /// Adds a specific bit to the bit set
        pub fn set(self: *Self, index: IndexT) void {
            self.mask |= maskBit(index);
        }

        /// Changes the value of all bits in the specified range to match the passed boolean.
        pub fn setRangeValue(self: *Self, start: IndexT, end: IndexT, value: bool) void {
            if (start == end) return;
            if (MaskInt == u0) return;

            const start_bit = @as(ShiftInt, @intFromEnum(start));
            var mask = std.math.boolMask(MaskInt, true) << start_bit;
            if (@as(usize, @intFromEnum(end)) != bit_length) {
                const end_bit = @as(ShiftInt, @intFromEnum(end));
                mask &= std.math.boolMask(MaskInt, true) >> @as(ShiftInt, @truncate(@as(usize, @bitSizeOf(MaskInt)) - @as(usize, end_bit)));
            }
            self.mask &= ~mask;

            mask = std.math.boolMask(MaskInt, value) << start_bit;
            if (@as(usize, @intFromEnum(end)) != bit_length) {
                const end_bit = @as(ShiftInt, @intFromEnum(end));
                mask &= std.math.boolMask(MaskInt, value) >> @as(ShiftInt, @truncate(@as(usize, @bitSizeOf(MaskInt)) - @as(usize, end_bit)));
            }
            self.mask |= mask;
        }

        /// Removes a specific bit from the bit set
        pub fn unset(self: *Self, index: IndexT) void {
            if (MaskInt == u0) return;
            self.mask &= ~maskBit(index);
        }

        /// Flips a specific bit in the bit set
        pub fn toggle(self: *Self, index: IndexT) void {
            self.mask ^= maskBit(index);
        }

        /// Flips all bits in this bit set which are present in the toggles bit set.
        pub fn toggleSet(self: *Self, toggles: Self) void {
            self.mask ^= toggles.mask;
        }

        /// Flips all bits in this bit set
        pub fn toggleAll(self: *Self) void {
            self.mask = ~self.mask;
        }

        /// Performs a union of two bit sets, and stores the result in the first one.
        pub fn setUnion(self: *Self, other: Self) void {
            self.mask |= other.mask;
        }

        /// Performs an intersection of two bit sets, and stores the result in the first one.
        pub fn setIntersection(self: *Self, other: Self) void {
            self.mask &= other.mask;
        }

        /// Finds the index of the first set bit. If no bits are set, returns null.
        pub fn findFirstSet(self: Self) ?IndexT {
            const mask = self.mask;
            if (mask == 0) return null;
            return @enumFromInt(@ctz(mask));
        }

        /// Toggles and returns the index of the first set bit. If no bits are set, returns null.
        pub fn toggleFirstSet(self: *Self) ?IndexT {
            const mask = self.mask;
            if (mask == 0) return null;
            const index = @ctz(mask);
            self.mask = mask & (mask - 1);
            return @enumFromInt(index);
        }

        /// Returns true if every corresponding bit in both bit sets are the same.
        pub fn eql(self: Self, other: Self) bool {
            return bit_length == 0 or self.mask == other.mask;
        }

        /// Returns true if the first bit set is a subset of the second one.
        pub fn subsetOf(self: Self, other: Self) bool {
            return self.intersectWith(other).eql(self);
        }

        /// Returns true if the first bit set is a superset of the second one.
        pub fn supersetOf(self: Self, other: Self) bool {
            return other.subsetOf(self);
        }

        /// Returns the complement bit set. Bits in the result are set if the corresponding bits were not set.
        pub fn complement(self: Self) Self {
            var result = self;
            result.toggleAll();
            return result;
        }

        /// Returns the union of two bit sets.
        pub fn unionWith(self: Self, other: Self) Self {
            var result = self;
            result.setUnion(other);
            return result;
        }

        /// Returns the intersection of two bit sets.
        pub fn intersectWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other);
            return result;
        }

        /// Returns the xor of two bit sets.
        pub fn xorWith(self: Self, other: Self) Self {
            var result = self;
            result.toggleSet(other);
            return result;
        }

        /// Returns the difference of two bit sets.
        pub fn differenceWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other.complement());
            return result;
        }

        pub fn iterator(self: *const Self, comptime options: IteratorOptions) Iterator(options) {
            return .{
                .bits_remain = switch (options.kind) {
                    .set => self.mask,
                    .unset => ~self.mask,
                },
            };
        }

        pub fn Iterator(comptime options: IteratorOptions) type {
            return struct {
                const IterSelf = @This();
                bits_remain: MaskInt,

                pub fn next(self: *IterSelf) ?IndexT {
                    if (self.bits_remain == 0) return null;

                    switch (options.direction) {
                        .forward => {
                            const next_index = @ctz(self.bits_remain);
                            self.bits_remain &= self.bits_remain - 1;
                            return @enumFromInt(next_index);
                        },
                        .reverse => {
                            const leading_zeroes = @clz(self.bits_remain);
                            const top_bit = (@bitSizeOf(MaskInt) - 1) - leading_zeroes;
                            self.bits_remain &= (@as(MaskInt, 1) << @as(ShiftInt, @intCast(top_bit))) - 1;
                            return @enumFromInt(top_bit);
                        },
                    }
                }
            };
        }

        inline fn maskBit(index: IndexT) MaskInt {
            if (MaskInt == u0) return 0;
            return @as(MaskInt, 1) << @as(ShiftInt, @intFromEnum(index));
        }
    };
}

pub const IteratorOptions = struct {
    kind: Kind = .set,
    direction: Direction = .forward,

    pub const Kind = enum { set, unset };
    pub const Direction = enum { forward, reverse };
};

test "IntegerBitSet with enum IndexT" {
    const TestFlags = enum(u4) {
        FLAG_0,
        FLAG_1,
        FLAG_2,
        FLAG_3,
        FLAG_4,
        FLAG_5,
        FLAG_6,
        FLAG_7,
        FLAG_8,
        FLAG_9,
        FLAG_10,
        FLAG_11,
        FLAG_12,
    };
    const BitSet = IntegerBitSet(TestFlags);
    var bitset = BitSet.initEmpty();

    // Test setting and checking bits
    bitset.set(.FLAG_12);
    try std.testing.expect(bitset.isSet(.FLAG_12));
    try std.testing.expect(!bitset.isSet(.FLAG_0));
    try std.testing.expectEqual(1, bitset.count());

    // Test range setting
    bitset.setRangeValue(.FLAG_0, .FLAG_5, true);
    try std.testing.expect(bitset.isSet(.FLAG_4));
    try std.testing.expectEqual(6, bitset.count());
}
