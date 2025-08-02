const std = @import("std");
const testing = std.testing;
const util = @import("util.zig");
const x = @import("x.zig");

const c = @import("c.zig");

const UTF_SIZE = 4;
const ESC_BUF_SIZE = 128 * UTF_SIZE;
const ESC_ARG_SIZE = 16;
const STR_BUF_SIZE = ESC_BUF_SIZE;
const STR_ARG_SIZE = ESC_ARG_SIZE;

// https://vt100.net/emu/dec_ansi_parser
const Control = struct {
    const NUL = @intFromEnum(C0.NUL); // 0x00
    const CAN = @intFromEnum(C0.CAN); // 0x18
    const SUB = @intFromEnum(C0.SUB); // 0x1A
    const ESC = @intFromEnum(C0.ESC); // 0x1B
    const FS = @intFromEnum(C0.FS); // 0x1C
    const GS = @intFromEnum(C0.GS); // 0x1D
    const RS = @intFromEnum(C0.RS); // 0x1E
    const US = @intFromEnum(C0.US); // 0x1F
    const DEL = @intFromEnum(C0.DEL); // 0x7F
};

const Ascii = struct {
    const SPACE = 0x20;
    const TILDE = 0x7E;
    const PRINTABLE_MIN = SPACE; // 0x20
    const PRINTABLE_MAX = TILDE; // 0x7E
    const INTERMEDIATE_MIN = SPACE; // 0x20
    const INTERMEDIATE_MAX = 0x2F; // '/'
    const DIGIT_MIN = 0x30; // '0'
    const DIGIT_MAX = 0x39; // '9'
    const SEMICOLON = 0x3B; // ';'
    const COLON = 0x3A; // ':'
    const PARAM_PREFIX_MIN = 0x3C; // '<'
    const PARAM_PREFIX_MAX = 0x3F; // '?'
    const FINAL_BYTE_MIN = 0x40; // '@'
    const FINAL_BYTE_MAX = TILDE; // 0x7E
};

const C1 = struct {
    const DCS = 0x90; // Device Control String
    const CSI = 0x9B; // Control Sequence Introducer
    const ST = 0x9C; // String Terminator
    const OSC = 0x9D; // Operating System Command
    const SOS = 0x98; // Start of String
    const PM = 0x9E; // Privacy Message
    const APC = 0x9F; // Application Program Command
    const C1_MIN = 0x80;
    const C1_MAX = 0x9F;
};

const StateTransition = struct {
    action: ?Action,
    to_state: ?State,
};

const state_transitions = [_][]const Transition{
    ground_transitions,
    escape_transitions,
    escape_intermediate_transitions,
    csi_entry_transitions,
    csi_param_transitions,
    csi_intermediate_transitions,
    csi_ignore_transitions,
    osc_string_transitions,
    dcs_entry_transitions,
    dcs_param_transitions,
    dcs_intermediate_transitions,
    dcs_ignore_transitions,
    dcs_passthrough_transitions,
    sos_pm_apc_string_transitions,
};

pub const entry_actions = [_]?Action{
    .CLEAR, null, null, null, .CLEAR, null, null, null, .HOOK, .CLEAR, null, null, .OSC_START, null,
    null,   null, null, null, null,   null,
};

pub const exit_actions = [_]?Action{
    null, null, null, null, null, null, null, null, .UNHOOK, null, null, null, .OSC_END, null,
    null, null, null, null, null, null,
};

pub const State = enum(u8) {
    GROUND,
    ESCAPE,
    ESCAPE_INTERMEDIATE,
    CSI_ENTRY,
    CSI_PARAM,
    CSI_INTERMEDIATE,
    CSI_IGNORE,
    OSC_STRING,
    DCS_ENTRY,
    DCS_PARAM,
    DCS_INTERMEDIATE,
    DCS_IGNORE,
    DCS_PASSTHROUGH,
    SOS_PM_APC_STRING,
};

pub const Action = enum(u8) {
    CLEAR,
    COLLECT,
    CSI_DISPATCH,
    ESC_DISPATCH,
    EXECUTE,
    HOOK,
    IGNORE,
    OSC_END,
    OSC_PUT,
    OSC_START,
    PARAM,
    PRINT,
    PUT,
    UNHOOK,
};

const Transition = struct {
    min_char: u8,
    max_char: u8,
    action: ?Action,
    to_state: ?State,
};

const StateTransitionEntry = struct {
    char: u8,
    action: ?Action,
    to_state: ?State,
};

const common_transitions = [_]Transition{
    .{ .min_char = 0x18, .max_char = 0x18, .action = .EXECUTE, .to_state = .GROUND },
    .{ .min_char = 0x1a, .max_char = 0x1a, .action = .EXECUTE, .to_state = .GROUND },
    .{ .min_char = 0x80, .max_char = 0x8f, .action = .EXECUTE, .to_state = .GROUND },
    .{ .min_char = 0x91, .max_char = 0x97, .action = .EXECUTE, .to_state = .GROUND },
    .{ .min_char = 0x99, .max_char = 0x99, .action = .EXECUTE, .to_state = .GROUND },
    .{ .min_char = 0x9a, .max_char = 0x9a, .action = .EXECUTE, .to_state = .GROUND },
    .{ .min_char = 0x9c, .max_char = 0x9c, .action = null, .to_state = .GROUND },
    .{ .min_char = 0x1b, .max_char = 0x1b, .action = null, .to_state = .ESCAPE },
    .{ .min_char = 0x98, .max_char = 0x98, .action = null, .to_state = .SOS_PM_APC_STRING },
    .{ .min_char = 0x9e, .max_char = 0x9f, .action = null, .to_state = .SOS_PM_APC_STRING },
    .{ .min_char = 0x90, .max_char = 0x90, .action = null, .to_state = .DCS_ENTRY },
    .{ .min_char = 0x9d, .max_char = 0x9d, .action = null, .to_state = .OSC_STRING },
    .{ .min_char = 0x9b, .max_char = 0x9b, .action = null, .to_state = .CSI_ENTRY },
};

