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

const tmp_file = "/tmp/macpaperd.db";

const PREF_FILE = 1;
const PREF_OREINTATION = 2;
const PREF_R = 3;
const PREF_G = 4;
const PREF_B = 5;
const PREF_FOLDER = 10;
const PREF_TRANSPARENCY = 15;
const PREF_DYNAMIC = 20;

const DATA_FILE = 1;
const DATA_OREINTATION = 2;
const DATA_R = 3;
const DATA_G = 4;
const DATA_B = 5;
const DATA_FOLDER = 6;
const DATA_TRANSPARENCY = 7;
const DATA_DYNAMIC = 8;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var log_debug: bool = undefined;

var db_file: []u8 = undefined;

fn debug_log(comptime msg: []const u8, args: anytype) void {
    if (log_debug) {
        std.debug.print(msg, args);
    }
}

fn printUsage() void {
    const usage =
        \\Usage:
        \\  Set a wallpaper image:
        \\  macpaperd --set [file]         Set 'file' as the wallpaper.
        \\            --orientation [type] Set the orientation of the image.
        \\                                 'orientation' must be one of 'full', 'center',
        \\                                 'fit', 'tile', or 'stretch'.
        \\            --color [color]      Set 'hex color' as the background color.
        \\                                 'hex color' must be a valid, 6 character
        \\                                 hexidecimal number, no '0x' prefix. Only
        \\                                 required if the image is transparent or the
        \\                                 orientation is not 'full'.
        \\            --dynamic [type]     Set the image as dynamic. 'type' must be one
        \\                                 of 'none', 'dynamic', 'light', or 'dark'.
        \\
        \\  Set a wallpaper color:
        \\  macpaperd --color [color]      Set 'hex color' as the background color.
        \\                                 'hex color' must be a valid, 6 character
        \\                                 hexidecimal number, no '0x' prefix.
        \\
        \\  Debug help:
        \\  macpaperd --displays           List the connected displays and their associated spaces.
        \\  macpaperd --help               Show this information.
        \\  macpaperd --reset              Reset the wallpaper to the default.
        \\
        \\Export 'LOG_DEBUG=1' to enable debug logging.
    ;
    std.debug.print("{s}\n", .{usage});
}

const WallpaperImage = struct {
    file: []u8,
    orientation: Orientation = .full,
    color: u24 = 0x000000,
    flat_color: bool = false,
    dynamic: Dynamic = .none,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, file: []const u8) !WallpaperImage {
        return WallpaperImage{
            .allocator = allocator,
            .file = try ensurePathValid(allocator, file),
        };
    }

    fn initColor(allocator: std.mem.Allocator, color: u24) !WallpaperImage {
        const file_full = "/System/Library/PreferencePanes/DesktopScreenEffectsPref.prefPane/Contents/Resources/DesktopPictures.prefPane/Contents/Resources/Transparent.tiff";
        var file = try allocator.alloc(u8, file_full.len);
        std.mem.copy(u8, file, file_full);
        return WallpaperImage{
            .file = file,
            .orientation = .full,
            .dynamic = .none,
            .color = color,
            .allocator = allocator,
            .flat_color = true,
        };
    }

    fn ensurePathValid(allocator: std.mem.Allocator, image: []const u8) ![]u8 {
        if (!std.mem.eql(u8, ".png", image[image.len - 4 ..]) and
            !std.mem.eql(u8, ".jpg", image[image.len - 4 ..]) and
            !std.mem.eql(u8, ".tiff", image[image.len - 5 ..]) and
            !std.mem.eql(u8, ".heic", image[image.len - 5 ..]))
        {
            return error.InvalidFormat;
        }

        if (image[0] == '/') {
            try std.fs.accessAbsolute(image, .{}); // exists
            var ret = try allocator.alloc(u8, image.len);
            std.mem.copy(u8, ret, image);
            return ret;
        } else {
            const global_path = try std.fs.path.resolve(allocator, &[_][]const u8{ std.os.getenv("PWD").?, image });
            try std.fs.accessAbsolute(global_path, .{});
            return global_path;
        }
    }

    fn deinit(self: WallpaperImage) void {
        self.allocator.free(self.file);
    }

    fn consumeArgs(self: *WallpaperImage, args: *std.process.ArgIterator) !void {
        while (args.next()) |option| {
            if (std.mem.eql(u8, option, "--orientation")) {
                if (args.next()) |orientation| {
                    self.orientation = try Orientation.init(orientation);
                } else return error.MissingOrientation;
            } else if (std.mem.eql(u8, option, "--dynamic")) {
                if (!std.mem.eql(u8, ".heic", self.file[self.file.len - 5 ..])) {
                    return error.NotDynamic;
                }
                if (args.next()) |dynamic| {
                    self.dynamic = try Dynamic.init(dynamic);
                } else {
                    return error.MissingDynamic;
                }
            } else if (std.mem.eql(u8, option, "--color")) {
                self.color = consumeColor(args) catch |err| {
                    if (err == error.MissingArgumentColor) {
                        return error.WallpaperImageMissingColor;
                    }
                    return err;
                };
            } else {
                return error.WallpaperImageInvalidOption;
            }
        }
    }

    const Orientation = enum(u8) {
        full = 0,
        tile = 2,
        center = 3,
        stretch = 4,
        fit = 5,

        fn init(str: []const u8) !Orientation {
            if (std.mem.eql(u8, str, "full")) {
                return .full;
            } else if (std.mem.eql(u8, str, "center")) {
                return .center;
            } else if (std.mem.eql(u8, str, "fit")) {
                return .fit;
            } else if (std.mem.eql(u8, str, "stretch")) {
                return .stretch;
            } else if (std.mem.eql(u8, str, "tile")) {
                return .tile;
            } else {
                return error.InvalidOrientation;
            }
        }
    };

    const Dynamic = enum {
        none,
        dynamic,
        light,
        dark,

        fn init(str: []const u8) !Dynamic {
            if (std.mem.eql(u8, str, "none")) {
                return .none;
            } else if (std.mem.eql(u8, str, "dynamic")) {
                return .dynamic;
            } else if (std.mem.eql(u8, str, "light")) {
                return .light;
            } else if (std.mem.eql(u8, str, "dark")) {
                return .dark;
            } else {
                return error.InvalidDynamic;
            }
        }
    };
};

