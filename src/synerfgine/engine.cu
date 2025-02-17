#include <chrono>
#include <synerfgine/engine.cuh>
#include <synerfgine/common.cuh>
#include <filesystem/path.h>
#include <iostream>
#include <type_traits>
#include <imguizmo/ImGuizmo.h>

namespace sng {

const std::unordered_map<std::string, ngp::ERenderMode> RENDER_MODE_MAP = {
    {"AO", ERenderMode::AO},
    {"Shade", ERenderMode::Shade},
    {"Normals", ERenderMode::Normals},
    {"Positions", ERenderMode::Positions},
    {"Depth", ERenderMode::Depth},
    {"ShadowDepth", ERenderMode::ShadowDepth},
    {"Cost", ERenderMode::Cost}
};

void Engine::set_virtual_world(const std::string& config_fp) {
    nlohmann::json config = File::read_json(config_fp);
    if (config.count("camera")) {
        nlohmann::json& cam_conf = config["camera"];
        if (cam_conf.count("view")) {
            m_default_view_dir = {cam_conf["view"][0], cam_conf["view"][1], cam_conf["view"][2]};
        }
        if (cam_conf.count("at")) {
            m_default_at_pos = {cam_conf["at"][0], cam_conf["at"][1], cam_conf["at"][2]};
        }
        if (cam_conf.count("zoom")) {
            m_default_zoom = cam_conf["zoom"];
        }
        if (cam_conf.count("show_ui_start")) {
            m_show_ui = cam_conf["show_ui_start"];
        }
        if (cam_conf.count("end_on_loop")) {
            m_end_on_loop = cam_conf["end_on_loop"];
        }
        if (cam_conf.count("vo_scale")) {
            m_relative_vo_scale = cam_conf["vo_scale"];
        }
        if (cam_conf.count("animation_speed")) {
            m_anim_speed = cam_conf["animation_speed"];
            m_enable_animations = m_anim_speed > 0.0f;
        }
        if (cam_conf.count("path")) {
            m_camera_path = sng::CamPath(cam_conf);
        }
    }
    if (config.count("rendering")) {
        m_default_render_settings = config["rendering"];
    }
    if (config.count("output")) {
        nlohmann::json& output_conf = config["output"];
        m_output_dest = output_conf["folder"];
        if (output_conf.count("img_count")) {
            m_display.m_img_count_max = output_conf["img_count"];
        } else {
            m_display.m_img_count_max = max(1, m_camera_path.get_total_images());
        }
        if (output_conf.count("record")) {
            m_has_output = output_conf["record"].get<bool>();
        }
    }
    nlohmann::json& mat_conf = config["materials"];
    for (uint32_t i = 0; i < mat_conf.size(); ++i) {
        m_materials.emplace_back(i, mat_conf[i]);
    }
    nlohmann::json& obj_conf = config["objfile"];
    for (uint32_t i = 0; i < obj_conf.size(); ++i) {
        m_objects.emplace_back(i, obj_conf[i]);
    }
    nlohmann::json& light_conf = config["lights"];
    for (uint32_t i = 0; i < light_conf.size(); ++i) {
        m_lights.emplace_back(i, light_conf[i]);
    }
}

void Engine::update_world_objects() {
    bool needs_reset = false;
    bool is_any_obj_dirty = false;
    for (auto& m : m_objects) {
        is_any_obj_dirty = is_any_obj_dirty || m.is_dirty;
        m.is_dirty = false;
    }
    if (is_any_obj_dirty || m_enable_animations) {
        needs_reset = true;
        std::vector<ObjectTransform> h_world;
        for (auto& obj : m_objects) {
            if (m_enable_animations) obj.next_frame(m_anim_speed);
            h_world.emplace_back(obj.gpu_node(), obj.gpu_triangles(), obj.get_rotate(), 
                obj.get_translate(), obj.get_scale(), obj.get_mat_idx());
        }
        d_world.check_guards();
        d_world.resize_and_copy_from_host(h_world);
    }
    is_any_obj_dirty = false;
    for (auto& m : m_materials) {
        is_any_obj_dirty = is_any_obj_dirty || m.is_dirty;
        m.is_dirty = false;
    }
    if (is_any_obj_dirty) {
        needs_reset = true;
        d_materials.check_guards();
        d_materials.resize_and_copy_from_host(m_materials);
    }
    is_any_obj_dirty = false;
    for (auto& l : m_lights) {
        is_any_obj_dirty = is_any_obj_dirty || l.is_dirty;
        l.is_dirty = false;
    }
    if (is_any_obj_dirty || m_enable_animations) {
        needs_reset = true;
        for (auto& obj : m_lights) {
            if (m_enable_animations) obj.next_frame(m_anim_speed);
        }
        d_lights.check_guards();
        d_lights.resize_and_copy_from_host(m_lights);
    }
    needs_reset = needs_reset || m_is_dirty;
    if (needs_reset && m_testbed) {
        m_raytracer.reset_accumulation();
        m_testbed->reset_accumulation();
    }
    CUDA_CHECK_THROW(cudaDeviceSynchronize());
}

void Engine::init(int res_width, int res_height, const std::string& frag_fp, Testbed* nerf) {
	m_testbed = nerf;
    m_testbed->m_train = false;
    m_testbed->set_n_views(1);
    m_next_frame_resolution = {res_width, res_height};
    GLFWwindow* glfw_window = m_display.init_window(res_width, res_height, frag_fp);
    glfwSetWindowUserPointer(glfw_window, this);
    glfwSetWindowSizeCallback(glfw_window, [](GLFWwindow* window, int width, int height) {
        Engine* engine = (Engine*)glfwGetWindowUserPointer(window);
        if (engine) {
            engine->m_next_frame_resolution = {width, height};
            engine->redraw_next_frame();
        }
    });
    glfwSetWindowCloseCallback(glfw_window, [](GLFWwindow* window) {
        Engine* engine = (Engine*)glfwGetWindowUserPointer(window);
        if (engine) { engine->set_dead(); }
    });
    Testbed::CudaDevice& device = m_testbed->primary_device();
    if (length2(m_default_view_dir) != 0.0f) {
        m_testbed->set_view_dir(m_default_view_dir);
        m_testbed->set_look_at(m_default_at_pos);
        m_testbed->set_scale(m_default_zoom);
    }
    m_stream_id = device.stream();
    m_testbed->m_imgui.enabled = m_show_ui;
    if (m_default_render_settings.count("res_factor")) {
        m_testbed->m_fixed_res_factor = m_default_render_settings["res_factor"].get<int>();
    }
    if (m_default_render_settings.count("exposure")) {
        m_testbed->m_exposure = m_default_render_settings["exposure"].get<float>();
    }
    if (m_default_render_settings.count("clear_color")) {
        m_default_clear_color = {m_default_render_settings["clear_color"][0], m_default_render_settings["clear_color"][1], m_default_render_settings["clear_color"][2]};
    }
    if (m_default_render_settings.count("smooth_threshold")) {
        m_testbed->sng_position_kernel_threshold = m_default_render_settings["smooth_threshold"].get<float>();
    }
    if (m_default_render_settings.count("path_trace_depth")) {
        m_raytracer.m_ray_iters = m_default_render_settings["path_trace_depth"];
    }
    if (m_default_render_settings.count("light_samples")) {
        m_raytracer.m_samples = m_default_render_settings["light_samples"];
    }
    if (m_default_render_settings.count("nerf_shadow_samples")) {
        m_testbed->sng_position_kernel_size = m_default_render_settings["nerf_shadow_samples"].get<int>();
    }
    if (m_default_render_settings.count("nerf_shadow_intensity")) {
        m_nerf_shadow_intensity = m_default_render_settings["nerf_shadow_intensity"];
    }
    if (m_default_render_settings.count("syn_shadow_samples")) {
        m_raytracer.m_shadow_iters = m_default_render_settings["syn_shadow_samples"];
    }
    if (m_default_render_settings.count("syn_shadow_intensity")) {
        m_raytracer.m_syn_shadow_factor = m_default_render_settings["syn_shadow_intensity"];
    }
    if (m_default_render_settings.count("attenuation")) {
        m_raytracer.m_attenuation_coeff = m_default_render_settings["attenuation"];
    }
    if (m_default_render_settings.count("lens_size")) {
        m_raytracer.m_lens_angle_constant = m_default_render_settings["lens_size"];
    }
    if (m_default_render_settings.count("nerf_on_nerf_shadow_threshold")) {
        m_nerf_self_shadow_threshold = m_default_render_settings["nerf_on_nerf_shadow_threshold"];
    }
    if (m_default_render_settings.count("show_light_pos") && m_default_render_settings["show_light_pos"] == true) {
        m_transform_type = WorldObjectType::LightObj;
    }
    if (m_default_render_settings.count("max_shadow_variance")) {
        m_testbed->sng_shadow_depth_variance = m_default_render_settings["max_shadow_variance"];
    }
    if (m_default_render_settings.count("nerf_ao_intensity")) {
        m_nerf_ao_intensity = m_default_render_settings["nerf_ao_intensity"];
    }
    if (m_default_render_settings.count("shadow_on_virtual_obj")) {
        m_raytracer.m_view_nerf_shadow = m_default_render_settings["shadow_on_virtual_obj"];
    }
    if (m_default_render_settings.count("shadow_on_nerf")) {
        m_view_syn_shadow = m_default_render_settings["shadow_on_nerf"];
    }
    if (m_default_render_settings.count("shadow_on_virtual_obj")) {
        m_raytracer.m_view_nerf_shadow = m_default_render_settings["shadow_on_virtual_obj"];
    }
    if (m_default_render_settings.count("show_virtual_obj")) {
        m_raytracer.m_show_virtual_obj = m_default_render_settings["show_virtual_obj"];
    }
    if (m_default_render_settings.count("show_nerf")) {
        m_show_nerf = m_default_render_settings["show_nerf"];
    }
    if (m_default_render_settings.count("nerf_filter")) {
        std::string filter_name = m_default_render_settings["nerf_filter"];
        m_testbed->m_render_mode = RENDER_MODE_MAP.at(filter_name);
    }
    if (m_default_render_settings.count("syn_filter")) {
        std::string filter_name = m_default_render_settings["syn_filter"];
        m_raytracer.set_buffer(filter_name);
    }
    if (m_default_render_settings.count("depth_offset")) {
        m_raytracer.m_depth_offset = m_default_render_settings["depth_offset"];
    }
    tlog::info() << "Default camera matrix: Matrix([Vector(" 
        << m_testbed->m_camera[0] << "), Vector("
        << m_testbed->m_camera[1] << "), Vector("
        << m_testbed->m_camera[2] << "), Vector("
        << m_testbed->m_camera[3] << ")]).to_mat4x4()";
}

void Engine::resize() {
    m_display.set_window_res(m_next_frame_resolution);
    m_testbed->m_window_res = m_next_frame_resolution;
    auto& view = nerf_render_buffer_view();
    m_last_res_factor = m_testbed->m_fixed_res_factor;
    float factor = min (1.0f, m_factor_constant / m_testbed->m_fixed_res_factor);
    // tlog::success() << "Scaling full resolution by " << factor;
    auto new_res = downscale_resolution(m_next_frame_resolution, factor);
    view.resize(new_res);
    auto new_res_count = product(new_res);
    d_nerf_rand_state.resize(new_res_count);
    linear_kernel(init_rand_state, 0, m_stream_id, d_nerf_rand_state.size(), d_nerf_rand_state.data());
    d_nerf_normals.resize(new_res_count);
    d_nerf_positions.resize(new_res_count);
    sync(m_stream_id);

    auto rt_res = min(scale_resolution(new_res, (float) m_relative_vo_scale), m_next_frame_resolution);
    m_raytracer.enlarge(rt_res);
    m_relative_vo_scale = rt_res.r / new_res.r;
}

void Engine::imgui() {
    auto& io = ImGui::GetIO();
    if (ImGui::IsKeyPressed(ImGuiKey_Tab)) {
        m_show_ui = !m_show_ui;
    }
    if (m_show_ui) {
        if (ImGui::Begin("Synthetic World")) {
            if (ImGui::CollapsingHeader("Camera", ImGuiTreeNodeFlags_DefaultOpen)) {
                if (ImGui::Button("Reset Camera") && length2(m_default_view_dir) != 0.0f) {
                    m_testbed->set_view_dir(m_default_view_dir);
                    m_testbed->set_look_at(m_default_at_pos);
                    m_testbed->set_scale(m_default_zoom);
                }
            }
            if (ImGui::CollapsingHeader("Materials", ImGuiTreeNodeFlags_DefaultOpen)) {
                for (auto& m : m_materials) { m.imgui(); }
            }
            if (ImGui::CollapsingHeader("Objects", ImGuiTreeNodeFlags_DefaultOpen)) {
                for (auto& m : m_objects) { m.imgui(); }
            }
            if (ImGui::CollapsingHeader("Lights", ImGuiTreeNodeFlags_DefaultOpen)) {
                for (auto& m : m_lights) { m.imgui(); }
            }
            m_raytracer.imgui();
            if (ImGui::CollapsingHeader("NeRF", ImGuiTreeNodeFlags_DefaultOpen)) {
                ImGui::Checkbox("View Virtual Object shadows on NeRF", &m_view_syn_shadow);
                auto& view = m_testbed->m_views.front();
                int max_scale = m_display.get_window_res().x / max(1, view.render_buffer->out_resolution().x);
                if (ImGui::SliderInt("Relative scale of Virtual Scene", &m_relative_vo_scale, 1, max_scale)) {
                    resize();
                    m_raytracer.reset_accumulation();
                }
            }
            if (ImGui::CollapsingHeader("Transform", ImGuiTreeNodeFlags_DefaultOpen)) {
                if (ImGui::Combo("Mode", (int*)&m_transform_type, world_object_names, sizeof(world_object_names) / sizeof(const char*))) {
                    m_transform_idx = 0;
                }
                int max_count = 0;
                switch (m_transform_type) {
                case WorldObjectType::LightObj:
                    max_count = m_lights.size() - 1;
                    break;
                case WorldObjectType::VirtualObjectObj:
                    max_count = m_objects.size() - 1;
                    break;
                default:
                    break;
                }
                ImGui::SliderInt("Obj idx", (int*)&m_transform_idx, 0, max_count);
            }
        }
        if (ImGui::CollapsingHeader("Shader", ImGuiTreeNodeFlags_DefaultOpen)) {
            if (ImGui::SliderFloat("NeRF Shadow Darkness", &m_nerf_shadow_intensity, MIN_DEPTH(), 10.0f)) { 
                m_is_dirty = true;
            }
            if (ImGui::SliderFloat("AO Shadow Darkness", &m_nerf_ao_intensity, MIN_DEPTH(), 10.0f)) { 
                m_is_dirty = true;
            }
            if (ImGui::SliderFloat("VO Shadow Darkness", &m_raytracer.m_syn_shadow_factor, MIN_DEPTH(), 10.0f)) { 
                m_is_dirty = true;
            }
            if (ImGui::SliderFloat("Threshold for NeRF shadow ray", &m_nerf_self_shadow_threshold, MIN_DEPTH(), 1.0f)) { 
                m_is_dirty = true;
            }
            ImGui::SliderInt("Position blur kernel size", &m_testbed->sng_position_kernel_size, 0, 14);
            ImGui::SliderFloat("Position blur kernel threshold", &m_testbed->sng_position_kernel_threshold, 0.000, 8.0f);
            ImGui::SliderFloat("Variance Threshold (Shadows)", &m_testbed->sng_shadow_depth_variance, 0.000, 1.000f);
        }
        if (ImGui::CollapsingHeader("Camera", ImGuiTreeNodeFlags_DefaultOpen)) {
            m_camera_path.imgui(*m_testbed);
        }
        if (ImGui::CollapsingHeader("Animation", ImGuiTreeNodeFlags_DefaultOpen)) {
            ImGui::SliderFloat("speed", &m_anim_speed, 0.01, 4.0);
        }
        ImGui::End();
    }

    if (m_transform_type == WorldObjectType::LightObj && !m_lights.empty()) { 
        m_pos_to_translate = &(m_lights[m_transform_idx].pos);
        m_rot_to_rotate = nullptr;
        m_scale_to_scale = nullptr;
        m_obj_dirty_marker = &(m_lights[m_transform_idx].is_dirty);
    } else if (m_transform_type == WorldObjectType::VirtualObjectObj && !m_objects.empty()) {
        m_pos_to_translate = &(m_objects[m_transform_idx].get_translate_mut());
        m_rot_to_rotate = &(m_objects[m_transform_idx].get_rotate_mut());
        m_scale_to_scale = &(m_objects[m_transform_idx].get_scale_mut());
        m_obj_dirty_marker = &(m_objects[m_transform_idx].is_dirty);
    } else {
        m_pos_to_translate = nullptr;
        m_rot_to_rotate = nullptr;
        m_scale_to_scale = nullptr;
        m_obj_dirty_marker = nullptr;
    }
}

bool Engine::frame() {
    if (!m_display.is_alive()) return false;
    Testbed::CudaDevice& device = m_testbed->primary_device();
    device.device_guard();
    if (!m_display.begin_frame()) return false;
    imgui();
    ivec2 curr_window_res = m_display.get_window_res();
    if (curr_window_res != m_next_frame_resolution || !m_testbed->m_render_skip_due_to_lack_of_camera_movement_counter || 
            m_last_res_factor != m_testbed->m_fixed_res_factor) {
        resize();
    }
    sync(m_stream_id);
    m_testbed->handle_user_input();
    m_camera_path.update(*m_testbed);
    if (m_testbed && m_testbed->m_syn_camera_reset) {
        m_raytracer.reset_accumulation();
        m_testbed->m_syn_camera_reset = false;
    }
    ImDrawList* list = ImGui::GetBackgroundDrawList();
    m_testbed->draw_visualizations(list, m_testbed->m_smoothed_camera, m_pos_to_translate, m_rot_to_rotate, m_scale_to_scale, m_obj_dirty_marker);
    update_world_objects();
    m_testbed->apply_camera_smoothing(__timer.get_ave_time("nerf"));

    auto& view = nerf_render_buffer_view();

    auto nerf_view = view.render_buffer->view();
    __timer.reset();

    vec2 focal_length = m_testbed->calc_focal_length(
        m_raytracer.resolution(),
        m_testbed->m_relative_focal_length, 
        m_testbed->m_fov_axis, 
        m_testbed->m_zoom);
    vec2 screen_center = m_testbed->render_screen_center(view.screen_center);
    m_raytracer.render(
        m_objects,
        d_materials,
        d_lights,
        view, 
        screen_center,
        nerf_view.spp,
        focal_length,
        m_depth_offset,
        m_testbed->m_snap_to_pixel_centers,
        m_testbed->m_nerf.density_grid_bitfield.data(),
        d_world
    );

    if (m_show_nerf) {
        m_testbed->render( m_stream_id, view, m_raytracer.get_tmp_frame_buffer(), m_raytracer.get_tmp_depth_buffer(),
            m_relative_vo_scale, d_world, d_lights, d_materials, d_nerf_rand_state, d_nerf_normals, 
            d_nerf_positions, m_view_syn_shadow, m_nerf_shadow_intensity, m_nerf_ao_intensity, m_nerf_self_shadow_threshold, m_raytracer.m_shadow_iters );
        sync(m_stream_id);
    }
    m_raytracer.overlay(view.render_buffer->view(), m_relative_vo_scale, EColorSpace::SRGB, m_testbed->m_tonemap_curve, m_testbed->m_exposure, m_show_nerf);

    sync(m_stream_id);
    view.prev_camera = view.camera0;
    view.prev_foveation = view.foveation;

    ivec2 nerf_res = nerf_view.resolution;
    auto n_elements = product(nerf_res);
    m_render_ms = (float)__timer.log_time("nerf");
    m_testbed->m_frame_ms.set(m_render_ms);
    m_testbed->m_rgba_render_textures.front()->load_gpu(nerf_view.frame_buffer, nerf_view.resolution, m_nerf_rgba_cpu);
    m_testbed->m_depth_render_textures.front()->load_gpu(nerf_view.depth_buffer, nerf_view.resolution, 1, m_nerf_depth_cpu);

    m_raytracer.load(m_syn_rgba_cpu, m_syn_depth_cpu);
    GLuint nerf_rgba_texid = m_testbed->m_rgba_render_textures.front()->texture();
    GLuint nerf_depth_texid = m_testbed->m_depth_render_textures.front()->texture();
    GLuint syn_rgba_texid = m_raytracer.m_rgba_texture->texture();
    GLuint syn_depth_texid = m_raytracer.m_depth_texture->texture();
    auto rt_res = m_raytracer.resolution();
    m_display.present(m_default_clear_color, nerf_rgba_texid, nerf_depth_texid, syn_rgba_texid, syn_depth_texid, view.render_buffer->out_resolution(), rt_res, view.foveation, m_raytracer.filter_type());
    if (has_output()) {
        auto fp = m_output_dest.str();
        return m_display.save_image(fp.c_str());
    } else if (m_end_on_loop) {
        return m_display.advance_image_count();
    }
    return m_display.is_alive();
}

}