const ground_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x7f, .action = .PRINT, .to_state = null },
} ++ common_transitions;

const escape_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x2f, .action = .COLLECT, .to_state = .ESCAPE_INTERMEDIATE },
    .{ .min_char = 0x30, .max_char = 0x4f, .action = .ESC_DISPATCH, .to_state = .GROUND },
    .{ .min_char = 0x51, .max_char = 0x57, .action = .ESC_DISPATCH, .to_state = .GROUND },
    .{ .min_char = 0x59, .max_char = 0x5a, .action = .ESC_DISPATCH, .to_state = .GROUND },
    .{ .min_char = 0x5c, .max_char = 0x5c, .action = .ESC_DISPATCH, .to_state = .GROUND },
    .{ .min_char = 0x60, .max_char = 0x7e, .action = .ESC_DISPATCH, .to_state = .GROUND },
    .{ .min_char = 0x5b, .max_char = 0x5b, .action = null, .to_state = .CSI_ENTRY },
    .{ .min_char = 0x5d, .max_char = 0x5d, .action = null, .to_state = .OSC_STRING },
    .{ .min_char = 0x50, .max_char = 0x50, .action = null, .to_state = .DCS_ENTRY },
    .{ .min_char = 0x58, .max_char = 0x58, .action = null, .to_state = .SOS_PM_APC_STRING },
    .{ .min_char = 0x5e, .max_char = 0x5f, .action = null, .to_state = .SOS_PM_APC_STRING },
} ++ common_transitions;

const escape_intermediate_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x2f, .action = .COLLECT, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x30, .max_char = 0x7e, .action = .ESC_DISPATCH, .to_state = .GROUND },
} ++ common_transitions;

const csi_entry_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x2f, .action = .COLLECT, .to_state = .CSI_INTERMEDIATE },
    .{ .min_char = 0x3a, .max_char = 0x3a, .action = null, .to_state = .CSI_IGNORE },
    .{ .min_char = 0x30, .max_char = 0x39, .action = .PARAM, .to_state = .CSI_PARAM },
    .{ .min_char = 0x3b, .max_char = 0x3b, .action = .PARAM, .to_state = .CSI_PARAM },
    .{ .min_char = 0x3c, .max_char = 0x3f, .action = .COLLECT, .to_state = .CSI_PARAM },
    .{ .min_char = 0x40, .max_char = 0x7e, .action = .CSI_DISPATCH, .to_state = .GROUND },
} ++ common_transitions;

const csi_param_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x30, .max_char = 0x39, .action = .PARAM, .to_state = null },
    .{ .min_char = 0x3b, .max_char = 0x3b, .action = .PARAM, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x3a, .max_char = 0x3a, .action = null, .to_state = .CSI_IGNORE },
    .{ .min_char = 0x3c, .max_char = 0x3f, .action = null, .to_state = .CSI_IGNORE },
    .{ .min_char = 0x20, .max_char = 0x2f, .action = .COLLECT, .to_state = .CSI_INTERMEDIATE },
    .{ .min_char = 0x40, .max_char = 0x7e, .action = .CSI_DISPATCH, .to_state = .GROUND },
} ++ common_transitions;

const csi_intermediate_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x2f, .action = .COLLECT, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x30, .max_char = 0x3f, .action = null, .to_state = .CSI_IGNORE },
    .{ .min_char = 0x40, .max_char = 0x7e, .action = .CSI_DISPATCH, .to_state = .GROUND },
} ++ common_transitions;

const csi_ignore_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .EXECUTE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x3f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x40, .max_char = 0x7e, .action = null, .to_state = .GROUND },
} ++ common_transitions;

const dcs_entry_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x3a, .max_char = 0x3a, .action = null, .to_state = .DCS_IGNORE },
    .{ .min_char = 0x20, .max_char = 0x2f, .action = .COLLECT, .to_state = .DCS_INTERMEDIATE },
    .{ .min_char = 0x30, .max_char = 0x39, .action = .PARAM, .to_state = .DCS_PARAM },
    .{ .min_char = 0x3b, .max_char = 0x3b, .action = .PARAM, .to_state = .DCS_PARAM },
    .{ .min_char = 0x3c, .max_char = 0x3f, .action = .COLLECT, .to_state = .DCS_PARAM },
    .{ .min_char = 0x40, .max_char = 0x7e, .action = null, .to_state = .DCS_PASSTHROUGH },
} ++ common_transitions;

const dcs_param_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x30, .max_char = 0x39, .action = .PARAM, .to_state = null },
    .{ .min_char = 0x3b, .max_char = 0x3b, .action = .PARAM, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x3a, .max_char = 0x3a, .action = null, .to_state = .DCS_IGNORE },
    .{ .min_char = 0x3c, .max_char = 0x3f, .action = null, .to_state = .DCS_IGNORE },
    .{ .min_char = 0x20, .max_char = 0x2f, .action = .COLLECT, .to_state = .DCS_INTERMEDIATE },
    .{ .min_char = 0x40, .max_char = 0x7e, .action = null, .to_state = .DCS_PASSTHROUGH },
} ++ common_transitions;

