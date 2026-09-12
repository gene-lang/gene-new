/* Small OpenGL resource/array adapters; game rules and mesh generation stay
 * in Gene. Resolve GL through SDL so this does not depend on a GL linker ABI. */
#include <SDL.h>
#include <SDL_opengl.h>
#include <SDL_ttf.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <math.h>

#define GL_FUNCTIONS(X) \
 X(void, ClearColor, (GLfloat, GLfloat, GLfloat, GLfloat)) \
 X(void, Clear, (GLbitfield)) \
 X(void, Viewport, (GLint, GLint, GLsizei, GLsizei)) \
 X(void, Enable, (GLenum)) \
 X(void, Disable, (GLenum)) \
 X(void, DepthFunc, (GLenum)) \
 X(void, CullFace, (GLenum)) \
 X(void, BlendFunc, (GLenum, GLenum)) \
 X(GLenum, GetError, (void)) \
 X(const GLubyte *, GetString, (GLenum)) \
 X(GLuint, CreateShader, (GLenum)) \
 X(void, ShaderSource, (GLuint, GLsizei, const GLchar *const *, const GLint *)) \
 X(void, CompileShader, (GLuint)) \
 X(void, GetShaderiv, (GLuint, GLenum, GLint *)) \
 X(void, GetShaderInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *)) \
 X(void, DeleteShader, (GLuint)) \
 X(GLuint, CreateProgram, (void)) \
 X(void, AttachShader, (GLuint, GLuint)) \
 X(void, LinkProgram, (GLuint)) \
 X(void, GetProgramiv, (GLuint, GLenum, GLint *)) \
 X(void, GetProgramInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *)) \
 X(void, DeleteProgram, (GLuint)) \
 X(void, UseProgram, (GLuint)) \
 X(GLint, GetUniformLocation, (GLuint, const GLchar *)) \
 X(void, Uniform1i, (GLint, GLint)) \
 X(void, Uniform1f, (GLint, GLfloat)) \
 X(void, Uniform3f, (GLint, GLfloat, GLfloat, GLfloat)) \
 X(void, Uniform2f, (GLint, GLfloat, GLfloat)) \
 X(void, Uniform4f, (GLint, GLfloat, GLfloat, GLfloat, GLfloat)) \
 X(void, UniformMatrix4fv, (GLint, GLsizei, GLboolean, const GLfloat *)) \
 X(void, GenVertexArrays, (GLsizei, GLuint *)) \
 X(void, BindVertexArray, (GLuint)) \
 X(void, DeleteVertexArrays, (GLsizei, const GLuint *)) \
 X(void, GenBuffers, (GLsizei, GLuint *)) \
 X(void, BindBuffer, (GLenum, GLuint)) \
 X(void, BufferData, (GLenum, GLsizeiptr, const void *, GLenum)) \
 X(void, DeleteBuffers, (GLsizei, const GLuint *)) \
 X(void, EnableVertexAttribArray, (GLuint)) \
 X(void, VertexAttribPointer, (GLuint, GLint, GLenum, GLboolean, GLsizei, const void *)) \
 X(void, DrawElements, (GLenum, GLsizei, GLenum, const void *)) \
 X(void, DrawArrays, (GLenum, GLint, GLsizei)) \
 X(void, GenTextures, (GLsizei, GLuint *)) \
 X(void, BindTexture, (GLenum, GLuint)) \
 X(void, TexImage2D, (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *)) \
 X(void, TexParameteri, (GLenum, GLenum, GLint)) \
 X(void, DeleteTextures, (GLsizei, const GLuint *)) \
 X(void, ReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *)) \
 X(void, Finish, (void))

#define DECLARE_GL(ret, name, args) ret (APIENTRY *name) args;
typedef struct {
  GL_FUNCTIONS(DECLARE_GL)
} GL;
#undef DECLARE_GL

typedef struct { GLuint vao, vbo, ebo; GLsizei indices; int alive, stride; size_t bytes; uint32_t max_index; } Mesh;
typedef struct { char *text; int font, width, height; GLuint texture; uint64_t used; } Text;
typedef struct GXDevice {
  SDL_Window *window; /* borrowed: caller closes the device before the window */
  SDL_GLContext context;
  SDL_threadID owner;
  GL gl;
  Mesh *meshes;
  size_t mesh_count;
  GLuint *programs, *textures;
  size_t program_count, texture_count;
  GLuint ui_program, ui_vao, ui_vbo, white;
  TTF_Font **fonts;
  size_t font_count;
  Text text[128];
  uint64_t clock;
  SDL_AudioDeviceID audio;
  int audio_rate;
  uint32_t noise_state;
} GXDevice;

