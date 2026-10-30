//! 3x3 Projective Transformation (Homography) for QR Code Model 2.
//!
//! Maps arbitrary planar quadrilaterals to quadrilaterals in closed form.
//! Follows the formulation from:
//!   - Paul Heckbert, "Projective Mappings for Image Warping",
//!     Master's thesis, University of California, Berkeley, 1989.
//!   - zxing-cpp: core/src/PerspectiveTransform.cpp
//!
//! Provides:
//!   - `quadrilateralToSquare`
//!   - `squareToQuadrilateral`
//!   - `quadrilateralToQuadrilateral`
//!   - `transform(u, v) -> Point`
//!   - `invert() -> Transform`

const std = @import("std");
const Point = @import("finder.zig").Point;

pub const Transform = struct {
    // 3x3 matrix in row-major order:
    // [ a11, a12, a13 ]
    // [ a21, a22, a23 ]
    // [ a31, a32, a33 ]
    a11: f64,
    a12: f64,
    a13: f64,
    a21: f64,
    a22: f64,
    a23: f64,
    a31: f64,
    a32: f64,
    a33: f64,

    /// Maps unit square (0,0), (1,0), (1,1), (0,1) to arbitrary quadrilateral (x0,y0)..(x3,y3).
    pub fn squareToQuadrilateral(
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        x3: f64,
        y3: f64,
    ) ?Transform {
        const dx3 = x0 - x1 + x2 - x3;
        const dy3 = y0 - y1 + y2 - y3;

        if (dx3 == 0.0 and dy3 == 0.0) {
            // Affine transform (parallelogram)
            return Transform{
                .a11 = x1 - x0,
                .a21 = x2 - x1,
                .a31 = x0,
                .a12 = y1 - y0,
                .a22 = y2 - y1,
                .a32 = y0,
                .a13 = 0.0,
                .a23 = 0.0,
                .a33 = 1.0,
            };
        } else {
            const dx1 = x1 - x2;
            const dx2 = x3 - x2;
            const dy1 = y1 - y2;
            const dy2 = y3 - y2;
            const denominator = dx1 * dy2 - dx2 * dy1;
            if (@abs(denominator) < 1e-12) return null; // Degenerate quadrilateral

            const a13 = (dx3 * dy2 - dx2 * dy3) / denominator;
            const a23 = (dx1 * dy3 - dx3 * dy1) / denominator;

            return Transform{
                .a11 = x1 - x0 + a13 * x1,
                .a21 = x3 - x0 + a23 * x3,
                .a31 = x0,
                .a12 = y1 - y0 + a13 * y1,
                .a22 = y3 - y0 + a23 * y3,
                .a32 = y0,
                .a13 = a13,
                .a23 = a23,
                .a33 = 1.0,
            };
        }
    }

    /// Computes the inverse 3x3 transformation matrix using the classical adjoint.
    pub fn invert(self: Transform) ?Transform {
        // Compute 2x2 sub-determinants (cofactors)
        const a11 = self.a22 * self.a33 - self.a23 * self.a32;
        const a21 = self.a23 * self.a31 - self.a21 * self.a33;
        const a31 = self.a21 * self.a32 - self.a22 * self.a31;

        const a12 = self.a13 * self.a32 - self.a12 * self.a33;
        const a22 = self.a11 * self.a33 - self.a13 * self.a31;
        const a32 = self.a12 * self.a31 - self.a11 * self.a32;

        const a13 = self.a12 * self.a23 - self.a13 * self.a22;
        const a23 = self.a13 * self.a21 - self.a11 * self.a23;
        const a33 = self.a11 * self.a22 - self.a12 * self.a21;

        const det = self.a11 * a11 + self.a12 * a21 + self.a13 * a31;
        if (@abs(det) < 1e-15) return null;

        const inv_det = 1.0 / det;
        return Transform{
            .a11 = a11 * inv_det,
            .a12 = a12 * inv_det,
            .a13 = a13 * inv_det,
            .a21 = a21 * inv_det,
            .a22 = a22 * inv_det,
            .a23 = a23 * inv_det,
            .a31 = a31 * inv_det,
            .a32 = a32 * inv_det,
            .a33 = a33 * inv_det,
        };
    }

    /// Maps arbitrary quadrilateral (x0,y0)..(x3,y3) to unit square (0,0), (1,0), (1,1), (0,1).
    pub fn quadrilateralToSquare(
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        x3: f64,
        y3: f64,
    ) ?Transform {
        const sq2q = squareToQuadrilateral(x0, y0, x1, y1, x2, y2, x3, y3) orelse return null;
        return sq2q.invert();
    }

    /// Composes two 3x3 projective transformation matrices: result = self * other.
    pub fn multiply(self: Transform, other: Transform) Transform {
        return Transform{
            .a11 = self.a11 * other.a11 + self.a21 * other.a12 + self.a31 * other.a13,
            .a21 = self.a11 * other.a21 + self.a21 * other.a22 + self.a31 * other.a23,
            .a31 = self.a11 * other.a31 + self.a21 * other.a32 + self.a31 * other.a33,

            .a12 = self.a12 * other.a11 + self.a22 * other.a12 + self.a32 * other.a13,
            .a22 = self.a12 * other.a21 + self.a22 * other.a22 + self.a32 * other.a23,
            .a32 = self.a12 * other.a31 + self.a22 * other.a32 + self.a32 * other.a33,

            .a13 = self.a13 * other.a11 + self.a23 * other.a12 + self.a33 * other.a13,
            .a23 = self.a13 * other.a21 + self.a23 * other.a22 + self.a33 * other.a23,
            .a33 = self.a13 * other.a31 + self.a23 * other.a32 + self.a33 * other.a33,
        };
    }

    /// Maps arbitrary source quadrilateral (src_u0,src_v0)..(src_u3,src_v3) to destination quadrilateral (x0,y0)..(x3,y3).
    pub fn quadrilateralToQuadrilateral(
        src_u0: f64,
        src_v0: f64,
        src_u1: f64,
        src_v1: f64,
        src_u2: f64,
        src_v2: f64,
        src_u3: f64,
        src_v3: f64,
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        x3: f64,
        y3: f64,
    ) ?Transform {
        const q2sq = quadrilateralToSquare(src_u0, src_v0, src_u1, src_v1, src_u2, src_v2, src_u3, src_v3) orelse return null;
        const sq2q = squareToQuadrilateral(x0, y0, x1, y1, x2, y2, x3, y3) orelse return null;
        return sq2q.multiply(q2sq);
    }

    /// Applies the projective transformation to point (u, v), returning projected point (x, y).
    pub fn map(self: Transform, u: f64, v: f64) Point {
        const den = self.a13 * u + self.a23 * v + self.a33;
        if (@abs(den) < 1e-15) {
            return .{ .x = 0.0, .y = 0.0 };
        }
        const inv_den = 1.0 / den;
        return .{
            .x = (self.a11 * u + self.a21 * v + self.a31) * inv_den,
            .y = (self.a12 * u + self.a22 * v + self.a32) * inv_den,
        };
    }
};