const dcs_intermediate_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x2f, .action = .COLLECT, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x30, .max_char = 0x3f, .action = null, .to_state = .DCS_IGNORE },
    .{ .min_char = 0x40, .max_char = 0x7e, .action = null, .to_state = .DCS_PASSTHROUGH },
} ++ common_transitions;

const dcs_passthrough_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .PUT, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .PUT, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .PUT, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x7e, .action = .PUT, .to_state = null },
    .{ .min_char = 0x7f, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
} ++ common_transitions;

const dcs_ignore_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
} ++ common_transitions;

const osc_string_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x7f, .action = .OSC_PUT, .to_state = null },
} ++ common_transitions;

const sos_pm_apc_string_transitions = [_]Transition{
    .{ .min_char = 0x00, .max_char = 0x17, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x19, .max_char = 0x19, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x1c, .max_char = 0x1f, .action = .IGNORE, .to_state = null },
    .{ .min_char = 0x20, .max_char = 0x7f, .action = .IGNORE, .to_state = null },
} ++ common_transitions;

fn build_state_table(comptime transitions: []const Transition) [256]?StateTransitionEntry {
    @setEvalBranchQuota(10000);
    var table: [256]?StateTransitionEntry = [_]?StateTransitionEntry{null} ** 256;
    comptime {
        for (transitions) |trans| {
            var char: u8 = trans.min_char;
            while (char <= trans.max_char) : (char += 1) {
                table[char] = .{
                    .char = char,
                    .action = trans.action,
                    .to_state = trans.to_state,
                };
            }
        }
    }
    return table;
}

const state_tables = blk: {
    const tables = [_][256]?StateTransitionEntry{
        build_state_table(&ground_transitions),
        build_state_table(&escape_transitions),
        build_state_table(&escape_intermediate_transitions),
        build_state_table(&csi_entry_transitions),
        build_state_table(&csi_param_transitions),
        build_state_table(&csi_intermediate_transitions),
        build_state_table(&csi_ignore_transitions),
        build_state_table(&osc_string_transitions),
        build_state_table(&dcs_entry_transitions),
        build_state_table(&dcs_param_transitions),
        build_state_table(&dcs_intermediate_transitions),
        build_state_table(&dcs_ignore_transitions),
        build_state_table(&dcs_passthrough_transitions),
        build_state_table(&sos_pm_apc_string_transitions),
    };
    break :blk tables;
};

fn get_transition(state: State, char: u8) ?StateTransitionEntry {
    return state_tables[@intFromEnum(state)][char];
}

test "GROUND state transitions" {
    try testing.expectEqual(get_transition(.GROUND, 'A').?.action, .PRINT);
    try testing.expectEqual(get_transition(.GROUND, 'A').?.to_state, null);
    try testing.expectEqual(get_transition(.GROUND, 0x20).?.action, .PRINT);
    try testing.expectEqual(get_transition(.GROUND, 0x7f).?.action, .PRINT);

    try testing.expectEqual(get_transition(.GROUND, 0x00).?.action, .EXECUTE);
    try testing.expectEqual(get_transition(.GROUND, 0x00).?.to_state, null);
    try testing.expectEqual(get_transition(.GROUND, 0x1f).?.action, .EXECUTE);

    try testing.expectEqual(get_transition(.GROUND, 0x1b).?.action, null);
    try testing.expectEqual(get_transition(.GROUND, 0x1b).?.to_state, .ESCAPE);

    try testing.expectEqual(get_transition(.GROUND, 0x9c).?.action, null);
    try testing.expectEqual(get_transition(.GROUND, 0x9c).?.to_state, .GROUND);
    try testing.expectEqual(get_transition(.GROUND, 0x9b).?.action, null);
    try testing.expectEqual(get_transition(.GROUND, 0x9b).?.to_state, .CSI_ENTRY);
}

test "ESCAPE state transitions" {
    try testing.expectEqual(get_transition(.ESCAPE, 0x00).?.action, .EXECUTE);
    try testing.expectEqual(get_transition(.ESCAPE, 0x00).?.to_state, null);
    try testing.expectEqual(get_transition(.ESCAPE, 0x7f).?.action, .IGNORE);

    try testing.expectEqual(get_transition(.ESCAPE, 0x20).?.action, .COLLECT);
    try testing.expectEqual(get_transition(.ESCAPE, 0x20).?.to_state, .ESCAPE_INTERMEDIATE);

    try testing.expectEqual(get_transition(.ESCAPE, 0x30).?.action, .ESC_DISPATCH);
    try testing.expectEqual(get_transition(.ESCAPE, 0x30).?.to_state, .GROUND);
    try testing.expectEqual(get_transition(.ESCAPE, 0x60).?.action, .ESC_DISPATCH);
    try testing.expectEqual(get_transition(.ESCAPE, 0x60).?.to_state, .GROUND);

    try testing.expectEqual(get_transition(.ESCAPE, 0x5b).?.action, null);
    try testing.expectEqual(get_transition(.ESCAPE, 0x5b).?.to_state, .CSI_ENTRY);
    try testing.expectEqual(get_transition(.ESCAPE, 0x5d).?.action, null);
    try testing.expectEqual(get_transition(.ESCAPE, 0x5d).?.to_state, .OSC_STRING);
    try testing.expectEqual(get_transition(.ESCAPE, 0x50).?.action, null);
    try testing.expectEqual(get_transition(.ESCAPE, 0x50).?.to_state, .DCS_ENTRY);
}

