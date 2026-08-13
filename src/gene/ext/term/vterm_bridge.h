#ifndef GENE_VTERM_BRIDGE_H
#define GENE_VTERM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GENE_VTERM_MAX_CHARS 6

typedef struct GeneVTerm GeneVTerm;

typedef struct {
  uint32_t chars[GENE_VTERM_MAX_CHARS];
  uint8_t width;
  uint8_t continuation;
  uint8_t bold;
  uint8_t dim;
  uint8_t underline;
  uint8_t italic;
  uint8_t blink;
  uint8_t reverse;
  uint8_t conceal;
  uint8_t strike;
  uint8_t fg_default;
  uint8_t fg_red;
  uint8_t fg_green;
  uint8_t fg_blue;
  uint8_t bg_default;
  uint8_t bg_red;
  uint8_t bg_green;
  uint8_t bg_blue;
} GeneVTermCell;

GeneVTerm *gene_vterm_new(int rows, int cols, int scrollback_lines);
void gene_vterm_free(GeneVTerm *term);
void gene_vterm_feed(GeneVTerm *term, const char *bytes, size_t len);
void gene_vterm_resize(GeneVTerm *term, int rows, int cols);
size_t gene_vterm_output_read(GeneVTerm *term, char *buffer, size_t len);

int gene_vterm_rows(const GeneVTerm *term);
int gene_vterm_cols(const GeneVTerm *term);
uint64_t gene_vterm_generation(const GeneVTerm *term);
int gene_vterm_cursor_row(const GeneVTerm *term);
int gene_vterm_cursor_col(const GeneVTerm *term);
int gene_vterm_cursor_visible(const GeneVTerm *term);
int gene_vterm_altscreen(const GeneVTerm *term);
int gene_vterm_mouse_mode(const GeneVTerm *term);
int gene_vterm_focus_reporting(const GeneVTerm *term);
const char *gene_vterm_title(const GeneVTerm *term);
const char *gene_vterm_working_directory_uri(const GeneVTerm *term);
int gene_vterm_get_cell(const GeneVTerm *term, int row, int col,
                        GeneVTermCell *cell);

int gene_vterm_scrollback_count(const GeneVTerm *term);
int gene_vterm_scrollback_cols(const GeneVTerm *term, int line);
int gene_vterm_get_scrollback_cell(const GeneVTerm *term, int line, int col,
                                   GeneVTermCell *cell);
uint64_t gene_vterm_scrollback_dropped(const GeneVTerm *term);

void gene_vterm_key(GeneVTerm *term, int key, int modifiers);
void gene_vterm_unichar(GeneVTerm *term, uint32_t codepoint, int modifiers);
void gene_vterm_paste_start(GeneVTerm *term);
void gene_vterm_paste_end(GeneVTerm *term);
void gene_vterm_mouse_move(GeneVTerm *term, int row, int col, int modifiers);
void gene_vterm_mouse_button(GeneVTerm *term, int button, int pressed,
                             int modifiers);
void gene_vterm_focus_in(GeneVTerm *term);
void gene_vterm_focus_out(GeneVTerm *term);

#ifdef __cplusplus
}
#endif

#endif