test "Transform: identity and squareToQuadrilateral" {
    const testing = std.testing;

    // Unit square to unit square
    const id = Transform.squareToQuadrilateral(0, 0, 1, 0, 1, 1, 0, 1).?;
    const p0 = id.map(0, 0);
    const p1 = id.map(1, 0);
    const p2 = id.map(1, 1);
    const p3 = id.map(0, 1);

    try testing.expectApproxEqAbs(@as(f64, 0.0), p0.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), p0.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), p1.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), p1.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), p2.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), p2.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), p3.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), p3.y, 1e-6);
}

test "Transform: quadrilateralToQuadrilateral perspective mapping and inverse" {
    const testing = std.testing;

    // Map square [0..100]x[0..100] to a tilted trapezoid
    const t = Transform.quadrilateralToQuadrilateral(
        0,
        0,
        100,
        0,
        100,
        100,
        0,
        100,
        10,
        15,
        90,
        20,
        80,
        85,
        20,
        80,
    ).?;

    // Check mapping of 4 corners
    const c0 = t.map(0, 0);
    try testing.expectApproxEqAbs(@as(f64, 10.0), c0.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 15.0), c0.y, 1e-6);

    const c1 = t.map(100, 0);
    try testing.expectApproxEqAbs(@as(f64, 90.0), c1.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 20.0), c1.y, 1e-6);

    const c2 = t.map(100, 100);
    try testing.expectApproxEqAbs(@as(f64, 80.0), c2.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 85.0), c2.y, 1e-6);

    const c3 = t.map(0, 100);
    try testing.expectApproxEqAbs(@as(f64, 20.0), c3.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 80.0), c3.y, 1e-6);

    // Invert and check round-trip of center (50, 50)
    const mid = t.map(50, 50);
    const inv = t.invert().?;
    const orig = inv.map(mid.x, mid.y);
    try testing.expectApproxEqAbs(@as(f64, 50.0), orig.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 50.0), orig.y, 1e-4);
}
