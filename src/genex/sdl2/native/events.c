#include <SDL.h>
#include <stdlib.h>

SDL_Event *gx_event_new(void) { return calloc(1,sizeof(SDL_Event)); }
unsigned gx_event_type(SDL_Event *e) { return e->type; }
int gx_event_key(SDL_Event *e) { return e->type==SDL_KEYDOWN || e->type==SDL_KEYUP ? e->key.keysym.sym : 0; }
int gx_event_repeat(SDL_Event *e) { return e->type==SDL_KEYDOWN ? e->key.repeat : 0; }
int gx_event_button(SDL_Event *e) { return e->type==SDL_MOUSEBUTTONDOWN || e->type==SDL_MOUSEBUTTONUP ? e->button.button : 0; }
int gx_event_x(SDL_Event *e) { return e->type==SDL_MOUSEMOTION ? e->motion.x : e->button.x; }
int gx_event_y(SDL_Event *e) { return e->type==SDL_MOUSEMOTION ? e->motion.y : e->button.y; }
int gx_event_dx(SDL_Event *e) { return e->type==SDL_MOUSEMOTION ? e->motion.xrel : 0; }
int gx_event_dy(SDL_Event *e) { return e->type==SDL_MOUSEMOTION ? e->motion.yrel : 0; }
double gx_event_wheel(SDL_Event *e) { return e->type==SDL_MOUSEWHEEL ? e->wheel.preciseY : 0; }
int gx_push_key(int key, int down) {
  SDL_Event e={0}; e.type=down ? SDL_KEYDOWN : SDL_KEYUP; e.key.keysym.sym=key;
  return SDL_PushEvent(&e);
}
int gx_push_button(int button, int down, int x, int y) {
  SDL_Event e={0}; e.type=down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
  e.button.button=(Uint8)button; e.button.x=x; e.button.y=y; return SDL_PushEvent(&e);
}
int gx_push_motion(int x, int y, int dx, int dy) {
  SDL_Event e={0}; e.type=SDL_MOUSEMOTION; e.motion.x=x; e.motion.y=y;
  e.motion.xrel=dx; e.motion.yrel=dy; return SDL_PushEvent(&e);
}
