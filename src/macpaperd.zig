//    macpaperd.zig is a part of macpaperd.
//    macpaperd is a wallpaper daemon for macOS
//    Copyright (C) 2023 Luke Murray
//
//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const sqlite = @import("sqlite");

const Display = @import("Display.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const tmp_file = "/tmp/macpaperd.db";

const db_filename = "desktoppicture.db";

var home: [:0]const u8 = undefined;

fn printUsage() void {
    const usage =
        \\Usage:
        \\  macpaperd --set [file]         Set 'file' as the wallpaper. 'file' must be an absolute path.
        \\  macpaperd --color [hex color]  Set 'hex color' as the background color. 'hex color' must be a
        \\                                 valid, 6 character hexidecimal number WITHOUT the '0x' prefix.
        \\  macpaperd --displays           List the connected displays and their associated spaces.
        \\  macpaperd --help               Show this information.
    ;
    std.debug.print("{s}\n", .{usage});
}

const Args = struct {
    action: union(enum) {
        print_usage,
        displays,
        color: u24,
        image: []u8,
    },
    allocator: std.mem.Allocator,

    pub fn deinit(self: Args) void {
        if (self.action == .image) {
            self.allocator.free(self.action.image);
        }
    }
};

var print_debug_messages = false;

fn debug_print(msg: []const u8, args: anytype) void {
    if (print_debug_messages) {
        std.debug.print(msg, args);
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // first arg is the name of the executable

    var ret: ?Args = null;

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--displays")) {
            ret = .{ .allocator = allocator, .action = .displays };
        } else if (std.mem.eql(u8, arg, "--set")) {
            if (args.next()) |image| {
                ret = .{ .allocator = allocator, .action = .{ .image = try allocator.alloc(u8, image.len) } };
                std.mem.copy(u8, ret.?.action.image, image);
            } else {
                return error.MissingArgumentSet;
            }
        } else if (std.mem.eql(u8, arg, "--color")) {
            if (args.next()) |color| {
                const col: u24 = std.fmt.parseInt(u24, color, 16) catch |err| {
                    if (err == error.Overflow or err == error.InvalidCharacter) {
                        std.debug.print("Invalid hex color: {s}\n", .{color});
                        std.process.exit(1);
                    }
                    unreachable;
                };
                ret = .{ .allocator = allocator, .action = .{ .color = col } };
            } else {
                return error.MissingArgumentColor;
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            ret = .{ .allocator = allocator, .action = .print_usage };
        }
    }

    while (args.next()) |arg| {
        std.debug.print("Unused arg: {s}\n", .{arg});
    }

    if (ret == null) {
        return error.NoArgs;
    }

    return ret.?;
}

pub fn main() !void {
    home = std.os.getenv("HOME").?;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = parseArgs(allocator) catch |err| {
        // TODO can do better? maybe merge MissingArgumentSet and MissingArgumentColor
        switch (err) {
            error.MissingArgumentSet => std.debug.print("Missing image argument for --set\n", .{}),
            error.MissingArgumentColor => std.debug.print("Missing color argument for --color\n", .{}),
            error.NoArgs => std.debug.print("Missing arguments; run with '--help' to see a list of options\n", .{}),
            else => return err,
        }
        std.process.exit(1);
    };
    defer args.deinit();

    switch (args.action) {
        .displays => try listDisplays(allocator),
        .print_usage => printUsage(),
        .color => try setColor(
            allocator,
            @intCast((args.action.color & 0xFF0000) >> 16),
            @intCast((args.action.color & 0x00FF00) >> 8),
            @intCast((args.action.color & 0x0000FF) >> 0),
        ),
        .image => {
            setWallpaper(allocator, args.action.image) catch |err| {
                if (err == error.InvalidFormat) {
                    std.debug.print("Invalid image format in file {s}\n", .{args.action.image});
                    std.process.exit(1);
                }
                return err;
            };
        },
    }
}

fn listDisplays(allocator: std.mem.Allocator) !void {
    const displays = try Display.getDisplays(allocator);
    defer {
        for (displays) |*display| {
            display.deinit();
        }
        allocator.free(displays);
    }
    for (displays, 1..) |display, i| {
        std.debug.print("Display {d} (uuid: {s})\n", .{ i, display.uuid });
        for (display.spaces, 1..) |space, j| {
            std.debug.print("  Space {d} (uuid: {s}, is-fullscreen: {s})\n", .{
                j,
                space.uuid,
                if (space.fullscreen) "true" else "false",
            });
        }
    }
}

const WallpaperType = enum {
    file,
    color,
};

fn setColor(allocator: std.mem.Allocator, r: u8, g: u8, b: u8) !void {
    debug_print("Setting wallpaper to color r: {d}, g: {d}, b: {d}\n", .{ r, g, b });
    std.fs.deleteFileAbsolute(tmp_file) catch |err| {
        if (err == error.FileNotFound) {} else return err;
    };
    var db = try createDb();
    defer db.deinit();
    try fillDisplaysAndSpaces(allocator, &db);
    try fillPicturesPreferences(allocator, &db, .color);
    try fillColorData(&db, r, g, b);
    try replaceOldWithNew(allocator);
    try restartDock(allocator);
}

fn setWallpaper(allocator: std.mem.Allocator, path: []const u8) !void {
    { // Validate path
        try std.fs.accessAbsolute(path, .{}); // exists
        if (!std.mem.eql(u8, ".png", path[path.len - 4 ..]) and
            !std.mem.eql(u8, ".jpg", path[path.len - 4 ..]) and
            !std.mem.eql(u8, ".tiff", path[path.len - 5 ..]) and
            !std.mem.eql(u8, ".heic", path[path.len - 5 ..]))
        {
            return error.InvalidFormat;
        }
    }
    std.fs.deleteFileAbsolute(tmp_file) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    var db = try createDb(); // prefs is complete (empty)
    defer db.deinit();
    try fillDisplaysAndSpaces(allocator, &db); // displays and spaces are complete
    try fillPicturesPreferences(allocator, &db, .file); // pictures and preferences are complete
    try fillFileData(&db, path); // data is complete; DB done
    try replaceOldWithNew(allocator);
    try restartDock(allocator);
}

fn restartDock(allocator: std.mem.Allocator) !void {
    const results = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "/usr/bin/killall", "Dock" },
    });
    assert(results.stdout.len == 0);
    assert(results.stderr.len == 0);
}