test "ESCAPE_INTERMEDIATE state transitions" {
    try testing.expectEqual(get_transition(.ESCAPE_INTERMEDIATE, 0x00).?.action, .EXECUTE);
    try testing.expectEqual(get_transition(.ESCAPE_INTERMEDIATE, 0x20).?.action, .COLLECT);
    try testing.expectEqual(get_transition(.ESCAPE_INTERMEDIATE, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.ESCAPE_INTERMEDIATE, 0x30).?.action, .ESC_DISPATCH);
    try testing.expectEqual(get_transition(.ESCAPE_INTERMEDIATE, 0x30).?.to_state, .GROUND);
    try testing.expectEqual(get_transition(.ESCAPE_INTERMEDIATE, 0x1b).?.action, null);
    try testing.expectEqual(get_transition(.ESCAPE_INTERMEDIATE, 0x1b).?.to_state, .ESCAPE);
}

test "CSI_ENTRY state transitions" {
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x00).?.action, .EXECUTE);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x20).?.action, .COLLECT);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x20).?.to_state, .CSI_INTERMEDIATE);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x30).?.action, .PARAM);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x30).?.to_state, .CSI_PARAM);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x3a).?.action, null);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x3a).?.to_state, .CSI_IGNORE);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x40).?.action, .CSI_DISPATCH);
    try testing.expectEqual(get_transition(.CSI_ENTRY, 0x40).?.to_state, .GROUND);
}

test "CSI_PARAM state transitions" {
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x00).?.action, .EXECUTE);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x30).?.action, .PARAM);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x3b).?.action, .PARAM);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x3a).?.action, null);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x3a).?.to_state, .CSI_IGNORE);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x20).?.action, .COLLECT);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x20).?.to_state, .CSI_INTERMEDIATE);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x40).?.action, .CSI_DISPATCH);
    try testing.expectEqual(get_transition(.CSI_PARAM, 0x40).?.to_state, .GROUND);
}

test "CSI_INTERMEDIATE state transitions" {
    try testing.expectEqual(get_transition(.CSI_INTERMEDIATE, 0x00).?.action, .EXECUTE);
    try testing.expectEqual(get_transition(.CSI_INTERMEDIATE, 0x20).?.action, .COLLECT);
    try testing.expectEqual(get_transition(.CSI_INTERMEDIATE, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.CSI_INTERMEDIATE, 0x30).?.action, null);
    try testing.expectEqual(get_transition(.CSI_INTERMEDIATE, 0x30).?.to_state, .CSI_IGNORE);
    try testing.expectEqual(get_transition(.CSI_INTERMEDIATE, 0x40).?.action, .CSI_DISPATCH);
    try testing.expectEqual(get_transition(.CSI_INTERMEDIATE, 0x40).?.to_state, .GROUND);
}

test "CSI_IGNORE state transitions" {
    try testing.expectEqual(get_transition(.CSI_IGNORE, 0x00).?.action, .EXECUTE);
    try testing.expectEqual(get_transition(.CSI_IGNORE, 0x20).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.CSI_IGNORE, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.CSI_IGNORE, 0x40).?.action, null);
    try testing.expectEqual(get_transition(.CSI_IGNORE, 0x40).?.to_state, .GROUND);
}

test "OSC_STRING state transitions" {
    try testing.expectEqual(get_transition(.OSC_STRING, 0x00).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.OSC_STRING, 0x20).?.action, .OSC_PUT);
    try testing.expectEqual(get_transition(.OSC_STRING, 0x7f).?.action, .OSC_PUT);
    try testing.expectEqual(get_transition(.OSC_STRING, 0x1b).?.action, null);
    try testing.expectEqual(get_transition(.OSC_STRING, 0x1b).?.to_state, .ESCAPE);
}

test "DCS_ENTRY state transitions" {
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x00).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x20).?.action, .COLLECT);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x20).?.to_state, .DCS_INTERMEDIATE);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x30).?.action, .PARAM);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x30).?.to_state, .DCS_PARAM);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x3a).?.action, null);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x3a).?.to_state, .DCS_IGNORE);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x40).?.action, null);
    try testing.expectEqual(get_transition(.DCS_ENTRY, 0x40).?.to_state, .DCS_PASSTHROUGH);
}

test "DCS_PARAM state transitions" {
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x00).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x30).?.action, .PARAM);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x3b).?.action, .PARAM);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x3a).?.action, null);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x3a).?.to_state, .DCS_IGNORE);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x20).?.action, .COLLECT);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x20).?.to_state, .DCS_INTERMEDIATE);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x40).?.action, null);
    try testing.expectEqual(get_transition(.DCS_PARAM, 0x40).?.to_state, .DCS_PASSTHROUGH);
}

test "DCS_INTERMEDIATE state transitions" {
    try testing.expectEqual(get_transition(.DCS_INTERMEDIATE, 0x00).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_INTERMEDIATE, 0x20).?.action, .COLLECT);
    try testing.expectEqual(get_transition(.DCS_INTERMEDIATE, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_INTERMEDIATE, 0x30).?.action, null);
    try testing.expectEqual(get_transition(.DCS_INTERMEDIATE, 0x30).?.to_state, .DCS_IGNORE);
    try testing.expectEqual(get_transition(.DCS_INTERMEDIATE, 0x40).?.action, null);
    try testing.expectEqual(get_transition(.DCS_INTERMEDIATE, 0x40).?.to_state, .DCS_PASSTHROUGH);
}

