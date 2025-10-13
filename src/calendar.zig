const std = @import("std");
const zul = @import("zul");

const utils = @import("utils.zig");

pub const TimeFilter = union(enum) {
    Today,
    Tomorrow,
    Week,
    Month,
    Custom: struct { start: []const u8, end: []const u8 },
};

const EventTime = struct {
    dateTime: ?[]const u8 = null,
    timeZone: ?[]const u8 = null,
    date: ?[]const u8 = null,
    pub fn deinit(self: *EventTime, allocator: std.mem.Allocator) void {
        if (self.dateTime) |date_time| {
            allocator.free(date_time);
        }
        if (self.timeZone) |time_zone| {
            allocator.free(time_zone);
        }
        if (self.date) |date| {
            allocator.free(date);
        }
    }
};

pub const Event = struct {
    summary: []const u8,
    start: EventTime,
    end: EventTime,
    meeting_link: ?[]const u8,
    description: ?[]const u8 = null,
    location: ?[]const u8 = null,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        self.start.deinit(allocator);
        self.end.deinit(allocator);
        if (self.meeting_link) |link| {
            allocator.free(link);
        }
        if (self.location) |loc| {
            allocator.free(loc);
        }
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }
};

const EventResponse = struct {
    items: []std.json.Value,
};

fn zeller(date: zul.Date) i16 {
    var m = date.month;
    if (m < 3) m += 12;
    const k = @mod(date.year, 100);
    const j = @divFloor(date.year, 100);
    const q = date.day;
    return @mod((q + @divFloor((13 * (m + 1)), 5) + k + @divFloor(k, 4) + @divFloor(j, 4) + 5 * j), 7);
}

fn dateToString(allocator: std.mem.Allocator, date: zul.Date, time: zul.Time) ![]u8 {
    const result = try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ @as(u16, @intCast(date.year)), date.month, date.day, time.hour, time.min, time.sec },
    );
    return result;
}

pub fn applyTzOffset(date: zul.DateTime, offset: zul.Time) zul.DateTime {
    const offset_micros = @as(i64, @intCast(offset.hour)) * 60 * 60 * 1000 * 1000 +
        @as(i64, @intCast(offset.min)) * 60 * 1000 * 1000;

    var d = date;
    if (offset.micros == 1) {
        d.micros -= offset_micros;
    } else {
        d.micros += offset_micros;
    }
    return d;
}

const CalendarReturn = struct {
    events: []*Event,
    start_date: zul.Date,
    end_date: zul.Date,
};

