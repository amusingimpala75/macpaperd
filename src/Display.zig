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

// Doesn't work?
//usingnamespace apple;

const std = @import("std");

const Display = @This();

extern fn SLSMainConnectionID() i32;
extern fn SLSCopyManagedDisplaySpaces(i32) apple.CFArrayRef;
extern fn SLSSpaceCopyName(cid: i32, sid: u64) apple.CFStringRef;
extern fn SLSSpaceGetType(cid: i32, sid: u64) i32;

extern const display_identifier: apple.CFStringRef;
extern const spaces: apple.CFStringRef;
extern const id64: apple.CFStringRef;

pub fn getDisplays(allocator: std.mem.Allocator) ![]const Display {
    var count: u32 = undefined;
    _ = apple.CGGetActiveDisplayList(0, null, &count);
    const display_ids = try allocator.alloc(u32, count);
    defer allocator.free(display_ids);
    _ = apple.CGGetActiveDisplayList(count, @ptrCast(display_ids), &count);
    var displays = std.ArrayList(Display).init(allocator);
    for (display_ids) |id| {
        try displays.append(try Display.initFromDID(allocator, id));
    }
    return try displays.toOwnedSlice();
}

allocator: std.mem.Allocator,
uuid: []const u8,
spaces: []const Space,

pub fn init(allocator: std.mem.Allocator, uuid: []const u8) !Display {
    const skylight_connection = SLSMainConnectionID();
    const displays_spaces_ref = SLSCopyManagedDisplaySpaces(skylight_connection);
    if (displays_spaces_ref) |_| {
        defer apple.CFRelease(displays_spaces_ref);
        for (0..@intCast(apple.CFArrayGetCount(displays_spaces_ref))) |i| {
            var dict = apple.CFArrayGetValueAtIndex(displays_spaces_ref, @intCast(i));
            const uuid_str = apple.CFDictionaryGetValue(@ptrCast(dict), display_identifier);
            const uuid1 = try CFStringRefToString(allocator, @ptrCast(uuid_str));
            defer allocator.free(uuid1);
            if (!std.mem.eql(u8, uuid, uuid1)) {
                continue;
            }

            var spaces_ref = apple.CFDictionaryGetValue(@ptrCast(dict), spaces);
            const spaces_count = apple.CFArrayGetCount(@ptrCast(spaces_ref));
            var _spaces = std.ArrayList(Space).init(allocator);
            for (0..@intCast(spaces_count)) |j| {
                var dict1 = apple.CFArrayGetValueAtIndex(@ptrCast(spaces_ref), @intCast(j));
                const space_id = apple.CFDictionaryGetValue(@ptrCast(dict1), id64);
                var id: u64 = undefined;
                _ = apple.CFNumberGetValue(@ptrCast(space_id), apple.CFNumberGetType(@ptrCast(space_id)), &id);
                try _spaces.append(try Space.init(allocator, id));
            }
            return .{
                .allocator = allocator,
                .uuid = uuid,
                .spaces = try _spaces.toOwnedSlice(),
            };
        }
    } else {
        return error.CannotRetreiveDisplaySpaces;
    }
    return error.NoSuchDisplay;
}

pub fn initFromDID(allocator: std.mem.Allocator, id: u32) !Display {
    const uuid_ref = apple.CGDisplayCreateUUIDFromDisplayID(id);
    defer apple.CFRelease(uuid_ref);
    const uuid = try UUIDToString(allocator, uuid_ref);
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
    uuid: []const u8,
    fullscreen: bool,

    pub fn init(allocator: std.mem.Allocator, id: u64) !Space {
        const skylight_connection = SLSMainConnectionID();
        const uuid_str = SLSSpaceCopyName(skylight_connection, id);
        defer apple.CFRelease(uuid_str);
        const uuid = try CFStringRefToString(allocator, uuid_str);
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

fn UUIDToString(allocator: std.mem.Allocator, uuid_ref: apple.CFUUIDRef) ![]const u8 {
    if (uuid_ref) |_| {
        const uuid_str = apple.CFUUIDCreateString(null, uuid_ref);
        defer apple.CFRelease(uuid_str);
        return try CFStringRefToString(allocator, uuid_str);
    }
    return error.UUIDDecode;
}

fn CFStringRefToString(allocator: std.mem.Allocator, str_ref: apple.CFStringRef) ![]const u8 {
    if (str_ref) |_| {
        const len = apple.CFStringGetLength(str_ref);
        var str = try allocator.alloc(u8, @intCast(len + 1));
        if (apple.CFStringGetCString(str_ref, @ptrCast(str), @intCast(str.len), apple.kCFStringEncodingASCII) != 0) {
            return str;
        }
    }
    return error.StringConversionError;
}
