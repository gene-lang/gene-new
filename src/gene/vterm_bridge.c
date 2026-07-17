#include "vterm_bridge.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "vterm.h"

typedef struct {
  int cols;
  VTermScreenCell *cells;
} GeneVTermScrollLine;

struct GeneVTerm {
  VTerm *vt;
  VTermState *state;
  VTermScreen *screen;
  int rows;
  int cols;
  uint64_t generation;
  int cursor_row;
  int cursor_col;
  int cursor_visible;
  int altscreen;
  int mouse_mode;
  int focus_reporting;
  char title[256];
  size_t title_len;
  char working_directory_uri[1024];
  size_t working_directory_uri_len;
  GeneVTermScrollLine *scrollback;
  int scrollback_capacity;
  int scrollback_start;
  int scrollback_count;
  uint64_t scrollback_dropped;
};

static int gene_vterm_damage(VTermRect rect, void *user) {
  GeneVTerm *term = user;
  (void)rect;
  term->generation++;
  return 1;
}

static int gene_vterm_moverect(VTermRect dest, VTermRect src, void *user) {
  GeneVTerm *term = user;
  (void)dest;
  (void)src;
  term->generation++;
  return 1;
}

static int gene_vterm_movecursor(VTermPos pos, VTermPos oldpos, int visible,
                                 void *user) {
  GeneVTerm *term = user;
  (void)oldpos;
  term->cursor_row = pos.row;
  term->cursor_col = pos.col;
  term->cursor_visible = visible != 0;
  term->generation++;
  return 1;
}

static int gene_vterm_settermprop(VTermProp prop, VTermValue *value,
                                  void *user) {
  GeneVTerm *term = user;
  switch (prop) {
  case VTERM_PROP_CURSORVISIBLE:
    term->cursor_visible = value->boolean != 0;
    break;
  case VTERM_PROP_ALTSCREEN:
    term->altscreen = value->boolean != 0;
    break;
  case VTERM_PROP_MOUSE:
    term->mouse_mode = value->number;
    break;
  case VTERM_PROP_FOCUSREPORT:
    term->focus_reporting = value->boolean != 0;
    break;
  case VTERM_PROP_TITLE:
    if (value->string.initial)
      term->title_len = 0;
    if (value->string.str != NULL && value->string.len > 0 &&
        term->title_len < sizeof(term->title) - 1) {
      size_t available = sizeof(term->title) - 1 - term->title_len;
      size_t copied = value->string.len < available ? value->string.len
                                                    : available;
      memcpy(term->title + term->title_len, value->string.str, copied);
      term->title_len += copied;
    }
    if (value->string.final || term->title_len == sizeof(term->title) - 1)
      term->title[term->title_len] = '\0';
    break;
  default:
    break;
  }
  term->generation++;
  return 1;
}

static int gene_vterm_bell(void *user) {
  GeneVTerm *term = user;
  term->generation++;
  return 1;
}

static int gene_vterm_fallback_osc(int command, VTermStringFragment frag,
                                   void *user) {
  GeneVTerm *term = user;
  if (command != 7)
    return 0;
  if (frag.initial)
    term->working_directory_uri_len = 0;
  if (frag.str != NULL && frag.len > 0 &&
      term->working_directory_uri_len <
          sizeof(term->working_directory_uri) - 1) {
    size_t available = sizeof(term->working_directory_uri) - 1 -
                       term->working_directory_uri_len;
    size_t copied = frag.len < available ? frag.len : available;
    memcpy(term->working_directory_uri + term->working_directory_uri_len,
           frag.str, copied);
    term->working_directory_uri_len += copied;
  }
  if (frag.final || term->working_directory_uri_len ==
                        sizeof(term->working_directory_uri) - 1)
    term->working_directory_uri[term->working_directory_uri_len] = '\0';
  term->generation++;
  return 1;
}

static const VTermStateFallbacks gene_vterm_fallbacks = {
    .osc = gene_vterm_fallback_osc,
};

