const std = @import("std");
const wgpu = @import("wgpu");
const glfw = @import("glfw");

const window_width = 640;
const window_height = 480;

// What the headless version rendered into. A surface only accepts formats the
// adapter and compositor agree on, so this is a preference rather than a given.
const preferred_format = wgpu.TextureFormat.bgra8_unorm_srgb;

const vertices = [_][2]f32{
    .{ -0.5, -0.5 },
    .{ 0.5, -0.5 },
    .{ 0.0, 0.5 },
};

// Based off of headless triangle example from https://github.com/eliemichel/LearnWebGPU-Code/tree/step030-headless

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    // wgpu owns the swap chain, so GLFW must not make an OpenGL context for us.
    glfw.windowHint(.client_api, .no_api);

    const window = try glfw.Window.create(window_width, window_height, "glowworm", null, null);
    defer window.destroy();

    const instance = wgpu.Instance.create(null).?;
    defer instance.release();

    const surface = try createWaylandSurface(instance, window);
    defer surface.release();

    const adapter_request = instance.requestAdapterSync(&wgpu.RequestAdapterOptions{
        .compatible_surface = surface,
    }, 0);

    if (adapter_request.status != .success) return error.NoAdapter;
    const adapter = adapter_request.adapter orelse return error.NoAdapter;
    defer adapter.release();

    const device_request = adapter.requestDeviceSync(instance, &wgpu.DeviceDescriptor{
        .required_limits = null,
    }, 0);

    if (adapter_request.status != .success) return error.NoAdapter;

    const device = device_request.device orelse return error.NoAdapter;
    defer device.release();

    const queue = device.getQueue().?;
    defer queue.release();

    var capabilities: wgpu.SurfaceCapabilities = undefined;
    if (surface.getCapabilities(adapter, &capabilities) != .success) {
        return error.NoSurfaceCapabilities;
    }
    defer capabilities.freeMembers();

    const swap_chain_format = pickFormat(capabilities);

    const shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./shader.wgsl"),
    })).?;
    defer shader_module.release();

    const color_targets = &[_]wgpu.ColorTargetState{
        wgpu.ColorTargetState{
            .format = swap_chain_format,
            .blend = &wgpu.BlendState{
                .color = wgpu.BlendComponent{
                    .operation = .add,
                    .src_factor = .src_alpha,
                    .dst_factor = .one_minus_src_alpha,
                },
                .alpha = wgpu.BlendComponent{
                    .operation = .add,
                    .src_factor = .zero,
                    .dst_factor = .one,
                },
            },
        },
    };

    const vertex_buffer = device.createBuffer(&wgpu.BufferDescriptor{
        .label = wgpu.StringView.fromSlice("Vertex buffer"),
        .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
        .size = @sizeOf(@TypeOf(vertices)),
    }).?;
    defer vertex_buffer.release();
    queue.writeBuffer(vertex_buffer, 0, &vertices, @sizeOf(@TypeOf(vertices)));

    const vertex_attributes = &[_]wgpu.VertexAttribute{
        wgpu.VertexAttribute{
            .format = .float32x2,
            .offset = 0,
            .shader_location = 0,
        },
    };
    const vertex_buffer_layouts = &[_]wgpu.VertexBufferLayout{
        wgpu.VertexBufferLayout{
            .array_stride = @sizeOf([2]f32),
            .attribute_count = vertex_attributes.len,
            .attributes = vertex_attributes.ptr,
        },
    };

    const pipeline = device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
        .vertex = wgpu.VertexState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("vs_main"),
            .buffer_count = vertex_buffer_layouts.len,
            .buffers = vertex_buffer_layouts.ptr,
        },
        .primitive = wgpu.PrimitiveState{},
        .fragment = &wgpu.FragmentState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = color_targets.len,
            .targets = color_targets.ptr,
        },
        .multisample = wgpu.MultisampleState{},
    }).?;
    defer pipeline.release();

    var config = wgpu.SurfaceConfiguration{
        .device = device,
        .format = swap_chain_format,
        .width = window_width,
        .height = window_height,
        .alpha_mode = pickAlphaMode(capabilities),
        // The only present mode guaranteed to be supported, and it vsyncs.
        .present_mode = .fifo,
    };
    surface.configure(&config);
    defer surface.unconfigure();

    while (!window.shouldClose()) {
        glfw.pollEvents();

        // On Wayland the compositor decides how big we are, so the surface has to
        // follow the framebuffer rather than the other way around.
        const framebuffer_size = window.getFramebufferSize();
        const width: u32 = @intCast(@max(framebuffer_size[0], 1));
        const height: u32 = @intCast(@max(framebuffer_size[1], 1));
        if (width != config.width or height != config.height) {
            config.width = width;
            config.height = height;
            surface.configure(&config);
        }

        var surface_texture: wgpu.SurfaceTexture = undefined;
        surface.getCurrentTexture(&surface_texture);
        switch (surface_texture.status) {
            .success_optimal, .success_suboptimal => {},
            // Usually means we're mid-resize and the swap chain we were handed is
            // already stale. Rebuild it and take the next frame instead.
            .timeout, .outdated, .lost => {
                if (surface_texture.texture) |stale| stale.release();
                surface.configure(&config);
                continue;
            },
            else => return error.NoSurfaceTexture,
        }
        const frame_texture = surface_texture.texture.?;
        defer frame_texture.release();

        const next_texture = frame_texture.createView(&wgpu.TextureViewDescriptor{
            .label = wgpu.StringView.fromSlice("Frame texture view"),
            .mip_level_count = 1,
            .array_layer_count = 1,
        }).?;
        defer next_texture.release();

        const encoder = device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView.fromSlice("Command Encoder"),
        }).?;
        defer encoder.release();

        const color_attachments = &[_]wgpu.ColorAttachment{wgpu.ColorAttachment{
            .view = next_texture,
            .clear_value = wgpu.Color{},
        }};
        const render_pass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = color_attachments.ptr,
        }).?;

        render_pass.setPipeline(pipeline);
        render_pass.setVertexBuffer(0, vertex_buffer, 0, vertex_buffer.getSize());
        render_pass.draw(vertices.len, 1, 0, 0);
        render_pass.end();

        // The render pass has to be released after .end() or otherwise we'll crash on queue.submit
        // https://github.com/gfx-rs/wgpu-native/issues/412#issuecomment-2311719154
        render_pass.release();

        const command_buffer = encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView.fromSlice("Command Buffer"),
        }).?;
        defer command_buffer.release();

        queue.submit(&[_]*const wgpu.CommandBuffer{command_buffer});
        _ = surface.present();
    }
}