static int current(GXDevice *d) {
  if (SDL_ThreadID() != d->owner) return SDL_SetError("OpenGL device belongs to another thread");
  if (SDL_GL_GetCurrentContext() != d->context)
    return SDL_GL_MakeCurrent(d->window, d->context);
  return 0;
}

void gx_device_free(GXDevice *d) {
  if (!d) return;
  if (d->audio) SDL_CloseAudioDevice(d->audio);
  if (current(d) == 0) {
    for (size_t i = 0; i < d->mesh_count; i++) if (d->meshes[i].alive) {
      d->gl.DeleteBuffers(1, &d->meshes[i].vbo);
      d->gl.DeleteBuffers(1, &d->meshes[i].ebo);
      d->gl.DeleteVertexArrays(1, &d->meshes[i].vao);
    }
    for (size_t i = 0; i < d->program_count; i++) d->gl.DeleteProgram(d->programs[i]);
    if (d->texture_count) d->gl.DeleteTextures((GLsizei)d->texture_count, d->textures);
    if (d->ui_vao) d->gl.DeleteVertexArrays(1, &d->ui_vao);
    if (d->ui_vbo) d->gl.DeleteBuffers(1, &d->ui_vbo);
    for (size_t i = 0; i < 128; i++) if (d->text[i].text) {
      d->gl.DeleteTextures(1, &d->text[i].texture); free(d->text[i].text);
    }
  }
  for (size_t i = 0; i < d->font_count; i++) TTF_CloseFont(d->fonts[i]);
  if (d->font_count) TTF_Quit();
  free(d->fonts);
  free(d->meshes); free(d->programs); free(d->textures);
  SDL_GL_DeleteContext(d->context);
  free(d);
}

