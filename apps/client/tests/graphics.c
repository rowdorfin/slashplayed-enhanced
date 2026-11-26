#include <assert.h>
#include "../spgraphics.h"

int main(void) {
    const char *original =
        "# SET graphicsSSAO \"4\" is a comment\r\n"
        "SET maxFPS \"99\"\r\n"
        "  set Maxfps\t\"120\"  \r\n"
        "SET useMaxFPS \"0\"\r\n"
        "SET graphicsSSAO \"3\"\r\n"
        "SET graphicsGroundClutter \"\"\r\n"
        "SET graphicsTextureResolution \"2\"\r\n"
        "SET uiScale \"0.8\"\r\n"
        "SET useUiScale \"1\"";
    char *backup = sp_graphics_backup(original);
    assert(backup && strstr(backup, "RenderScale\t-\n"));
    assert(strstr(backup, "graphicsGroundClutter\t+\n"));
    assert(strstr(backup, "maxFPS\t+120\n"));
    assert(!strstr(backup, "uiScale"));

    size_t applied, unchanged;
    char *performance = sp_graphics_edit(original, backup, SP_GRAPHICS_PERFORMANCE, false, &applied, &unchanged);
    assert(performance && applied == 7 && unchanged == 1);
    assert(strstr(performance, "\r\nSET maxFPS \"99\"\r\n  set Maxfps\t\"30\"  \r\n"));
    assert(strstr(performance, "\r\nSET RenderScale \"0.75\"\r\n"));
    assert(strstr(performance, "SET useMaxFPS \"0\"") == NULL);
    assert(strstr(performance, "SET graphicsTextureResolution \"2\"\r\nSET uiScale \"0.8\"\r\n"));
    assert(strstr(performance, "# SET graphicsSSAO \"4\" is a comment\r\n"));
    assert(performance[strlen(performance) - 1] == '"');

    char *again = sp_graphics_edit(performance, backup, SP_GRAPHICS_PERFORMANCE, false, &applied, &unchanged);
    assert(again && !strcmp(again, performance) && applied == 0 && unchanged == SP_GRAPHICS_COUNT);
    free(again);

    char *balanced = sp_graphics_edit(performance, backup, SP_GRAPHICS_BALANCED, false, &applied, &unchanged);
    assert(balanced && applied == 6 && unchanged == 2);
    assert(strstr(balanced, "SET RenderScale \"0.85\"") && strstr(balanced, "set Maxfps\t\"45\""));

    char *quality = sp_graphics_edit(balanced, backup, SP_GRAPHICS_QUALITY, true, &applied, &unchanged);
    assert(quality && !strstr(quality, "SET RenderScale") && !strstr(quality, "SET graphicsShadowQuality"));
    assert(strstr(quality, "SET useMaxFPS \"0\"") && strstr(quality, "set Maxfps\t\"60\""));
    char *qualityFirst = sp_graphics_edit(original, backup, SP_GRAPHICS_QUALITY, false, &applied, &unchanged);
    assert(qualityFirst && !strcmp(quality, qualityFirst) && applied == 1 && unchanged == 0);
    free(qualityFirst);

    char *restored = sp_graphics_edit(quality, backup, SP_GRAPHICS_KEEP, false, &applied, &unchanged);
    assert(restored && !strcmp(restored, original));
    free(restored);
    restored = sp_graphics_edit(performance, backup, SP_GRAPHICS_KEEP, false, &applied, &unchanged);
    assert(restored && !strcmp(restored, original));
    free(restored);
    assert(!sp_graphics_edit(performance, "# truncated", SP_GRAPHICS_KEEP, false, &applied, &unchanged));
    free(quality);
    free(balanced);
    free(performance);
    free(backup);

    const char *escaped = "SET maxFPS \"escaped \\\" quote\"\n";
    backup = sp_graphics_backup(escaped);
    performance = sp_graphics_edit(escaped, backup, SP_GRAPHICS_PERFORMANCE, false, &applied, &unchanged);
    restored = sp_graphics_edit(performance, backup, SP_GRAPHICS_KEEP, false, &applied, &unchanged);
    assert(restored && !strcmp(restored, escaped));
    free(restored);
    free(performance);
    free(backup);

    backup = sp_graphics_backup("");
    performance = sp_graphics_edit("", backup, SP_GRAPHICS_PERFORMANCE, false, &applied, &unchanged);
    assert(performance && applied == SP_GRAPHICS_COUNT && unchanged == 0);
    restored = sp_graphics_edit(performance, backup, SP_GRAPHICS_KEEP, false, &applied, &unchanged);
    assert(restored && !restored[0]);
    free(restored);
    free(performance);
    free(backup);

    SPWTFEdit seed = {.name = "playIntroMovie", .value = "99", .length = 2, .seed = true};
    char *seeded = sp_wtf_edit("# SET playIntroMovie \"1\"\n", &seed, 1);
    assert(seeded && seed.changed && strstr(seeded, "\nSET playIntroMovie \"99\"\n"));
    free(seeded);
    seed = (SPWTFEdit){.name = "playIntroMovie", .value = "99", .length = 2, .seed = true};
    seeded = sp_wtf_edit("set playintromovie \"1\"\r\n", &seed, 1);
    assert(seeded && !seed.changed && !strcmp(seeded, "set playintromovie \"1\"\r\n"));
    free(seeded);
    puts("graphics: presets, FPS gating, untouched lines, exact restore, invalid backup, and intro seeding passed");
}
