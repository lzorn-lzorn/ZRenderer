// @brief 在此唯一翻译单元启用第三方 stb 图像解码实现，不改动上游头文件。
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

// @brief 在同一翻译单元启用 stb 图像编码实现。
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
