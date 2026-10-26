const std = @import("std");
const testing = std.testing;
const zqr = @import("zqr");
const Ecc = zqr.Ecc;
const Encoder = zqr.Encoder;

const golden_vectors_txt = @embedFile("golden/vectors.txt");

fn parseHexByte(high: u8, low: u8) !u8 {
    const h = try std.fmt.charToDigit(high, 16);
    const l = try std.fmt.charToDigit(low, 16);
    return (@as(u8, @intCast(h)) << 4) | @as(u8, @intCast(l));
}

test "golden vectors suite: verify against Nayuki reference fixtures" {
    var line_it = std.mem.splitScalar(u8, golden_vectors_txt, '\n');

    var current_id: []const u8 = "";
    var current_version: u8 = 0;
    var current_ecc: Ecc = .low;
    var current_mask: u3 = 0;
    var current_size: u8 = 0;
    var input_buf: [4096]u8 = undefined;
    var input_len: usize = 0;
    var is_multi = false;
    var multi_kind: usize = 0; // 1: 152 bits, 2: 153 bits
    var is_eci = false;
    var eci_val: u32 = 0;

    var matrix_buf: [177 * 177]u8 = undefined;
    var expected_matrix: [177 * 177]u8 = undefined;
    var row_idx: usize = 0;
    var reading_matrix = false;
    var cases_verified: usize = 0;

    while (line_it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) {
            if (reading_matrix) {
                // End of matrix for this case, run verification
                try testing.expectEqual(@as(usize, current_size), row_idx);

                var qr: zqr.QrMatrix = undefined;
                if (is_multi) {
                    if (multi_kind == 1) {
                        // Exact fit in v1: 2 alnum chars ("AB") + 34 digits ("1" * 34) = 152 bits
                        var b1: [16]u8 = undefined;
                        var b2: [32]u8 = undefined;
                        const s1 = zqr.makeAlphanumeric("AB", &b1);
                        const s2 = zqr.makeNumeric("1111111111111111111111111111111111", &b2);
                        const segs = [_]zqr.Segment{ s1, s2 };
                        qr = try Encoder(40).encodeSegmentsAdvanced(&matrix_buf, &segs, 1, 40, current_ecc, null);
                    } else if (multi_kind == 2) {
                        // Exceeds v1 by 1 bit: 1 alnum char ("A") + 36 digits ("1" * 36) = 153 bits
                        var b1: [16]u8 = undefined;
                        var b2: [32]u8 = undefined;
                        const s1 = zqr.makeAlphanumeric("A", &b1);
                        const s2 = zqr.makeNumeric("111111111111111111111111111111111111", &b2);
                        const segs = [_]zqr.Segment{ s1, s2 };
                        qr = try Encoder(40).encodeSegmentsAdvanced(&matrix_buf, &segs, 1, 40, current_ecc, null);
                    }
                } else if (is_eci) {
                    var b_eci: [16]u8 = undefined;
                    var b_bytes: [128]u8 = undefined;
                    const s_eci = zqr.makeEci(eci_val, &b_eci);
                    const s_data = zqr.makeBytes(input_buf[0..input_len], &b_bytes);
                    const segs = [_]zqr.Segment{ s_eci, s_data };
                    qr = try Encoder(40).encodeSegmentsAdvanced(&matrix_buf, &segs, current_version, current_version, current_ecc, current_mask);
                } else {
                    const payload = input_buf[0..input_len];
                    qr = try Encoder(40).encodeWithVersion(&matrix_buf, payload, current_version, current_ecc, current_mask);
                }

                // Verify metadata
                try testing.expectEqual(current_version, qr.version);
                try testing.expectEqual(current_size, qr.size);
                try testing.expectEqual(current_mask, qr.mask);

                // Verify modules bit-by-bit
                const total_modules = @as(usize, current_size) * current_size;
                try testing.expectEqualSlices(u8, expected_matrix[0..total_modules], qr.modules[0..total_modules]);

                cases_verified += 1;
                reading_matrix = false;
                row_idx = 0;
                input_len = 0;
                is_multi = false;
                is_eci = false;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "# CASE: ")) {
            current_id = line["# CASE: ".len..];
            reading_matrix = false;
            row_idx = 0;
            input_len = 0;
            is_multi = false;
            is_eci = false;
        } else if (std.mem.startsWith(u8, line, "version: ")) {
            current_version = try std.fmt.parseInt(u8, line["version: ".len..], 10);
        } else if (std.mem.startsWith(u8, line, "ecc: ")) {
            const ecc_char = line["ecc: ".len];
            current_ecc = switch (ecc_char) {
                'L' => .low,
                'M' => .medium,
                'Q' => .quartile,
                'H' => .high,
                else => unreachable,
            };
        } else if (std.mem.startsWith(u8, line, "mask: ")) {
            current_mask = try std.fmt.parseInt(u3, line["mask: ".len..], 10);
        } else if (std.mem.startsWith(u8, line, "size: ")) {
            current_size = try std.fmt.parseInt(u8, line["size: ".len..], 10);
        } else if (std.mem.startsWith(u8, line, "multi: ")) {
            is_multi = true;
            if (std.mem.indexOf(u8, line, "AB") != null) {
                multi_kind = 1; // 152 bits
            } else {
                multi_kind = 2; // 153 bits
            }
        } else if (std.mem.startsWith(u8, line, "eci: ")) {
            is_eci = true;
            eci_val = try std.fmt.parseInt(u32, line["eci: ".len..], 10);
        } else if (std.mem.startsWith(u8, line, "input_hex: ")) {
            const hex_str = line["input_hex: ".len..];
            input_len = hex_str.len / 2;
            std.debug.assert(input_len <= input_buf.len);
            var i: usize = 0;
            while (i < input_len) : (i += 1) {
                input_buf[i] = try parseHexByte(hex_str[i * 2], hex_str[i * 2 + 1]);
            }
        } else if (std.mem.eql(u8, line, "matrix:")) {
            reading_matrix = true;
            row_idx = 0;
        } else if (reading_matrix) {
            std.debug.assert(line.len == current_size);
            const offset = row_idx * current_size;
            for (line, 0..) |c, col| {
                expected_matrix[offset + col] = if (c == '1') 1 else 0;
            }
            row_idx += 1;
        }
    }

    // Expect at least 50 cases verified
    try testing.expect(cases_verified >= 50);
}
