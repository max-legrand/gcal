const std = @import("std");
const builtin = @import("builtin");

const calendar = @import("calendar.zig");
const config = @import("config.zig");
const token = @import("token.zig");
const utils = @import("utils.zig");

const CalendarListResponse = struct {
    items: []CalendarEntry,
};

const CalendarEntry = struct {
    id: []const u8,
    summary: []const u8,
};

const DIVIDER_PADDING = 8;
const PRIMARY_CALENDAR_ID = "primary";

pub fn main() !void {
    var allocator: std.mem.Allocator = undefined;
    if (builtin.mode == .Debug) {
        var gpa = std.heap.DebugAllocator(.{}).init;
        defer if (builtin.mode == .Debug) {
            if (gpa.detectLeaks()) {
                std.posix.exit(1);
            }
        };
        allocator = gpa.allocator();
    } else {
        allocator = std.heap.smp_allocator;
    }

    const width = try utils.getTerminalWidth(allocator);
    const divider_width = width - DIVIDER_PADDING;

    var time_filter: calendar.TimeFilter = undefined;
    var custom_start: ?[]const u8 = null;
    var custom_end: ?[]const u8 = null;
    var use_pager = true;
    var filter_set = false;
    var list_calendars = false;
    var calendar_id: []const u8 = PRIMARY_CALENDAR_ID;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var arg_i: usize = 1; // skip program name
    while (arg_i < args.len) {
        const arg = args[arg_i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--no-pager")) {
            use_pager = false;
            arg_i += 1;
        } else if (std.mem.eql(u8, arg, "--week") or std.mem.eql(u8, arg, "-W")) {
            if (filter_set) return error.MultipleTimeFiltersSpecified;
            time_filter = .Week;
            filter_set = true;
            arg_i += 1;
        } else if (std.mem.eql(u8, arg, "--month") or std.mem.eql(u8, arg, "-M")) {
            if (filter_set) return error.MultipleTimeFiltersSpecified;
            time_filter = .Month;
            filter_set = true;
            arg_i += 1;
        } else if (std.mem.eql(u8, arg, "--custom") or std.mem.eql(u8, arg, "-C")) {
            if (filter_set) return error.MultipleTimeFiltersSpecified;
            arg_i += 1;
            if (arg_i >= args.len) return error.MissingStartDateForCustomFilter;
            const start_date = args[arg_i];
            validateDate(start_date) catch {
                std.debug.print("Invalid date format. Must be YYYY-MM-DD.\n", .{});
                std.process.exit(1);
            };
            arg_i += 1;
            var end_date: ?[]const u8 = null;
            if (arg_i < args.len and !std.mem.startsWith(u8, args[arg_i], "-")) {
                end_date = args[arg_i];
                validateDate(end_date.?) catch {
                    std.debug.print("Invalid date format. Must be YYYY-MM-DD.\n", .{});
                    std.process.exit(1);
                };
                arg_i += 1;
            }
            const start_str = try std.fmt.allocPrint(allocator, "{s}T00:00:00Z", .{start_date});
            custom_start = start_str;
            const end_str = if (end_date) |ed| try std.fmt.allocPrint(allocator, "{s}T23:59:59Z", .{ed}) else try std.fmt.allocPrint(allocator, "{s}T23:59:59Z", .{start_date});
            custom_end = end_str;
            time_filter = .{
                .Custom = .{
                    .start = custom_start.?,
                    .end = custom_end.?,
                },
            };
            filter_set = true;
        } else if (std.mem.eql(u8, arg, "--today") or std.mem.eql(u8, arg, "-t")) {
            if (filter_set) return error.MultipleTimeFiltersSpecified;
            time_filter = .Today;
            filter_set = true;
            arg_i += 1;
        } else if (std.mem.eql(u8, arg, "--tomorrow") or std.mem.eql(u8, arg, "-T")) {
            if (filter_set) return error.MultipleTimeFiltersSpecified;
            time_filter = .Tomorrow;
            filter_set = true;
            arg_i += 1;
        } else if (std.mem.eql(u8, arg, "--user") or std.mem.eql(u8, arg, "-u")) {
            arg_i += 1;
            if (arg_i >= args.len) return error.MissingEmailForUserArgument;
            calendar_id = args[arg_i];
            arg_i += 1;
        } else if (std.mem.eql(u8, arg, "--list-calendars") or std.mem.eql(u8, arg, "-l")) {
            list_calendars = true;
            arg_i += 1;
        } else {
            return error.UnknownArgument;
        }
    }
    if (!filter_set) time_filter = .Week;

    var actual_stdout: *std.Io.Writer = undefined;
    var actual_stdout_buf: [1024]u8 = undefined;
    var actual_stdout_file = std.fs.File.stdout().writer(&actual_stdout_buf);
    actual_stdout = &actual_stdout_file.interface;

    // First look for the config file. If not present, go through the auth flow.
    const token_file = try token.getTokenFile(allocator);
    var exists = true;
    defer allocator.free(token_file);

    const config_file = try config.getConfigFile(allocator);
    var config_file_exists = true;
    defer allocator.free(config_file);

    std.fs.accessAbsolute(token_file, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => exists = false,
        else => return err,
    };

    std.fs.accessAbsolute(config_file, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => config_file_exists = false,
        else => return err,
    };

    if (!exists) {
        try token.getDeviceCode(.{
            .allocator = allocator,
            .stdout = actual_stdout,
            .token_file = token_file,
            .config_file = config_file,
            .config_file_exists = config_file_exists,
        });
    }

    var token_file_object = try std.fs.openFileAbsolute(token_file, .{});
    defer token_file_object.close();
    var token_file_reader = token_file_object.reader(&.{});
    var reader = &token_file_reader.interface;

    const token_file_contents = try reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(token_file_contents);

    var token_parsed = try std.json.parseFromSlice(token.Token, allocator, token_file_contents, .{});
    defer token_parsed.deinit();

    var t: token.Token = token_parsed.value;
    // Copy this so that we can always free it if we have to refresh the token.
    t.access_token = try allocator.dupe(u8, t.access_token);
    defer t.deinit(allocator);

    var cfg = try config.parseConfigFile(allocator, config_file);
    defer cfg.deinit(allocator);

    // If the token expires in less than 1 minute, refresh it
    if (std.time.milliTimestamp() >= t.current_time + (t.expires_in * 1000) - 60_000) {
        try t.refreshToken(allocator, cfg);
    }

    const auth_header_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{t.access_token});
    defer allocator.free(auth_header_value);
    var headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header_value },
    };

    if (list_calendars) {
        const cal_response = try utils.makeRequest(allocator, .{
            .method = .GET,
            .url = "https://www.googleapis.com/calendar/v3/users/me/calendarList",
            .body = null,
            .headers = headers[0..],
        });
        defer allocator.free(cal_response);

        var cal_parsed = try std.json.parseFromSlice(
            CalendarListResponse,
            allocator,
            cal_response,
            .{ .ignore_unknown_fields = true },
        );
        defer cal_parsed.deinit();

        std.debug.print("Available calendars:\n", .{});
        for (cal_parsed.value.items, 1..) |entry, i| {
            std.debug.print("{d}. {s}\n", .{ i, entry.summary });
        }

        std.debug.print("Select a calendar (1-{}): ", .{cal_parsed.value.items.len});
        var stdin_buf: [1024]u8 = undefined;
        var stdin = std.fs.File.stdin().reader(&stdin_buf);
        var stdin_reader = &stdin.interface;
        var selection: usize = 0;
        var buf: [1]u8 = undefined;
        while (true) {
            var done = false;
            stdin_reader.readSliceAll(&buf) catch |err| {
                switch (err) {
                    error.EndOfStream => {
                        done = true;
                    },
                    else => return err,
                }
            };
            if (buf[0] == '\n') {
                break;
            }
            if (buf[0] >= '0' and buf[0] <= '9') {
                selection = selection * 10 + (buf[0] - '0');
            } else {
                std.debug.print("Invalid input: {s}.\n", .{buf});
                std.process.exit(1);
            }
            if (done) {
                break;
            }
        }
        if (selection < 1 or selection > cal_parsed.value.items.len) {
            std.debug.print("Selection out of range.\n", .{});
            std.process.exit(1);
        }
        calendar_id = try allocator.dupe(u8, cal_parsed.value.items[selection - 1].id);
        std.debug.print("Selected: {s}\n", .{cal_parsed.value.items[selection - 1].summary});
    }

    errdefer {
        if (custom_start) |start_str| {
            allocator.free(start_str);
        }
        if (custom_end) |end_str| {
            allocator.free(end_str);
        }
        if (list_calendars) {
            allocator.free(calendar_id);
        }
    }

    var stdout: *std.Io.Writer = undefined;
    var child: std.process.Child = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var pager_stdin_file: std.fs.File = undefined;
    if (use_pager) {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        const pager = env.get("GCAL_PAGER") orelse "less";
        child = std.process.Child.init(&[_][]const u8{pager}, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Inherit;
        try child.spawn();

        pager_stdin_file = child.stdin.?;
        var stdin_writer = pager_stdin_file.writer(&stdout_buf);
        stdout = &stdin_writer.interface;
    } else {
        var stdout_file = std.fs.File.stdout().writer(&stdout_buf);
        stdout = &stdout_file.interface;
    }

    const tz_offset = try utils.getTzOffset(allocator);
    const response = try calendar.getData(
        allocator,
        t.access_token,
        time_filter,
        calendar_id,
        tz_offset,
    );
    defer {
        for (response.events) |event| {
            event.deinit(allocator);
            allocator.destroy(event);
        }
        allocator.free(response.events);
    }
    if (custom_start) |start_str| {
        allocator.free(start_str);
    }
    if (custom_end) |end_str| {
        allocator.free(end_str);
    }
    if (list_calendars) {
        allocator.free(calendar_id);
    }

    var date_groups = std.StringHashMap(
        std.ArrayList(*calendar.Event),
    ).init(allocator);
    defer {
        var it = date_groups.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        date_groups.deinit();
    }

    for (response.events) |event| {
        var start_date_value: []const u8 = undefined;
        var end_date_value: []const u8 = undefined;
        const is_all_day = event.start.dateTime == null;

        if (event.start.dateTime) |date_time| {
            start_date_value = date_time;
        } else {
            start_date_value = event.start.date.?;
        }
        if (event.end.dateTime) |date_time| {
            end_date_value = date_time;
        } else {
            end_date_value = event.end.date.?;
        }

        var start_date = try calendar.parseDateTime(start_date_value, tz_offset);
        var end_date = try calendar.parseDateTime(end_date_value, tz_offset);

        // For multi-day all-day events, add to each date it spans
        if (is_all_day and !start_date.equalDate(&end_date)) {
            var current_date = start_date;

            while (!current_date.equalDate(&end_date)) {
                const year: u16 = @intCast(current_date.date.year);
                const date_key = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, current_date.date.month, current_date.date.day });
                var result = try date_groups.getOrPut(date_key);
                if (!result.found_existing) {
                    result.value_ptr.* = std.ArrayList(*calendar.Event).empty;
                } else {
                    allocator.free(date_key);
                }
                try result.value_ptr.append(allocator, event);

                // Move to next day
                current_date.date.day += 1;
                const month_days = utils.getMonthDays(@intCast(year));
                const days_in_month = month_days[current_date.date.month - 1];
                if (current_date.date.day > days_in_month) {
                    current_date.date.day = 1;
                    current_date.date.month += 1;
                    if (current_date.date.month > 12) {
                        current_date.date.month = 1;
                        current_date.date.year += 1;
                    }
                }
            }
        } else {
            // Single day event or timed multi-day event
            const year: u16 = @intCast(start_date.date.year);
            const date_key = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, start_date.date.month, start_date.date.day });
            var result = try date_groups.getOrPut(date_key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(*calendar.Event).empty;
            } else {
                allocator.free(date_key);
            }
            try result.value_ptr.append(allocator, event);
        }
    }

    var dates = std.ArrayList([]const u8).empty;
    defer dates.deinit(allocator);

    var it = date_groups.keyIterator();
    while (it.next()) |key| {
        try dates.append(allocator, key.*);
    }

    std.mem.sort([]const u8, dates.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var printed_count: usize = 0;
    for (dates.items) |date_key| {
        const events = date_groups.get(date_key).?;

        const date_year = try std.fmt.parseInt(i32, date_key[0..4], 10);
        const date_month = try std.fmt.parseInt(u4, date_key[5..7], 10);
        const date_day = try std.fmt.parseInt(u5, date_key[8..10], 10);
        const in_range = (date_year > response.start_date.year or (date_year == response.start_date.year and (date_month > response.start_date.month or (date_month == response.start_date.month and date_day >= response.start_date.day)))) and
            (date_year < response.end_date.year or (date_year == response.end_date.year and (date_month < response.end_date.month or (date_month == response.end_date.month and date_day <= response.end_date.day))));
        if (!in_range) continue;

        if (printed_count > 0) {
            try stdout.print("\n", .{});
        }
        try printDivider(stdout, divider_width, '=');
        const header = try isoToHeaderLabel(allocator, date_key);
        defer allocator.free(header);
        try stdout.print("{s}\n", .{header});
        try printDivider(stdout, divider_width, '=');

        for (events.items) |event| {
            var start_date_value: []const u8 = undefined;
            var end_date_value: []const u8 = undefined;
            if (event.start.dateTime) |date_time| {
                start_date_value = date_time;
            } else {
                start_date_value = event.start.date.?;
            }
            if (event.end.dateTime) |date_time| {
                end_date_value = date_time;
            } else {
                end_date_value = event.end.date.?;
            }

            var start_date = try calendar.parseDateTime(start_date_value, tz_offset);
            const start_date_string = try start_date.dateString(allocator);
            defer allocator.free(start_date_string);

            var end_date = try calendar.parseDateTime(end_date_value, tz_offset);
            const end_date_string = try end_date.dateString(allocator);
            defer allocator.free(end_date_string);

            const start_time_string = try start_date.timeString(allocator);
            defer allocator.free(start_time_string);
            const end_time_string = try end_date.timeString(allocator);
            defer allocator.free(end_time_string);

            try stdout.print("{s}\n", .{event.summary});
            if (start_date.equalDate(&end_date)) {
                try stdout.print(
                    "{s} -> {s}",
                    .{
                        start_time_string,
                        end_time_string,
                    },
                );
            } else {
                try stdout.print(
                    "{s} {s} -> {s} {s}",
                    .{
                        start_date_string,
                        start_time_string,
                        end_date_string,
                        end_time_string,
                    },
                );
            }
            if (event.location) |location| {
                try stdout.print("\nLocation: {s}", .{location});
            }
            if (event.description) |description| {
                if (event.meeting_link != null) {
                    const start_idx = std.mem.indexOf(u8, description, "<html>");
                    const end_idx = std.mem.indexOf(u8, description, "</html>");
                    if (start_idx != null and end_idx != null) {
                        const desc = try std.fmt.allocPrint(allocator, "{s}{s}", .{ description[0..start_idx.?], description[end_idx.? + 7 ..] });
                        defer allocator.free(desc);
                        if (!std.mem.eql(u8, std.mem.trim(u8, desc, " \n\r\t"), "")) {
                            const cleaned_desc = try sanitizeDescription(allocator, desc);
                            defer allocator.free(cleaned_desc);
                            if (!std.mem.eql(u8, std.mem.trim(u8, cleaned_desc, " \n\r\t"), "")) {
                                try stdout.print("\nDescription: {s}", .{cleaned_desc});
                            }
                        }
                    } else {
                        const cleaned_desc = try sanitizeDescription(allocator, description);
                        defer allocator.free(cleaned_desc);
                        if (!std.mem.eql(u8, std.mem.trim(u8, cleaned_desc, " \n\r\t"), "")) {
                            try stdout.print("\nDescription: {s}", .{cleaned_desc});
                        }
                    }
                } else {
                    const cleaned_desc = try sanitizeDescription(allocator, description);
                    defer allocator.free(cleaned_desc);
                    if (!std.mem.eql(u8, std.mem.trim(u8, cleaned_desc, " \n\r\t"), "")) {
                        try stdout.print("\nDescription: {s}", .{cleaned_desc});
                    }
                }
            }
            if (event.meeting_link) |meeting_link| {
                try stdout.print("\nLink: {s}", .{meeting_link});
            }
            try stdout.print("\n", .{});
            if (event.attendees) |attendees| {
                try stdout.print("Attendees: \n", .{});
                for (attendees, 0..) |attendee, i| {
                    if (i > 0) try stdout.print(", ", .{});
                    try stdout.print("{s}", .{attendee});
                }
                try stdout.print("\n", .{});
            }
            try printDivider(stdout, divider_width, '-');
        }
        printed_count += 1;
        try stdout.flush();
    }

    if (use_pager) {
        pager_stdin_file.close();
        child.stdin = null;
        _ = try child.wait();
    }
}

