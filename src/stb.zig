//! Hand-written extern declarations for the stb C implementation
//! (compiled via src/stb_impl.c with the STB_*_IMPLEMENTATION macros).

/// Loads an image (PNG/JPG/BMP/...). Returns a tightly-packed buffer of
/// `req_comp` channels, or null on failure.
pub extern fn stbi_load(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    comp: *c_int,
    req_comp: c_int,
) ?[*]u8;

pub extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;

/// Writes `w*h` pixels of `comp` channels (interleaved) to a PNG file.
/// `stride_in_bytes` of 0 means tightly packed.
pub extern fn stbi_write_png(
    filename: [*:0]const u8,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
    stride_in_bytes: c_int,
) c_int;