static int gene_vterm_screen_resize(int rows, int cols, void *user) {
  GeneVTerm *term = user;
  term->rows = rows;
  term->cols = cols;
  term->generation++;
  return 1;
}

static void gene_vterm_free_scroll_line(GeneVTermScrollLine *line) {
  free(line->cells);
  line->cells = NULL;
  line->cols = 0;
}

static int gene_vterm_sb_pushline(int cols, const VTermScreenCell *cells,
                                  void *user) {
  GeneVTerm *term = user;
  if (term->scrollback_capacity <= 0)
    return 1;

  VTermScreenCell *copy = calloc((size_t)cols, sizeof(*copy));
  if (copy == NULL)
    return 0;
  memcpy(copy, cells, (size_t)cols * sizeof(*copy));

  int index;
  if (term->scrollback_count == term->scrollback_capacity) {
    index = term->scrollback_start;
    gene_vterm_free_scroll_line(&term->scrollback[index]);
    term->scrollback_start =
        (term->scrollback_start + 1) % term->scrollback_capacity;
    term->scrollback_dropped++;
  } else {
    index = (term->scrollback_start + term->scrollback_count) %
            term->scrollback_capacity;
    term->scrollback_count++;
  }
  term->scrollback[index].cols = cols;
  term->scrollback[index].cells = copy;
  term->generation++;
  return 1;
}

static int gene_vterm_sb_popline(int cols, VTermScreenCell *cells, void *user) {
  GeneVTerm *term = user;
  if (term->scrollback_count <= 0)
    return 0;

  int index = (term->scrollback_start + term->scrollback_count - 1) %
              term->scrollback_capacity;
  GeneVTermScrollLine *line = &term->scrollback[index];
  int copied = cols < line->cols ? cols : line->cols;
  memcpy(cells, line->cells, (size_t)copied * sizeof(*cells));
  if (copied < cols)
    memset(cells + copied, 0, (size_t)(cols - copied) * sizeof(*cells));
  gene_vterm_free_scroll_line(line);
  term->scrollback_count--;
  term->generation++;
  return 1;
}

static int gene_vterm_sb_clear(void *user) {
  GeneVTerm *term = user;
  for (int i = 0; i < term->scrollback_count; i++) {
    int index = (term->scrollback_start + i) % term->scrollback_capacity;
    gene_vterm_free_scroll_line(&term->scrollback[index]);
  }
  term->scrollback_start = 0;
  term->scrollback_count = 0;
  term->generation++;
  return 1;
}

static const VTermScreenCallbacks gene_vterm_callbacks = {
    .damage = gene_vterm_damage,
    .moverect = gene_vterm_moverect,
    .movecursor = gene_vterm_movecursor,
    .settermprop = gene_vterm_settermprop,
    .bell = gene_vterm_bell,
    .resize = gene_vterm_screen_resize,
    .sb_pushline = gene_vterm_sb_pushline,
    .sb_popline = gene_vterm_sb_popline,
    .sb_clear = gene_vterm_sb_clear,
};

GeneVTerm *gene_vterm_new(int rows, int cols, int scrollback_lines) {
  if (rows <= 0 || cols <= 0 || scrollback_lines < 0)
    return NULL;
  GeneVTerm *term = calloc(1, sizeof(*term));
  if (term == NULL)
    return NULL;
  if (scrollback_lines > 0) {
    term->scrollback =
        calloc((size_t)scrollback_lines, sizeof(*term->scrollback));
    if (term->scrollback == NULL) {
      free(term);
      return NULL;
    }
  }
  term->scrollback_capacity = scrollback_lines;
  term->rows = rows;
  term->cols = cols;
  term->cursor_visible = 1;
  term->vt = vterm_new(rows, cols);
  if (term->vt == NULL) {
    free(term->scrollback);
    free(term);
    return NULL;
  }
  vterm_set_utf8(term->vt, 1);
  term->state = vterm_obtain_state(term->vt);
  term->screen = vterm_obtain_screen(term->vt);
  vterm_screen_set_callbacks(term->screen, &gene_vterm_callbacks, term);
  vterm_screen_set_unrecognised_fallbacks(term->screen,
                                          &gene_vterm_fallbacks, term);
  vterm_screen_set_damage_merge(term->screen, VTERM_DAMAGE_SCROLL);
  vterm_screen_enable_altscreen(term->screen, 1);
  vterm_screen_enable_reflow(term->screen, true);
  vterm_screen_reset(term->screen, 1);
  return term;
}