fn consumeColor(args: *std.process.ArgIterator) !u24 {
    if (args.next()) |color| {
        const col = try std.fmt.parseInt(u24, color, 16);
        return col;
    } else {
        return error.MissingArgumentColor;
    }
}

const Args = struct {
    action: union(enum) {
        print_usage,
        displays,
        reset,
        set: WallpaperImage,
    },
    allocator: std.mem.Allocator,

    pub fn deinit(self: Args) void {
        if (self.action == .set) {
            self.action.set.deinit();
        }
    }

    fn init(allocator: std.mem.Allocator) !Args {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        _ = args.next(); // first arg is the name of the executable

        var ret: ?Args = null;

        if (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--displays")) {
                ret = .{ .allocator = allocator, .action = .displays };
            } else if (std.mem.eql(u8, arg, "--help")) {
                ret = .{ .allocator = allocator, .action = .print_usage };
            } else if (std.mem.eql(u8, arg, "--reset")) {
                ret = .{ .allocator = allocator, .action = .reset };
            } else if (std.mem.eql(u8, arg, "--set")) {
                if (args.next()) |image| {
                    ret = .{ .allocator = allocator, .action = .{ .set = try WallpaperImage.init(allocator, image) } };
                    try ret.?.action.set.consumeArgs(&args);
                } else {
                    return error.MissingArgumentSet;
                }
            } else if (std.mem.eql(u8, arg, "--color")) {
                const col = try consumeColor(&args);
                ret = .{ .allocator = allocator, .action = .{ .set = try WallpaperImage.initColor(allocator, col) } };
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
};

// TODO proper printing to stdout/stderr for non-debug logging
// 1 => image file (if transparent: /System/Library/PreferencePanes/DesktopScreenEffectsPref.prefPane/Contents/Resources/DesktopPictures.prefPane/Contents/Resources/Transparent.tiff)
// 2 => what modifications to image (missing = full, 3 = center, 5 = fit, 4 = stretch)
// 3 => r  |
// 4 => g  | RGB of the background
// 5 => b  |
// 10 => image folder
// 15 => indicates transparency in the image (1 = allow transparency)
// 20 => automatically changing wallpapers (0 = not dynamic, 1 = dynamic/automatic (dynamic is for location, automatic is for system theme), 2 = light, 3 = dark)
pub fn main() !void {
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    log_debug = std.mem.eql(u8, "1", std.os.getenv("LOG_DEBUG") orelse "0");
    db_file = try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/Dock/desktoppicture.db", .{std.os.getenv("HOME").?});
    defer allocator.free(db_file);

    var args = Args.init(allocator) catch |err| {
        // TODO can do better? maybe merge MissingArgumentSet and MissingArgumentColor
        std.debug.print("{s}\n", .{switch (err) {
            error.MissingArgumentSet => "Missing file for --set",
            error.MissingArgumentColor => "Missing color for --color",
            error.NoArgs => "Missing arguments; run with --help to see a list of options",
            error.Overflow, error.InvalidCharacter => "Invalid hex color",
            error.InvalidOrientation => "Invalid orientation",
            error.MissingOrientation => "Missing orientation for --orientation",
            error.MissingDynamic => "Missing dynamic value",
            error.WallpaperImageMissingColor => "Missing color",
            error.WallpaperImageInvalidOption => "Invalid wallpaper configuration options",
            error.NotDynamic => "Cannot use --dynamic on a non-dynamic wallpaper",
            else => return err,
        }});
        std.process.exit(1);
    };
    defer args.deinit();

    switch (args.action) {
        .displays => try listDisplays(allocator),
        .print_usage => printUsage(),
        .set => |wp| try setWallpaper(allocator, wp),
        .reset => {
            try removeOld();
            try restartDock(allocator);
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

fn setWallpaper(allocator: std.mem.Allocator, wp: WallpaperImage) !void {
    std.fs.deleteFileAbsolute(tmp_file) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    var db = try createDb();
    defer db.deinit();
    try fillDisplaysAndSpaces(allocator, &db);
    try fillPicturesPreferences(allocator, &db);
    try fillData(&db, wp);
    try replaceOldWithNew();
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

fn removeOld() !void {
    std.fs.deleteFileAbsolute(db_file) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

fn replaceOldWithNew() !void {
    try removeOld();
    try std.fs.copyFileAbsolute(tmp_file, db_file, .{});
}

fn fillData(db: *sqlite.Db, wp: WallpaperImage) !void {
    const folder = blk: {
        var i = wp.file.len - 1;
        while (i >= 0) : (i -= 1) {
            if (wp.file[i] == '/') {
                break :blk wp.file[0..i];
            }
        }
    };
    const insert = "INSERT INTO data(value) VALUES(?)";

    try db.execDynamic(insert, .{}, .{ .value = @as([]const u8, wp.file) });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, @intFromEnum(wp.orientation)) });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt((wp.color & 0xff0000) >> 16)) / 255.0 });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt((wp.color & 0x00ff00) >> 8)) / 255.0 });
    try db.execDynamic(insert, .{}, .{ .value = @as(f32, @floatFromInt((wp.color & 0x0000ff))) / 255.0 });
    try db.execDynamic(insert, .{}, .{ .value = @as([]const u8, folder) });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, if (wp.flat_color) 1 else 0) });
    try db.execDynamic(insert, .{}, .{ .value = @as(usize, @intFromEnum(wp.dynamic)) });
}