test "DCS_PASSTHROUGH state transitions" {
    try testing.expectEqual(get_transition(.DCS_PASSTHROUGH, 0x00).?.action, .PUT);
    try testing.expectEqual(get_transition(.DCS_PASSTHROUGH, 0x20).?.action, .PUT);
    try testing.expectEqual(get_transition(.DCS_PASSTHROUGH, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_PASSTHROUGH, 0x1b).?.action, null);
    try testing.expectEqual(get_transition(.DCS_PASSTHROUGH, 0x1b).?.to_state, .ESCAPE);
}

test "DCS_IGNORE state transitions" {
    try testing.expectEqual(get_transition(.DCS_IGNORE, 0x00).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_IGNORE, 0x20).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_IGNORE, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.DCS_IGNORE, 0x1b).?.action, null);
    try testing.expectEqual(get_transition(.DCS_IGNORE, 0x1b).?.to_state, .ESCAPE);
}

test "SOS_PM_APC_STRING state transitions" {
    try testing.expectEqual(get_transition(.SOS_PM_APC_STRING, 0x00).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.SOS_PM_APC_STRING, 0x20).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.SOS_PM_APC_STRING, 0x7f).?.action, .IGNORE);
    try testing.expectEqual(get_transition(.SOS_PM_APC_STRING, 0x1b).?.action, null);
    try testing.expectEqual(get_transition(.SOS_PM_APC_STRING, 0x1b).?.to_state, .ESCAPE);
}

// https://en.wikipedia.org/wiki/ANSI_escape_code
/// See also: https://en.wikipedia.org/wiki/C0_and_C1_control_codes and `isControl`
/// 7 bit standart ascii escape_codes
pub const C0 = enum(u7) {
    NUL = 0x00,
    /// Null
    /// Start of Heading
    SOH = 0x01,
    /// Start of Text
    STX = 0x02,
    /// End of Text
    ETX = 0x03,
    /// End of Transmission
    EOT = 0x04,
    /// Enquiry
    ENQ = 0x05,
    /// Acknowledge
    ACK = 0x06,
    /// Bell
    BEL = 0x07,
    /// Backspace
    BS = 0x08,
    /// Horizontal Tab
    HT = 0x09,
    /// Line Feed
    LF = 0x0A,
    /// Vertical Tab
    VT = 0x0B,
    /// Form Feed
    FF = 0x0C,
    /// Carriage Return
    CR = 0x0D,
    /// Shift Out
    SO = 0x0E,
    /// Shift In
    SI = 0x0F,
    /// Data Link Escape
    DLE = 0x10,
    /// Device Control 1 (often XON)
    DC1 = 0x11,
    /// Device Control 2
    DC2 = 0x12,
    /// Device Control 3 (often XOFF)
    DC3 = 0x13,
    /// Device Control 4
    DC4 = 0x14,
    /// Negative Acknowledge
    NAK = 0x15,
    /// Synchronous Idle
    SYN = 0x16,
    /// End of Transmission Block
    ETB = 0x17,
    /// Cancel
    CAN = 0x18,
    /// End of Medium
    EM = 0x19,
    /// Substitute
    SUB = 0x1A,
    /// Escape \x1B \033  \e "\0x1B[31mHello\0x1B[0m"
    ESC = 0x1B,
    /// File Separator
    FS = 0x1C,
    /// Group Separator
    GS = 0x1D,
    /// Record Separator
    RS = 0x1E,
    /// Unit Separator
    US = 0x1F,
    /// Delete
    DEL = 0x7F,
};
pub fn isControl(n: u8) bool {
    return n <= @intFromEnum(C0.US) or n == @intFromEnum(C0.DEL);
}

pub const SGR = enum(u8) {
    /// Reset all attributes 0m reset
    Reset = 0,
    /// Bold or increased intensity
    Bold = 1,
    /// Faint or decreased intensity
    Faint = 2,
    /// Italic for example \033[3mtest\033[m
    Italic = 3,
    /// Underline
    Underline = 4,
    /// Slow blink
    BlinkSlow = 5,
    /// Rapid blink
    BlinkRapid = 6,
    /// Reverse video (swap foreground and background)
    Reverse = 7,
    /// Conceal (hide text)
    Conceal = 8,
    /// Crossed-out (strikethrough)
    CrossedOut = 9,

    /// Foreground: Black
    FgBlack = 30,
    /// Foreground: Red
    FgRed = 31,
    /// Foreground: Green
    FgGreen = 32,
    /// Foreground: Yellow
    FgYellow = 33,
    /// Foreground: Blue
    FgBlue = 34,
    /// Foreground: Magenta
    FgMagenta = 35,
    /// Foreground: Cyan
    FgCyan = 36,
    /// Foreground: White
    FgWhite = 37,
    /// Foreground: Default
    FgDefault = 39,

    /// Background: Black
    BgBlack = 40,
    /// Background: Red
    BgRed = 41,
    /// Background: Green
    BgGreen = 42,
    /// Background: Yellow
    BgYellow = 43,
    /// Background: Blue
    BgBlue = 44,
    /// Background: Magenta
    BgMagenta = 45,
    /// Background: Cyan
    BgCyan = 46,
    /// Background: White
    BgWhite = 47,
    /// Background: Default
    BgDefault = 49,

    /// Bright Foreground: Black
    FgBrightBlack = 90,
    /// Bright Foreground: Red
    FgBrightRed = 91,
    /// Bright Foreground: Green
    FgBrightGreen = 92,
    /// Bright Foreground: Yellow
    FgBrightYellow = 93,
    /// Bright Foreground: Blue
    FgBrightBlue = 94,
    /// Bright Foreground: Magenta
    FgBrightMagenta = 95,
    /// Bright Foreground: Cyan
    FgBrightCyan = 96,
    /// Bright Foreground: White
    FgBrightWhite = 97,

    /// Bright Background: Black
    BgBrightBlack = 100,
    /// Bright Background: Red
    BgBrightRed = 101,
    /// Bright Background: Green
    BgBrightGreen = 102,
    /// Bright Background: Yellow
    BgBrightYellow = 103,
    /// Bright Background: Blue
    BgBrightBlue = 104,
    /// Bright Background: Magenta
    BgBrightMagenta = 105,
    /// Bright Background: Cyan
    BgBrightCyan = 106,
    /// Bright Background: White
    BgBrightWhite = 107,
};

