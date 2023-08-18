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

pub fn main() !void {
    home = std.os.getenv("HOME").?;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // Unix first arg being name of executable
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--set")) {
            if (args.next()) |path| {
                try setWallpaper(allocator, path);
            } else {
                std.debug.print("Missing path arg for '--set'\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--displays")) {
            try listDisplays(allocator);
        } else if (std.mem.eql(u8, arg, "--color")) {
            if (args.next()) |str| {
                const col: u24 = std.fmt.parseInt(u24, str, 16) catch |err| {
                    if (err == error.Overflow or err == error.InvalidCharacter) {
                        std.debug.print("Invalid hex color: {s}\n", .{str});
                        std.process.exit(1);
                    }
                    unreachable;
                };
                try setColor(
                    allocator,
                    @intCast((col & 0xFF0000) >> 16),
                    @intCast((col & 0x00FF00) >> 8),
                    @intCast((col & 0x0000FF)),
                );
            } else {
                std.debug.print("Missing color arg for '--color'\n", .{});
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
        } else {
            std.debug.print("Unrecognized arg: {s}\n", .{arg});
            printUsage();
            std.process.exit(1);
        }
    } else {
        printUsage();
        std.process.exit(1);
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
    std.debug.print("Setting wallpaper to color r: {d}, g: {d}, b: {d}\n", .{ r, g, b });
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
            std.process.exit(1);
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
    std.debug.print("{s}\n", .{insert});
    try db.execDynamic(insert, .{}, .{ .value = folder });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, 0) });
    try db.execDynamic(insert, .{}, .{ .value = file_path });
}

fn fillColorData(db: *sqlite.Db, r: u8, g: u8, b: u8) !void {
    const insert = "INSERT INTO data(value) VALUES(?)";
    std.debug.print("{s}\n", .{insert});
    try db.execDynamic(insert, .{}, .{ .value = @as([]const u8, "/System/Library/Desktop Pictures/Solid Colors") });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, 0) });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, 1) });
    try db.execDynamic(insert, .{}, .{ .value = @as([]const u8, "/System/Library/PreferencePanes/DesktopScreenEffectsPref.prefPane/Contents/Resources/DesktopPictures.prefPane/Contents/Resources/Transparent.tiff") });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt(r)) / 255.0 });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt(g)) / 255.0 });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt(b)) / 255.0 });
}

fn fillFilePreference(db: *sqlite.Db, cmd: []const u8, index: usize) !void {
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 10), .data_id = @as(usize, 1), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 20), .data_id = @as(usize, 2), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 1), .data_id = @as(usize, 3), .picture_id = index });
}

fn fillColorPreference(db: *sqlite.Db, cmd: []const u8, index: usize) !void {
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 15), .data_id = @as(usize, 3), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 1), .data_id = @as(usize, 4), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 3), .data_id = @as(usize, 5), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 4), .data_id = @as(usize, 6), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 5), .data_id = @as(usize, 7), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 10), .data_id = @as(usize, 1), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 20), .data_id = @as(usize, 2), .picture_id = index });
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
    std.debug.print("{s}\n", .{insert_picture});
    std.debug.print("{s}\n", .{insert_preference});

    try db.execDynamic(insert_picture, .{}, .{ .space_id = null, .display_id = null });
    try db.execDynamic(insert_picture, .{}, .{ .space_id = null, .display_id = @as(usize, 1) });

    const insert_function: *const fn (*sqlite.Db, []const u8, usize) anyerror!void = switch (wallpaper_type) {
        .file => fillFilePreference,
        .color => fillColorPreference,
    };

    try insert_function(db, insert_preference, 1);
    try insert_function(db, insert_preference, 2);

    for (1..row_count + 1) |i| {
        try db.execDynamic(insert_picture, .{}, .{ .space_id = i, .display_id = 1 });
        try db.execDynamic(insert_picture, .{}, .{ .space_id = i, .display_id = null });
        try insert_function(db, insert_preference, 2 * (i - 1) + 2 + 1);
        try insert_function(db, insert_preference, 2 * (i - 1) + 2 + 2);
    }
    std.debug.print("Added {d} rows to pictures\n", .{(row_count + 1) * 2});
    std.debug.print("Added {d} rows to preferences\n", .{(row_count + 1) * 2 * @as(u8, if (wallpaper_type == .file) 3 else 7)});
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
            std.debug.print("{s}\n", .{filled});
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
            std.debug.print("{s}\n", .{filled});
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
            std.debug.print("{s}\n", .{filled});
            try db.exec(filled, .{}, .{});
        }
    }

    return db;
}

fn assert(ok: bool) void {
    if (!ok) unreachable;
}
