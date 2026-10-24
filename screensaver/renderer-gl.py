#!/usr/bin/env python3
"""Hardware-accelerated Hive CRT screensaver for GTK4/Wayland."""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import math
import os
import random
import signal
import sys
import time

import cairo
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402


# A resolution-independent 16:9 design coordinate system. Every monitor gets
# its own fullscreen GLArea and these coordinates are scaled to its live size.
W, H = 1920.0, 1080.0
FONT = "JetBrainsMono Nerd Font"

COLORS = {
    "white": (0.847, 0.867, 0.882),
    "bright": (0.969, 0.976, 0.980),
    "steel": (0.408, 0.439, 0.471),
    "dim": (0.204, 0.227, 0.251),
    "red": (0.710, 0.071, 0.106),
    "alarm": (1.000, 0.200, 0.255),
    "green": (0.435, 0.608, 0.475),
    "cyan": (0.427, 0.616, 0.639),
}


GL = ctypes.CDLL(ctypes.util.find_library("GL"))
GL_VERTEX_SHADER = 0x8B31
GL_FRAGMENT_SHADER = 0x8B30
GL_COMPILE_STATUS = 0x8B81
GL_LINK_STATUS = 0x8B82
GL_INFO_LOG_LENGTH = 0x8B84
GL_TEXTURE_2D = 0x0DE1
GL_TEXTURE0 = 0x84C0
GL_TEXTURE1 = 0x84C1
GL_TEXTURE_MIN_FILTER = 0x2801
GL_TEXTURE_MAG_FILTER = 0x2800
GL_TEXTURE_WRAP_S = 0x2802
GL_TEXTURE_WRAP_T = 0x2803
GL_LINEAR = 0x2601
GL_CLAMP_TO_EDGE = 0x812F
GL_RGBA8 = 0x8058
GL_BGRA = 0x80E1
GL_UNSIGNED_BYTE = 0x1401
GL_COLOR_BUFFER_BIT = 0x00004000
GL_TRIANGLES = 0x0004
GL_UNPACK_ALIGNMENT = 0x0CF5
GL_VENDOR = 0x1F00
GL_RENDERER = 0x1F01
GL_VERSION = 0x1F02


def gl_function(name: str, restype, *argtypes):
    function = getattr(GL, name)
    function.restype = restype
    function.argtypes = argtypes
    return function


glCreateShader = gl_function("glCreateShader", ctypes.c_uint, ctypes.c_uint)
glShaderSource = gl_function("glShaderSource", None, ctypes.c_uint, ctypes.c_int,
                             ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_int))
glCompileShader = gl_function("glCompileShader", None, ctypes.c_uint)
glGetShaderiv = gl_function("glGetShaderiv", None, ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(ctypes.c_int))
glGetShaderInfoLog = gl_function("glGetShaderInfoLog", None, ctypes.c_uint, ctypes.c_int,
                                ctypes.POINTER(ctypes.c_int), ctypes.c_char_p)
glCreateProgram = gl_function("glCreateProgram", ctypes.c_uint)
glAttachShader = gl_function("glAttachShader", None, ctypes.c_uint, ctypes.c_uint)
glLinkProgram = gl_function("glLinkProgram", None, ctypes.c_uint)
glGetProgramiv = gl_function("glGetProgramiv", None, ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(ctypes.c_int))
glGetProgramInfoLog = gl_function("glGetProgramInfoLog", None, ctypes.c_uint, ctypes.c_int,
                                 ctypes.POINTER(ctypes.c_int), ctypes.c_char_p)
glDeleteShader = gl_function("glDeleteShader", None, ctypes.c_uint)
glUseProgram = gl_function("glUseProgram", None, ctypes.c_uint)
glGenVertexArrays = gl_function("glGenVertexArrays", None, ctypes.c_int, ctypes.POINTER(ctypes.c_uint))
glBindVertexArray = gl_function("glBindVertexArray", None, ctypes.c_uint)
glGenTextures = gl_function("glGenTextures", None, ctypes.c_int, ctypes.POINTER(ctypes.c_uint))
glBindTexture = gl_function("glBindTexture", None, ctypes.c_uint, ctypes.c_uint)
glTexParameteri = gl_function("glTexParameteri", None, ctypes.c_uint, ctypes.c_uint, ctypes.c_int)
glPixelStorei = gl_function("glPixelStorei", None, ctypes.c_uint, ctypes.c_int)
glTexImage2D = gl_function("glTexImage2D", None, ctypes.c_uint, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                          ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p)
glActiveTexture = gl_function("glActiveTexture", None, ctypes.c_uint)
glGetUniformLocation = gl_function("glGetUniformLocation", ctypes.c_int, ctypes.c_uint, ctypes.c_char_p)
glUniform1i = gl_function("glUniform1i", None, ctypes.c_int, ctypes.c_int)
glUniform1f = gl_function("glUniform1f", None, ctypes.c_int, ctypes.c_float)
glUniform2f = gl_function("glUniform2f", None, ctypes.c_int, ctypes.c_float, ctypes.c_float)
glViewport = gl_function("glViewport", None, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int)
glClearColor = gl_function("glClearColor", None, ctypes.c_float, ctypes.c_float, ctypes.c_float, ctypes.c_float)
glClear = gl_function("glClear", None, ctypes.c_uint)
glDrawArrays = gl_function("glDrawArrays", None, ctypes.c_uint, ctypes.c_int, ctypes.c_int)
glGetString = gl_function("glGetString", ctypes.c_char_p, ctypes.c_uint)


