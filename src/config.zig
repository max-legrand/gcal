const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    client_id: []const u8,
    client_secret: []const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.client_secret);
    }
};

const ConfigFile = struct {
    installed: Config,
};

pub fn parseConfigFile(allocator: std.mem.Allocator, filepath: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var abs_path = try alloc.dupe(u8, filepath);
    if (!std.fs.path.isAbsolute(abs_path)) {
        abs_path = try std.fs.cwd().realpathAlloc(alloc, filepath);
    }

    var file = try std.fs.openFileAbsolute(abs_path, .{ .mode = .read_only });
    defer file.close();

    var r = file.reader(&.{});
    var reader = &r.interface;
    const file_contents = try reader.allocRemaining(alloc, .unlimited);
    const config_file = try std.json.parseFromSlice(
        ConfigFile,
        alloc,
        file_contents,
        .{ .ignore_unknown_fields = true },
    );

    const client_id_len = config_file.value.installed.client_id.len;
    const client_secret_len = config_file.value.installed.client_secret.len;

    var client_id: []u8 = try allocator.alloc(u8, client_id_len);
    var client_secret: []u8 = try allocator.alloc(u8, client_secret_len);

    @memcpy(client_id[0..], config_file.value.installed.client_id);
    @memcpy(client_secret[0..], config_file.value.installed.client_secret);

    return Config{
        .client_id = client_id,
        .client_secret = client_secret,
    };
}

pub fn getConfigFile(allocator: std.mem.Allocator) ![]u8 {
    const home_dir = switch (builtin.os.tag) {
        .windows => try std.process.getEnvVarOwned(allocator, "USERPROFILE"),
        .macos, .linux, .freebsd, .netbsd, .dragonfly, .openbsd, .solaris, .illumos, .serenity => try std.process.getEnvVarOwned(allocator, "HOME"),
        else => return error.UnsupportedOS,
    };
    defer allocator.free(home_dir);

    const config_file = try std.fs.path.join(
        allocator,
        &[_][]const u8{ home_dir, ".gcal.config" },
    );
    return config_file;
}