fn replaceOldWithNew(allocator: std.mem.Allocator) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/Dock/desktoppicture.db", .{home});
    defer allocator.free(path);

    std.fs.deleteFileAbsolute(path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try std.fs.copyFileAbsolute(tmp_file, path, .{});
}

fn fillFileData(db: *sqlite.Db, file_path: []const u8) !void {
    try std.fs.accessAbsolute(file_path, .{}); // ensure file exists
    const folder = blk: {
        var i = file_path.len - 1;
        while (i >= 0) : (i -= 1) {
            if (file_path[i] == '/') {
                break :blk file_path[0..i];
            }
        }
    };
    const insert = "INSERT INTO data(value) VALUES(?)";
    debug_print("{s}\n", .{insert});
    try db.execDynamic(insert, .{}, .{ .value = folder });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, 0) });
    try db.execDynamic(insert, .{}, .{ .value = file_path });
}

fn fillColorData(db: *sqlite.Db, r: u8, g: u8, b: u8) !void {
    const insert = "INSERT INTO data(value) VALUES(?)";
    debug_print("{s}\n", .{insert});
    try db.execDynamic(insert, .{}, .{ .value = @as([]const u8, "/System/Library/Desktop Pictures/Solid Colors") });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, 0) });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, 1) });
    try db.execDynamic(insert, .{}, .{ .value = @as([]const u8, "/System/Library/PreferencePanes/DesktopScreenEffectsPref.prefPane/Contents/Resources/DesktopPictures.prefPane/Contents/Resources/Transparent.tiff") });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt(r)) / 255.0 });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt(g)) / 255.0 });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt(b)) / 255.0 });
}

const Preference = struct {
    key: u8,
    data_id: u8,
};

const file_preferences = [_]Preference{
    Preference{ .key = 10, .data_id = 1 },
    Preference{ .key = 20, .data_id = 2 },
    Preference{ .key = 1, .data_id = 3 },
};

const color_preferences = [_]Preference{
    Preference{ .key = 15, .data_id = 3 },
    Preference{ .key = 1, .data_id = 4 },
    Preference{ .key = 3, .data_id = 5 },
    Preference{ .key = 4, .data_id = 6 },
    Preference{ .key = 5, .data_id = 7 },
    Preference{ .key = 10, .data_id = 1 },
    Preference{ .key = 20, .data_id = 2 },
};

fn fillPreference(db: *sqlite.Db, cmd: []const u8, index: usize, preferences: []const Preference) !void {
    for (preferences) |*pref| {
        try db.execDynamic(cmd, .{}, .{ .key = @as(usize, pref.key), .data_id = @as(usize, pref.data_id), .picture_id = index });
    }
}

// Inserts into preferences and pictures, since those depend on looping through the spaces
fn fillPicturesPreferences(allocator: std.mem.Allocator, db: *sqlite.Db, wallpaper_type: WallpaperType) !void {
    const row_count: usize = blk: {
        const displays = try Display.getDisplays(allocator);
        defer {
            for (displays) |*display| {
                display.deinit();
            }
            allocator.free(displays);
        }
        break :blk displays[0].spaces.len;
    };
    const insert_picture = "INSERT INTO pictures(space_id, display_id) VALUES(?, ?)";
    const insert_preference = "INSERT INTO preferences(key, data_id, picture_id) VALUES(?, ?, ?)";
    debug_print("{s}\n", .{insert_picture});
    debug_print("{s}\n", .{insert_preference});

    try db.execDynamic(insert_picture, .{}, .{ .space_id = null, .display_id = null });
    try db.execDynamic(insert_picture, .{}, .{ .space_id = null, .display_id = @as(usize, 1) });

    const pref: []const Preference = switch (wallpaper_type) {
        .file => &file_preferences,
        .color => &color_preferences,
    };

    try fillPreference(db, insert_preference, 1, pref);
    try fillPreference(db, insert_preference, 2, pref);

    for (1..row_count + 1) |i| {
        try db.execDynamic(insert_picture, .{}, .{ .space_id = i, .display_id = 1 });
        try db.execDynamic(insert_picture, .{}, .{ .space_id = i, .display_id = null });
        try fillPreference(db, insert_preference, 2 * (i - 1) + 2 + 1, pref);
        try fillPreference(db, insert_preference, 2 * (i - 1) + 2 + 2, pref);
    }
    debug_print("Added {d} rows to pictures\n", .{(row_count + 1) * 2});
    debug_print("Added {d} rows to preferences\n", .{(row_count + 1) * 2 * @as(u8, if (wallpaper_type == .file) 3 else 7)});
}