const Preference = struct {
    key: u8,
    data_id: u8,
};

const preferences = [_]Preference{
    Preference{ .key = PREF_FILE, .data_id = DATA_FILE },
    Preference{ .key = PREF_OREINTATION, .data_id = DATA_OREINTATION },
    Preference{ .key = PREF_R, .data_id = DATA_R },
    Preference{ .key = PREF_G, .data_id = DATA_G },
    Preference{ .key = PREF_B, .data_id = DATA_B },
    Preference{ .key = PREF_FOLDER, .data_id = DATA_FOLDER },
    Preference{ .key = PREF_TRANSPARENCY, .data_id = DATA_TRANSPARENCY },
    Preference{ .key = PREF_DYNAMIC, .data_id = DATA_DYNAMIC },
};

fn fillPreference(db: *sqlite.Db, index: usize) !void {
    for (preferences) |pref| {
        try db.execDynamic(
            "INSERT INTO preferences(key, data_id, picture_id) VALUES(?, ?, ?)",
            .{},
            .{ .key = @as(usize, pref.key), .data_id = @as(usize, pref.data_id), .picture_id = index },
        );
    }
}

// Inserts into preferences and pictures, since those depend on looping through the spaces
fn fillPicturesPreferences(allocator: std.mem.Allocator, db: *sqlite.Db) !void {
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

    try fillPreference(db, 1);
    try fillPreference(db, 2);
    try db.execDynamic(insert_picture, .{}, .{ .space_id = null, .display_id = null });
    try db.execDynamic(insert_picture, .{}, .{ .space_id = null, .display_id = @as(usize, 1) });

    for (1..row_count + 1) |i| {
        try db.execDynamic(insert_picture, .{}, .{ .space_id = i, .display_id = @as(usize, 1) });
        try db.execDynamic(insert_picture, .{}, .{ .space_id = i, .display_id = null });
        try fillPreference(db, 2 * (i - 1) + 2 + 1);
        try fillPreference(db, 2 * (i - 1) + 2 + 2);
    }
    debug_log("Added {d} rows to pictures\n", .{(row_count + 1) * 2});
    debug_log("Added {d} rows to preferences\n", .{(row_count + 1) * 2 * preferences.len});
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
            debug_log("{s}\n", .{filled});
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
            debug_log("{s}\n", .{filled});
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
            debug_log("{s}\n", .{filled});
            try db.exec(filled, .{}, .{});
        }
    }

    return db;
}

fn assert(ok: bool) void {
    if (!ok) unreachable;
}