fn createWaylandSurface(instance: *wgpu.Instance, window: *glfw.Window) !*wgpu.Surface {
    if (glfw.getPlatform() != .wayland) return error.UnsupportedPlatform;

    const source = wgpu.SurfaceSourceWaylandSurface{
        .display = glfw.getWaylandDisplay() orelse return error.NoWaylandDisplay,
        .surface = glfw.getWaylandWindow(window) orelse return error.NoWaylandWindow,
    };
    return instance.createSurface(&wgpu.SurfaceDescriptor{
        .next_in_chain = @ptrCast(&source),
        .label = wgpu.StringView.fromSlice("Window surface"),
    }) orelse error.NoSurface;
}

fn pickFormat(capabilities: wgpu.SurfaceCapabilities) wgpu.TextureFormat {
    const formats = capabilities.formats[0..capabilities.format_count];
    for (formats) |format| {
        if (format == preferred_format) return format;
    }
    // The list is in order of preference, so the first entry is the next best thing.
    return if (formats.len > 0) formats[0] else preferred_format;
}

fn pickAlphaMode(capabilities: wgpu.SurfaceCapabilities) wgpu.CompositeAlphaMode {
    const alpha_modes = capabilities.alpha_modes[0..capabilities.alpha_mode_count];
    for (alpha_modes) |alpha_mode| {
        if (alpha_mode == .@"opaque") return alpha_mode;
    }
    return .auto;
}