GXDevice *gx_device_new(SDL_Window *window) {
  GXDevice *d = calloc(1, sizeof *d);
  if (!d) { SDL_OutOfMemory(); return NULL; }
  d->window = window;
  d->owner = SDL_ThreadID();
  d->context = SDL_GL_CreateContext(window);
  if (!d->context) { free(d); return NULL; }
#define LOAD_GL(ret, name, args) \
  d->gl.name = (ret (APIENTRY *) args)SDL_GL_GetProcAddress("gl" #name); \
  if (!d->gl.name) { SDL_SetError("missing OpenGL function gl" #name); goto fail; }
  GL_FUNCTIONS(LOAD_GL)
#undef LOAD_GL
  d->gl.Enable(GL_DEPTH_TEST);
  d->gl.DepthFunc(GL_LEQUAL);
  d->gl.Enable(GL_CULL_FACE);
  d->gl.CullFace(GL_BACK);
  return d;
fail:
  SDL_GL_DeleteContext(d->context); free(d); return NULL;
}

const char *gx_gl_version(GXDevice *d) {
  if (current(d) != 0) return "";
  return (const char *)d->gl.GetString(GL_VERSION);
}
unsigned gx_gl_error(GXDevice *d) { return current(d) == 0 ? d->gl.GetError() : UINT_MAX; }
int gx_width(GXDevice *d) { int w, h; SDL_GL_GetDrawableSize(d->window, &w, &h); return w; }
int gx_height(GXDevice *d) { int w, h; SDL_GL_GetDrawableSize(d->window, &w, &h); return h; }
int gx_logical_width(GXDevice *d) { int w,h; SDL_GetWindowSize(d->window,&w,&h); return w; }
int gx_logical_height(GXDevice *d) { int w,h; SDL_GetWindowSize(d->window,&w,&h); return h; }

static GLuint shader(GXDevice *d, GLenum kind, const char *source) {
  GLuint s = d->gl.CreateShader(kind);
  d->gl.ShaderSource(s, 1, &source, NULL);
  d->gl.CompileShader(s);
  GLint ok = 0;
  d->gl.GetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[4096] = {0};
    d->gl.GetShaderInfoLog(s, sizeof log - 1, NULL, log);
    SDL_SetError("shader compilation: %s", log);
    d->gl.DeleteShader(s); return 0;
  }
  return s;
}
unsigned gx_program(GXDevice *d, const char *vs, const char *fs) {
  if (current(d) != 0) return 0;
  GLuint v = shader(d, GL_VERTEX_SHADER, vs);
  if (!v) return 0;
  GLuint f = shader(d, GL_FRAGMENT_SHADER, fs);
  if (!f) { d->gl.DeleteShader(v); return 0; }
  GLuint p = d->gl.CreateProgram();
  d->gl.AttachShader(p, v); d->gl.AttachShader(p, f); d->gl.LinkProgram(p);
  d->gl.DeleteShader(v); d->gl.DeleteShader(f);
  GLint ok = 0;
  d->gl.GetProgramiv(p, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[4096] = {0};
    d->gl.GetProgramInfoLog(p, sizeof log - 1, NULL, log);
    SDL_SetError("program link: %s", log); d->gl.DeleteProgram(p); return 0;
  }
  GLuint *all = realloc(d->programs, (d->program_count + 1) * sizeof *all);
  if (!all) { SDL_OutOfMemory(); d->gl.DeleteProgram(p); return 0; }
  d->programs = all; d->programs[d->program_count++] = p;
  return p;
}

int gx_begin(GXDevice *d, unsigned program, double r, double g, double b) {
  if (current(d) != 0) return -1;
  d->gl.Viewport(0, 0, gx_width(d), gx_height(d));
  d->gl.ClearColor((float)r, (float)g, (float)b, 1);
  d->gl.Clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  d->gl.UseProgram(program);
  d->gl.Enable(GL_DEPTH_TEST); d->gl.Enable(GL_CULL_FACE); d->gl.Disable(GL_BLEND);
  return 0;
}
void gx_present(GXDevice *d) { if (current(d) == 0) SDL_GL_SwapWindow(d->window); }

/* Gene's binary codecs explicitly produce little-endian words. Convert rather
 * than assuming the C host's byte order or the byte buffer's alignment. */
static uint32_t le32(const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void *words(const void *data, size_t n) {
  if (n % 4 || n > (size_t)INT_MAX) { SDL_SetError("invalid 32-bit buffer size"); return NULL; }
  void *out = malloc(n ? n : 1);
  if (!out) { SDL_OutOfMemory(); return NULL; }
  for (size_t i = 0; i < n; i += 4) {
    uint32_t v = le32((const unsigned char *)data + i);
    memcpy((unsigned char *)out + i, &v, 4);
  }
  return out;
}
static Mesh *mesh(GXDevice *d, int id) {
  if (current(d) != 0) return NULL;
  if (id < 0 || (size_t)id >= d->mesh_count || !d->meshes[id].alive) {
    SDL_SetError("invalid mesh id"); return NULL;
  }
  return &d->meshes[id];
}
int gx_mesh_new(GXDevice *d) {
  if (current(d) != 0 || d->mesh_count >= INT_MAX) return -1;
  Mesh *all = realloc(d->meshes, (d->mesh_count + 1) * sizeof *all);
  if (!all) { SDL_OutOfMemory(); return -1; }
  d->meshes = all;
  Mesh *m = &all[d->mesh_count]; memset(m, 0, sizeof *m);
  d->gl.GenVertexArrays(1, &m->vao);
  d->gl.GenBuffers(1, &m->vbo); d->gl.GenBuffers(1, &m->ebo);
  m->alive = 1;
  return (int)d->mesh_count++;
}
int gx_mesh_upload(GXDevice *d, int id, void *v, size_t vn, void *i, size_t in) {
  Mesh *m = mesh(d, id); if (!m) return -1;
  void *vertices = words(v, vn); if (!vertices) return -1;
  void *indices = words(i, in); if (!indices) { free(vertices); return -1; }
  d->gl.BindVertexArray(m->vao);
  d->gl.BindBuffer(GL_ARRAY_BUFFER, m->vbo);
  d->gl.BufferData(GL_ARRAY_BUFFER, (GLsizeiptr)vn, vertices, GL_STATIC_DRAW);
  d->gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, m->ebo);
  d->gl.BufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)in, indices, GL_STATIC_DRAW);
  m->indices = (GLsizei)(in / 4);
  m->bytes = vn; m->max_index = 0;
  for (size_t at = 0; at < in / 4; at++)
    if (((uint32_t *)indices)[at] > m->max_index) m->max_index = ((uint32_t *)indices)[at];
  free(vertices); free(indices);
  return 0;
}
int gx_mesh_attribute(GXDevice *d, int id, unsigned location, int count, int stride, int offset) {
  Mesh *m = mesh(d, id); if (!m) return -1;
  if (count < 1 || count > 4 || stride < count * 4 || offset < 0 || offset > stride - count * 4)
    return SDL_SetError("invalid vertex attribute layout");
  if (m->stride && m->stride != stride) return SDL_SetError("attributes must share an interleaved stride");
  m->stride = stride;
  d->gl.BindVertexArray(m->vao); d->gl.BindBuffer(GL_ARRAY_BUFFER, m->vbo);
  d->gl.EnableVertexAttribArray(location);
  d->gl.VertexAttribPointer(location, count, GL_FLOAT, GL_FALSE, stride, (void *)(uintptr_t)offset);
  return 0;
}
int gx_mesh_draw(GXDevice *d, int id) {
  Mesh *m = mesh(d, id); if (!m) return -1;
  if (m->indices && (!m->stride || m->indices % 3 || m->max_index >= m->bytes / (size_t)m->stride))
    return SDL_SetError("mesh indices exceed its vertex layout");
  d->gl.BindVertexArray(m->vao);
  d->gl.DrawElements(GL_TRIANGLES, m->indices, GL_UNSIGNED_INT, NULL);
  return 0;
}
int gx_mesh_free(GXDevice *d, int id) {
  Mesh *m = mesh(d, id); if (!m) return -1;
  d->gl.DeleteBuffers(1, &m->vbo); d->gl.DeleteBuffers(1, &m->ebo);
  d->gl.DeleteVertexArrays(1, &m->vao); m->alive = 0;
  return 0;
}
int gx_uniform_matrix(GXDevice *d, unsigned p, const char *name, void *bytes, size_t n) {
  if (current(d) != 0) return -1;
  if (n != 64) return SDL_SetError("a mat4 needs 64 bytes");
  void *matrix = words(bytes, n); if (!matrix) return -1;
  d->gl.UseProgram(p);
  d->gl.UniformMatrix4fv(d->gl.GetUniformLocation(p, name), 1, GL_FALSE, matrix);
  free(matrix); return 0;
}
int gx_uniform_f(GXDevice *d, unsigned p, const char *name, double v) {
  if (current(d) != 0) return -1;
  d->gl.UseProgram(p); d->gl.Uniform1f(d->gl.GetUniformLocation(p, name), (float)v); return 0;
}
int gx_uniform_i(GXDevice *d, unsigned p, const char *name, int v) {
  if (current(d) != 0) return -1;
  d->gl.UseProgram(p); d->gl.Uniform1i(d->gl.GetUniformLocation(p, name), v); return 0;
}
int gx_uniform_3f(GXDevice *d, unsigned p, const char *name, double x, double y, double z) {
  if (current(d) != 0) return -1;
  d->gl.UseProgram(p); d->gl.Uniform3f(d->gl.GetUniformLocation(p, name), (float)x, (float)y, (float)z); return 0;
}
unsigned gx_texture(GXDevice *d, int w, int h, void *rgba, size_t n) {
  if (current(d) != 0) return 0;
  if (w < 1 || h < 1 || w > 16384 || h > 16384 || n != (size_t)w * (size_t)h * 4) {
    SDL_SetError("invalid RGBA texture dimensions"); return 0;
  }
  GLuint t; d->gl.GenTextures(1, &t); d->gl.BindTexture(GL_TEXTURE_2D, t);
  d->gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
  d->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  d->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  d->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  d->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  GLuint *all = realloc(d->textures, (d->texture_count + 1) * sizeof *all);
  if (!all) { SDL_OutOfMemory(); d->gl.DeleteTextures(1, &t); return 0; }
  d->textures = all; d->textures[d->texture_count++] = t; return t;
}
int gx_texture_bind(GXDevice *d, unsigned texture) {
  if (current(d) != 0) return -1;
  d->gl.BindTexture(GL_TEXTURE_2D, texture); return 0;
}
unsigned gx_pixel(GXDevice *d, int x, int y) {
  if (current(d) != 0) return 0;
  if (x < 0 || y < 0 || x >= gx_width(d) || y >= gx_height(d)) {
    SDL_SetError("pixel outside framebuffer"); return 0;
  }
  unsigned char p[4] = {0}; d->gl.Finish();
  d->gl.ReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, p);
  return (unsigned)p[0] << 24 | (unsigned)p[1] << 16 | (unsigned)p[2] << 8 | p[3];
}
int gx_read_pixels(GXDevice *d, void *rgba, size_t n) {
  if (current(d) != 0) return -1;
  int w=gx_width(d), h=gx_height(d);
  if (w<1 || h<1 || n!=(size_t)w*(size_t)h*4) return SDL_SetError("invalid framebuffer buffer size");
  d->gl.Finish(); d->gl.ReadPixels(0,0,w,h,GL_RGBA,GL_UNSIGNED_BYTE,rgba); return 0;
}