VERTEX_SHADER = """#version 330 core
out vec2 v_uv;
void main() {
    const vec2 vertices[6] = vec2[6](
        vec2(-1.0, -1.0), vec2( 1.0, -1.0), vec2( 1.0,  1.0),
        vec2(-1.0, -1.0), vec2( 1.0,  1.0), vec2(-1.0,  1.0));
    vec2 position = vertices[gl_VertexID];
    v_uv = position * 0.5 + 0.5;
    gl_Position = vec4(position, 0.0, 1.0);
}
"""


FRAGMENT_SHADER = """#version 330 core
in vec2 v_uv;
out vec4 out_color;
uniform sampler2D u_scene;
uniform sampler2D u_clock;
uniform vec2 u_resolution;
uniform float u_time;
uniform float u_fade;
uniform float u_interference;
uniform int u_scene_id;

const vec3 RED = vec3(0.710, 0.071, 0.106);
const vec3 ALARM = vec3(1.000, 0.200, 0.255);
const vec3 GREEN = vec3(0.435, 0.608, 0.475);
const vec3 CYAN = vec3(0.427, 0.616, 0.639);
const vec3 WHITE = vec3(0.847, 0.867, 0.882);

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float circle(vec2 p, vec2 center, float radius) {
    return 1.0 - smoothstep(radius - 1.2, radius + 1.2, length(p - center));
}

float segment(vec2 p, vec2 a, vec2 b, float width) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return 1.0 - smoothstep(width, width + 1.0, length(pa - ba * h));
}

vec3 add_glow(vec3 color, vec2 p, vec2 center, vec3 tint, float radius, float strength) {
    float glow = exp(-length(p - center) / radius) * strength;
    return color + tint * glow;
}

vec4 clock_at(vec2 p, vec4 rect) {
    vec2 local = (p - rect.xy) / rect.zw;
    if (min(local.x, local.y) < 0.0 || max(local.x, local.y) > 1.0) return vec4(0.0);
    return texture(u_clock, vec2(local.x, 1.0 - local.y));
}

vec4 time_at(vec2 p, vec4 rect) {
    vec2 local = (p - rect.xy) / rect.zw;
    if (min(local.x, local.y) < 0.0 || max(local.x, local.y) > 1.0) return vec4(0.0);
    return texture(u_clock, vec2(0.60 + local.x * 0.40, 1.0 - local.y));
}

void main() {
    vec2 display_uv = vec2(v_uv.x, 1.0 - v_uv.y);
    float screen_aspect = u_resolution.x / max(u_resolution.y, 1.0);
    const float design_aspect = 16.0 / 9.0;
    vec2 design_uv = display_uv;
    if (screen_aspect > design_aspect) {
        float width = design_aspect / screen_aspect;
        float left = (1.0 - width) * 0.5;
        if (display_uv.x < left || display_uv.x > left + width) {
            out_color = vec4(0.001, 0.002, 0.002, 1.0);
            return;
        }
        design_uv.x = (display_uv.x - left) / width;
    } else if (screen_aspect < design_aspect) {
        float height = screen_aspect / design_aspect;
        float top = (1.0 - height) * 0.5;
        if (display_uv.y < top || display_uv.y > top + height) {
            out_color = vec4(0.001, 0.002, 0.002, 1.0);
            return;
        }
        design_uv.y = (display_uv.y - top) / height;
    }
    vec2 centered = design_uv * 2.0 - 1.0;
    float radial = dot(centered, centered);
    vec2 curved = centered * (1.0 + radial * 0.006);
    vec2 scene_uv = curved * 0.5 + 0.5;
    if (min(scene_uv.x, scene_uv.y) < 0.0 || max(scene_uv.x, scene_uv.y) > 1.0) {
        out_color = vec4(0.001, 0.002, 0.002, 1.0);
        return;
    }

    float edge = smoothstep(0.48, 1.18, length(centered));
    float split = 0.00045 * edge;
    vec3 color;
    color.r = texture(u_scene, scene_uv + vec2(split, 0.0)).r;
    color.g = texture(u_scene, scene_uv).g;
    color.b = texture(u_scene, scene_uv - vec2(split, 0.0)).b;
    vec2 p = scene_uv * vec2(1920.0, 1080.0);

    float pulse = 0.66 + 0.16 * sin(u_time * 2.24399475);
    if (u_scene_id == 0) {
        const vec2 nodes[6] = vec2[6](vec2(296,318), vec2(596,318), vec2(896,318),
                                      vec2(396,558), vec2(696,558), vec2(996,558));
        for (int i = 0; i < 6; i++) {
            vec3 tint = (i == 4) ? RED : GREEN;
            color += tint * circle(p, nodes[i], 3.5) * pulse;
            if (i == 4) color = add_glow(color, p, nodes[i], RED, 13.0, 0.15 * pulse);
        }
        const vec3 status_colors[5] = vec3[5](GREEN, GREEN, RED, CYAN, RED);
        for (int i = 0; i < 5; i++) {
            vec2 center = vec2(1120.0, 267.0 + float(i) * 57.0);
            color += status_colors[i] * circle(p, center, 4.0) * ((i == 0 || i == 4) ? pulse : 0.82);
        }
    } else if (u_scene_id == 1) {
        float lp = 0.55 + 0.11 * sin(u_time * 2.32710567);
        float border = max(segment(p, vec2(126,220), vec2(1794,220), 1.5),
                       max(segment(p, vec2(1794,220), vec2(1794,850), 1.5),
                       max(segment(p, vec2(1794,850), vec2(126,850), 1.5),
                           segment(p, vec2(126,850), vec2(126,220), 1.5))));
        color += RED * border * lp;
        color += RED * segment(p, vec2(500,520), vec2(1420,520), 1.5) * lp;
        const vec2 lamps[4] = vec2[4](vec2(158,251), vec2(1762,251), vec2(158,819), vec2(1762,819));
        for (int i = 0; i < 4; i++) color = add_glow(color, p, lamps[i], RED, 18.0, 0.16 * lp);
    } else if (u_scene_id == 2) {
        float index = floor((p.y - 320.0) / 12.0 + 0.5);
        if (index >= 0.0 && index < 42.0) {
            float y = 320.0 + index * 12.0;
            float x1 = 430.0 + sin(index * 0.44 + u_time * 0.42) * 125.0;
            float x2 = 430.0 + sin(index * 0.44 + u_time * 0.42 + 3.14159265) * 125.0;
            vec3 left = (mod(index, 6.0) < 0.5) ? RED : WHITE;
            vec3 right = (mod(index, 6.0) < 0.5) ? CYAN : vec3(0.408,0.439,0.471);
            color += left * circle(p, vec2(x1,y), 2.7) * 0.72;
            color += right * circle(p, vec2(x2,y), 2.4) * 0.60;
            if (mod(index, 3.0) < 0.5) color += vec3(0.408,0.439,0.471) * segment(p, vec2(x1,y), vec2(x2,y), 0.55) * 0.22;
            if (mod(index, 12.0) < 0.5) color = add_glow(color, p, vec2(x1,y), RED, 11.0, 0.13);
        }
    } else if (u_scene_id == 3) {
        float rq = 0.11 + 0.035 * sin(u_time * 1.14239733);
        color = add_glow(color, p, vec2(960,530), RED, 150.0, rq * 2.0);
        color += RED * segment(p, vec2(960,382), vec2(960,655), 0.75) * 0.30;
        color += RED * circle(p, vec2(960,520), 7.0) * 0.82;
        color = add_glow(color, p, vec2(960,520), RED, 28.0, 0.18);
    } else if (u_scene_id == 4) {
        const vec2 origins[4] = vec2[4](vec2(100,205), vec2(1040,205), vec2(100,570), vec2(1040,570));
        for (int i = 0; i < 4; i++) {
            float sy = origins[i].y + 58.0 + mod(u_time * 12.0 + float(i) * 47.0, 228.0);
            float within = step(origins[i].x + 12.0, p.x) * step(p.x, origins[i].x + 768.0);
            color += CYAN * (1.0 - smoothstep(0.0, 1.2, abs(p.y - sy))) * within * 0.055;
        }
    }

    vec4 clock_pixel = clock_at(p, vec4(1630,1017,212,27));
    if (u_scene_id == 4) {
        clock_pixel = max(clock_pixel, time_at(p, vec4(290,489,100,20)));
        clock_pixel = max(clock_pixel, time_at(p, vec4(1230,489,100,20)));
        clock_pixel = max(clock_pixel, time_at(p, vec4(290,854,100,20)));
        clock_pixel = max(clock_pixel, time_at(p, vec4(1230,854,100,20)));
    }
    color = clock_pixel.rgb + color * (1.0 - clock_pixel.a);

    float scanline = 0.985 + 0.015 * sin(p.y * 3.14159265);
    color *= scanline;
    float sweep_y = 40.0 + mod(u_time * 22.0, 1000.0);
    color += vec3(0.25,0.45,0.38) * exp(-pow((p.y - sweep_y) / 22.0, 2.0)) * 0.026;
    float grain = hash21(floor(p * 0.72) + floor(u_time * 12.0) * 17.0) - 0.5;
    color += vec3(grain * 0.008);
    if (u_interference > 0.5) {
        float iy = 160.0 + mod(floor(u_time * 997.0), 720.0);
        color += vec3(0.75,0.88,0.82) * (1.0 - smoothstep(0.0, 2.0, abs(p.y - iy))) * 0.10;
    }
    float vignette = smoothstep(0.42, 1.25, length(centered));
    color *= 1.0 - vignette * 0.58;
    color *= 0.988 + 0.006 * sin(u_time * 0.55);
    color = mix(color, vec3(0.001,0.002,0.002), u_fade * 0.96);
    out_color = vec4(max(color, vec3(0.0)), 1.0);
}
"""


