const std = @import("std");
const builtin = @import("builtin");
const zul = @import("zul");

pub const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const leap_year_month_days = [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
pub fn getMonthDays(year: i32) [12]u8 {
    if (@mod(year, 4) == 0 and @mod(year, 100) != 0 or @mod(year, 400) == 0) {
        return leap_year_month_days;
    }
    return month_days;
}

const RequestArgs = struct {
    url: []const u8,
    method: std.http.Method,
    body: ?[]u8,
    headers: []std.http.Header,
};

pub fn makeRequest(allocator: std.mem.Allocator, args: RequestArgs) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(args.url);

    var request = try client.request(args.method, uri, .{});
    defer request.deinit();
    request.extra_headers = args.headers;

    if (args.body) |body| {
        try request.sendBodyComplete(body);
    } else {
        try request.sendBodiless();
    }
    var response = try request.receiveHead(&.{});

    var transfer_buf: [1024 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;

    const reader = response.readerDecompressing(
        &transfer_buf,
        &decompress,
        &decompress_buf,
    );

    const response_body = try reader.allocRemaining(allocator, .unlimited);
    return response_body;
}

pub fn openResource(file_or_url: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const binary = switch (builtin.os.tag) {
        .windows => "explorer.exe",
        .macos => "open",
        .linux, .freebsd, .netbsd, .dragonfly, .openbsd, .solaris, .illumos, .serenity => "xdg-open",
        else => return error.UnsupportedOS,
    };

    const args = &[_][]const u8{ binary, file_or_url };
    var child = std.process.Child.init(
        args,
        arena.allocator(),
    );
    const result = try child.spawnAndWait();
    if (result.Exited != 0) {
        return error.OpenFailed;
    }
}

pub fn getTerminalWidth(allocator: std.mem.Allocator) !u16 {
    // Run the tput command to get the terminal width
    var child = std.process.Child.init(&[_][]const u8{ "tput", "cols" }, allocator);
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout_file = child.stdout.?;
    var stdout_buf: [1024]u8 = undefined;
    var stdout_reader = stdout_file.reader(&stdout_buf);

    var term_buf: [1024]u8 = undefined;
    stdout_reader.interface.readSliceAll(&term_buf) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };

    const term = try child.wait();
    if (term.Exited != 0) {
        return error.GetTerminalWidthFailed;
    }
    const raw_width_str = term_buf[0..stdout_reader.pos];
    const width_str = std.mem.trim(u8, raw_width_str, " \n\r\t");

    return std.fmt.parseInt(u16, width_str, 10) catch return error.GetTerminalWidthFailed;
}

pub fn getTzOffset(allocator: std.mem.Allocator) !zul.Time {
    var child = std.process.Child.init(&[_][]const u8{ "date", "+%z" }, allocator);
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout_file = child.stdout.?;
    var stdout_buf: [1024]u8 = undefined;
    var stdout_reader = stdout_file.reader(&stdout_buf);

    var tz_buf: [1024]u8 = undefined;
    stdout_reader.interface.readSliceAll(&tz_buf) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };

    const tz = try child.wait();
    if (tz.Exited != 0) {
        return error.GetTzOffsetFailed;
    }

    const raw_tz_str = tz_buf[0..stdout_reader.pos];

    // TZ offset is of the form +HHMM or -HHMM
    // We will use the micros field to determine the sign.
    const micros: u8 = if (tz_buf[0] == '-') 1 else 0;
    const hours = std.fmt.parseInt(u8, raw_tz_str[1..3], 10) catch return error.GetTzOffsetFailed;
    const minutes = std.fmt.parseInt(u8, raw_tz_str[3..5], 10) catch return error.GetTzOffsetFailed;
    return .{
        .hour = hours,
        .min = minutes,
        .sec = 0,
        .micros = micros,
    };
}
