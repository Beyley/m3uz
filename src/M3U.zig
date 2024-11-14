const std = @import("std");

const Self = @This();

pub const enable_extensions_directive = "EXTM3U";
pub const track_information_directive = "EXTINF";
pub const line_ending = "\r\n";

pub const Track = struct {
    pub const Identifier = union(Type) {
        pub const Type = enum {
            path,
            url,
        };

        path: []const u8,
        url: struct {
            buf: []const u8,
            uri: std.Uri,
        },

        pub fn deinit(self: Identifier, allocator: std.mem.Allocator) void {
            switch (self) {
                .path => |path| allocator.free(path),
                .url => |url| {
                    allocator.free(url.buf);
                },
            }
        }
    };

    pub const Information = struct {
        display_title: ?[]const u8,
        time_in_seconds: f64,

        pub fn deinit(self: Information, allocator: std.mem.Allocator) void {
            if (self.display_title) |display_title| allocator.free(display_title);
        }
    };

    identifier: Identifier,
    information: ?Information,

    pub fn deinit(self: Track, allocator: std.mem.Allocator) void {
        self.identifier.deinit(allocator);
        if (self.information) |information| information.deinit(allocator);
    }
};

allocator: std.mem.Allocator,
title: ?[]const u8,
tracks: []Track,

pub fn deinit(self: Self) void {
    if (self.title) |title| self.allocator.free(title);
    for (self.tracks) |track| track.deinit(self.allocator);
    self.allocator.free(self.tracks);
}

pub fn read(allocator: std.mem.Allocator, reader: anytype) !Self {
    var tracks: std.ArrayList(Track) = .init(allocator);
    errdefer {
        for (tracks.items) |track| track.deinit(allocator);
        tracks.deinit();
    }

    var playlist_name: ?[]const u8 = null;
    errdefer if (playlist_name) |name| allocator.free(name);

    var extensions_enabled = false;

    var time_in_seconds: ?f64 = null;
    var display_title: ?[]const u8 = null;
    errdefer if (display_title) |title| allocator.free(title);

    var read_buf: [std.fs.max_path_bytes]u8 = undefined;
    var song_index: usize = 0;
    var line: usize = 0;
    while (try reader.readUntilDelimiterOrEof(&read_buf, '\n')) |raw_read_line| {
        defer line += 1;

        // Read and trim the line of its whitespace
        var read_line = std.mem.trim(u8, raw_read_line, &std.ascii.whitespace);

        // Skip blank lines
        if (read_line.len == 0) continue;

        if (read_line[0] == '#') {
            const directive_line = read_line[1..];

            const directive_index = std.mem.indexOf(u8, directive_line, ":");

            const directive: []const u8, const params: ?[]const u8 = if (directive_index) |idx| .{
                std.mem.trim(u8, directive_line[0..idx], &std.ascii.whitespace),
                std.mem.trim(u8, directive_line[idx + 1 ..], &std.ascii.whitespace),
            } else .{
                std.mem.trim(u8, directive_line, &std.ascii.whitespace),
                null,
            };

            if (std.mem.eql(u8, directive, enable_extensions_directive)) {
                if (line != 0) return error.InvalidExtendedHeader;
                extensions_enabled = true;

                continue;
            }

            if (!extensions_enabled) return error.ExtensionsUsedWhenNotEnabled;

            if (std.mem.eql(u8, directive, "EXTM3A")) {
                return error.M3AUnsupported;
            } else if (std.mem.eql(u8, directive, "PLAYLIST")) {
                playlist_name = try allocator.dupe(u8, params orelse return error.MissingPlaylistName);

                continue;
            } else if (std.mem.eql(u8, directive, track_information_directive)) {
                if (params == null) return error.MissingParamsForExtInf;

                if (std.mem.indexOf(u8, params.?, ",")) |separator_idx| {
                    time_in_seconds = try std.fmt.parseFloat(f64, std.mem.trim(u8, params.?[0..separator_idx], &std.ascii.whitespace));
                    display_title = try allocator.dupe(u8, std.mem.trim(u8, params.?[separator_idx + 1 ..], &std.ascii.whitespace));
                } else {
                    time_in_seconds = try std.fmt.parseFloat(f64, std.mem.trim(u8, params.?, &std.ascii.whitespace));
                }

                continue;
            }
        }

        const identifier: Track.Identifier = blk: {
            const alloc_line = try allocator.dupe(u8, read_line);

            const uri = std.Uri.parse(alloc_line) catch {
                break :blk .{ .path = alloc_line };
            };
            break :blk .{ .url = .{ .uri = uri, .buf = alloc_line } };
        };
        errdefer identifier.deinit(allocator);

        try tracks.append(.{
            .identifier = identifier,
            .information = if (time_in_seconds) |time_in_secs| .{
                .time_in_seconds = time_in_secs,
                .display_title = display_title,
            } else null,
        });

        time_in_seconds = null;
        display_title = null;

        song_index += 1;
    }

    return .{
        .allocator = allocator,
        .title = playlist_name,
        .tracks = try tracks.toOwnedSlice(),
    };
}

pub fn write(self: Self, writer: anytype, use_extensions: bool) !void {
    if (use_extensions) try writer.writeAll("#" ++ enable_extensions_directive ++ line_ending);

    for (self.tracks) |track| {
        if (use_extensions) {
            if (track.information) |track_information| {
                try writer.print("#" ++ track_information_directive ++ ":{d}", .{track_information.time_in_seconds});
                if (track_information.display_title) |track_display_title|
                    try writer.print(",{s}", .{track_display_title});
                try writer.writeAll(line_ending);
            }
        }
        switch (track.identifier) {
            .path => |path| try writer.writeAll(path),
            .url => |url| try writer.print("{}", .{url.uri}),
        }
        try writer.writeAll(line_ending);
    }
}

comptime {
    if (false) _ = read(undefined, @as(std.io.fs.File.Reader, undefined));
    if (false) _ = write(undefined, @as(std.io.fs.File.Writer, undefined), true);
}
