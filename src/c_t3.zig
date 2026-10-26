//! C root for tier 3 (versions 1...40): libzqr_t3.a / libzqr_t3.so,
//! symbols prefixed `zqr_t3_`.

comptime {
    _ = @import("c_api.zig").cWrapper(40, "zqr_t3");
}