pub fn getData(
    allocator: std.mem.Allocator,
    token: []const u8,
    view_type: TimeFilter,
    calendar_id: []const u8,
    tz_offset: zul.Time,
) !CalendarReturn {
    const now_utc = zul.DateTime.now();

    const now = applyTzOffset(now_utc, tz_offset);

    var start_string: []const u8 = undefined;
    var end_string: []const u8 = undefined;
    defer allocator.free(start_string);
    defer allocator.free(end_string);

    var start_date: zul.Date = undefined;
    var end_date: zul.Date = undefined;
    switch (view_type) {
        .Week => {
            start_date = now.date();
            // Move backwards to the start of the week (Sunday).
            const start_dow = zeller(start_date);
            if (start_dow != 1) {
                var days_back: i16 = undefined;
                if (start_dow == 0) {
                    days_back = 6;
                } else {
                    days_back = start_dow - 1;
                }
                const new_day: i16 = @as(i16, @intCast(start_date.day)) - days_back;
                if (new_day < 1) {
                    start_date.month -= 1;
                    if (start_date.month < 1) {
                        start_date.month = 12;
                        start_date.year -= 1;
                    }
                    const month_days = utils.getMonthDays(start_date.year);
                    start_date.day = @as(u8, @intCast(month_days[start_date.month - 1] + new_day));
                } else {
                    start_date.day = @as(u8, @intCast(new_day));
                }
            }
            const start_time = zul.Time{
                .hour = 0,
                .min = 0,
                .sec = 0,
                .micros = 0,
            };

            start_string = try dateToString(allocator, start_date, start_time);

            end_date = start_date;
            // Add 6 days to reach the end of the week (Saturday).
            const new_end_day: i16 = @as(i16, @intCast(end_date.day)) + 6;
            // Handle month and year rollover if necessary
            const month_days = utils.getMonthDays(end_date.year);
            const days_in_month = month_days[end_date.month - 1];
            if (new_end_day > days_in_month) {
                end_date.day = @as(u8, @intCast(new_end_day - days_in_month));
                end_date.month += 1;
                if (end_date.month > 12) {
                    end_date.month = 1;
                    end_date.year += 1;
                }
            } else {
                end_date.day = @as(u8, @intCast(new_end_day));
            }
            const end_time = zul.Time{
                .hour = 23,
                .min = 59,
                .sec = 59,
                .micros = 0,
            };
            end_string = try dateToString(allocator, end_date, end_time);
        },
        .Month => {
            const tz_offset_micros = @as(i64, tz_offset.hour) * 60 * 60 * 1_000_000 + @as(i64, tz_offset.min) * 60 * 1_000_000;
            const seconds_since_midnight = @as(i64, now.time().hour) * 3600 + @as(i64, @intCast(now.time().min)) * 60 + @as(i64, @intCast(now.time().sec));
            const micros_since_midnight = seconds_since_midnight * 1_000_000 + now.time().micros;
            const start_of_day_local_micros = now.micros - micros_since_midnight;
            const days_back = now.date().day - 1;
            const micros_back = @as(i64, days_back) * 24 * 60 * 60 * 1_000_000;
            const start_local_micros = start_of_day_local_micros - micros_back;
            const start_utc_micros = if (tz_offset.micros == 1) start_local_micros + tz_offset_micros else start_local_micros - tz_offset_micros;
            const start_utc = zul.DateTime{ .micros = start_utc_micros };
            start_date = start_utc.date();
            start_string = try dateToString(allocator, start_utc.date(), start_utc.time());

            const month_days = utils.getMonthDays(now.date().year);
            const days_in_month = month_days[now.date().month - 1];
            const end_local_micros = start_local_micros + @as(i64, days_in_month) * 24 * 60 * 60 * 1_000_000;
            const end_utc_micros = if (tz_offset.micros == 1) end_local_micros + tz_offset_micros else end_local_micros - tz_offset_micros;
            const end_utc = zul.DateTime{ .micros = end_utc_micros };
            end_string = try dateToString(allocator, end_utc.date(), end_utc.time());
            end_date = end_utc.date();
        },
        .Today => {
            const today = now.date();
            start_date = today;
            const start_time = zul.Time{
                .hour = 0,
                .min = 0,
                .sec = 0,
                .micros = 0,
            };
            start_string = try dateToString(allocator, today, start_time);
            const end_time = zul.Time{
                .hour = 23,
                .min = 59,
                .sec = 59,
                .micros = 0,
            };
            end_string = try dateToString(allocator, today, end_time);
            end_date = today;
        },
        .Tomorrow => {
            var tomorrow = now.date();
            tomorrow.day += 1;
            const month_days = utils.getMonthDays(tomorrow.year);
            const days_in_month = month_days[tomorrow.month - 1];
            if (tomorrow.day > days_in_month) {
                tomorrow.day = 1;
                tomorrow.month += 1;
                if (tomorrow.month > 12) {
                    tomorrow.month = 1;
                    tomorrow.year += 1;
                }
            }
            start_date = tomorrow;
            const start_time = zul.Time{
                .hour = 0,
                .min = 0,
                .sec = 0,
                .micros = 0,
            };
            start_string = try dateToString(allocator, tomorrow, start_time);
            const end_time = zul.Time{
                .hour = 23,
                .min = 59,
                .sec = 59,
                .micros = 0,
            };
            end_string = try dateToString(allocator, tomorrow, end_time);
            end_date = tomorrow;
        },
        .Custom => |dates| {
            start_string = try allocator.dupe(u8, dates.start);
            end_string = try allocator.dupe(u8, dates.end);
        },
    }

    const replacement_size = std.mem.replacementSize(u8, start_string, ":", "%3A");
    const start_string_encoded = try allocator.alloc(u8, replacement_size);
    defer allocator.free(start_string_encoded);
    const end_string_encoded = try allocator.alloc(u8, replacement_size);
    defer allocator.free(end_string_encoded);
    _ = std.mem.replace(u8, start_string, ":", "%3A", start_string_encoded);
    _ = std.mem.replace(u8, end_string, ":", "%3A", end_string_encoded);

    const url = try std.fmt.allocPrint(allocator, "https://www.googleapis.com/calendar/v3/calendars/{s}/events?singleEvents=true&orderBy=startTime&timeMin={s}&timeMax={s}", .{
        calendar_id,
        start_string_encoded,
        end_string_encoded,
    });
    defer allocator.free(url);

    const auth_header_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header_value);

    var headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header_value },
    };

    const response = try utils.makeRequest(allocator, .{
        .url = url,
        .method = .GET,
        .headers = &headers,
        .body = null,
    });
    defer allocator.free(response);

    const calendar_response: std.json.Parsed(EventResponse) = try std.json.parseFromSlice(EventResponse, allocator, response, .{
        .ignore_unknown_fields = true,
    });
    defer calendar_response.deinit();

    var events_list = try std.ArrayList(*Event).initCapacity(allocator, calendar_response.value.items.len);
    defer events_list.deinit(allocator);

    for (calendar_response.value.items) |item| {
        const item_map = item.object;
        const event_type = item_map.get("eventType");
        if (event_type) |event_type_value| {
            if (std.mem.eql(u8, event_type_value.string, "workingLocation")) {
                // We don't care about events that are just posting the working location to the calendar
                continue;
            }
        }
        const event = try allocator.create(Event);
        var meeting_link: ?[]const u8 = null;
        const conference_data = item.object.get("conferenceData");
        if (conference_data) |conference_data_value| {
            const entry_points = conference_data_value.object.get("entryPoints");
            if (entry_points) |entry_points_value| {
                const entry_points_array = entry_points_value.array;
                for (entry_points_array.items) |entry_point| {
                    const entry_point_type = entry_point.object.get("entryPointType").?.string;
                    if (std.mem.eql(u8, entry_point_type, "video")) {
                        meeting_link = entry_point.object.get("uri").?.string;
                        break;
                    }
                }
            }
        }

        // No summary is a private event
        const summary = if (item_map.get("summary") != null) item_map.get("summary").?.string else "Private Event";
        const start = item_map.get("start").?.object;
        const start_date_time = if (start.get("dateTime") != null) start.get("dateTime").?.string else null;
        const start_date_date = if (start.get("date") != null) start.get("date").?.string else null;
        const start_timezone = if (start.get("timeZone") != null) start.get("timeZone").?.string else null;
        const end = item_map.get("end").?.object;
        const end_date_time = if (end.get("dateTime") != null) end.get("dateTime").?.string else null;
        const end_date_date = if (end.get("date") != null) end.get("date").?.string else null;
        const end_timezone = if (end.get("timeZone") != null) end.get("timeZone").?.string else null;
        const description = if (item_map.get("description") != null) item_map.get("description").?.string else null;
        const location = if (item_map.get("location") != null) item_map.get("location").?.string else null;
        event.* = .{
            .summary = try allocator.dupe(u8, summary),
            .start = .{
                .dateTime = if (start_date_time != null) try allocator.dupe(u8, start_date_time.?) else null,
                .date = if (start_date_date != null) try allocator.dupe(u8, start_date_date.?) else null,
                .timeZone = if (start_timezone != null) try allocator.dupe(u8, start_timezone.?) else null,
            },
            .end = .{
                .dateTime = if (end_date_time != null) try allocator.dupe(u8, end_date_time.?) else null,
                .date = if (end_date_date != null) try allocator.dupe(u8, end_date_date.?) else null,
                .timeZone = if (end_timezone != null) try allocator.dupe(u8, end_timezone.?) else null,
            },
            .meeting_link = if (meeting_link) |link| try allocator.dupe(u8, link) else null,
            .description = if (description != null) try allocator.dupe(u8, description.?) else null,
            .location = if (location != null) try allocator.dupe(u8, location.?) else null,
        };
        events_list.appendAssumeCapacity(event);
    }

    return .{
        .events = try events_list.toOwnedSlice(allocator),
        .start_date = start_date,
        .end_date = end_date,
    };
}