/// Remove HTML tags from descriptions and replaces line breaks with newlines
fn sanitizeDescription(allocator: std.mem.Allocator, description: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < description.len) {
        // Find start of the first tag
        const tag_start = std.mem.indexOfScalarPos(u8, description, i, '<') orelse description.len;
        try result.appendSlice(allocator, description[i..tag_start]);
        i = tag_start + 1;
        if (tag_start < description.len) {
            // Find the end of the tag
            const tag_end = std.mem.indexOfScalarPos(u8, description, i, '>') orelse description.len;
            if (tag_end < description.len) {
                const tag = description[i..tag_end];
                if (std.mem.eql(u8, tag, "br") or std.mem.eql(u8, tag, "br/")) {
                    try result.append(allocator, '\n');
                }
                i = tag_end + 1;
            } else {
                i = tag_end;
            }
        }
    }
    var deduped = try std.ArrayList(u8).initCapacity(allocator, result.items.len);
    defer deduped.deinit(allocator);
    var last_was_newline = false;
    for (result.items) |c| {
        if (c == '\n') {
            if (!last_was_newline) {
                try deduped.append(allocator, '\n');
                last_was_newline = true;
            }
        } else {
            try deduped.append(allocator, c);
            last_was_newline = false;
        }
    }
    const deduped_string = try deduped.toOwnedSlice(allocator);
    defer allocator.free(deduped_string);

    var lines_iter = std.mem.splitScalar(u8, deduped_string, '\n');
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    while (lines_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    var cleaned_lines = std.ArrayList([]const u8).empty;
    defer cleaned_lines.deinit(allocator);
    var idx: usize = 0;
    if (lines.items.len > 0) {
        var empty = true;
        while (idx < lines.items.len) {
            const line = std.mem.trim(u8, lines.items[idx], " \t\r\n");
            if (line.len > 0) {
                empty = false;
                break;
            }
            idx += 1;
        }
        const trimmed_line = std.mem.trim(u8, lines.items[idx], " \t\r\n");
        if (!empty and (trimmed_line[0] == 226 or trimmed_line[0] == '-')) {
            const start = lines.items[idx];
            idx += 1;
            var found_start = false;
            while (idx < lines.items.len) {
                if (std.mem.eql(u8, lines.items[idx], start)) {
                    idx += 1;
                    found_start = true;
                    break;
                }
                idx += 1;
            }
            if (idx >= lines.items.len and !found_start) {
                idx = 0;
            }
        }
    }
    while (idx < lines.items.len) {
        var line = lines.items[idx];
        if (idx == 0) {
            if (std.mem.indexOf(u8, line, "Zoom meeting") != null) {
                while (!std.mem.startsWith(u8, line, "Find your local number")) {
                    idx += 1;
                    if (idx >= lines.items.len) break;
                    line = lines.items[idx];
                }
                // Look ahead to see if there is a meeting id line
                var jdx = idx;
                while (jdx < lines.items.len) {
                    if (!std.mem.startsWith(u8, lines.items[jdx], "Meeting ID")) {
                        jdx += 1;
                    } else {
                        break;
                    }
                }
                if (jdx < lines.items.len) {
                    idx = jdx + 1;
                }
                idx += 1;
                continue;
            } else {
                try cleaned_lines.append(allocator, line);
                idx += 1;
            }
        } else {
            try cleaned_lines.append(allocator, line);
            idx += 1;
        }
    }
    // Join the lines back into a single string.
    return std.mem.join(allocator, "\n", cleaned_lines.items);
}

