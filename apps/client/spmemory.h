// Independent Config.wtf overrides with one original line saved per CVar.
#ifndef SP_MEMORY_H
#define SP_MEMORY_H

#include "spgraphics.h"

enum {
    SP_MEMORY_ALLOCATOR, SP_MEMORY_LOW_PRIORITY, SP_MEMORY_CACHELESS,
    SP_MEMORY_PRELOAD_OBJECTS, SP_MEMORY_PRELOAD_TEXTURES, SP_MEMORY_COUNT
};

static const char *const sp_memory_names[SP_MEMORY_COUNT] = {
    [SP_MEMORY_ALLOCATOR] = "ThreadPoolPerThreadAllocator",
    [SP_MEMORY_LOW_PRIORITY] = "ThreadPoolLimitLP",
    [SP_MEMORY_CACHELESS] = "GxAllowCachelessShaderMode",
    [SP_MEMORY_PRELOAD_OBJECTS] = "worldPreloadNonCritical",
    [SP_MEMORY_PRELOAD_TEXTURES] = "worldPreloadHighResTextures",
};

static void sp_memory_choices(const char *choices[SP_MEMORY_COUNT], long allocator, long limit,
                              long cacheless, long preload) {
    choices[SP_MEMORY_ALLOCATOR] = allocator == 1 ? "0" : NULL;
    choices[SP_MEMORY_LOW_PRIORITY] = limit == 1 ? "1" : limit == 2 ? "2" : NULL;
    choices[SP_MEMORY_CACHELESS] = cacheless == 1 ? "1" : NULL;
    choices[SP_MEMORY_PRELOAD_OBJECTS] = preload == 1 ? "0" : NULL;
    choices[SP_MEMORY_PRELOAD_TEXTURES] = choices[SP_MEMORY_PRELOAD_OBJECTS];
}

static bool sp_memory_valid(size_t key, const char *request) {
    switch (key) {
    case SP_MEMORY_ALLOCATOR:
    case SP_MEMORY_PRELOAD_OBJECTS:
    case SP_MEMORY_PRELOAD_TEXTURES:
        return !strcmp(request, "0");
    case SP_MEMORY_LOW_PRIORITY:
        return !strcmp(request, "1") || !strcmp(request, "2");
    case SP_MEMORY_CACHELESS:
        return !strcmp(request, "1");
    default:
        return false;
    }
}

// A NULL request means client default. The launcher publishes a new snapshot before
// writing Config.wtf and retires it only after a successful restore.
static bool sp_memory_edit(const char *text, size_t key, const char *request, const char *saved,
                           char **output, char **snapshot) {
    *output = *snapshot = NULL;
    if (key >= SP_MEMORY_COUNT || (request && !sp_memory_valid(key, request))) return false;
    SPWTFEdit edit = {.name = sp_memory_names[key]};
    sp_wtf_find(text, &edit, 1);
    bool absent = saved && !strcmp(saved, "-");
    size_t savedLength = saved ? strlen(saved) : 0;
    const char *savedNewline = saved ? strchr(saved, '\n') : NULL;
    if (saved && !absent) {
        const char *value, *close;
        const char *end = savedNewline ? savedNewline : saved + savedLength;
        if ((savedNewline && savedNewline[1]) ||
            sp_wtf_line(saved, end, &edit, 1, &value, &close) != 0) return false;
    }

    if (request) {
        edit.value = request;
        edit.length = strlen(request);
        if (edit.last && edit.length == (size_t)(edit.end - edit.begin) &&
            !memcmp(edit.begin, request, edit.length)) return true;
        if (!saved) {
            const char *newline = edit.last ? strchr(edit.last, '\n') : NULL;
            size_t length = edit.last ? (newline ? (size_t)(newline + 1 - edit.last) : strlen(edit.last)) : 1;
            *snapshot = malloc(length + 1);
            if (!*snapshot) return false;
            memcpy(*snapshot, edit.last ? edit.last : "-", length);
            (*snapshot)[length] = '\0';
        }
        SPWTFEdit apply = {.name = edit.name, .value = request, .length = edit.length};
        *output = sp_wtf_edit(text, &apply, 1);
        return *output != NULL;
    }
    if (!saved) return true;
    if (absent) {
        if (!edit.last) return true;
        SPWTFEdit remove = {.name = edit.name, .remove = true};
        *output = sp_wtf_edit(text, &remove, 1);
        return *output != NULL;
    }

    const char *last = edit.last ? edit.last : text + strlen(text);
    const char *newline = strchr(last, '\n');
    const char *tail = newline ? newline + 1 : last + strlen(last);
    if (savedLength == (size_t)(tail - last) && !memcmp(last, saved, savedLength)) return true;
    *output = malloc(strlen(text) + savedLength + 2);
    if (!*output) return false;
    char *out = *output;
    memcpy(out, text, (size_t)(last - text));
    out += last - text;
    // An original unterminated line must be last, even if the client moved it.
    if (savedNewline) {
        if (!edit.last && out != *output && out[-1] != '\n') *out++ = '\n';
        memcpy(out, saved, savedLength);
        strcpy(out + savedLength, tail);
    } else {
        size_t tailLength = strlen(tail);
        memcpy(out, tail, tailLength);
        out += tailLength;
        if (out != *output && out[-1] != '\n') *out++ = '\n';
        strcpy(out, saved);
    }
    return true;
}
#endif