pub fn isSGR(n: u8) bool {
    return (n <= 9) or
        (n >= 30 and n <= 39) or
        (n >= 40 and n <= 49) or
        (n >= 90 and n <= 97) or
        (n >= 100 and n <= 107);
}

pub const CSI_ENUM = enum(u8) {
    /// Cursor Up (CUU)
    CursorUp = 'A',
    /// Cursor Down (CUD)
    CursorDown = 'B',
    /// Cursor Forward (CUF)
    CursorForward = 'C',
    /// Cursor Back (CUB)
    CursorBack = 'D',
    /// Cursor Next Line (CNL)
    CursorNextLine = 'E',
    /// Cursor Previous Line (CPL)
    CursorPreviousLine = 'F',
    /// Cursor Horizontal Absolute (CHA)
    CursorHorizontalAbsolute = 'G',
    /// Cursor Position (CUP)
    CursorPosition = 'H',
    /// Erase in Display (ED)
    EraseInDisplay = 'J',
    /// Erase in Line (EL)
    EraseInLine = 'K',
    /// Scroll Up (SU)
    ScrollUp = 'S',
    /// Scroll Down (SD)
    ScrollDown = 'T',
    /// Horizontal and Vertical Position (HVP), same as CUP
    HorizontalVerticalPosition = 'f',
    /// Select Graphic Rendition (SGR)
    SelectGraphicRendition = 'm',
    /// Device Status Report (DSR)
    DeviceStatusReport = 'n',
    /// Save Cursor Position (SCP)
    SaveCursorPosition = 's',
    /// Restore Cursor Position (RCP)
    RestoreCursorPosition = 'u',
    /// Insert Line (IL)
    InsertLine = 'L',
    /// Delete Line (DL)
    DeleteLine = 'M',
    /// Erase Characters (ECH)
    EraseCharacters = 'X',
    /// Insert Characters (ICH)
    InsertCharacters = '@',
    /// Delete Characters (DCH)
    DeleteCharacters = 'P',
    /// Character Tabulation (CHT)
    CharacterTabulation = 'I',
    /// Character Backwards Tabulation (CBT)
    CharacterBackwardsTabulation = 'Z',
    /// Vertical Position Absolute (VPA)
    VerticalPositionAbsolute = 'd',
    /// Media Control (MC)
    MediaControl = 'i',
    /// Device Attributes (DA)
    DeviceAttributes = 'c',
    /// Set Top and Bottom Margins (DECSTBM)
    DECSTBM = 'r',
};

pub fn isCSI(n: u8) bool {
    return (n >= 'A' and n <= 'K') or
        (n == 'S' or n == 'T') or
        (n == 'f' or n == 'm' or n == 'n' or n == 's' or n == 'u');
}

pub const OSC = enum(u8) {
    /// Set icon name and window title
    SetIconAndWindowTitle = 0,
    /// Set window title
    SetWindowTitle = 2,
    /// Set X property on top-level window
    SetXProperty = 3,
    /// Set foreground color
    SetForegroundColor = 10,
    /// Set background color
    SetBackgroundColor = 11,
    /// Set text cursor color
    SetCursorColor = 12,
    /// Set mouse foreground color
    SetMouseForegroundColor = 13,
    /// Set mouse background color
    SetMouseBackgroundColor = 14,
    /// Set highlight color
    SetHighlightColor = 17,
    /// Set hyperlink
    SetHyperlink = 8,
    /// Set current directory
    SetCurrentDirectory = 7,
    /// Set clipboard
    SetClipboard = 52,
};

