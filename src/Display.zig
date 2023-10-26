//    Display.zig is a part of macpaperd.
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

const apple = @cImport({
    @cInclude("Carbon/Carbon.h");
    @cInclude("objc/objc-runtime.h");
    @cInclude("mach/mach_time.h");
});

const std = @import("std");

const Display = @This();

extern fn SLSMainConnectionID() i32;
extern fn SLSCopyManagedDisplaySpaces(i32) apple.CFArrayRef;
extern fn SLSSpaceCopyName(cid: i32, sid: u64) apple.CFStringRef;
extern fn SLSSpaceGetType(cid: i32, sid: u64) i32;

extern const display_identifier: apple.CFStringRef;
extern const spaces: apple.CFStringRef;
extern const id64: apple.CFStringRef;

pub var cg_errno: apple.CGError = undefined;

pub const Error = error{CGError} || std.mem.Allocator.Error;

pub fn getDisplays(allocator: std.mem.Allocator) Error![]const Display {
    var count: u32 = undefined;
    {
        const err = apple.CGGetActiveDisplayList(0, null, &count);
        if (err != 0) {
            cg_errno = err;
            return error.CGError;
        }
    }
    const display_ids = try allocator.alloc(u32, count);
    defer allocator.free(display_ids);
    {
        const err = apple.CGGetActiveDisplayList(count, @ptrCast(display_ids), &count);
        if (err != 0) {
            cg_errno = err;
            return error.CGError;
        }
    }
    var displays = std.ArrayList(Display).init(allocator);
    for (display_ids, 1..) |id, i| {
        const display = Display.initFromDID(allocator, id) catch |err| {
            switch (err) {
                InitError.DisplayInitError => {
                    std.debug.print("Error retrieving display {d} (id: {d}), skipping.\n", .{ i, id });
                    continue;
                },
                else => |e| return e,
            }
        };
        try displays.append(display);
    }
    return try displays.toOwnedSlice();
}

allocator: std.mem.Allocator,
uuid: [:0]const u8,
spaces: []const Space,

const InitError = error{DisplayInitError} || std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator, uuid: [:0]const u8) InitError!Display {
    const skylight_connection = SLSMainConnectionID();
    const displays_spaces_ref = SLSCopyManagedDisplaySpaces(skylight_connection);
    if (displays_spaces_ref == null) {
        return error.DisplayInitError;
    }

    defer apple.CFRelease(displays_spaces_ref);
    for (0..@intCast(apple.CFArrayGetCount(displays_spaces_ref))) |i| {
        var dict: apple.CFDictionaryRef = @ptrCast(apple.CFArrayGetValueAtIndex(displays_spaces_ref, @intCast(i)));
        const uuid_str: apple.CFStringRef = @ptrCast(apple.CFDictionaryGetValue(dict, display_identifier));
        if (uuid_str == null) {
            return InitError.DisplayInitError;
        }
        const uuid1 = CFStringRefToString(allocator, uuid_str) catch |err| {
            switch (err) {
                StringError.CannotGetString => return InitError.DisplayInitError,
                else => |e| return e,
            }
        };
        defer allocator.free(uuid1);
        if (!std.mem.eql(u8, uuid, uuid1)) {
            continue;
        }

        var spaces_ref: apple.CFArrayRef = @ptrCast(apple.CFDictionaryGetValue(dict, spaces));
        if (spaces_ref == null) {
            return InitError.DisplayInitError;
        }
        const spaces_count = apple.CFArrayGetCount(spaces_ref);
        var _spaces = std.ArrayList(Space).init(allocator);
        for (0..@intCast(spaces_count)) |j| {
            var dict1: apple.CFDictionaryRef = @ptrCast(apple.CFArrayGetValueAtIndex(spaces_ref, @intCast(j)));
            const space_id: apple.CFNumberRef = @ptrCast(apple.CFDictionaryGetValue(dict1, id64));
            if (space_id == null) {
                return InitError.DisplayInitError;
            }
            var id: u64 = undefined;
            if (apple.CFNumberGetValue(space_id, apple.CFNumberGetType(space_id), &id) == 0) {
                return InitError.DisplayInitError;
            }
            const space = Space.init(allocator, id) catch |err| {
                switch (err) {
                    Space.Error.SpaceInitError => return InitError.DisplayInitError,
                    else => |e| return e,
                }
            };
            try _spaces.append(space);
        }
        return .{
            .allocator = allocator,
            .uuid = uuid,
            .spaces = try _spaces.toOwnedSlice(),
        };
    }
    return InitError.DisplayInitError;
}

const DIDInitError = Error || InitError;

pub fn initFromDID(allocator: std.mem.Allocator, id: u32) DIDInitError!Display {
    const uuid_ref = apple.CGDisplayCreateUUIDFromDisplayID(id);
    if (uuid_ref == null) {
        return Error.CGError;
    }
    defer apple.CFRelease(uuid_ref);
    const uuid = UUIDToString(allocator, uuid_ref) catch |err| {
        switch (err) {
            UUIDError.CannotGetUUID => return InitError.DisplayInitError,
            else => |e| return e,
        }
    };
    return init(allocator, uuid);
}

pub fn deinit(self: Display) void {
    self.allocator.free(self.uuid);
    for (self.spaces) |*space| {
        space.deinit();
    }
    self.allocator.free(self.spaces);
}

pub const Space = struct {
    allocator: std.mem.Allocator,
    uuid: [:0]const u8,
    fullscreen: bool,

    const Error = error{SpaceInitError} || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, id: u64) Space.Error!Space {
        const skylight_connection = SLSMainConnectionID();
        const uuid_str = SLSSpaceCopyName(skylight_connection, id);
        if (uuid_str == null) {
            return error.SpaceInitError;
        }
        defer apple.CFRelease(uuid_str);
        const uuid = CFStringRefToString(allocator, uuid_str) catch |err| {
            switch (err) {
                StringError.CannotGetString => return Space.Error.SpaceInitError,
                else => |e| return e,
            }
        };
        return .{
            .allocator = allocator,
            .uuid = uuid,
            .fullscreen = SLSSpaceGetType(skylight_connection, id) == 4,
        };
    }

    pub fn deinit(self: Space) void {
        self.allocator.free(self.uuid);
    }
};

const UUIDError = error{CannotGetUUID} || std.mem.Allocator.Error;

// Requires that uuid_ref is non-null
fn UUIDToString(allocator: std.mem.Allocator, uuid_ref: apple.CFUUIDRef) UUIDError![:0]const u8 {
    const uuid_str = apple.CFUUIDCreateString(null, uuid_ref);
    if (uuid_str == null) {
        return UUIDError.CannotGetUUID;
    }
    defer apple.CFRelease(uuid_str);
    return CFStringRefToString(allocator, uuid_str) catch |err| {
        switch (err) {
            StringError.CannotGetString => return UUIDError.CannotGetUUID,
            else => |e| return e,
        }
    };
}

const StringError = error{CannotGetString} || std.mem.Allocator.Error;

// Requires that str_ref is non-null
fn CFStringRefToString(allocator: std.mem.Allocator, str_ref: apple.CFStringRef) StringError![:0]const u8 {
    const len = apple.CFStringGetLength(str_ref);
    var str = try allocator.allocSentinel(u8, @intCast(len), 0);
    if (apple.CFStringGetCString(str_ref, @ptrCast(str), @intCast(str.len + 1), apple.kCFStringEncodingASCII) != 0) {
        return str;
    }
    return StringError.CannotGetString;
}