void gene_vterm_free(GeneVTerm *term) {
  if (term == NULL)
    return;
  gene_vterm_sb_clear(term);
  free(term->scrollback);
  vterm_free(term->vt);
  free(term);
}

void gene_vterm_feed(GeneVTerm *term, const char *bytes, size_t len) {
  if (term == NULL || bytes == NULL || len == 0)
    return;
  vterm_input_write(term->vt, bytes, len);
  vterm_screen_flush_damage(term->screen);
}

void gene_vterm_resize(GeneVTerm *term, int rows, int cols) {
  if (term == NULL || rows <= 0 || cols <= 0)
    return;
  if (rows == term->rows && cols == term->cols)
    return;
  vterm_set_size(term->vt, rows, cols);
  vterm_screen_flush_damage(term->screen);
}

size_t gene_vterm_output_read(GeneVTerm *term, char *buffer, size_t len) {
  if (term == NULL || buffer == NULL || len == 0)
    return 0;
  return vterm_output_read(term->vt, buffer, len);
}

int gene_vterm_rows(const GeneVTerm *term) { return term ? term->rows : 0; }
int gene_vterm_cols(const GeneVTerm *term) { return term ? term->cols : 0; }
uint64_t gene_vterm_generation(const GeneVTerm *term) {
  return term ? term->generation : 0;
}
int gene_vterm_cursor_row(const GeneVTerm *term) {
  return term ? term->cursor_row : 0;
}
int gene_vterm_cursor_col(const GeneVTerm *term) {
  return term ? term->cursor_col : 0;
}
int gene_vterm_cursor_visible(const GeneVTerm *term) {
  return term ? term->cursor_visible : 0;
}
int gene_vterm_altscreen(const GeneVTerm *term) {
  return term ? term->altscreen : 0;
}
int gene_vterm_mouse_mode(const GeneVTerm *term) {
  return term ? term->mouse_mode : 0;
}
int gene_vterm_focus_reporting(const GeneVTerm *term) {
  return term ? term->focus_reporting : 0;
}
const char *gene_vterm_title(const GeneVTerm *term) {
  return term ? term->title : "";
}
const char *gene_vterm_working_directory_uri(const GeneVTerm *term) {
  return term ? term->working_directory_uri : "";
}

static void gene_vterm_flatten_cell(const VTermScreen *screen,
                                    const VTermScreenCell *source,
                                    int continuation,
                                    GeneVTermCell *target) {
  memset(target, 0, sizeof(*target));
  memcpy(target->chars, source->chars, sizeof(target->chars));
  target->width = source->width;
  target->continuation = continuation != 0;
  target->bold = source->attrs.bold;
  target->dim = source->attrs.dim;
  target->underline = source->attrs.underline;
  target->italic = source->attrs.italic;
  target->blink = source->attrs.blink;
  target->reverse = source->attrs.reverse;
  target->conceal = source->attrs.conceal;
  target->strike = source->attrs.strike;

  VTermColor fg = source->fg;
  VTermColor bg = source->bg;
  target->fg_default = VTERM_COLOR_IS_DEFAULT_FG(&fg) != 0;
  target->bg_default = VTERM_COLOR_IS_DEFAULT_BG(&bg) != 0;
  vterm_screen_convert_color_to_rgb(screen, &fg);
  vterm_screen_convert_color_to_rgb(screen, &bg);
  target->fg_red = fg.rgb.red;
  target->fg_green = fg.rgb.green;
  target->fg_blue = fg.rgb.blue;
  target->bg_red = bg.rgb.red;
  target->bg_green = bg.rgb.green;
  target->bg_blue = bg.rgb.blue;
}

