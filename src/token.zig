const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");
const utils = @import("utils.zig");

pub const Token = struct {
    access_token: []const u8,
    expires_in: u64,
    scope: []const u8,
    refresh_token: []const u8,
    token_type: []const u8,
    current_time: u64,

    pub fn refreshToken(t: *Token, allocator: std.mem.Allocator, cfg: config.Config) !void {
        var headers = [_]std.http.Header{
            .{
                .name = "Content-Type",
                .value = "application/x-www-form-urlencoded",
            },
        };

        const token_request_body = try std.fmt.allocPrint(
            allocator,
            "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token",
            .{
                cfg.client_id,
                cfg.client_secret,
                t.refresh_token,
            },
        );
        defer allocator.free(token_request_body);

        const response = try utils.makeRequest(allocator, .{
            .url = "https://oauth2.googleapis.com/token",
            .method = .POST,
            .headers = &headers,
            .body = token_request_body,
        });
        defer allocator.free(response);

        const RefreshTokenResponse = struct {
            access_token: []const u8,
            expires_in: u64,
        };
        var refresh_token_response = try std.json.parseFromSlice(RefreshTokenResponse, allocator, response, .{ .ignore_unknown_fields = true });
        defer refresh_token_response.deinit();

        allocator.free(t.access_token);
        t.access_token = try allocator.dupe(u8, refresh_token_response.value.access_token);
        t.expires_in = refresh_token_response.value.expires_in;
        t.current_time = @intCast(std.time.milliTimestamp());

        const token_file = try getTokenFile(allocator);
        defer allocator.free(token_file);
        try t.writeToFile(allocator, token_file);
    }

    pub fn deinit(t: *Token, allocator: std.mem.Allocator) void {
        allocator.free(t.access_token);
    }

    pub fn writeToFile(t: *Token, allocator: std.mem.Allocator, token_file: []const u8) !void {
        const json_string = try std.json.Stringify.valueAlloc(allocator, t, .{});
        defer allocator.free(json_string);

        var f = try std.fs.openFileAbsolute(token_file, .{ .mode = .write_only });
        defer f.close();

        try f.writeAll(json_string);
    }
};

pub fn getTokenFile(allocator: std.mem.Allocator) ![]u8 {
    const home_dir = switch (builtin.os.tag) {
        .windows => try std.process.getEnvVarOwned(allocator, "USERPROFILE"),
        .macos, .linux, .freebsd, .netbsd, .dragonfly, .openbsd, .solaris, .illumos, .serenity => try std.process.getEnvVarOwned(allocator, "HOME"),
        else => return error.UnsupportedOS,
    };
    defer allocator.free(home_dir);

    const token_file = try std.fs.path.join(
        allocator,
        &[_][]const u8{ home_dir, ".gcal" },
    );
    return token_file;
}

const DeviceCodeArgs = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    token_file: []const u8,
    config_file_exists: bool,
    config_file: []const u8,
};
pub fn getDeviceCode(
    args: DeviceCodeArgs,
) !void {
    const stdout = args.stdout;
    const token_file = args.token_file;
    const allocator = args.allocator;
    const config_file = args.config_file;

    if (!args.config_file_exists) {
        // Get path from stdin
        try stdout.print("Enter path to config file: ", .{});
        try stdout.flush();

        var path_buf: [1024]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&path_buf);
        var stdin = &stdin_reader.interface;
        const path = try stdin.peekDelimiterExclusive('\n');

        std.fs.copyFileAbsolute(path, config_file, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("File {s} not found\n", .{path});
                std.posix.exit(1);
            },
            else => return err,
        };
    }

    var cfg = try config.parseConfigFile(allocator, config_file);
    defer cfg.deinit(allocator);

    var headers = [_]std.http.Header{
        .{
            .name = "Content-Type",
            .value = "application/x-www-form-urlencoded",
        },
    };
    const code_body = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&scope=https://www.googleapis.com/auth/calendar.readonly",
        .{cfg.client_id},
    );
    defer allocator.free(code_body);
    const response = try utils.makeRequest(allocator, .{
        .url = "https://oauth2.googleapis.com/device/code",
        .method = .POST,
        .headers = &headers,
        .body = code_body,
    });
    defer allocator.free(response);

    const CodeResponse = struct {
        device_code: []const u8,
        user_code: []const u8,
        expires_in: u64,
        interval: u64,
        verification_url: []const u8,
    };
    var code_response = try std.json.parseFromSlice(CodeResponse, allocator, response, .{});
    defer code_response.deinit();

    try stdout.print("Please enter code {s} at {s}\n", .{
        code_response.value.user_code,
        code_response.value.verification_url,
    });
    try stdout.flush();
    try stdout.print("Press enter to open your default browser\n", .{});
    try stdout.flush();

    // Await user input
    var buf: [1]u8 = undefined;
    var stdin_file = std.fs.File.stdin().reader(&buf);
    var sreader = &stdin_file.interface;
    _ = try sreader.take(1);
    try utils.openResource(code_response.value.verification_url);

    const token_request_body = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&client_secret={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code",
        .{
            cfg.client_id,
            cfg.client_secret,
            code_response.value.device_code,
        },
    );
    defer allocator.free(token_request_body);

    const TokenResponse = struct {
        @"error": ?[]const u8 = null,
        error_description: ?[]const u8 = null,
        access_token: []const u8 = "",
        expires_in: u64 = 0,
        refresh_token: []const u8 = "",
        scope: []const u8 = "",
        token_type: []const u8 = "",
    };

    var counter: usize = 0;
    const max_fetch: usize = @intCast(code_response.value.expires_in / code_response.value.interval);
    while (true) : (counter += 1) {
        if (counter >= max_fetch) {
            std.debug.print("Code is expired, please re-run gcal\n", .{});
            std.posix.exit(1);
        }
        const token_response_raw = try utils.makeRequest(allocator, .{
            .url = "https://oauth2.googleapis.com/token",
            .method = .POST,
            .headers = &headers,
            .body = token_request_body,
        });
        defer allocator.free(token_response_raw);

        const token_response = try std.json.parseFromSlice(
            TokenResponse,
            allocator,
            token_response_raw,
            .{
                .ignore_unknown_fields = true,
            },
        );
        defer token_response.deinit();
        if (token_response.value.@"error") |err| {
            if (!std.mem.eql(u8, err, "authorization_pending")) {
                std.debug.print("{s}\n", .{token_response.value.error_description.?});
                std.posix.exit(1);
            }
        } else {
            var f = try std.fs.createFileAbsolute(token_file, .{});
            defer f.close();
            const t = Token{
                .access_token = token_response.value.access_token,
                .expires_in = token_response.value.expires_in,
                .scope = token_response.value.scope,
                .refresh_token = token_response.value.refresh_token,
                .token_type = token_response.value.token_type,
                .current_time = @intCast(std.time.milliTimestamp()),
            };
            const json_string = try std.json.Stringify.valueAlloc(allocator, t, .{});
            defer allocator.free(json_string);
            try f.writeAll(json_string);
            break;
        }
        std.Thread.sleep(code_response.value.interval * std.time.ns_per_s);
    }
}