def source(ctx: cairo.Context, name: str, alpha: float = 1.0) -> None:
    r, g, b = COLORS[name]
    ctx.set_source_rgba(r, g, b, alpha)


def rounded_rect(ctx: cairo.Context, x: float, y: float, w: float, h: float, radius: float) -> None:
    radius = min(radius, w / 2, h / 2)
    ctx.new_sub_path()
    ctx.arc(x + w - radius, y + radius, radius, -math.pi / 2, 0)
    ctx.arc(x + w - radius, y + h - radius, radius, 0, math.pi / 2)
    ctx.arc(x + radius, y + h - radius, radius, math.pi / 2, math.pi)
    ctx.arc(x + radius, y + radius, radius, math.pi, math.pi * 1.5)
    ctx.close_path()


class Model:
    scenes = ("security", "lockdown", "diagnostic", "red_queen", "cctv")

    def __init__(self, scene_seconds: float) -> None:
        now = time.monotonic()
        self.scene_seconds = max(12.0, scene_seconds)
        self.scene_index = random.randrange(len(self.scenes))
        self.scene_started = now
        self.next_scene = now + self.scene_seconds
        self.transition_started: float | None = None
        self.transition_switched = False
        self.clock = time.strftime("%Y-%m-%d  %H:%M:%S")
        self.last_second = -1
        self.next_data = now
        self.next_status = now
        self.next_camera = now + 7.0
        self.next_interference = now + random.uniform(18.0, 38.0)
        self.interference_until = 0.0
        self.camera_loss: int | None = None
        self.camera_loss_until = 0.0
        self.status_index = 0
        self.sample_index = random.randrange(100, 999)
        self.integrity = 98.7
        self.containment = 99.4
        self.network_load = [0.22, 0.31, 0.27, 0.42, 0.36, 0.52, 0.44, 0.61, 0.48, 0.56]
        self.camera_integrity = [99.7, 99.9, 98.6, 100.0]

    @property
    def scene(self) -> str:
        return self.scenes[self.scene_index]

    def update_data(self, now: float) -> tuple[bool, bool]:
        static_changed = False
        clock_changed = False
        second = int(now)
        if second != self.last_second:
            self.last_second = second
            self.clock = time.strftime("%Y-%m-%d  %H:%M:%S")
            clock_changed = True
        if now >= self.next_data:
            self.next_data = now + random.uniform(2.8, 4.6)
            self.integrity = max(97.8, min(99.8, self.integrity + random.uniform(-0.18, 0.18)))
            self.containment = max(98.7, min(100.0, self.containment + random.uniform(-0.12, 0.12)))
            self.network_load = self.network_load[1:] + [max(0.12, min(0.78, self.network_load[-1] + random.uniform(-0.18, 0.18)))]
            static_changed = True
        if now >= self.next_status:
            self.next_status = now + random.uniform(8.0, 13.0)
            self.status_index = (self.status_index + 1) % 4
            self.sample_index = (self.sample_index + random.randrange(1, 7)) % 1000
            static_changed = True
        if now >= self.next_camera:
            self.next_camera = now + random.uniform(12.0, 20.0)
            self.camera_integrity = [max(97.8, min(100.0, v + random.uniform(-0.25, 0.25))) for v in self.camera_integrity]
            if random.random() < 0.22:
                self.camera_loss = random.randrange(4)
                self.camera_loss_until = now + random.uniform(1.2, 2.2)
            static_changed = True
        if now >= self.camera_loss_until:
            if self.camera_loss is not None:
                static_changed = True
            self.camera_loss = None
        return static_changed, clock_changed

    def update_animation(self, now: float) -> bool:
        scene_changed = False
        if now >= self.next_interference:
            self.interference_until = now + 0.22
            self.next_interference = now + random.uniform(24.0, 52.0)
        if self.transition_started is None and now >= self.next_scene:
            self.transition_started = now
            self.transition_switched = False
        if self.transition_started is not None:
            progress = (now - self.transition_started) / 0.8
            if progress >= 0.5 and not self.transition_switched:
                self.scene_index = (self.scene_index + 1) % len(self.scenes)
                self.scene_started = now
                self.transition_switched = True
                scene_changed = True
            if progress >= 1.0:
                self.transition_started = None
                self.transition_switched = False
                self.next_scene = now + self.scene_seconds
        return scene_changed

    def fade_alpha(self, now: float) -> float:
        if self.transition_started is None:
            return 0.0
        progress = max(0.0, min(1.0, (now - self.transition_started) / 0.8))
        return 1.0 - abs(2.0 * progress - 1.0)


