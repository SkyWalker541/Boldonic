#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* Boldonic Reading - Word Highlighting Engine
 * Bolds the first portion of each word to aid reading speed.
 * Written in C for maximum portability and small binary size.
 */

static int bold_ratio = 40;

static int is_word_start(const char *s, int *char_len) {
    unsigned char c = (unsigned char)s[0];
    
    /* ASCII letters */
    if (c >= 'A' && c <= 'Z') { *char_len = 1; return 1; }
    if (c >= 'a' && c <= 'z') { *char_len = 1; return 1; }
    
    /* UTF-8 multi-byte sequences */
    if ((c & 0xE0) == 0xC0) { 
        *char_len = 2; 
        /* Check for Latin Extended (0xC0-0xDF followed by 0x80-0xBF) */
        if (c >= 0xC0 && c <= 0xDF) return 1;
        return 0;
    }
    if ((c & 0xF0) == 0xE0) { 
        *char_len = 3; 
        /* Cyrillic (0xD0-0xD1), Latin Extended Additional (0x1E) */
        if (c == 0xD0 || c == 0xD1) return 1;
        if (c == 0xC4 || c == 0xC5) return 1; /* Ä, Å */
        return 0;
    }
    if ((c & 0xF8) == 0xF0) { 
        *char_len = 4; 
        return 0;  /* No 4-byte word chars for now */
    }
    
    *char_len = 1;
    return 0;
}

static int is_word_cont(const char *s, int *char_len) {
    unsigned char c = (unsigned char)s[0];
    
    /* ASCII letters */
    if (c >= 'A' && c <= 'Z') { *char_len = 1; return 1; }
    if (c >= 'a' && c <= 'z') { *char_len = 1; return 1; }
    
    /* UTF-8 continuation bytes (10xxxxxx) */
    if ((c & 0xC0) == 0x80) {
        *char_len = 1;
        return 1;
    }
    
    /* UTF-8 lead bytes for word characters */
    int clen;
    if (is_word_start(s, &clen)) {
        *char_len = clen;
        return 1;
    }
    
    *char_len = 1;
    return 0;
}

static int get_utf8_char_len(unsigned char c) {
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if ((c & 0xF8) == 0xF0) return 4;
    return 1;
}

static char *result_buf = NULL;
static int result_cap = 0;

static void ensure_result(int need) {
    if (need >= result_cap) {
        result_cap = need + 65536;
        result_buf = realloc(result_buf, result_cap);
    }
}

static void process_line(const char *line) {
    int len = strlen(line);
    int i = 0;
    int in_tag = 0;
    int in_decl = 0;
    int rpos = 0;

    ensure_result(len * 3 + 256);
    result_buf[0] = '\0';
    
    while (i < len) {
        char c = line[i];
        
        /* Handle declarations (<?xml ... ?>) */
        if (in_decl) {
            ensure_result(rpos + 2);
            result_buf[rpos++] = c;
            if (c == '>' && i > 0 && line[i-1] == '?') {
                in_decl = 0;
            }
            i++;
            continue;
        }
        
        /* Handle tags */
        if (in_tag) {
            ensure_result(rpos + 2);
            result_buf[rpos++] = c;
            if (c == '>') {
                in_tag = 0;
            }
            i++;
            continue;
        }
        
        /* Detect start of tag or declaration */
        if (c == '<') {
            ensure_result(rpos + 2);
            if (i+1 < len && line[i+1] == '?') {
                in_decl = 1;
            } else {
                in_tag = 1;
            }
            result_buf[rpos++] = c;
            i++;
            continue;
        }
        
        /* Check for start of word */
        int clen;
        if (is_word_start(line + i, &clen)) {
            /* Collect word */
            char word[2048];
            int wlen = 0;
            int wbytes = 0;
            
            while (i < len) {
                int next_clen;
                if (is_word_cont(line + i, &next_clen)) {
                    memcpy(word + wbytes, line + i, next_clen);
                    wbytes += next_clen;
                    i += next_clen;
                    wlen++; /* count characters, not bytes */
                } else {
                    break;
                }
            }
            word[wbytes] = '\0';
            
            /* Calculate bold count (in characters, not bytes) */
            int bold_count;
            if (wlen <= 2) {
                bold_count = 1;
            } else {
                bold_count = (int)(wlen * bold_ratio / 100.0 + 0.5);
                if (bold_count < 1) bold_count = 1;
                if (bold_count >= wlen) bold_count = wlen - 1;
            }
            
            /* Find byte position for bold_count characters */
            int bold_byte_pos = 0;
            int chars_seen = 0;
            int pos = 0;
            while (pos < wbytes && chars_seen < bold_count) {
                int charlen = get_utf8_char_len((unsigned char)word[pos]);
                pos += charlen;
                chars_seen++;
            }
            bold_byte_pos = pos;
            
            /* Output: <b>bold_part</b>normal_part */
            ensure_result(rpos + wbytes + 32);
            result_buf[rpos++] = '<';
            result_buf[rpos++] = 'b';
            result_buf[rpos++] = '>';
            memcpy(result_buf + rpos, word, bold_byte_pos);
            rpos += bold_byte_pos;
            result_buf[rpos++] = '<';
            result_buf[rpos++] = '/';
            result_buf[rpos++] = 'b';
            result_buf[rpos++] = '>';
            memcpy(result_buf + rpos, word + bold_byte_pos, wbytes - bold_byte_pos);
            rpos += wbytes - bold_byte_pos;
        } else {
            ensure_result(rpos + 2);
            result_buf[rpos++] = c;
            i++;
        }
    }
    
    result_buf[rpos] = '\0';
    printf("%s", result_buf);
}

int main(int argc, char *argv[]) {
    if (argc > 1) {
        bold_ratio = atoi(argv[1]);
        if (bold_ratio < 10 || bold_ratio > 90) {
            bold_ratio = 40;
        }
    }
    
    char *line = NULL;
    size_t len = 0;
    ssize_t nread;
    
    while ((nread = getline(&line, &len, stdin)) != -1) {
        /* Remove trailing newline */
        if (nread > 0 && line[nread-1] == '\n') {
            line[nread-1] = '\0';
        }
        process_line(line);
        putchar('\n');
    }
    
    free(line);
    free(result_buf);
    return 0;
}