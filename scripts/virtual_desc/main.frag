#version 330 core

in vec2 UVs;
out vec4 frag_color;
uniform sampler2D syn_rgba;
uniform sampler2D syn_depth;
uniform sampler2D nerf_rgba;
uniform sampler2D nerf_depth;
uniform ivec2 nerf_resolution;
uniform ivec2 syn_resolution;
uniform ivec2 full_resolution;

struct FoveationWarp {
    float al, bl, cl;
    float am, bm;
    float ar, br, cr;
    float switch_left, switch_right;
    float inv_switch_left, inv_switch_right;
};

uniform FoveationWarp warp_x;
uniform FoveationWarp warp_y;

float unwarp(in FoveationWarp warp, float y) {
    y = clamp(y, 0.0, 1.0);
    if (y < warp.inv_switch_left) {
        return (sqrt(-4.0 * warp.al * warp.cl + 4.0 * warp.al * y + warp.bl * warp.bl) - warp.bl) / (2.0 * warp.al);
    } else if (y > warp.inv_switch_right) {
        return (sqrt(-4.0 * warp.ar * warp.cr + 4.0 * warp.ar * y + warp.br * warp.br) - warp.br) / (2.0 * warp.ar);
    } else {
        return (y - warp.bm) / warp.am;
    }
}

vec2 unwarp(in vec2 pos) {
    return vec2(unwarp(warp_x, pos.x), unwarp(warp_y, pos.y));
}

void main() {
    int syn_pixel_size = full_resolution.x / syn_resolution.x;
    int nerf_pixel_size = full_resolution.x / nerf_resolution.x;
    vec2 tex_coords = UVs;
    tex_coords.y = 1.0 - tex_coords.y;
    tex_coords = unwarp(tex_coords);
    vec4 view_coords = vec4(tex_coords, 1.0, 1.0);
    vec4 syn = texture(syn_rgba, tex_coords);
    float sd = texture(syn_depth, tex_coords).r;
    // vec4 nerf = texture(nerf_rgba, tex_coords);
    // float nd = texture(nerf_depth, tex_coords).r;
    frag_color = vec4(syn.rgb, 1.0);
    gl_FragDepth = sd;
}