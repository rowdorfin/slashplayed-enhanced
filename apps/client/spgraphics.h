// Config.wtf line editing shared by the launcher and the portable graphics tests.
#ifndef SP_GRAPHICS_H
#define SP_GRAPHICS_H

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum SPGraphicsPreset {
    SP_GRAPHICS_KEEP, SP_GRAPHICS_PERFORMANCE, SP_GRAPHICS_BALANCED, SP_GRAPHICS_QUALITY,
    SP_GRAPHICS_A16, SP_GRAPHICS_A16_LOW_MEMORY
};

static bool sp_graphics_is_a16(enum SPGraphicsPreset preset) {
    return preset == SP_GRAPHICS_A16 || preset == SP_GRAPHICS_A16_LOW_MEMORY;
}

typedef struct {
    const char *name;
    const char *value;
    size_t length;
    bool remove, seed;
    const char *last, *begin, *end;
    bool changed;
} SPWTFEdit;

static bool sp_wtf_space(char c) { return c == ' ' || c == '\t'; }

static bool sp_wtf_key(const char *start, size_t length, const char *name) {
    if (strlen(name) != length) return false;
    for (size_t i = 0; i < length; i++)
        if (tolower((unsigned char)start[i]) != tolower((unsigned char)name[i])) return false;
    return true;
}

static size_t sp_wtf_line(const char *start, const char *end, SPWTFEdit *edits, size_t count,
                          const char **value, const char **close) {
    const char *p = start;
    while (p < end && sp_wtf_space(*p)) p++;
    if (end - p < 4 || !sp_wtf_key(p, 3, "SET") || !sp_wtf_space(p[3])) return count;
    p += 4;
    while (p < end && sp_wtf_space(*p)) p++;
    const char *key = p;
    while (p < end && !sp_wtf_space(*p)) p++;
    size_t length = (size_t)(p - key);
    while (p < end && sp_wtf_space(*p)) p++;
    if (p == end || *p++ != '"') return count;
    *value = p;
    while (p < end && *p != '"') {
        if (*p == '\\' && end - p > 1) p++;
        p++;
    }
    if (p == end) return count;
    *close = p++;
    while (p < end && sp_wtf_space(*p)) p++;
    if (p < end && *p == '\r') p++;
    if (p != end) return count;
    for (size_t i = 0; i < count; i++)
        if (sp_wtf_key(key, length, edits[i].name)) return i;
    return count;
}

static void sp_wtf_find(const char *text, SPWTFEdit *edits, size_t count) {
    for (const char *line = text; *line;) {
        const char *newline = strchr(line, '\n');
        const char *end = newline ? newline : line + strlen(line);
        const char *value, *close;
        size_t i = sp_wtf_line(line, end, edits, count, &value, &close);
        if (i < count) {
            edits[i].last = line;
            edits[i].begin = value;
            edits[i].end = close;
        }
        line = newline ? newline + 1 : end;
    }
}

static char *sp_wtf_add_missing(char *out, const char *newline, SPWTFEdit *edits, size_t count) {
    for (size_t i = 0; i < count; i++) {
        SPWTFEdit *edit = &edits[i];
        if (edit->last || !edit->value || edit->remove) continue;
        out += sprintf(out, "SET %s \"", edit->name);
        memcpy(out, edit->value, edit->length);
        out += edit->length;
        out += sprintf(out, "\"%s", newline);
        edit->changed = true;
    }
    return out;
}

// Update the last assignment (the effective value), preserving earlier duplicates and line spelling.
// If the final line lacks a newline, insert new keys before it so a later removal restores that EOF.
static char *sp_wtf_edit(const char *text, SPWTFEdit *edits, size_t count) {
    sp_wtf_find(text, edits, count);
    size_t capacity = strlen(text) + 1;
    for (size_t i = 0; i < count; i++)
        if (edits[i].value) capacity += strlen(edits[i].name) + edits[i].length + 10;
    char *output = malloc(capacity);
    if (!output) return NULL;

    const char *firstNewline = strchr(text, '\n');
    const char *newlineStyle = firstNewline && firstNewline > text && firstNewline[-1] == '\r' ? "\r\n" : "\n";
    char *out = output;
    bool inserted = false;
    for (const char *line = text; *line;) {
        const char *newline = strchr(line, '\n');
        const char *end = newline ? newline : line + strlen(line);
        const char *next = newline ? newline + 1 : end;
        if (!newline) {
            out = sp_wtf_add_missing(out, newlineStyle, edits, count);
            inserted = true;
        }
        const char *value, *close;
        size_t i = sp_wtf_line(line, end, edits, count, &value, &close);
        SPWTFEdit *edit = i < count ? &edits[i] : NULL;
        if (edit && edit->remove) {
            edit->changed = true;
        } else if (edit && !edit->seed && edit->value && edit->last == line &&
                   (edit->length != (size_t)(close - value) || memcmp(value, edit->value, edit->length))) {
            memcpy(out, line, (size_t)(value - line));
            out += value - line;
            memcpy(out, edit->value, edit->length);
            out += edit->length;
            memcpy(out, close, (size_t)(next - close));
            out += next - close;
            edit->changed = true;
        } else {
            memcpy(out, line, (size_t)(next - line));
            out += next - line;
        }
        line = next;
    }
    if (!inserted) out = sp_wtf_add_missing(out, newlineStyle, edits, count);
    *out = '\0';
    return output;
}

