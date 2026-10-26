//! C root for tier 2 (versions 1...10): libzqr_t2.a / libzqr_t2.so,
//! symbols prefixed `zqr_t2_`.

comptime {
    _ = @import("c_api.zig").cWrapper(10, "zqr_t2");
}
