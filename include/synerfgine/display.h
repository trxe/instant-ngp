#pragma once

#include <neural-graphics-primitives/render_buffer.h>

#include <tiny-cuda-nn/common.h>
#include <tiny-cuda-nn/common_host.h>

#ifdef NGP_GUI
#	include <imgui/backends/imgui_impl_glfw.h>
#	include <imgui/backends/imgui_impl_opengl3.h>
#	include <imgui/imgui.h>
#	include <imguizmo/ImGuizmo.h>
#	ifdef _WIN32
#		include <GL/gl3w.h>
#	else
#		include <GL/glew.h>
#	endif
#	include <GLFW/glfw3.h>
#	include <GLFW/glfw3native.h>
#	include <cuda_gl_interop.h>

#endif

// Windows.h is evil
#undef min
#undef max
#undef near
#undef far

namespace sng {

using ngp::CudaRenderBuffer;
using ngp::GLTexture;

class Renderer {
public:
	GLFWwindow* create_glfw_window(const ivec2& m_window_res);
	bool begin_frame();
	bool present(const ivec2& m_n_views, std::shared_ptr<ngp::GLTexture> rgba, std::shared_ptr<ngp::GLTexture> depth);
	void end_frame();
	void blit_texture(const ngp::Foveation& foveation, GLint rgba_texture, GLint rgba_filter_mode, 
		GLint depth_texture, GLint framebuffer, const ivec2& offset, const ivec2& resolution);
private:
	GLFWwindow* m_glfw_window = nullptr;
	ivec2 m_window_res = ivec2(0);

	// The VAO will be empty, but we need a valid one for attribute-less rendering
	GLuint m_blit_vao = 0;
	GLuint m_blit_program = 0;

	void init_opengl_shaders();
};

class Ui {
public:
	void init_imgui(GLFWwindow* m_glfw_window);
    void imgui();
	bool begin_frame();
	void end_frame();
private:
	GLFWwindow* m_glfw_window = nullptr;
};

class Display {
public:
    void init_window(int resw, int resh, bool hidden);
	void destroy();
	bool begin_frame();
	bool present(); 
	void end_frame();
	Display() {}
	~Display() { destroy(); }

private:
	void init_buffers();

	ivec2 m_window_res = ivec2(0);
	Renderer renderer;
	Ui ui;

	// Buffers
	std::shared_ptr<GLTexture> m_rgba_render_textures;
	std::shared_ptr<GLTexture> m_depth_render_textures;
	std::shared_ptr<CudaRenderBuffer> m_render_buffer;
	ivec2 m_view_res = ivec2(0);
	static bool m_is_init;

#ifdef NGP_GUI
	GLFWwindow* m_glfw_window = nullptr;
#endif
};

}
