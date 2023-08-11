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

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const tmp_file = "/tmp/macpaperd.db";

pub fn main() !void {
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = blk: while (args.next()) |arg| {
        if (!std.mem.eql(u8, arg, "--set")) {
            std.debug.print("Invalid arg: {s}\n", .{arg});
            unreachable;
        }
        break :blk args.next().?;
    } else unreachable;

    { // Validate path
        try std.fs.accessAbsolute(path, .{}); // exists
        if (!std.mem.eql(u8, ".png", path[path.len - 4 ..]) and
            !std.mem.eql(u8, ".jpg", path[path.len - 4 ..]))
        {
            std.debug.print("Invalid image format: {s}\n", .{path[path.len - 6 ..]});
            unreachable;
        }
    }
    std.fs.deleteFileAbsolute("/tmp/macpaperd.db") catch |err| {
        if (err == error.FileNotFound) {} else return err;
    };
    var db = try createDb(); // prefs is complete (empty)
    defer db.deinit();
    try copyFromOld(allocator, &db); // displays and spaces are complete
    try insertSpaceData(allocator, &db); // pictures and preferences are complete
    try addData(&db, path); // data is complete; DB done
    try backupOld(allocator);
    try copyInNew(allocator);
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

fn copyInNew(allocator: std.mem.Allocator) !void {
    const home = std.os.getenv("HOME").?;
    const path = try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/Dock/desktoppicture.db", .{home});
    defer allocator.free(path);

    try std.fs.copyFileAbsolute("/tmp/macpaperd.db", path, .{});
}

fn backupOld(allocator: std.mem.Allocator) !void {
    const home = std.os.getenv("HOME").?;
    const dock_dir_path = try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/Dock", .{home});
    defer allocator.free(dock_dir_path);
    var dock_dir = try std.fs.openDirAbsolute(dock_dir_path, .{});
    defer dock_dir.close();
    const backup_already_existed = blk: {
        dock_dir.makeDir("backups") catch |err| {
            if (err == error.PathAlreadyExists) {
                break :blk true;
            }
            return err;
        };
        break :blk false;
    };
    var backup_dir = try dock_dir.openDir("backups", .{});
    defer backup_dir.close();
    if (!backup_already_existed) {
        try dock_dir.copyFile("desktoppicture.db", backup_dir, "desktoppicture.db", .{});
    } else {
        var iterable: std.fs.IterableDir = .{ .dir = try dock_dir.openDirZ("backups", .{}, true) };
        defer iterable.close();
        const count = iterable.iterate().end_index + 1;
        const path = try std.fmt.allocPrint(allocator, "desktoppicture{d}.db", .{count});
        defer allocator.free(path);
        try dock_dir.copyFile("desktoppicture.db", backup_dir, path, .{});
    }
}

fn addData(db: *sqlite.Db, file_path: []const u8) !void {
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

fn insertPreference(db: *sqlite.Db, cmd: []const u8, index: usize) !void {
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 10), .data_id = @as(usize, 1), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 20), .data_id = @as(usize, 2), .picture_id = index });
    try db.execDynamic(cmd, .{}, .{ .key = @as(usize, 1), .data_id = @as(usize, 3), .picture_id = index });
}

// Inserts into preferences and pictures, since those depend on looping through the spaces
fn insertSpaceData(allocator: std.mem.Allocator, db: *sqlite.Db) !void {
    const row_count: usize = blk: {
        const extract = "SELECT space_uuid FROM spaces";
        var statement = try db.prepare(extract);
        defer statement.deinit();
        break :blk (try statement.all(
            struct { space_uuid: []const u8 },
            allocator,
            .{},
            .{},
        )).len;
    };
    const insert_picture = "INSERT INTO pictures(space_id, display_id) VALUES(?, ?)";
    const insert_preference = "INSERT INTO preferences(key, data_id, picture_id) VALUES(?, ?, ?)";
    std.debug.print("{s}\n", .{insert_picture});
    std.debug.print("{s}\n", .{insert_preference});

    try db.execDynamic(insert_picture, .{}, .{ .space_id = null, .display_id = null });
    try db.execDynamic(insert_picture, .{}, .{ .space_id = null, .display_id = @as(usize, 1) });

    try insertPreference(db, insert_preference, 1);
    try insertPreference(db, insert_preference, 2);

    for (1..row_count + 1) |i| {
        try db.execDynamic(insert_picture, .{}, .{ .space_id = i, .display_id = 1 });
        try db.execDynamic(insert_picture, .{}, .{ .space_id = i, .display_id = null });
        try insertPreference(db, insert_preference, 2 * (i - 1) + 2 + 1);
        try insertPreference(db, insert_preference, 2 * (i - 1) + 2 + 2);
    }
    std.debug.print("Added {d} rows to pictures\n", .{(row_count + 1) * 2});
    std.debug.print("Added {d} rows to preferences\n", .{(row_count + 1) * 2 * 3});
}

fn copyFromOld(allocator: std.mem.Allocator, db: *sqlite.Db) !void {
    const home = std.os.getenv("HOME").?;
    const file = try std.fmt.allocPrintZ(allocator, "{s}/Library/Application Support/Dock/desktoppicture.db", .{home});
    defer allocator.free(file);
    var old = try sqlite.Db.init(.{
        .mode = .{ .File = file },
        .open_flags = .{
            .write = false,
            .create = false,
        },
    });
    defer old.deinit();

    { // Copy Displays
        const extract = "SELECT display_uuid FROM displays";
        std.debug.print("{s}\n", .{extract});
        var statement = try old.prepare(extract);
        defer statement.deinit();
        const rows = try statement.all(
            struct { display_uuid: []const u8 },
            allocator,
            .{},
            .{},
        );
        if (rows.len < 1) {
            std.builtin.panic("Cannot copy desktop wallpaper if it has never been set\n", null, null);
        } else {
            std.debug.print("{s}\n", .{rows[0].display_uuid});
        }
        for (rows[1..]) |row| {
            std.debug.print("warn: multiple displays not supported {s}\n", .{row.display_uuid});
        }
        const uuid = rows[0]; // TODO support > 1 display
        const insert = "INSERT INTO displays(display_uuid) VALUES(?)";
        std.debug.print("{s}\n", .{insert});
        try db.execDynamic(insert, .{}, uuid);
    }

    { // Copy Spaces
        const extract = "SELECT space_uuid FROM spaces";
        std.debug.print("{s}\n", .{extract});
        var statement = try old.prepare(extract);
        defer statement.deinit();
        const rows = try statement.all(
            struct { space_uuid: []const u8 },
            allocator,
            .{},
            .{},
        );
        if (rows.len < 1) {
            std.builtin.panic("Cannot copy desktop wallpaper if it has never been set\n", null, null);
        }
        const insert = "INSERT INTO spaces(space_uuid) VALUES(?)";
        for (rows) |row| {
            std.debug.print("{s}\n", .{row.space_uuid});
            try db.execDynamic(insert, .{}, row);
        }
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
