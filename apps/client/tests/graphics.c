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
    char *backup = sp_graphics_backup(original, SP_GRAPHICS_LEGACY_COUNT);
    assert(backup && strstr(backup, "RenderScale\t-\n"));
    assert(strstr(backup, "graphicsGroundClutter\t+\n"));
    assert(strstr(backup, "maxFPS\t+120\n"));
    assert(!strstr(backup, "uiScale"));

    size_t applied, unchanged;
    char *performance = sp_graphics_edit(original, backup, SP_GRAPHICS_PERFORMANCE, false, false, &applied, &unchanged);
    assert(performance && applied == 8 && unchanged == 0);
    assert(strstr(performance, "\r\nSET maxFPS \"99\"\r\n  set Maxfps\t\"30\"  \r\n"));
    assert(strstr(performance, "\r\nSET RenderScale \"0.75\"\r\n"));
    assert(strstr(performance, "SET useMaxFPS \"0\"") == NULL);
    assert(strstr(performance, "SET graphicsTextureResolution \"0\"\r\nSET uiScale \"0.8\"\r\n"));
    assert(strstr(performance, "# SET graphicsSSAO \"4\" is a comment\r\n"));
    assert(performance[strlen(performance) - 1] == '"');

    char *again = sp_graphics_edit(performance, backup, SP_GRAPHICS_PERFORMANCE, false, false, &applied, &unchanged);
    assert(again && !strcmp(again, performance) && applied == 0 && unchanged == SP_GRAPHICS_LEGACY_COUNT);
    free(again);

    char *balanced = sp_graphics_edit(performance, backup, SP_GRAPHICS_BALANCED, false, false, &applied, &unchanged);
    assert(balanced && applied == 7 && unchanged == 1);
    assert(strstr(balanced, "SET RenderScale \"0.85\"") && strstr(balanced, "set Maxfps\t\"45\""));

    char *quality = sp_graphics_edit(balanced, backup, SP_GRAPHICS_QUALITY, true, false, &applied, &unchanged);
    assert(quality && !strstr(quality, "SET RenderScale") && !strstr(quality, "SET graphicsShadowQuality"));
    assert(strstr(quality, "SET useMaxFPS \"0\"") && strstr(quality, "set Maxfps\t\"60\""));
    char *qualityFirst = sp_graphics_edit(original, backup, SP_GRAPHICS_QUALITY, false, false, &applied, &unchanged);
    assert(qualityFirst && !strcmp(quality, qualityFirst) && applied == 1 && unchanged == 0);
    free(qualityFirst);

    char *restored = sp_graphics_edit(quality, backup, SP_GRAPHICS_KEEP, false, false, &applied, &unchanged);
    assert(restored && !strcmp(restored, original));
    free(restored);
    restored = sp_graphics_edit(performance, backup, SP_GRAPHICS_KEEP, false, false, &applied, &unchanged);
    assert(restored && !strcmp(restored, original));
    free(restored);
    assert(!sp_graphics_edit(performance, "# truncated", SP_GRAPHICS_KEEP, false, false, &applied, &unchanged));
    free(quality);
    free(balanced);
    free(performance);
    free(backup);

    const char *escaped = "SET maxFPS \"escaped \\\" quote\"\n";
    backup = sp_graphics_backup(escaped, SP_GRAPHICS_LEGACY_COUNT);
    performance = sp_graphics_edit(escaped, backup, SP_GRAPHICS_PERFORMANCE, false, false, &applied, &unchanged);
    restored = sp_graphics_edit(performance, backup, SP_GRAPHICS_KEEP, false, false, &applied, &unchanged);
    assert(restored && !strcmp(restored, escaped));
    free(restored);
    free(performance);
    free(backup);

    backup = sp_graphics_backup("", SP_GRAPHICS_LEGACY_COUNT);
    performance = sp_graphics_edit("", backup, SP_GRAPHICS_PERFORMANCE, false, false, &applied, &unchanged);
    assert(performance && applied == SP_GRAPHICS_LEGACY_COUNT && unchanged == 0);
    restored = sp_graphics_edit(performance, backup, SP_GRAPHICS_KEEP, false, false, &applied, &unchanged);
    assert(restored && !restored[0]);
    free(restored);
    free(performance);
    free(backup);

    const char *a16Original = "SET graphicsViewDistance \"7\"\nSET graphicsTextureResolution \"2\"\n";
    backup = sp_graphics_backup(a16Original, SP_GRAPHICS_LEGACY_COUNT);
    assert(backup && !strstr(backup, "graphicsViewDistance"));
    char *expanded = sp_graphics_expand_backup(backup, a16Original);
    assert(expanded && strstr(expanded, "graphicsViewDistance\t+7\n"));
    char *a16 = sp_graphics_edit(a16Original, expanded, SP_GRAPHICS_A16, false, false, &applied, &unchanged);
    assert(a16 && strstr(a16, "SET graphicsTextureResolution \"0\"") && strstr(a16, "SET maxFPS \"30\""));
    restored = sp_graphics_edit(a16, expanded, SP_GRAPHICS_KEEP, false, false, &applied, &unchanged);
    assert(restored && !strcmp(restored, a16Original));
    free(restored);
    performance = sp_graphics_edit(a16, expanded, SP_GRAPHICS_PERFORMANCE, false, true, &applied, &unchanged);
    assert(performance && strstr(performance, "SET graphicsViewDistance \"7\"") && !strstr(performance, "MSAAQuality"));
    free(performance);
    const char *lowOriginal = "SET graphicsViewDistance \"7\"\nSET graphicsTextureResolution \"2\"\nSET useHighResTextures \"1\"\n";
    char *oldA16Backup = sp_graphics_backup(a16Original, SP_GRAPHICS_ORIGINAL_A16_COUNT);
    char *newA16Backup = sp_graphics_expand_backup(oldA16Backup, lowOriginal);
    assert(newA16Backup && strstr(newA16Backup, "useHighResTextures\t+1\n"));
    char *a16WithHighRes = malloc(strlen(a16) + sizeof "SET useHighResTextures \"1\"\n");
    assert(a16WithHighRes);
    sprintf(a16WithHighRes, "%sSET useHighResTextures \"1\"\n", a16);
    char *low = sp_graphics_edit(a16WithHighRes, newA16Backup, SP_GRAPHICS_A16_LOW_MEMORY, false, true, &applied, &unchanged);
    assert(low && strstr(low, "SET RenderScale \"0.5\"") && strstr(low, "SET useHighResTextures \"0\""));
    assert(strstr(low, "SET graphicsParticleDensity \"1\"") && strstr(low, "SET graphicsProjectedTextures \"0\""));
    assert(strstr(low, "SET ffxAntiAliasingMode \"0\"") && strstr(low, "SET MSAAQuality \"0\""));
    restored = sp_graphics_edit(low, newA16Backup, SP_GRAPHICS_KEEP, false, false, &applied, &unchanged);
    assert(restored && !strcmp(restored, lowOriginal));
    free(restored);
    char *backToA16 = sp_graphics_edit(low, newA16Backup, SP_GRAPHICS_A16, false, true, &applied, &unchanged);
    assert(backToA16 && strstr(backToA16, "SET useHighResTextures \"1\""));
    free(backToA16);
    free(low);
    free(a16WithHighRes);
    free(newA16Backup);
    free(oldA16Backup);
    free(a16);
    free(expanded);
    free(backup);

    SPWTFEdit seed = {.name = "playIntroMovie", .value = "99", .length = 2, .seed = true};
    char *seeded = sp_wtf_edit("# SET playIntroMovie \"1\"\n", &seed, 1);
    assert(seeded && seed.changed && strstr(seeded, "\nSET playIntroMovie \"99\"\n"));
    free(seeded);
    seed = (SPWTFEdit){.name = "playIntroMovie", .value = "99", .length = 2, .seed = true};
    seeded = sp_wtf_edit("set playintromovie \"1\"\r\n", &seed, 1);
    assert(seeded && !seed.changed && !strcmp(seeded, "set playintromovie \"1\"\r\n"));
    free(seeded);
    puts("graphics: presets including A16 Low Memory, both legacy backup expansions, FPS gating, exact restore, invalid backup and intro seeding passed");
}