pub const Parser = struct {
    state: State,
    buf: [ESC_BUF_SIZE]u8,
    len: usize,
    params: [ESC_ARG_SIZE]u32,
    narg: usize,
    priv: u8,
    mode: [2]u8,
    str_buf: [ESC_BUF_SIZE]u8,
    str_len: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .state = .GROUND,
            .buf = undefined,
            .len = 0,
            .params = [_]u32{0} ** ESC_ARG_SIZE,
            .narg = 0,
            .priv = 0,
            .mode = [_]u8{ 0, 0 },
            .str_buf = undefined,
            .str_len = 0,
            .allocator = allocator,
        };
    }

    pub fn reset(self: *Self) void {
        self.state = .GROUND;
        self.len = 0;
        self.narg = 0;
        self.priv = 0;
        self.mode = [_]u8{ 0, 0 };
        self.str_len = 0;
    }

    pub fn process_char(self: *Self, term: *x.Term, xterm: *x.XlibTerminal, char: u8) !void {
        if (self.len >= self.buf.len) {
            std.log.warn("Escape sequence buffer overflow: {x}", .{self.buf[0..self.len]});
            self.reset();
            return;
        }

        if (get_transition(self.state, char)) |trans| {
            if (trans.to_state) |new_state| {
                if (exit_actions[@intFromEnum(self.state)]) |exit_action| {
                    try self.perform_action(term, xterm, exit_action, null);
                }
                if (entry_actions[@intFromEnum(new_state)]) |entry_action| {
                    try self.perform_action(term, xterm, entry_action, null);
                }
                self.state = new_state;
            }

            if (trans.action) |action| {
                try self.perform_action(term, xterm, action, char);
            }
        }
    }

    pub fn process_input(self: *Self, term: *x.Term, xterm: *x.XlibTerminal, input: []const u8) !void {
        var i: usize = 0;
        while (i < input.len) {
            // try to find start csi escape 0x1B
            if (util.indexOfCsiStart(input[i..])) |start| {
                // process csi bytes
                for (input[i .. i + start]) |cc| {
                    if (util.isPrintable(cc)) {
                        term.tputc(cc);
                    } else if (util.isControl(cc)) {
                        try self.process_char(term, xterm, cc);
                    } else {
                        std.log.warn("Non-ASCII character ignored: {x}", .{cc});
                    }
                }
                i += start;

                // process CSI ESCAPE
                var end: usize = undefined;
                const csi_len = util.simd_extract_csi_sequence(input[i..].ptr, input.len - i, 0, &end);
                if (csi_len > 0 and end <= input.len - i) {
                    const csi = input[i .. i + end];
                    if (csi.len <= self.buf.len) {
                        util.move(
                            u8,
                            self.buf[0..csi.len],
                            csi,
                        );
                        self.len = csi.len;
                        self.mode[0] = csi[csi.len - 1];
                        self.parse_csi_params();
                        try self.handle_csi(term, xterm);
                        self.reset();
                    } else {
                        std.log.warn("CSI sequence too long: {x}", .{csi});
                    }
                    i += end;
                } else {
                    // if csi not complete  make ostatok
                    try self.process_char(term, xterm, input[i]);
                    i += 1;
                }
            } else {
                // ostatok
                for (input[i..]) |cc| {
                    if (util.isPrintable(cc)) {
                        term.tputc(cc);
                    } else if (util.isControl(cc)) {
                        try self.process_char(term, xterm, cc);
                    } else {
                        std.log.warn("Non-ASCII character ignored: {x}", .{cc});
                    }
                }
                break;
            }
        }
    }
    fn perform_action(self: *Self, term: *x.Term, xterm: *x.XlibTerminal, action: Action, char: ?u8) !void {
        switch (action) {
            .CLEAR => {
                self.reset();
            },
            .COLLECT => {
                if (char) |cc| {
                    if (self.state == .CSI_PARAM or self.state == .CSI_ENTRY or self.state == .DCS_PARAM or self.state == .DCS_ENTRY) {
                        self.buf[self.len] = cc;
                        self.len += 1;
                    } else {
                        self.buf[self.len] = cc;
                        self.len += 1;
                    }
                }
            },
            .CSI_DISPATCH => {
                if (char) |cc| {
                    self.mode[0] = cc;
                    if (cc < Ascii.FINAL_BYTE_MIN or cc > Ascii.FINAL_BYTE_MAX) {
                        std.log.warn("Invalid CSI final byte: {x}", .{cc});
                        self.reset();
                        return;
                    }
                    self.parse_csi_params();
                    try self.handle_csi(term, xterm);
                    self.reset();
                }
            },
            .ESC_DISPATCH => {
                if (char) |cc| {
                    try self.handle_esc(term, cc);
                    self.reset();
                }
            },
            .EXECUTE => {
                if (char) |cc| {
                    try self.handle_execute(term, xterm, cc);
                }
            },
            .HOOK => {
                self.str_len = 0;
            },
            .IGNORE => {},
            .OSC_START => {
                self.str_len = 0;
            },
            .OSC_PUT => {
                if (char) |cc| {
                    if (self.str_len < self.str_buf.len) {
                        self.str_buf[self.str_len] = cc;
                        self.str_len += 1;
                    }
                }
            },
            .OSC_END => {
                try self.handle_osc(xterm);
                self.reset();
            },
            .PUT => {
                if (char) |cc| {
                    if (self.str_len < self.str_buf.len) {
                        self.str_buf[self.str_len] = cc;
                        self.str_len += 1;
                    }
                }
            },
            .UNHOOK => {
                // try self.handle_dcs(term, xterm);
                self.reset();
            },
            .PRINT => {
                if (char) |cc| {
                    if (util.isPrintable(cc)) {
                        term.tputc(cc);
                    } else {
                        std.log.warn("Non-printable character ignored: {x}", .{cc});
                    }
                }
            },
            else => unreachable,
        }
    }

    inline fn parse_csi_params(self: *Self) void {
        self.narg = 0;
        self.priv = if (self.len > 0 and self.buf[0] == '?') 1 else 0;

        if (self.len <= 1 + self.priv) {
            self.params[0] = 0;
            self.narg = 1;
            return;
        }

        const param_str = self.buf[self.priv..self.len];
        var iter = std.mem.splitScalar(u8, param_str, ';');
        while (iter.next()) |param| {
            if (self.narg >= ESC_ARG_SIZE) break;
            if (param.len == 0) {
                self.params[self.narg] = 0;
            } else {
                self.params[self.narg] = std.fmt.parseInt(u32, param, 10) catch 0;
            }
            self.narg += 1;
        }
        if (self.narg == 0) {
            self.params[0] = 0;
            self.narg = 1;
        }
    }
    //  CSI-escapes
    fn handle_csi(self: *Self, term: *x.Term, xterm: *x.XlibTerminal) !void {
        const mode = self.mode[0];
        switch (@as(CSI_ENUM, @enumFromInt(mode))) {
            .CursorUp => try term.csi_cuu(self.params[0..self.narg]),
            .CursorDown => term.csi_cud(self.params[0..self.narg]),
            .CursorForward => term.csi_cuf(self.params[0..self.narg]),
            .CursorBack => try term.csi_cub(self.params[0..self.narg]),
            .CursorNextLine => term.csi_cnl(self.params[0..self.narg]),
            .CursorPreviousLine => term.csi_cpl(self.params[0..self.narg]),
            .CursorHorizontalAbsolute => term.csi_cha(self.params[0..self.narg]),
            .CursorPosition => term.csi_cup(self.params[0..self.narg]),
            .EraseInDisplay => term.csi_ed(self.params[0..self.narg]),
            .EraseInLine => term.csi_el(self.params[0..self.narg]),
            .ScrollUp => term.csi_su(self.params[0..self.narg]),
            .ScrollDown => term.csi_sd(self.params[0..self.narg]),
            .InsertLine => term.csi_il(self.params[0..self.narg]),
            .DeleteLine => term.csi_dl(self.params[0..self.narg]),
            .EraseCharacters => term.csi_ech(self.params[0..self.narg]),
            .InsertCharacters => try term.csi_ich(self.params[0..self.narg]),
            .DeleteCharacters => term.csi_dch(self.params[0..self.narg]),
            .CharacterTabulation => term.csi_cht(self.params[0..self.narg]),
            .CharacterBackwardsTabulation => term.csi_cbt(self.params[0..self.narg]),
            .VerticalPositionAbsolute => term.csi_vpa(self.params[0..self.narg]),
            .SelectGraphicRendition => term.csi_sgr(self.params[0..self.narg], self.narg),
            .DeviceStatusReport => term.csi_dsr(self.params[0..self.narg], xterm),
            .MediaControl => term.csi_mc(self.params[0..self.narg], xterm),
            .DeviceAttributes => term.csi_da(self.params[0..self.narg], xterm),
            .SaveCursorPosition => term.tcursor(.CURSOR_SAVE),
            .RestoreCursorPosition => term.tcursor(.CURSOR_LOAD),
            .DECSTBM => term.csi_decstbm(self.params[0..self.narg]),
            else => std.log.warn("Unknown CSI mode: {c}", .{mode}),
        }
    }

    // ESC escapes
    inline fn handle_esc(_: *Self, term: *x.Term, char: u8) !void {
        switch (char) {
            'D' => term.tscrolldown(term.top, 1), // IND
            'E' => {
                term.cursor.pos.addX(0);
                if (term.cursor.pos.getY().? < term.window.tty_grid.getRows().? - 1) {
                    term.cursor.pos.addY(term.cursor.pos.getY().? + 1);
                } else {
                    term.tscrollup(term.top, 1);
                }
                term.set_dirt(@intCast(term.cursor.pos.getY().?), @intCast(term.cursor.pos.getY().?));
            },
            'M' => term.tscrollup(term.top, 1), // RI
            'H' => term.tabs[@intCast(term.cursor.pos.getX().?)] = 1, // HTS
            'c' => {
                term.reset();
                term.fulldirt();
            },
            '7' => term.tcursor(.CURSOR_SAVE),
            '8' => term.tcursor(.CURSOR_LOAD),
            else => std.log.debug("Unhandled ESC sequence: ESC {c}", .{char}),
        }
    }

    inline fn handle_execute(_: *Self, term: *x.Term, xterm: *x.XlibTerminal, char: u8) !void {
        switch (@as(C0, @enumFromInt(char))) {
            .BEL => xterm.ttywrite("\x07", 1, 0),
            .BS => try term.csi_cub(@ptrCast(@constCast(&[_]u32{1}))),
            .CR => term.cursor.pos.addX(0),
            .LF, .VT, .FF => {
                term.cursor.pos.addX(0);
                if (term.cursor.pos.getY().? < term.window.tty_grid.getRows().? - 1) {
                    term.cursor.pos.addY(term.cursor.pos.getY().? + 1);
                } else {
                    term.tscrollup(term.top, 1);
                }
                term.set_dirt(@intCast(term.cursor.pos.getY().?), @intCast(term.cursor.pos.getY().?));
            },
            .HT => term.tputtab(1),
            else => std.log.debug("Unhandled C0 control: {x}", .{char}),
        }
    }

    // OSC ESCAPES
    inline fn handle_osc(self: *Self, xterm: *x.XlibTerminal) !void {
        if (self.str_len == 0) return;
        const str = self.str_buf[0..self.str_len];

        if (util.containsNewlineOrNonASCIIOrQuote(&self.str_buf)) {
            std.log.warn("Invalid OSC string: {s}", .{str});
            return;
        }

        var iter = std.mem.splitAny(u8, str, ";");
        if (iter.next()) |cmd_str| {
            const cmd = std.fmt.parseInt(u32, cmd_str, 10) catch return;
            switch (@as(OSC, @enumFromInt(cmd))) {
                .SetWindowTitle, .SetIconAndWindowTitle => {
                    if (iter.next()) |title| {
                        var title_buf: [ESC_BUF_SIZE]u8 = undefined;
                        util.move(
                            u8,
                            @constCast(title),
                            &title_buf,
                        );
                        util.toUpper(title_buf[0..title.len]);
                        try xterm.set_title(title_buf[0..title.len]);
                    }
                },
                else => std.log.debug("Unhandled OSC command: {}", .{cmd}),
            }
        }
    }
};
