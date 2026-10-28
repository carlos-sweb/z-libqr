//! Unified Rendering API for z-libqr (SVG zero-dependency + PNG via libpng).

pub const svg = @import("render_svg.zig");
pub const png = @import("render_png.zig");

pub const RenderOptions = svg.RenderOptions;
pub const renderSvg = svg.renderSvg;
pub const renderSvgBuffer = svg.renderSvgBuffer;
pub const calcSvgLen = svg.calcSvgLen;

pub const renderPng = png.renderPng;
pub const renderPngBuffer = png.renderPngBuffer;
pub const calcPngMaxBound = png.calcPngMaxBound;

test {
    _ = svg;
    _ = png;
}