class HiveCanvas(Gtk.GLArea):
    def __init__(self, model: Model, report_gl: bool = False) -> None:
        super().__init__()
        self.model = model
        self.report_gl = report_gl
        self.static_dirty = True
        self.clock_dirty = True
        self.program = 0
        self.vao = ctypes.c_uint(0)
        self.textures = (ctypes.c_uint * 2)()
        self.uniforms: dict[str, int] = {}
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.set_required_version(3, 3)
        self.set_auto_render(False)
        self.set_has_depth_buffer(False)
        self.set_has_stencil_buffer(False)
        self.connect("realize", self.on_realize)
        self.connect("render", self.on_render)

    def font(self, ctx: cairo.Context, size: float, bold: bool = False) -> None:
        ctx.select_font_face(FONT, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
        ctx.set_font_size(size)

    def text(self, ctx: cairo.Context, x: float, y: float, value: str, color: str = "white", size: float = 18,
             alpha: float = 1.0, glow: float = 0.0, bold: bool = False, spacing: float = 0.0) -> None:
        self.font(ctx, size, bold)
        if spacing <= 0:
            if glow > 0:
                for dx, dy in ((-2, 0), (2, 0), (0, -2), (0, 2), (-1, -1), (1, 1)):
                    source(ctx, color, glow * 0.12)
                    ctx.move_to(x + dx, y + dy)
                    ctx.show_text(value)
            source(ctx, color, alpha)
            ctx.move_to(x, y)
            ctx.show_text(value)
            return
        cursor = x
        for char in value:
            source(ctx, color, alpha)
            ctx.move_to(cursor, y)
            ctx.show_text(char)
            cursor += ctx.text_extents(char).x_advance + spacing

    def centered(self, ctx: cairo.Context, y: float, value: str, color: str = "white", size: float = 18,
                 alpha: float = 1.0, glow: float = 0.0, bold: bool = False) -> None:
        self.font(ctx, size, bold)
        ext = ctx.text_extents(value)
        self.text(ctx, (W - ext.width) / 2 - ext.x_bearing, y, value, color, size, alpha, glow, bold)

    def line(self, ctx: cairo.Context, x1: float, y1: float, x2: float, y2: float, color: str = "steel",
             alpha: float = 1.0, width: float = 1.0) -> None:
        source(ctx, color, alpha)
        ctx.set_line_width(width)
        ctx.move_to(x1, y1); ctx.line_to(x2, y2); ctx.stroke()

    def box(self, ctx: cairo.Context, x: float, y: float, w: float, h: float, color: str = "steel",
            alpha: float = 1.0, width: float = 1.0, radius: float = 0.0) -> None:
        rounded_rect(ctx, x, y, w, h, radius) if radius else ctx.rectangle(x, y, w, h)
        source(ctx, color, alpha); ctx.set_line_width(width); ctx.stroke()

    def dot(self, ctx: cairo.Context, x: float, y: float, color: str, radius: float = 4.0, alpha: float = 1.0,
            glow: bool = False) -> None:
        if glow:
            gradient = cairo.RadialGradient(x, y, 0, x, y, radius * 4)
            r, g, b = COLORS[color]
            gradient.add_color_stop_rgba(0, r, g, b, alpha * 0.42)
            gradient.add_color_stop_rgba(1, r, g, b, 0)
            ctx.set_source(gradient); ctx.arc(x, y, radius * 4, 0, math.tau); ctx.fill()
        source(ctx, color, alpha); ctx.arc(x, y, radius, 0, math.tau); ctx.fill()

    def header(self, ctx: cairo.Context, title: str, subtitle: str = "INTERNAL // LEVEL 4") -> None:
        self.text(ctx, 78, 84, title, "bright", 27, 0.96, 0.28, True)
        self.text(ctx, 80, 119, subtitle, "steel", 13, 0.85, spacing=2.0)
        self.line(ctx, 78, 154, 1842, 154, "steel", 0.34)
        self.line(ctx, 78, 157, 1842, 157, "red", 0.18)

    def footer(self, ctx: cairo.Context) -> None:
        self.line(ctx, 78, 1006, 1842, 1006, "steel", 0.24)
        self.text(ctx, 78, 1038, "HIVE FACILITY // INTERNAL NETWORK", "steel", 12, 0.68, spacing=1.5)

    def draw_background(self, ctx: cairo.Context, now: float) -> None:
        ctx.set_source_rgb(0.002, 0.004, 0.004); ctx.paint(); ctx.save()
        rounded_rect(ctx, 18, 18, 1884, 1044, 32); ctx.clip()
        bg = cairo.LinearGradient(0, 0, 0, H)
        bg.add_color_stop_rgb(0, 0.018, 0.029, 0.027)
        bg.add_color_stop_rgb(0.55, 0.010, 0.016, 0.016)
        bg.add_color_stop_rgb(1, 0.032, 0.008, 0.011)
        ctx.set_source(bg); ctx.paint()
        source(ctx, "steel", 0.025); ctx.set_line_width(1)
        for x in range(46, 1900, 48): ctx.move_to(x, 22); ctx.line_to(x, 1058)
        for y in range(42, 1060, 48): ctx.move_to(22, y); ctx.line_to(1898, y)
        ctx.stroke()
        glow = cairo.RadialGradient(960, 520, 30, 960, 520, 890)
        glow.add_color_stop_rgba(0, 0.12, 0.16, 0.15, 0.085)
        glow.add_color_stop_rgba(0.62, 0.04, 0.06, 0.055, 0.025)
        glow.add_color_stop_rgba(1, 0, 0, 0, 0)
        ctx.set_source(glow); ctx.paint(); ctx.restore()

    def draw_security(self, ctx: cairo.Context, now: float) -> None:
        self.header(ctx, "UMBRELLA CORPORATION // HIVE SECURITY TERMINAL", "FACILITY CONTROL // RED QUEEN NETWORK")
        self.text(ctx, 104, 215, "FACILITY SECTOR DIAGRAM", "white", 16, 0.92, bold=True)
        nodes = {"SECTOR 01": (130, 300), "CENTRAL LIFT": (430, 300), "SECTOR 02": (730, 300),
                 "LAB A-3": (230, 540), "RED QUEEN": (530, 540), "POWER": (830, 540)}
        links = (("SECTOR 01", "CENTRAL LIFT"), ("CENTRAL LIFT", "SECTOR 02"), ("SECTOR 01", "LAB A-3"),
                 ("CENTRAL LIFT", "RED QUEEN"), ("SECTOR 02", "POWER"), ("LAB A-3", "RED QUEEN"), ("RED QUEEN", "POWER"))
        for a, b in links:
            ax, ay = nodes[a]; bx, by = nodes[b]; self.line(ctx, ax + 92, ay + 31, bx + 92, by + 31, "steel", 0.42)
        for label, (x, y) in nodes.items():
            self.box(ctx, x, y, 184, 62, "red" if label == "RED QUEEN" else "steel", 0.74 if label == "RED QUEEN" else 0.48)
            self.text(ctx, x + 16, y + 38, label, "white" if label == "RED QUEEN" else "steel", 12, 0.92)
        self.text(ctx, 1110, 215, "SYSTEM STATUS", "white", 16, 0.92, bold=True)
        statuses = (("SECURITY SYSTEM", "ACTIVE", "green"), ("BIOMETRIC ACCESS", "ONLINE", "green"),
                    ("CONTAINMENT", "ARMED", "red"), ("ENVIRONMENTAL", "NOMINAL", "cyan"), ("RED QUEEN SYSTEM", "ONLINE", "red"))
        for i, (label, value, color) in enumerate(statuses):
            y = 272 + i * 57
            self.text(ctx, 1140, y, label, "steel", 13, 0.80)
            self.text(ctx, 1515, y, value, color, 13, 0.94, 0.18 if color == "red" else 0)
            self.line(ctx, 1140, y + 15, 1760, y + 15, "steel", 0.12)
        self.text(ctx, 1110, 600, "NETWORK ACTIVITY", "white", 14, 0.88)
        self.box(ctx, 1110, 626, 650, 150, "steel", 0.28)
        points = self.model.network_load
        for i in range(len(points) - 1):
            self.line(ctx, 1130 + i * 67, 750 - points[i] * 150, 1130 + (i + 1) * 67, 750 - points[i + 1] * 150, "cyan", 0.67, 2)
        self.text(ctx, 1120, 820, f"CONTAINMENT {self.model.containment:05.2f}%", "red", 13, 0.86)
        self.text(ctx, 1455, 820, "CLEARANCE // LEVEL 4", "steel", 13, 0.72)
        self.footer(ctx)

    def draw_lockdown(self, ctx: cairo.Context, now: float) -> None:
        self.header(ctx, "HIVE FACILITY", "EMERGENCY CONTROL // BIOLOGICAL EVENT")
        self.box(ctx, 126, 220, 1668, 630, "red", 0.44, 2); self.box(ctx, 142, 236, 1636, 598, "steel", 0.20)
        self.centered(ctx, 395, "HIVE FACILITY", "white", 27, 0.93, 0.14, True)
        self.centered(ctx, 474, "BIOLOGICAL CONTAINMENT PROTOCOL", "alarm", 36, 0.94, 0.31, True)
        self.line(ctx, 500, 520, 1420, 520, "red", 0.44, 2)
        self.centered(ctx, 590, "SECURITY SYSTEM ACTIVE", "white", 17, 0.88)
        self.centered(ctx, 638, "SECTOR STATUS: LOCKED", "red", 16, 0.90, 0.20)
        self.centered(ctx, 706, "ACCESS RESTRICTED // LEVEL 4 CLEARANCE REQUIRED", "steel", 13, 0.72)
        self.footer(ctx)

    def draw_diagnostic(self, ctx: cairo.Context, now: float) -> None:
        self.header(ctx, "T-VIRUS DIAGNOSTIC // CONTAINMENT ANALYSIS", "BIOTECHNOLOGY DIVISION // SAMPLE CONTROL")
        self.text(ctx, 110, 218, f"SPECIMEN T-{self.model.sample_index:03d} // SYNTHETIC", "white", 15, 0.90, bold=True)
        self.box(ctx, 100, 248, 760, 640, "steel", 0.34)
        self.text(ctx, 125, 282, "MOLECULAR SCHEMATIC", "steel", 12, 0.76, spacing=1.5)
        self.text(ctx, 112, 852, "HELIX ROTATION // 0.42 RAD/S", "dim", 11, 0.72)
        self.text(ctx, 970, 218, "CELLULAR ANALYSIS", "white", 15, 0.90, bold=True)
        rows = (("RNA SEQUENCE", "ACQUIRED", "cyan"), ("CELL INTEGRITY", f"{self.model.integrity:05.2f}%", "green"),
                ("REPLICATION INDEX", "RESTRICTED", "red"), ("THERMAL ENVELOPE", "STABLE", "white"),
                ("CONTAINMENT", f"{self.model.containment:05.2f}%", "red"), ("PRESSURE", "NEGATIVE", "green"))
        for i, (label, value, color) in enumerate(rows):
            y = 292 + i * 68; self.text(ctx, 982, y, label, "steel", 13, 0.76)
            self.text(ctx, 1490, y, value, color, 13, 0.94, 0.15 if color == "red" else 0); self.line(ctx, 982, y + 20, 1765, y + 20, "steel", 0.15)
        self.text(ctx, 982, 742, "SAMPLE STATUS", "white", 13, 0.85); self.box(ctx, 982, 770, 783, 90, "red", 0.45)
        self.text(ctx, 1015, 825, "[ ACTIVE ]  NEGATIVE-PRESSURE CONTAINMENT", "red", 15, 0.93, 0.22, True)
        self.footer(ctx)

    def draw_red_queen(self, ctx: cairo.Context, now: float) -> None:
        self.centered(ctx, 280, "R E D   Q U E E N", "red", 25, 0.84, 0.28, True)
        self.centered(ctx, 325, "ARTIFICIAL INTELLIGENCE CORE", "steel", 13, 0.64)
        for i, (label, value) in enumerate((("SYSTEM STATUS", "ONLINE"), ("FACILITY CONTROL", "ACTIVE"), ("BIOHAZARD CONTAINMENT", "ACTIVE"))):
            y = 720 + i * 42; self.text(ctx, 655, y, label, "steel", 12, 0.66)
            self.text(ctx, 1175, y, value, "red" if i == 2 else "white", 12, 0.82, 0.12 if i == 2 else 0)
        messages = ("Observation mode. All sectors remain under central control.", "Biometric network synchronized. No external access detected.",
                    "Containment geometry stable. Monitoring continues.", "Environmental systems operating within expected parameters.")
        self.centered(ctx, 905, messages[self.model.status_index], "dim", 11, 0.62); self.footer(ctx)

    def centered_in_box(self, ctx: cairo.Context, x: float, y: float, w: float, h: float, value: str, color: str, size: float) -> None:
        self.font(ctx, size, True); ext = ctx.text_extents(value)
        self.text(ctx, x + (w - ext.width) / 2, y + h / 2, value, color, size, 0.90, 0.22, True)

    def camera_view(self, ctx: cairo.Context, index: int, x: float, y: float, title: str, now: float) -> None:
        w, h = 780, 320; self.box(ctx, x, y, w, h, "steel", 0.38)
        self.text(ctx, x + 20, y + 34, f"CAM {index + 1:02d} // {title}", "steel", 12, 0.80, spacing=1.0)
        self.dot(ctx, x + w - 24, y + 26, "red", 4, 0.80, True)
        if self.model.camera_loss == index:
            self.centered_in_box(ctx, x, y, w, h, "SIGNAL INTERRUPTED", "red", 15)
        else:
            horizon = y + 195; self.line(ctx, x + 65, horizon, x + w - 65, horizon, "steel", 0.20)
            self.line(ctx, x + 65, horizon, x + 220, y + 82, "steel", 0.31)
            self.line(ctx, x + w - 65, horizon, x + w - 220, y + 82, "steel", 0.31)
            self.line(ctx, x + w / 2, y + 82, x + w / 2, horizon, "steel", 0.22)
        self.text(ctx, x + 20, y + h - 18, f"FEED {self.model.camera_integrity[index]:05.2f}% //", "dim", 10, 0.64)

    def draw_cctv(self, ctx: cairo.Context, now: float) -> None:
        self.header(ctx, "HIVE CCTV // SURVEILLANCE NETWORK", "SECURITY ARCHIVE // RECORDING")
        self.camera_view(ctx, 0, 100, 205, "SECTOR B / LAB LEVEL", now); self.camera_view(ctx, 1, 1040, 205, "TRANSIT / CENTRAL LIFT", now)
        self.camera_view(ctx, 2, 100, 570, "CONTAINMENT / AIRLOCK", now); self.camera_view(ctx, 3, 1040, 570, "RED QUEEN / CORE", now)
        self.footer(ctx)

    def invalidate_static(self) -> None:
        self.static_dirty = True

    def invalidate_clock(self) -> None:
        self.clock_dirty = True

    def compile_shader(self, shader_type: int, shader_source: str) -> int:
        shader = glCreateShader(shader_type)
        encoded = shader_source.encode("utf-8")
        pointer = ctypes.c_char_p(encoded)
        glShaderSource(shader, 1, ctypes.byref(pointer), None)
        glCompileShader(shader)
        status = ctypes.c_int()
        glGetShaderiv(shader, GL_COMPILE_STATUS, ctypes.byref(status))
        if not status.value:
            length = ctypes.c_int()
            glGetShaderiv(shader, GL_INFO_LOG_LENGTH, ctypes.byref(length))
            log = ctypes.create_string_buffer(max(1, length.value))
            glGetShaderInfoLog(shader, length.value, None, log)
            raise RuntimeError(f"GL shader compilation failed: {log.value.decode(errors='replace')}")
        return shader

    def build_program(self) -> int:
        vertex = self.compile_shader(GL_VERTEX_SHADER, VERTEX_SHADER)
        fragment = self.compile_shader(GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        program = glCreateProgram()
        glAttachShader(program, vertex)
        glAttachShader(program, fragment)
        glLinkProgram(program)
        glDeleteShader(vertex); glDeleteShader(fragment)
        status = ctypes.c_int()
        glGetProgramiv(program, GL_LINK_STATUS, ctypes.byref(status))
        if not status.value:
            length = ctypes.c_int()
            glGetProgramiv(program, GL_INFO_LOG_LENGTH, ctypes.byref(length))
            log = ctypes.create_string_buffer(max(1, length.value))
            glGetProgramInfoLog(program, length.value, None, log)
            raise RuntimeError(f"GL program link failed: {log.value.decode(errors='replace')}")
        return program

    def configure_texture(self, texture: int) -> None:
        glBindTexture(GL_TEXTURE_2D, texture)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

    def upload_surface(self, texture: int, surface: cairo.ImageSurface) -> None:
        surface.flush()
        raw = bytes(surface.get_data())
        pixels = ctypes.create_string_buffer(raw)
        glBindTexture(GL_TEXTURE_2D, texture)
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, surface.get_width(), surface.get_height(), 0,
                     GL_BGRA, GL_UNSIGNED_BYTE, ctypes.cast(pixels, ctypes.c_void_p))

    def rebuild_static_texture(self, now: float) -> None:
        width, height = int(W), int(H)
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
        scene_ctx = cairo.Context(surface)
        scene_ctx.scale(width / W, height / H)
        self.draw_background(scene_ctx, now)
        {"security": self.draw_security, "lockdown": self.draw_lockdown, "diagnostic": self.draw_diagnostic,
         "red_queen": self.draw_red_queen, "cctv": self.draw_cctv}[self.model.scene](scene_ctx, now)
        self.upload_surface(self.textures[0], surface)
        self.static_dirty = False

    def rebuild_clock_texture(self) -> None:
        width, height = 212, 27
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
        ctx = cairo.Context(surface)
        ctx.set_operator(cairo.OPERATOR_SOURCE); ctx.set_source_rgba(0, 0, 0, 0); ctx.paint()
        ctx.set_operator(cairo.OPERATOR_OVER)
        self.font(ctx, 12)
        ext = ctx.text_extents(self.model.clock)
        self.text(ctx, width - ext.width - 2, 18, self.model.clock, "steel", 12, 0.76)
        self.upload_surface(self.textures[1], surface)
        self.clock_dirty = False

    def on_realize(self, _area: Gtk.GLArea) -> None:
        self.make_current()
        error = self.get_error()
        if error is not None:
            print(f"Hive screensaver: unable to create an OpenGL context: {error}", file=sys.stderr)
            GLib.idle_add(self.quit_application)
            return
        self.program = self.build_program()
        glGenVertexArrays(1, ctypes.byref(self.vao))
        glBindVertexArray(self.vao.value)
        glGenTextures(2, self.textures)
        for texture in self.textures:
            self.configure_texture(texture)
        glUseProgram(self.program)
        for name in ("u_scene", "u_clock", "u_resolution", "u_time", "u_fade", "u_interference", "u_scene_id"):
            self.uniforms[name] = glGetUniformLocation(self.program, name.encode())
        glUniform1i(self.uniforms["u_scene"], 0)
        glUniform1i(self.uniforms["u_clock"], 1)
        if self.report_gl:
            values = [glGetString(key) for key in (GL_VENDOR, GL_RENDERER, GL_VERSION)]
            labels = ("vendor", "renderer", "version")
            print("HIVE_GL " + " ".join(f"{label}={value.decode(errors='replace') if value else 'unknown'}"
                                          for label, value in zip(labels, values)), flush=True)

    def quit_application(self) -> bool:
        root = self.get_root()
        if isinstance(root, Gtk.ApplicationWindow):
            application = root.get_application()
            if application is not None:
                application.quit()
        return False

    def on_render(self, _area: Gtk.GLArea, _context: Gdk.GLContext) -> bool:
        if not self.program:
            return False
        now = time.monotonic()
        width, height = max(1, self.get_width()), max(1, self.get_height())
        if self.static_dirty:
            self.rebuild_static_texture(now)
        if self.clock_dirty:
            self.rebuild_clock_texture()
        scale = self.get_scale_factor()
        glViewport(0, 0, width * scale, height * scale)
        glClearColor(0.001, 0.002, 0.002, 1.0); glClear(GL_COLOR_BUFFER_BIT)
        glUseProgram(self.program); glBindVertexArray(self.vao.value)
        glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, self.textures[0])
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, self.textures[1])
        glUniform2f(self.uniforms["u_resolution"], width * scale, height * scale)
        glUniform1f(self.uniforms["u_time"], now)
        glUniform1f(self.uniforms["u_fade"], self.model.fade_alpha(now))
        glUniform1f(self.uniforms["u_interference"], 1.0 if now < self.model.interference_until else 0.0)
        glUniform1i(self.uniforms["u_scene_id"], self.model.scene_index)
        glDrawArrays(GL_TRIANGLES, 0, 6)
        return True