// Gethe/wow-ui-source 1.60.1: G = Blizzard_SettingsDefinitions_Shared/Graphics.lua;
// O = Blizzard_Settings_Shared/Mainline/GraphicsOverrides.lua (both under Interface/AddOns).
// GetMinRenderScale() is a runtime query; use the existing iPhone seed of 0.5.
// G:1292-1305 exposes shadowrt only on non-Mac clients without secondary lighting.
// Neither UI file exposes shadowTextureSize or shadowMode.
static const struct { const char *name, *values[SP_GRAPHICS_A16_LOW_MEMORY]; } sp_graphics_cvars[] = {
    {"RenderScale",                 {"0.75", "0.85", NULL, "0.5", "0.5"}}, // G:877,895-899
    {"graphicsShadowQuality",       {"0", "2", NULL, "0", "0"}}, // O:7; G:137
    {"graphicsParticleDensity",     {"1", "2", NULL, "1", "1"}}, // O:12; G:179-196
    {"graphicsSSAO",                {"0", "1", NULL, "0", "0"}}, // O:13; G:201-208
    {"graphicsGroundClutter",       {"0", "4", NULL, "0", "0"}}, // O:29; G:441-443,491
    {"graphicsTextureResolution",   {"0", "1", NULL, "0", "0"}}, // O:19,67-74
    {"useMaxFPS",                   {"1", "1", NULL, "1", "1"}}, // G:1466-1469
    {"maxFPS",                      {"30", "45", "60", "30", "30"}}, // G:1471-1477
    {"graphicsLiquidDetail",        {NULL, NULL, NULL, "0", "0"}}, // O:8; G:161
    {"graphicsDepthEffects",        {NULL, NULL, NULL, "0", "0"}}, // O:14; G:216
    {"graphicsComputeEffects",      {NULL, NULL, NULL, "0", "0"}}, // O:15; G:227
    {"graphicsPBRLiquidDetail",     {NULL, NULL, NULL, "0", "0"}}, // O:9-11; G:172
    {"graphicsProjectedTextures",   {NULL, NULL, NULL, "0", "0"}}, // O:23; G:261
    {"graphicsViewDistance",        {NULL, NULL, NULL, "0", "0"}}, // O:27; G:441-443,489
    {"graphicsEnvironmentDetail",   {NULL, NULL, NULL, "0", "0"}}, // O:28; G:441-443,490
    {"textureFilteringMode",        {NULL, NULL, NULL, "0", "0"}}, // G:1275-1279
    {"ffxAntiAliasingMode",         {NULL, NULL, NULL, "0", "0"}}, // G:1032-1035,1085
    {"MSAAQuality",                 {NULL, NULL, NULL, "0", "0"}}, // G:1032-1035,1110
    {"RAIDsettingsEnabled",         {NULL, NULL, NULL, "0", "0"}}, // G:1,444-447
    {"useHighResTextures",          {NULL, NULL, NULL, NULL, "0"}}, // O:89-103
};
enum { SP_GRAPHICS_LEGACY_COUNT = 8, SP_GRAPHICS_ORIGINAL_A16_COUNT = 19 };
#define SP_GRAPHICS_COUNT (sizeof sp_graphics_cvars / sizeof sp_graphics_cvars[0])
#define SP_GRAPHICS_BACKUP_HEADER "# Slashplayed graphics backup v1\n"

static void sp_graphics_keys(SPWTFEdit *edits) {
    for (size_t i = 0; i < SP_GRAPHICS_COUNT; i++) edits[i].name = sp_graphics_cvars[i].name;
}