const DateTime = struct {
    date: zul.Date,
    time: zul.Time,
    const Self = @This();

    pub fn dateString(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        const month = self.date.month - 1;
        const month_str = utils.months[month];
        return try std.fmt.allocPrint(allocator, "{s}-{d:0>2}", .{ month_str, self.date.day });
    }

    pub fn timeString(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var hour = self.time.hour;
        var meridiem = "AM";
        if (hour > 12) {
            hour -= 12;
            meridiem = "PM";
        }
        return try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2} {s}", .{ hour, self.time.min, meridiem });
    }

    pub fn equalDate(self: *Self, other: *Self) bool {
        return self.date.year == other.date.year and
            self.date.month == other.date.month and
            self.date.day == other.date.day;
    }
};

pub fn parseDateTime(date_time: []const u8, user_tz: zul.Time) !DateTime {
    var iter = std.mem.splitScalar(u8, date_time, 'T');

    const date = iter.next() orelse return error.InvalidDate;
    const time_and_offset_iter = iter.next() orelse null;

    var date_parts = std.mem.splitScalar(u8, date, '-');
    const year = date_parts.next() orelse return error.InvalidYear;
    const month = date_parts.next() orelse return error.InvalidMonth;
    const day = date_parts.next() orelse return error.InvalidDay;

    const parsed_year = std.fmt.parseInt(i16, year, 10) catch return error.InvalidYear;
    const parsed_month = std.fmt.parseInt(u8, month, 10) catch return error.InvalidMonth;
    const parsed_day = std.fmt.parseInt(u8, day, 10) catch return error.InvalidDay;

    const parsed_date = zul.Date{
        .year = parsed_year,
        .month = parsed_month,
        .day = parsed_day,
    };
    var adjusted_dt: zul.DateTime = undefined;
    if (time_and_offset_iter) |time_and_offset| {
        const time = time_and_offset[0..8];
        const offset = time_and_offset[8..];
        var time_parts = std.mem.splitScalar(u8, time, ':');
        const hour = time_parts.next() orelse return error.InvalidHour;
        const minute = time_parts.next() orelse return error.InvalidMinute;
        const second = time_parts.next() orelse return error.InvalidSecond;

        const timezone = offset;
        const tz_hour = std.fmt.parseInt(u8, timezone[1..3], 10) catch return error.InvalidTimezone;
        const tz_min = std.fmt.parseInt(u8, timezone[4..6], 10) catch return error.InvalidTimezone;
        var tz_micros: i64 = @as(i64, @intCast(tz_hour)) * 60 * 60 * 1000 * 1000 + @as(i64, @intCast(tz_min)) * 60 * 1000 * 1000;
        if (timezone[0] == '-') {
            tz_micros *= -1;
        }
        var user_tz_micros = @as(i64, @intCast(user_tz.hour)) * 60 * 60 * 1000 * 1000 + @as(i64, @intCast(user_tz.min)) * 60 * 1000 * 1000;
        if (user_tz.micros == 1) {
            user_tz_micros *= -1;
        }

        const delta_micros = user_tz_micros - tz_micros;
        const parsed_time = zul.Time{
            .hour = std.fmt.parseInt(u8, hour, 10) catch return error.InvalidHour,
            .min = std.fmt.parseInt(u8, minute, 10) catch return error.InvalidMinute,
            .sec = std.fmt.parseInt(u8, second, 10) catch return error.InvalidSecond,
            .micros = 0,
        };
        const parsed_dt = try zul.DateTime.initUTC(parsed_date.year, parsed_date.month, parsed_date.day, parsed_time.hour, parsed_time.min, parsed_time.sec, parsed_time.micros);

        const abs_delta = @abs(delta_micros);
        const diff_hour = @divFloor(abs_delta, 3600 * 1_000_000);
        const diff_min = @divFloor(@mod(abs_delta, 3600 * 1_000_000), 60 * 1_000_000);
        const diff_sec = @divFloor(@mod(abs_delta, 60 * 1_000_000), 1_000_000);
        const diff_tz = zul.Time{
            .hour = @intCast(diff_hour),
            .min = @intCast(diff_min),
            .sec = @intCast(diff_sec),
            .micros = if (delta_micros < 0) 1 else 0,
        };

        adjusted_dt = applyTzOffset(parsed_dt, diff_tz);
    } else {
        adjusted_dt = try zul.DateTime.initUTC(parsed_date.year, parsed_date.month, parsed_date.day, 0, 0, 0, 0);
    }

    return DateTime{
        .date = adjusted_dt.date(),
        .time = adjusted_dt.time(),
    };
}