class HiveApplication(Gtk.Application):
    def __init__(self, app_id: str, scene_seconds: float, visual_fps: float,
                 ignore_input: bool = False, report_gl: bool = False) -> None:
        super().__init__(application_id=app_id, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.model = Model(scene_seconds); self.windows = []; self.canvases = []
        self.started = time.monotonic(); self.last_pointer = None; self.ignore_input = ignore_input
        self.report_gl = report_gl
        self.visual_fps = max(15.0, min(30.0, visual_fps))

    def dismiss(self, *_args) -> bool:
        self.quit(); return True

    def on_input(self, *_args) -> bool:
        if self.ignore_input:
            return False
        return self.dismiss()

    def on_motion(self, _controller, x: float, y: float) -> None:
        if self.ignore_input:
            return
        if self.last_pointer is None:
            self.last_pointer = (x, y); return
        old_x, old_y = self.last_pointer; self.last_pointer = (x, y)
        if time.monotonic() - self.started > 0.9 and abs(x - old_x) + abs(y - old_y) > 1.5: self.quit()

    def make_window(self, monitor: Gdk.Monitor) -> None:
        window = Gtk.ApplicationWindow(application=self); window.set_title("Hive Security Monitor")
        window.set_decorated(False); window.set_resizable(False); window.set_cursor_from_name("none")
        canvas = HiveCanvas(self.model, self.report_gl); window.set_child(canvas)
        key = Gtk.EventControllerKey(); key.connect("key-pressed", self.on_input); window.add_controller(key)
        motion = Gtk.EventControllerMotion(); motion.connect("motion", self.on_motion); window.add_controller(motion)
        click = Gtk.GestureClick(); click.connect("pressed", self.on_input); window.add_controller(click)
        scroll = Gtk.EventControllerScroll.new(Gtk.EventControllerScrollFlags.BOTH_AXES); scroll.connect("scroll", self.on_input); window.add_controller(scroll)
        window.connect("close-request", self.dismiss); self.windows.append(window); self.canvases.append(canvas)
        geometry = monitor.get_geometry(); window.set_default_size(geometry.width, geometry.height)
        window.fullscreen_on_monitor(monitor); window.present(); window.fullscreen()

    def do_activate(self) -> None:
        display = Gdk.Display.get_default()
        if display is None: self.quit(); return
        monitors = display.get_monitors()
        for i in range(monitors.get_n_items()): self.make_window(monitors.get_item(i))
        GLib.timeout_add(1000, self.data_tick)
        GLib.timeout_add(round(1000 / self.visual_fps), self.animation_tick)
        signal.signal(signal.SIGTERM, lambda *_args: GLib.idle_add(self.dismiss))
        signal.signal(signal.SIGINT, lambda *_args: GLib.idle_add(self.dismiss))

    def data_tick(self) -> bool:
        static_changed, clock_changed = self.model.update_data(time.monotonic())
        if static_changed:
            for canvas in self.canvases:
                canvas.invalidate_static()
        if clock_changed:
            for canvas in self.canvases:
                canvas.invalidate_clock()
        return True

    def animation_tick(self) -> bool:
        if self.model.update_animation(time.monotonic()):
            for canvas in self.canvases:
                canvas.invalidate_static()
        for canvas in self.canvases:
            canvas.queue_render()
        return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", nargs="?", choices=("preview",), help=argparse.SUPPRESS)
    parser.add_argument("--app-id", default="org.omarchy.screensaver")
    parser.add_argument("--scene-seconds", type=float, default=float(os.environ.get("HIVE_SCENE_SECONDS", "28")))
    parser.add_argument("--fps", type=float, default=float(os.environ.get("HIVE_VISUAL_FPS", "24")))
    parser.add_argument("--ignore-input", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--report-gl", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--scene", choices=Model.scenes, help=argparse.SUPPRESS)
    args = parser.parse_args()
    app = HiveApplication(args.app_id, args.scene_seconds, args.fps, args.ignore_input, args.report_gl)
    if args.scene:
        app.model.scene_index = app.model.scenes.index(args.scene)
    return app.run([])


if __name__ == "__main__":
    raise SystemExit(main())