int gene_vterm_get_cell(const GeneVTerm *term, int row, int col,
                        GeneVTermCell *cell) {
  if (term == NULL || cell == NULL || row < 0 || row >= term->rows || col < 0 ||
      col >= term->cols)
    return 0;
  VTermScreenCell source;
  if (!vterm_screen_get_cell(term->screen, (VTermPos){.row = row, .col = col},
                             &source))
    return 0;
  int continuation = 0;
  if (col > 0) {
    VTermScreenCell previous;
    if (vterm_screen_get_cell(term->screen,
                              (VTermPos){.row = row, .col = col - 1},
                              &previous) &&
        previous.width > 1)
      continuation = 1;
  }
  gene_vterm_flatten_cell(term->screen, &source, continuation, cell);
  return 1;
}

int gene_vterm_scrollback_count(const GeneVTerm *term) {
  return term ? term->scrollback_count : 0;
}

static const GeneVTermScrollLine *gene_vterm_scrollback_line(
    const GeneVTerm *term, int line) {
  if (term == NULL || line < 0 || line >= term->scrollback_count)
    return NULL;
  int index = (term->scrollback_start + line) % term->scrollback_capacity;
  return &term->scrollback[index];
}

int gene_vterm_scrollback_cols(const GeneVTerm *term, int line) {
  const GeneVTermScrollLine *entry = gene_vterm_scrollback_line(term, line);
  return entry ? entry->cols : 0;
}

int gene_vterm_get_scrollback_cell(const GeneVTerm *term, int line, int col,
                                   GeneVTermCell *cell) {
  const GeneVTermScrollLine *entry = gene_vterm_scrollback_line(term, line);
  if (entry == NULL || cell == NULL || col < 0 || col >= entry->cols)
    return 0;
  int continuation = col > 0 && entry->cells[col - 1].width > 1;
  gene_vterm_flatten_cell(term->screen, &entry->cells[col], continuation,
                          cell);
  return 1;
}

uint64_t gene_vterm_scrollback_dropped(const GeneVTerm *term) {
  return term ? term->scrollback_dropped : 0;
}

void gene_vterm_key(GeneVTerm *term, int key, int modifiers) {
  if (term != NULL)
    vterm_keyboard_key(term->vt, (VTermKey)key, (VTermModifier)modifiers);
}
void gene_vterm_unichar(GeneVTerm *term, uint32_t codepoint, int modifiers) {
  if (term != NULL)
    vterm_keyboard_unichar(term->vt, codepoint, (VTermModifier)modifiers);
}
void gene_vterm_paste_start(GeneVTerm *term) {
  if (term != NULL)
    vterm_keyboard_start_paste(term->vt);
}
void gene_vterm_paste_end(GeneVTerm *term) {
  if (term != NULL)
    vterm_keyboard_end_paste(term->vt);
}
void gene_vterm_mouse_move(GeneVTerm *term, int row, int col, int modifiers) {
  if (term != NULL)
    vterm_mouse_move(term->vt, row, col, (VTermModifier)modifiers);
}
void gene_vterm_mouse_button(GeneVTerm *term, int button, int pressed,
                             int modifiers) {
  if (term != NULL)
    vterm_mouse_button(term->vt, button, pressed != 0,
                       (VTermModifier)modifiers);
}
void gene_vterm_focus_in(GeneVTerm *term) {
  if (term != NULL)
    vterm_state_focus_in(term->state);
}
void gene_vterm_focus_out(GeneVTerm *term) {
  if (term != NULL)
    vterm_state_focus_out(term->state);
}
