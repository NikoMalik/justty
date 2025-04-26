const std = @import("std");
const util = @import("util.zig");

const assert = std.debug.assert;

pub fn IntegerBitSet(comptime size: u16, comptime IndexT: type) type { // make way to put enum here
    comptime {
        const max_index = (@as(u64, 1) << @bitSizeOf(IndexT)) - 1;
        if (size > max_index) {
            @compileError("IndexT is too small to represent all indices for size=" ++ std.fmt.comptimePrint("{}", .{size}));
        }
    }

    return packed struct {
        const Self = @This();

        /// number elements in bit cluster
        pub const bit_length: usize = size;

        /// type integer for keep bitmask
        pub const MaskInt = std.meta.Int(.unsigned, size);

        /// type for operations
        pub const ShiftInt = std.math.Log2Int(MaskInt);

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

        /// Returns true if the bit at the specified index
        /// is present in the set, false otherwise.
        pub fn isSet(self: Self, index: IndexT) bool {
            if (comptime util.isDebug) {
                assert(@as(usize, @intCast(index)) < bit_length);
            }
            return (self.mask & maskBit(index)) != 0;
        }

        /// Returns the total number of set bits in this bit set.
        pub fn count(self: Self) usize {
            return @popCount(self.mask);
        }

        /// Changes the value of the specified bit of the bit
        /// set to match the passed boolean.
        pub fn setValue(self: *Self, index: IndexT, value: bool) void {
            if (comptime util.isDebug) {
                assert(@as(usize, @intCast(index)) < bit_length);
            }

            if (MaskInt == u0) return;
            const bit = maskBit(index);
            const new_bit = bit & std.math.boolMask(MaskInt, value);
            self.mask = (self.mask & ~bit) | new_bit;
        }

        /// Adds a specific bit to the bit set
        pub fn set(self: *Self, index: IndexT) void {
            if (comptime util.isDebug) {
                assert(@as(usize, @intCast(index)) < bit_length);
            }

            self.mask |= maskBit(index);
        }
        /// Changes the value of all bits in the specified range to
        /// match the passed boolean.
        pub fn setRangeValue(self: *Self, start: IndexT, end: IndexT, value: bool) void {
            if (comptime util.isDebug) {
                assert(@as(usize, @intCast(end)) <= bit_length);
                assert(@as(usize, @intCast(start)) <= @as(usize, @intCast(end)));
            }
            if (start == end) return;
            if (MaskInt == u0) return;

            const start_bit = @as(ShiftInt, @intCast(start));
            var mask = std.math.boolMask(MaskInt, true) << start_bit;
            if (@as(usize, @intCast(end)) != bit_length) {
                const end_bit = @as(ShiftInt, @intCast(end));
                mask &= std.math.boolMask(MaskInt, true) >> @as(ShiftInt, @truncate(@as(usize, @bitSizeOf(MaskInt)) - @as(usize, end_bit)));
            }
            self.mask &= ~mask;

            mask = std.math.boolMask(MaskInt, value) << start_bit;
            if (@as(usize, @intCast(end)) != bit_length) {
                const end_bit = @as(ShiftInt, @intCast(end));
                mask &= std.math.boolMask(MaskInt, value) >> @as(ShiftInt, @truncate(@as(usize, @bitSizeOf(MaskInt)) - @as(usize, end_bit)));
            }
            self.mask |= mask;
        }

        /// Removes a specific bit from the bit set
        pub fn unset(self: *Self, index: IndexT) void {
            if (comptime util.isDebug) {
                assert(@as(usize, @intCast(index)) < bit_length);
            }
            if (MaskInt == u0) return;
            self.mask &= ~maskBit(index);
        }

        /// Flips a specific bit in the bit set
        pub fn toggle(self: *Self, index: IndexT) void {
            if (comptime util.isDebug) {
                assert(@as(usize, @intCast(index)) < bit_length);
            }
            self.mask ^= maskBit(index);
        }
        /// Flips a specific bit in the bit set
        pub fn toggleSet(self: *Self, toggles: Self) void {
            self.mask ^= toggles.mask;
        }

        /// Flips all bits in this bit set which are present
        /// in the toggles bit set.
        pub fn toggleAll(self: *Self) void {
            self.mask = ~self.mask;
        }

        /// Performs a union of two bit sets, and stores the
        /// result in the first one.  Bits in the result are
        /// set if the corresponding bits were set in either input.
        pub fn setUnion(self: *Self, other: Self) void {
            self.mask |= other.mask;
        }

        /// Performs an intersection of two bit sets, and stores
        /// the result in the first one.  Bits in the result are
        /// set if the corresponding bits were set in both inputs.
        pub fn setIntersection(self: *Self, other: Self) void {
            self.mask &= other.mask;
        }

        /// Finds the index of the first set bit.
        /// If no bits are set, returns null.
        pub fn findFirstSet(self: Self) ?IndexT {
            const mask = self.mask;
            if (mask == 0) return null;
            return @intCast(@ctz(mask));
        }

        /// Находит и сбрасывает первый установленный бит
        pub fn toggleFirstSet(self: *Self) ?IndexT {
            const mask = self.mask;
            if (mask == 0) return null;
            const index = @ctz(mask);
            self.mask = mask & (mask - 1);
            return @intCast(index);
        }

        /// Returns true iff every corresponding bit in both
        /// bit sets are the same.
        pub fn eql(self: Self, other: Self) bool {
            return bit_length == 0 or self.mask == other.mask;
        }

        /// Returns the complement bit sets. Bits in the result
        /// are set if the corresponding bits were not set.
        pub fn subsetOf(self: Self, other: Self) bool {
            return self.intersectWith(other).eql(self);
        }

        /// Returns true iff the first bit set is the superset
        /// of the second one.
        pub fn supersetOf(self: Self, other: Self) bool {
            return other.subsetOf(self);
        }

        /// Returns the complement bit sets. Bits in the result
        /// are set if the corresponding bits were not set.
        pub fn complement(self: Self) Self {
            var result = self;
            result.toggleAll();
            return result;
        }

        /// Returns the union of two bit sets. Bits in the
        /// result are set if the corresponding bits were set
        /// in either input.
        pub fn unionWith(self: Self, other: Self) Self {
            var result = self;
            result.setUnion(other);
            return result;
        }

        /// Returns the intersection of two bit sets. Bits in
        /// the result are set if the corresponding bits were
        /// set in both inputs.
        pub fn intersectWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other);
            return result;
        }

        /// Returns the xor of two bit sets. Bits in the
        /// result are set if the corresponding bits were
        /// not the same in both inputs.
        pub fn xorWith(self: Self, other: Self) Self {
            var result = self;
            result.toggleSet(other);
            return result;
        }

        /// Returns the difference of two bit sets. Bits in
        /// the result are set if set in the first but not
        /// set in the second set.
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
                            return @intCast(next_index);
                        },
                        .reverse => {
                            const leading_zeroes = @clz(self.bits_remain);
                            const top_bit = (@bitSizeOf(MaskInt) - 1) - leading_zeroes;
                            self.bits_remain &= (@as(MaskInt, 1) << @as(ShiftInt, @intCast(top_bit))) - 1;
                            return @intCast(top_bit);
                        },
                    }
                }
            };
        }

        inline fn maskBit(index: IndexT) MaskInt {
            if (MaskInt == u0) return 0;
            return @as(MaskInt, 1) << @as(ShiftInt, @intCast(index));
        }
    };
}

pub const IteratorOptions = struct {
    kind: Kind = .set,
    direction: Direction = .forward,

    pub const Kind = enum { set, unset };
    pub const Direction = enum { forward, reverse };
};