static int ui_init(GXDevice *d) {
  if (d->ui_program) return 0;
  d->ui_program = gx_program(d,
    "#version 330 core\nlayout(location=0) in vec2 position; layout(location=1) in vec2 uv;"
    "uniform vec2 screen; out vec2 v_uv; void main(){v_uv=uv; gl_Position=vec4(position.x/screen.x*2.0-1.0,1.0-position.y/screen.y*2.0,0,1);}",
    "#version 330 core\nin vec2 v_uv; uniform sampler2D image; uniform vec4 tint; out vec4 color;"
    "void main(){color=texture(image,v_uv)*tint;}");
  if (!d->ui_program) return -1;
  unsigned char white[4] = {255,255,255,255}; d->white = gx_texture(d, 1, 1, white, 4);
  d->gl.GenVertexArrays(1, &d->ui_vao); d->gl.GenBuffers(1, &d->ui_vbo);
  d->gl.BindVertexArray(d->ui_vao); d->gl.BindBuffer(GL_ARRAY_BUFFER, d->ui_vbo);
  d->gl.EnableVertexAttribArray(0); d->gl.VertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,16,NULL);
  d->gl.EnableVertexAttribArray(1); d->gl.VertexAttribPointer(1,2,GL_FLOAT,GL_FALSE,16,(void *)8);
  return d->white ? 0 : -1;
}
static int quad(GXDevice *d, GLuint texture, float x, float y, float w, float h, uint32_t rgba) {
  if (current(d) != 0 || ui_init(d) != 0) return -1;
  int width, height; SDL_GetWindowSize(d->window, &width, &height);
  if (width < 1 || height < 1) return 0;
  const float v[] = {x,y,0,0, x+w,y,1,0, x+w,y+h,1,1, x,y,0,0, x+w,y+h,1,1, x,y+h,0,1};
  d->gl.Disable(GL_DEPTH_TEST); d->gl.Disable(GL_CULL_FACE); d->gl.Enable(GL_BLEND);
  d->gl.BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  d->gl.UseProgram(d->ui_program);
  d->gl.Uniform2f(d->gl.GetUniformLocation(d->ui_program,"screen"),(float)width,(float)height);
  d->gl.Uniform4f(d->gl.GetUniformLocation(d->ui_program,"tint"),
    (float)(rgba>>24)/255, (float)((rgba>>16)&255)/255, (float)((rgba>>8)&255)/255, (float)(rgba&255)/255);
  d->gl.Uniform1i(d->gl.GetUniformLocation(d->ui_program,"image"),0);
  d->gl.BindTexture(GL_TEXTURE_2D,texture); d->gl.BindVertexArray(d->ui_vao);
  d->gl.BindBuffer(GL_ARRAY_BUFFER,d->ui_vbo);
  d->gl.BufferData(GL_ARRAY_BUFFER,sizeof v,v,GL_STREAM_DRAW);
  d->gl.DrawArrays(GL_TRIANGLES,0,6); return 0;
}
int gx_rect(GXDevice *d, double x, double y, double w, double h, uint32_t color) {
  if (current(d) != 0 || ui_init(d) != 0) return -1;
  return quad(d,d->white,(float)x,(float)y,(float)w,(float)h,color);
}
int gx_font_open(GXDevice *d, const char *path, int size) {
  if (current(d) != 0) return -1;
  if (size < 1 || size > 256) return SDL_SetError("font size must be 1..256");
  if (!d->font_count && TTF_Init() != 0) return -1;
  TTF_Font *font = TTF_OpenFont(path,size);
  if (!font) { if (!d->font_count) TTF_Quit(); return -1; }
  TTF_Font **all = realloc(d->fonts,(d->font_count+1)*sizeof *all);
  if (!all) { TTF_CloseFont(font); if (!d->font_count) TTF_Quit(); return SDL_OutOfMemory(); }
  d->fonts=all; d->fonts[d->font_count]=font; return (int)d->font_count++;
}
int gx_text(GXDevice *d, int font, const char *text, double x, double y, uint32_t color) {
  if (current(d) != 0) return -1;
  if (font < 0 || (size_t)font >= d->font_count) return SDL_SetError("invalid font id");
  size_t length=strlen(text); if (!length) return 0;
  if (length > 8192) return SDL_SetError("text is too long");
  Text *entry=NULL, *oldest=&d->text[0];
  for (size_t i=0;i<128;i++) {
    Text *t=&d->text[i];
    if (t->text && t->font==font && !strcmp(t->text,text)) { entry=t; break; }
    if (t->used < oldest->used) oldest=t;
  }
  if (!entry) {
    int width, height;
    if (TTF_SizeUTF8(d->fonts[font],text,&width,&height)!=0) return -1;
    if (width<1 || height<1 || width>16384 || height>16384 || (size_t)width*height>16u*1024u*1024u)
      return SDL_SetError("text raster is too large");
    SDL_Color white={255,255,255,255};
    SDL_Surface *original=TTF_RenderUTF8_Blended(d->fonts[font],text,white);
    if (!original) return -1;
    SDL_Surface *surface=SDL_ConvertSurfaceFormat(original,SDL_PIXELFORMAT_RGBA32,0);
    SDL_FreeSurface(original); if (!surface) return -1;
    size_t n=(size_t)surface->w*(size_t)surface->h*4;
    unsigned char *pixels=malloc(n); char *copy=malloc(length+1);
    if (!pixels || !copy) { free(pixels); free(copy); SDL_FreeSurface(surface); return SDL_OutOfMemory(); }
    memcpy(copy,text,length+1);
    for (int row=0;row<surface->h;row++) memcpy(pixels+(size_t)row*surface->w*4,
      (unsigned char *)surface->pixels+(size_t)row*surface->pitch,(size_t)surface->w*4);
    entry=oldest;
    if (entry->text) { free(entry->text); d->gl.DeleteTextures(1,&entry->texture); }
    d->gl.GenTextures(1,&entry->texture); d->gl.BindTexture(GL_TEXTURE_2D,entry->texture);
    d->gl.TexImage2D(GL_TEXTURE_2D,0,GL_RGBA,surface->w,surface->h,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
    d->gl.TexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    d->gl.TexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    d->gl.TexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    d->gl.TexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    entry->text=copy; entry->font=font; entry->width=surface->w; entry->height=surface->h;
    free(pixels); SDL_FreeSurface(surface);
  }
  entry->used=++d->clock;
  return quad(d,entry->texture,(float)x,(float)y,(float)entry->width,(float)entry->height,color);
}

int gx_sound(GXDevice *d, double frequency, double duration, double gain, int noise) {
  if (current(d)!=0) return -1;
  if (!isfinite(frequency) || !isfinite(duration) || !isfinite(gain) ||
      frequency<0 || frequency>20000 || duration<=0 || duration>2 || gain<0 || gain>1)
    return SDL_SetError("invalid sound parameters");
  if (!d->audio) {
    if (SDL_InitSubSystem(SDL_INIT_AUDIO)!=0) return -1;
    SDL_AudioSpec desired={0}, actual={0};
    desired.freq=44100; desired.format=AUDIO_F32SYS; desired.channels=1; desired.samples=1024;
    d->audio=SDL_OpenAudioDevice(NULL,0,&desired,&actual,0);
    if (!d->audio) return -1;
    d->audio_rate=actual.freq; d->noise_state=1;
    SDL_PauseAudioDevice(d->audio,0);
  }
  if (SDL_GetQueuedAudioSize(d->audio)>(Uint32)d->audio_rate*4) return 0;
  size_t n=(size_t)(duration*d->audio_rate);
  float *samples=malloc(n*sizeof *samples);
  if (!samples) return SDL_OutOfMemory();
  for (size_t i=0;i<n;i++) {
    double value;
    if (noise) { d->noise_state=d->noise_state*1664525u+1013904223u; value=(double)d->noise_state/2147483648.0-1.0; }
    else value=sin(6.283185307179586*frequency*(double)i/d->audio_rate);
    samples[i]=(float)(value*gain*(1.0-(double)i/n));
  }
  int result=SDL_QueueAudio(d->audio,samples,(Uint32)(n*sizeof *samples)); free(samples); return result;
}
