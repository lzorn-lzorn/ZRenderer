// @brief stb 的手写 C 外部接口声明。
// @notice 对应实现由 stb_impl.c 启用 STB_*_IMPLEMENTATION 宏后编译。

// @brief 加载 PNG、JPG、BMP 等图像为紧密排列的字节缓冲。
// @param filename 以零结尾的输入路径。
// @param x 输出宽度；y 输出高度。
// @param comp 输出源图像通道数，不一定等于返回缓冲的通道数。
// @param req_comp 请求的输出通道数；零表示保持源通道数。
// @return 像素缓冲或失败时的 null；必须通过 stbi_image_free 释放。
pub extern fn stbi_load(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    comp: *c_int,
    req_comp: c_int,
) ?[*]u8;

// @brief 释放 stb 返回的像素缓冲，允许传入 null。
pub extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;

// @brief 将按通道交错排列的 w×h 个像素写入 PNG 文件。
// @param filename 以零结尾的输出路径。
// @param w 图像宽度；h 为图像高度，comp 为每像素通道数。
// @param data 输入像素字节缓冲。
// @param stride_in_bytes 每行跨度字节数；零表示紧密排列。
// @return 非零表示成功，零表示失败。
pub extern fn stbi_write_png(
    filename: [*:0]const u8,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: [*]const u8,
    stride_in_bytes: c_int,
) c_int;