fn validateDate(date: []const u8) !void {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return error.InvalidDateFormat;
    const year = std.fmt.parseInt(u16, date[0..4], 10) catch return error.InvalidDateFormat;
    const month = std.fmt.parseInt(u8, date[5..7], 10) catch return error.InvalidDateFormat;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch return error.InvalidDateFormat;
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDateFormat;
    if (day > utils.getMonthDays(year)[month - 1]) return error.InvalidDateFormat;
}

fn printDivider(stdout: *std.io.Writer, width: u16, character: u8) !void {
    for (0..width) |_| {
        try stdout.writeByte(character);
    }
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn isoToHeaderLabel(allocator: std.mem.Allocator, iso: []const u8) ![]u8 {
    // iso = "YYYY-MM-DD"
    const month = std.fmt.parseInt(u8, iso[5..7], 10) catch return error.InvalidMonth;
    const day = std.fmt.parseInt(u8, iso[8..10], 10) catch return error.InvalidDay;
    const month_str = utils.months[month - 1];
    return try std.fmt.allocPrint(allocator, "{s}-{d:0>2}", .{ month_str, day });
}

fn printUsage() void {
    std.debug.print(
        \\gcal —  A Google Calendar CLI (read-only)
        \\
        \\Usage:
        \\  gcal [flags]
        \\
        \\Flags:
        \\  --today, -t           Show today’s events
        \\  --tomorrow, -T        Show tomorrow’s events
        \\  --week, -W            Show this week (default)
        \\  --month, -M           Show this month
        \\  --custom, -C START [END]  Custom date range (YYYY-MM-DD)
        \\  --user, -u EMAIL      Use calendar by email (default: primary)
        \\  --list-calendars, -l  List calendars and interactively pick one
        \\  --no-pager            Print directly without pager (default uses $GCAL_PAGER or less)
        \\  --help, -h            Show this help and exit
        \\
        \\Examples:
        \\  gcal -t
        \\  gcal -C 2025-10-01 2025-10-07
        \\  gcal -u someone@example.com -W
        \\
    ,
        .{},
    );
}