fn fillDisplaysAndSpaces(allocator: std.mem.Allocator, db: *sqlite.Db) !void {
    const displays = try Display.getDisplays(allocator);
    defer {
        for (displays) |*display| {
            display.deinit();
        }
        allocator.free(displays);
    }
    if (displays.len > 1) {
        std.debug.print("warn: multiple displays not supported at the moment: {d} displays\n", .{displays.len});
    }
    try db.exec("INSERT INTO displays(display_uuid) VALUES(?)", .{}, .{displays[0].uuid});
    for (displays[0].spaces) |*space| {
        try db.exec("INSERT INTO spaces(space_uuid) VALUES(?)", .{}, .{space.uuid});
    }
}

fn createDb() !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = .{ .File = tmp_file },
        .open_flags = .{
            .write = true,
            .create = true,
        },
    });

    { // Create Tables
        const tables = [_][]const u8{
            // table       mappings
            "data",        "value",
            "displays",    "display_uuid",
            "pictures",    "space_id INTEGER, display_id INTEGER",
            "preferences", "key INTEGER, data_id INTEGER, picture_id INTEGER",
            "prefs",       "key INTEGER, data",
            "spaces",      "space_uuid VARCHAR",
        };
        const create_table = "CREATE TABLE {s} ({s})";
        const stride = 2;

        comptime {
            assert(tables.len % stride == 0);
        }

        inline for (0..tables.len / stride) |i| {
            const filled = std.fmt.comptimePrint(create_table, .{ tables[stride * i], tables[stride * i + 1] });
            debug_print("{s}\n", .{filled});
            try db.exec(filled, .{}, .{});
        }
    }

    { // Create Indices
        const indices = [_][]const u8{
            // index             table          mappings
            "data_index",        "data",        "value",
            "displays_index",    "displays",    "display_uuid",
            "pictures_index",    "pictures",    "space_id, display_id",
            "preferences_index", "preferences", "picture_id, data_id",
            "prefs_index",       "prefs",       "key",
            "spaces_index",      "spaces",      "space_uuid",
        };
        const create_index = "CREATE INDEX {s} ON {s} ({s})";
        const stride = 3;

        comptime {
            assert(indices.len % stride == 0);
        }

        inline for (0..indices.len / stride) |i| {
            const filled = std.fmt.comptimePrint(create_index, .{ indices[stride * i], indices[stride * i + 1], indices[stride * i + 2] });
            debug_print("{s}\n", .{filled});
            try db.exec(filled, .{}, .{});
        }
    }

    { // Create Triggers
        const triggers = [_][]const u8{
            // Trigger             Table          Command
            "display_deleted",     "displays",    "DELETE FROM pictures WHERE display_id=OLD.ROWID",
            "picture_deleted",     "pictures",    "DELETE FROM preferences WHERE picture_id=OLD.ROWID; DELETE FROM displays WHERE ROWID=OLD.display_id AND NOT EXISTS (SELECT NULL FROM pictures WHERE display_id=OLD.display_id); DELETE FROM spaces WHERE ROWID=OLD.space_id AND NOT EXISTS (SELECT NULL FROM pictures WHERE space_id=OLD.space_id)",
            "preferences_deleted", "preferences", "DELETE FROM data WHERE ROWID=OLD.data_id AND NOT EXISTS (SELECT NULL FROM preferences WHERE data_id=OLD.data_id)",
            "space_deleted",       "spaces",      "DELETE FROM pictures WHERE space_id=OLD.ROWID",
        };
        const create_trigger = "CREATE TRIGGER {s} AFTER DELETE ON {s} BEGIN {s}; END";
        const stride = 3;

        comptime {
            assert(triggers.len % stride == 0);
        }

        inline for (0..triggers.len / stride) |i| {
            const filled = std.fmt.comptimePrint(create_trigger, .{ triggers[stride * i], triggers[stride * i + 1], triggers[stride * i + 2] });
            debug_print("{s}\n", .{filled});
            try db.exec(filled, .{}, .{});
        }
    }

    return db;
}

fn assert(ok: bool) void {
    if (!ok) unreachable;
}
