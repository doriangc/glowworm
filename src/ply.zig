const std = @import("std");
const fs = std.fs;

const ElementType = enum(u8) { char, uchar, short, ushort, int, uint, float, double };

const Element = struct {
    name: []u8,
    type: ElementType,
};

pub fn loadPly(file_path: []u8) void {
    const file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    const buf: [1024]u8 = undefined;

    // Check magic number
    readline(&in_stream, &buf);
    if (!strStartsWith(&buf, "ply")) return error.InvalidFormat;

    while (true) {
        readline(&in_stream, &buf);

        if (strStartsWith(&buf, "comment")) continue; // Ignore comments
        if (strStartsWith(&buf, "end_header")) break;
        if (strStartsWith(&buf, "element")) {
            const element_name = try extractWord(buf, 1);
            _ = element_name; // TODO: Use element name for some purpose....
            const element_cnt_str = try extractWord(buf, 2);

            const element_cnt = try std.fmt.parseInt(usize, element_cnt_str, 10);
            parseElements(&in_stream, element_cnt);
        }
    }
}

fn parseElements(
    allocator: std.mem.Allocator,
    in_stream: *std.io.AnyReader,
    element_cnt: usize,
) []Element {
    const buf: [1024]u8 = undefined;

    const elem_arr = std.ArrayListUnmanaged(Element).empty;

    for (0..element_cnt) |_| {
        readline(&in_stream, &buf);
        if (!strStartsWith(&buf, "property")) return error.InvalidFormat;
        const property_type_str = try extractWord(buf, 1);
        const property_name_str = try extractWord(buf, 2);

        // for ()
        std.enums.tagName(Color, my_color);

        elem_arr.append(allocator, .{
            .name = ,
            .@"type" = 
        });
    }
}

fn readline(in_stream: *std.io.AnyReader, buf: []u8) !void {
    try in_stream.readUntilDelimiterOrEof(&buf, '\n') orelse return error.InvalidFormat;
}

fn strStartsWith(str: []u8, starts_with: []u8) bool {
    if (str.len < starts_with.len) return false;
    const str_cut = str[0..starts_with.len];

    return std.mem.eql(u8, str_cut, starts_with);
}

fn extractWord(str: []u8, word_idx: u8) ![]u8 {
    var rem_str = str;

    for (0..word_idx) |_| {
        const space_idx = std.mem.indexOfScalar(u8, rem_str, ' ') orelse return error.OutOfBounds;
        rem_str = rem_str[space_idx + 1 ..];
    }
    const next_space_idx = std.mem.indexOfScalar(u8, rem_str, ' ') orelse rem_str.len;
    return str[0..next_space_idx];
}
