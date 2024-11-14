const std = @import("std");

const M3U = @import("M3U.zig");

const Songs = std.StringArrayHashMap(void);

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leak");
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try std.io.getStdErr().writeAll("Need to pass output file path and files/folders! `m3uz out.m3u8 file.mp3 https://url/file.flac /home/user/some_dir/");
        return;
    }

    var songs = Songs.init(allocator);
    defer {
        for (songs.keys()) |key|
            allocator.free(key);
        songs.deinit();
    }

    blk: {
        const file = std.fs.cwd().openFile(args[1], .{}) catch |err| {
            if (err == std.fs.File.OpenError.FileNotFound)
                break :blk;

            return err;
        };
        defer file.close();
        var buffered_reader = std.io.bufferedReader(file.reader());

        const m3u = try M3U.read(allocator, buffered_reader.reader());
        defer m3u.deinit();

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for (m3u.tracks) |track| {
            switch (track.identifier) {
                .path => |path| {
                    const real_path = try std.fs.cwd().realpath(path, &buf);

                    if (!songs.contains(real_path)) {
                        try songs.put(try allocator.dupe(u8, real_path), {});
                    }
                },
                .url => |url| {
                    var fbs = std.io.fixedBufferStream(&buf);
                    try fbs.writer().print("{}", .{url.uri});

                    const uri = fbs.buffer[0..fbs.pos];

                    if (!songs.contains(uri)) {
                        try songs.put(try allocator.dupe(u8, uri), {});
                    }
                },
            }
        }

        std.debug.print("Loaded {d} existing songs...\n", .{songs.count()});
    }

    for (args[2..]) |entry| {
        try addEntry(allocator, entry, &songs);
    }

    const out = try std.fs.cwd().createFile(args[1], .{});
    defer out.close();

    var buffered_writer = std.io.bufferedWriter(out.writer());
    const writer = buffered_writer.writer();

    const m3u: M3U = .{
        .allocator = allocator,
        .title = null,
        .tracks = blk: {
            const tracks = try allocator.alloc(M3U.Track, songs.count());

            for (tracks, songs.keys()) |*track, song| {
                const uri = std.Uri.parse(song) catch {
                    track.* = .{
                        .information = null,
                        .identifier = .{ .path = song },
                    };

                    continue;
                };

                track.* = .{
                    .information = null,
                    .identifier = .{ .url = .{ .uri = uri, .buf = song } },
                };
            }

            break :blk tracks;
        },
    };
    defer allocator.free(m3u.tracks);

    try m3u.write(writer, false);
    try buffered_writer.flush();
}

fn addEntry(allocator: std.mem.Allocator, entry: []const u8, songs: *Songs) !void {
    var done: bool = false;

    if (!done) blk: {
        const uri = std.Uri.parse(entry) catch {
            break :blk;
        };

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try fbs.writer().print("{}", .{uri});

        const formatted_uri = fbs.buffer[0..fbs.pos];

        if (!songs.contains(formatted_uri)) {
            try songs.put(try allocator.dupe(u8, formatted_uri), {});
            std.debug.print("Added URL {s}\n", .{formatted_uri});
        } else {
            std.debug.print("URL {s} already exists.\n", .{formatted_uri});
        }
        done = true;
    }

    if (!done) blk: {
        var dir = std.fs.cwd().openDir(entry, .{
            .access_sub_paths = false,
            .iterate = true,
        }) catch |err| {
            if (err == std.fs.Dir.OpenError.NotDir) {
                break :blk;
            }

            return err;
        };
        defer dir.close();

        var iterator = dir.iterateAssumeFirstIteration();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        while (try iterator.next()) |sub| {
            const real_path = try dir.realpath(sub.name, &buf);

            if (!songs.contains(real_path)) {
                try songs.put(try allocator.dupe(u8, real_path), {});
                std.debug.print("Added path {s}\n", .{real_path});
            } else {
                std.debug.print("Path {s} already exists.\n", .{real_path});
            }
        }

        done = true;
    }

    if (!done) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_path = try std.fs.cwd().realpath(entry, &buf);

        if (!songs.contains(real_path)) {
            try songs.put(try allocator.dupe(u8, real_path), {});
            std.debug.print("Added file {s}\n", .{real_path});
        } else {
            std.debug.print("File {s} already exists\n", .{real_path});
        }

        done = true;
    }
}
