//! C root for tier 1 (versions 1...6): libzqr_t1.a / libzqr_t1.so,
//! symbols prefixed `zqr_t1_`.

comptime {
    _ = @import("c_api.zig").cWrapper(6, "zqr_t1");
}