static char *sp_graphics_backup(const char *text, size_t count) {
    SPWTFEdit edits[SP_GRAPHICS_COUNT] = {0};
    sp_graphics_keys(edits);
    sp_wtf_find(text, edits, count);
    size_t capacity = sizeof SP_GRAPHICS_BACKUP_HEADER;
    for (size_t i = 0; i < count; i++) {
        capacity += strlen(edits[i].name) + 3;
        if (edits[i].last) capacity += (size_t)(edits[i].end - edits[i].begin);
    }
    char *backup = malloc(capacity);
    if (!backup) return NULL;
    char *out = backup + sprintf(backup, "%s", SP_GRAPHICS_BACKUP_HEADER);
    for (size_t i = 0; i < count; i++) {
        SPWTFEdit *edit = &edits[i];
        out += sprintf(out, "%s\t%c", edit->name, edit->last ? '+' : '-');
        if (edit->last) {
            size_t length = (size_t)(edit->end - edit->begin);
            memcpy(out, edit->begin, length);
            out += length;
        }
        *out++ = '\n';
    }
    *out = '\0';
    return backup;
}

static size_t sp_graphics_read_backup(const char *backup, SPWTFEdit *edits) {
    size_t header = sizeof SP_GRAPHICS_BACKUP_HEADER - 1;
    if (!backup || strncmp(backup, SP_GRAPHICS_BACKUP_HEADER, header)) return false;
    backup += header;
    for (size_t i = 0; i < SP_GRAPHICS_COUNT; i++) {
        if (!*backup && (i == SP_GRAPHICS_LEGACY_COUNT || i == SP_GRAPHICS_ORIGINAL_A16_COUNT)) return i;
        SPWTFEdit *edit = &edits[i];
        size_t name = strlen(edit->name);
        if (strncmp(backup, edit->name, name) || backup[name] != '\t') return false;
        backup += name + 1;
        const char *end = strchr(backup, '\n');
        if (!end) return false;
        if (*backup == '+' && end > backup) {
            edit->value = backup + 1;
            edit->length = (size_t)(end - edit->value);
            for (const char *p = edit->value; p < end; p++) {
                if (*p == '\\' && end - p > 1) p++;
                else if (*p == '"' || *p == '\\' || *p == '\r') return false;
            }
        } else if (*backup == '-' && end == backup + 1) {
            edit->remove = true;
        } else {
            return false;
        }
        backup = end + 1;
    }
    return *backup ? 0 : SP_GRAPHICS_COUNT;
}

// Append keys added since the snapshot, keeping the original saved values.
static char *sp_graphics_expand_backup(const char *backup, const char *text) {
    SPWTFEdit edits[SP_GRAPHICS_COUNT] = {0};
    sp_graphics_keys(edits);
    size_t count = sp_graphics_read_backup(backup, edits);
    if (!count || count == SP_GRAPHICS_COUNT) return NULL;
    char *full = sp_graphics_backup(text, SP_GRAPHICS_COUNT);
    if (!full) return NULL;
    const char *suffix = full + sizeof SP_GRAPHICS_BACKUP_HEADER - 1;
    for (size_t i = 0; i < count; i++) suffix = strchr(suffix, '\n') + 1;
    char *expanded = malloc(strlen(backup) + strlen(suffix) + 1);
    if (expanded) sprintf(expanded, "%s%s", backup, suffix);
    free(full);
    return expanded;
}

static char *sp_graphics_edit(const char *text, const char *backup, enum SPGraphicsPreset preset,
                              bool restoreBaseline, bool restoreA16, size_t *applied, size_t *unchanged) {
    SPWTFEdit edits[SP_GRAPHICS_COUNT] = {0};
    sp_graphics_keys(edits);
    size_t count = sp_graphics_read_backup(backup, edits);
    if (!count || (sp_graphics_is_a16(preset) && count <
                   (preset == SP_GRAPHICS_A16 ? SP_GRAPHICS_ORIGINAL_A16_COUNT : SP_GRAPHICS_COUNT))) return NULL;
    for (size_t i = 0; i < count && preset != SP_GRAPHICS_KEEP; i++) {
        const char *value = sp_graphics_cvars[i].values[preset - 1];
        if (value || !(i < SP_GRAPHICS_LEGACY_COUNT ? restoreBaseline : restoreA16)) {
            edits[i].value = value;
            edits[i].length = value ? strlen(value) : 0;
            edits[i].remove = false;
        }
    }
    char *output = sp_wtf_edit(text, edits, count);
    if (!output) return NULL;
    *applied = *unchanged = 0;
    for (size_t i = 0; i < count; i++) {
        if (edits[i].changed) (*applied)++;
        else if (edits[i].value || edits[i].remove) (*unchanged)++;
    }
    return output;
}
#endif
