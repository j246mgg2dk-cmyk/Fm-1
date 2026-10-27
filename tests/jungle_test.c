/* SPDX-License-Identifier: GPL-3.0-only */
/* JUNGLE (this fork): BREAK SYNC, AMEN BRAIN and DRILL on the Mac, through hostsim.c (run_tests.sh):
 *   build/host/jungle_test LOOP DEMO_DIR
 * LOOP: tests/slice_loop.py's user loop as `fm1_sample_upload.py build` writes it (slice_test.c's).
 * 1. the parameters: three before P_E0 (P_COUNT 114), OFF / 0 by default, lockable, the JUNGLE page on SLICE only.
 * 2. BREAK SYNC: the beats found (BREAK one bar of 120, the loop's two bars of 96 as 192), a slice lasting its beats at
 *    the song tempo (SYNC, HALF, DBL; the external clock's too), OFF as before, a one shot keeping its rate.
 * 3. AMEN BRAIN: the kinds of BREAK's slices against how gen_samples.py built it, 0 = the slices as played,
 *    127 re-cuts most, 25 leaves the kicks and snares mostly be, no kick dropped, the moves all seen.
 * 4. DRILL: x2 x4 x8 more hits in a step (x8 of a RATCH x4: 32), UP / DN an octave from first to last, OFF as RATCH.
 * 5. demos into DEMO_DIR: BREAK at 172 synced, brained and drilled; the user loop synced to 174. */
#include <stdarg.h>
#include <sys/stat.h>
#include <stdint.h>
static uint32_t host_slots[3u * 0x14000u / 4u];          /* USR1..3, as the flash at 0xA0000 */
#define SMP_USER_XIP(k) ((const uint8_t *)host_slots + (k) * SMP_USER_SIZE)
#define main hostsim_main
#include "hostsim.c"
#undef main
#define SLC_ENG 13u

static int fails;
static void check(const char *what, int ok, const char *fmt, ...)
{
    printf("jungle: %-64s %s", what, ok ? "ok" : "FAIL");
    if (fmt) {
        va_list ap;
        va_start(ap, fmt);
        printf("  (");
        vprintf(fmt, ap);
        printf(")");
        va_end(ap);
    }
    printf("\n");
    fails += !ok;
}
static long load(const char *path, void *dst, long max)
{
    FILE *f = fopen(path, "rb");
    long n;
    if (!f)
        return -1;
    n = (long)fread(dst, 1, (size_t)max, f);
    fclose(f);
    return n;
}
static void voices_off(void)
{
    uint32_t i, k;
    for (k = 0; k < NTRK; k++)
        for (i = 0; i < NVOICE; i++)
            trk[k].v[i].active = trk[k].v[i].gate = 0;
}
static void blocks(uint32_t n)
{
    int32_t o[2 * CTL];
    while (n--)
        mix_block(o, CTL);
}
static int page_of(const char *title)
{
    uint32_t i;
    for (i = 0; i < NPAGES; i++)
        if (!strcmp(PAGES[i].title, title))
            return (int)i;
    return -1;
}

/* track 1 on SLICE (SRC src, DIV div, MODE ONE, no DECAY), the note of slice j played; the samples until it ends
 * (ext_beat: the external clock's measured beat, 0 none) */
static uint32_t ext_beat;
static uint32_t slice_len(int16_t src, int16_t div, uint32_t j, int16_t bsync, uint32_t bpm)
{
    track_t *t = &trk[0];
    uint32_t f = 0, i;
    host_tracks_init();
    voices_off();
    song.g[G_BPM] = (int16_t)bpm;
    song.g[G_CLOCK] = ext_beat != 0;
    midi_clock.mode = (uint8_t)song.g[G_CLOCK];         /* (else events_block starts the clock over: no tempo yet) */
    midi_beat_samples = ext_beat;
    host_preset(t, SLC_ENG, 0);
    t->p[P_E0] = src;
    t->p[P_E1] = div;
    t->p[P_E2] = 0;
    t->p[P_E3] = 0;
    t->p[P_E4] = SLC_ONE;
    t->p[P_E5] = 0;
    t->p[P_E6] = 127;
    t->p[P_BSYNC] = bsync;
    t->p[P_ATK] = 0;
    t->p[P_SUS] = 127;
    t->p[P_REL] = 0;
    trk_note_on(t, SLC_BASE + t->p[P_ROOT] + j, 100);
    for (; f < 20u * FS; f += CTL) {
        blocks(1);
        for (i = 0; i < NVOICE && !t->v[i].active; i++)
            ;
        if (i == NVOICE)
            break;
    }
    trk_note_off(t, SLC_BASE + t->p[P_ROOT] + j);
    return f;
}

/* track 1 plays one NOTE step (RATCH ratch, DRILL drill) on engine eng: the note-ons in it, the last one's pitch16 */
static uint32_t drill_run(uint32_t eng, uint32_t ratch, int16_t drill, int32_t *last_pitch, int32_t *first_pitch)
{
    track_t *t = &trk[0];
    uint8_t n = 60;
    uint32_t a, f, i, hits = 0, seen = 0;
    host_tracks_init();
    voices_off();
    song.g[G_BPM] = 120;
    host_preset(t, eng, 0);
    t->p[P_DRILL] = drill;
    t->p[P_SLEN] = 16;
    t->p[P_VOICE] = V_POLY;
    put_step(t, 0, 1, &n, ST_NOTE, (ratch - 1u) << SF_RATCH_SH);
    transport_req = 1;
    a = vage;
    *first_pitch = *last_pitch = -1;
    for (f = 0; f < div_samples(2) - CTL; f += CTL) {   /* (the first step: 1/16) */
        blocks(1);
        if (vage != a) {
            uint32_t best = 0;
            hits += vage - a;
            a = vage;
            for (i = 0; i < NVOICE; i++)
                if (t->v[i].active && t->v[i].age > t->v[best].age)
                    best = i;
            *last_pitch = t->v[best].pitch16;
            if (!seen++)
                *first_pitch = t->v[best].pitch16;
        }
    }
    transport_req = 2;
    blocks(2);
    return hits;
}

/* the slices a pattern of n notes (one a 1/16 step) plays with BRAIN brain, from a fresh seed: into got[] (0xFF a drop) */
static void brain_run(int16_t src, int16_t div, int16_t brain, const uint8_t *notes, uint32_t n, uint8_t *got,
                      uint32_t *revs, uint32_t *jumps)
{
    track_t *t = &trk[0];
    uint32_t i, k;
    host_tracks_init();
    voices_off();
    host_preset(t, SLC_ENG, 0);
    t->p[P_E0] = src;
    t->p[P_E1] = div;
    t->p[P_E5] = 0;
    t->p[P_BRAIN] = brain;
    ((slc_mem_t *)ENG_MEM(0))->rng = 12345u;
    ((slc_mem_t *)ENG_MEM(0))->last = 0;
    *revs = *jumps = 0;
    for (i = 0; i < n; i++) {
        uint32_t a = vage;
        t->seq_idx = (uint16_t)(i % 16u);
        trk_note_on(t, notes[i], 100);
        got[i] = 0xFF;
        for (k = 0; k < NVOICE; k++)
            if (t->v[k].age == a + 1u && t->v[k].active) {
                uint32_t pk = (uint32_t)t->v[k].s[4];
                if (t->v[k].s[6] != 2) {
                    got[i] = (uint8_t)((pk >> 8) & 63u);
                    *revs += (pk >> 7) & 1u;
                    *jumps += ((int32_t)pk >> 20) != 0;
                }
            }
        blocks(4);
        trk_note_off(t, notes[i]);
        voices_off();
    }
}

static int demo(const char *path, int16_t src, int16_t div, uint32_t bpm, int16_t bsync, int16_t brain,
                const uint8_t *notes, uint32_t nsteps, uint32_t bars, int drill_last)
{
    FILE *w;
    track_t *t = &trk[0];
    uint32_t f, i, frames, peak = 0, bar;
    if (!(w = fopen(path, "wb")))
        return 1;
    host_tracks_init();
    voices_off();
    song.g[G_BPM] = (int16_t)bpm;
    host_preset(t, SLC_ENG, 0);
    t->p[P_E0] = src;
    t->p[P_E1] = div;
    t->p[P_BSYNC] = bsync;
    t->p[P_BRAIN] = brain;
    for (i = 0; i < nsteps; i++) {
        uint8_t n = notes[i];
        put_step(t, i, n ? 1u : 0u, &n, n ? ST_NOTE : ST_REST, i % 4u == 0u ? SF_ACCENT : 0u);
    }
    if (drill_last) {                               /* a lock-free stand-in: the last step x4, DRILL x4UP on the track */
        t->step[nsteps - 1u].flags |= 3u << SF_RATCH_SH;
        t->p[P_DRILL] = 6;
    }
    t->p[P_SLEN] = (int16_t)nsteps;
    bar = (uint32_t)(4.0 * 60.0 / bpm * FS);
    frames = bars * bar + FS / 2u;
    wav_hdr(w, frames);
    transport_req = 1;
    for (f = 0; f < frames; f += CTL) {
        int32_t o[2 * CTL];
        if (f >= bars * bar && f < bars * bar + CTL)
            transport_req = 2;
        mix_block(o, CTL);
        for (i = 0; i < CTL; i++) {
            uint32_t a = (uint32_t)abs(o[2 * i]);
            peak = a > peak ? a : peak;
            wav_put(w, o[2 * i], o[2 * i + 1]);
        }
    }
    fclose(w);
    printf("jungle: demo %-40s %u bars at %u BPM, peak %u\n", strrchr(path, '/') ? strrchr(path, '/') + 1 : path, bars,
           bpm, peak);
    return peak < 2000u || peak > 32767u;
}

int main(int argc, char **argv)
{
    static const char *const KIND[4] = {"KICK", "SNR", "HAT", "GHST"};
    /* BREAK's 16ths as tools/gen_samples.py BREAK_HITS lays them: the loudest hit of each (-1: no hit, a tail) */
    static const int8_t BREAK_KIND[16] = {SLC_KICK, -1, SLC_KICK, -1, SLC_SNARE, -1, SLC_HAT, SLC_KICK,
                                          SLC_HAT, SLC_GHOST, SLC_KICK, -1, SLC_SNARE, -1, -1, -1};
    static const uint8_t AMEN[16] = {60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75};
    static const uint8_t JUNGLE[32] = {60, 0, 62, 0, 64, 0, 0, 67, 0, 62, 70, 0, 64, 0, 66, 67,
                                       60, 0, 62, 63, 64, 0, 62, 67, 68, 0, 70, 64, 72, 64, 72, 76};
    const char *loop = argc > 1 ? argv[1] : "build/slice_demo/loop";
    const char *dir = argc > 2 ? argv[2] : "build/jungle_demo";
    char path[512];
    uint32_t i, j, n, len, want, ok, right = 0, judged = 0;
    long sz;

    /* 1 */
    check("parameters: BSYNC BRAIN DRILL before P_E0 (P_E0 106, P_COUNT 114)",
          P_ESYNC + 1 == P_BSYNC && P_BSYNC + 1 == P_BRAIN && P_BRAIN + 1 == P_DRILL && P_DRILL + 1 == P_E0 &&
          P_E0 == 106 && P_COUNT == 114, 0);
    check("parameters: OFF / 0 by default, ranges",
          TP[P_BSYNC].def == 0 && TP[P_BRAIN].def == 0 && TP[P_DRILL].def == 0 && TP[P_BSYNC].max == 3 &&
          TP[P_BRAIN].max == 127 && TP[P_DRILL].max == 11 && !strcmp(TP[P_DRILL].names[7], "x8UP"), 0);
    check("parameters: lockable (motion_param)", motion_param(P_BSYNC) && motion_param(P_BRAIN) && motion_param(P_DRILL), 0);
    {
        int pj = page_of("JUNGLE"), pv = page_of("VOICE 3");   /* (ui.c page_visible: on SLICE only, by its P_BSYNC) */
        check("pages: JUNGLE (BSYNC BRAIN DRILL) in EDIT, DRILL on VOICE 3", pj >= 0 && pv >= 0 &&
              PAGES[pj].fam == FAM_EDIT && PAGES[pj].id[0] == P_BSYNC && PAGES[pj].id[1] == P_BRAIN &&
              PAGES[pj].id[2] == P_DRILL && PAGES[pv].id[1] == P_DRILL, 0);
    }

    /* the user loop into USR1 (as slice_test.c) */
    snprintf(path, sizeof path, "%s.hdr", loop);
    sz = load(path, host_slots, SMP_USER_DATA);
    snprintf(path, sizeof path, "%s.bin", loop);
    sz = sz == (long)sizeof(smp_user_hdr_t) ? load(path, (uint8_t *)host_slots + SMP_USER_DATA, SMP_USER_SIZE - SMP_USER_DATA) : -1;
    if (sz <= 0) {
        printf("jungle: no user loop (%s.hdr / .bin: tests/slice_loop.py + fm1_sample_upload.py build)\n", loop);
        return 1;
    }
    smp_user_scan(0);
    check("USR1: the loop read, BREAK's kinds made with it", slc_get(1) != 0 && slc_cls_break, 0);

    /* 2: BREAK SYNC */
    {
        uint32_t sbb = slc_sb_of(&SLC_BREAK, 0), sbu = slc_sb_of(&slc_usr[0], 0);
        double bpm_b = 60.0 * FS * SLC_BREAK.rate / 65536.0 / sbb, bpm_u = 60.0 * FS * slc_usr[0].rate / 65536.0 / sbu;
        check("BSYNC: BREAK's beat a quarter of its bar (120 BPM)", sbb && fabs(bpm_b - 120.0) < 0.5, "%.2f BPM", bpm_b);
        check("BSYNC: the loop's two bars of 96 read as 192 (a power of two in 120 .. 240)", sbu && fabs(bpm_u - 192.0) < 1.0,
              "%.2f BPM", bpm_u);
        check("BSYNC: a one shot (1/8 s) has no beat; 3 s at 22 kHz: 160 BPM", !slc_beat_of(FS / 8u, 65536u) &&
              fabs(60.0 * 22050.0 / slc_beat_of(3u * 22050u, 32768u) - 160.0) < 0.5, 0);
    }
    {
        static const struct { int16_t bs; uint32_t bpm; double beats; const char *what; } SY[] = {
            {2, 172, 1.0, "BSYNC SYNC: a BREAK quarter (DIV 4) lasts a beat of 172"},
            {2, 90, 1.0, "BSYNC SYNC: .. a beat of 90"},
            {1, 172, 2.0, "BSYNC HALF: .. two beats of 172"},
            {3, 172, 0.5, "BSYNC DBL: .. half a beat of 172"},
        };
        uint32_t off = slice_len(0, 0, 0, 0, 172), base = (uint32_t)(SLC_BREAK.len / 4u * 65536.0 / SLC_BREAK.rate);
        check("BSYNC OFF: a BREAK quarter at its own rate (a beat of 120 at any tempo)",
              off + 2u * CTL >= base && off <= base + 2u * CTL, "%u samples, %u", off, base);
        for (i = 0; i < NELEM(SY); i++) {
            want = (uint32_t)(SY[i].beats * FS * 60.0 / SY[i].bpm);
            len = slice_len(0, 0, 0, SY[i].bs, SY[i].bpm);
            check(SY[i].what, len + 2u * CTL >= want && len <= want + 2u * CTL, "%u samples, want %u", len, want);
        }
        want = (uint32_t)(4.0 * FS * 60.0 / 174.0);    /* DIV 4 of two bars of 192: 2 of its beats .. of 174: 4 */
        len = slice_len(1, 0, 0, 2, 174);
        want = (uint32_t)(slc_usr[0].len / 4u / (double)slc_sb_of(&slc_usr[0], 0) * FS * 60.0 / 174.0);
        check("BSYNC SYNC: a quarter of the user loop at 174", len + 2u * CTL >= want && len <= want + 2u * CTL,
              "%u samples, want %u", len, want);
        ext_beat = FS * 60u / 165u;
        want = FS * 60u / 165u;
        len = slice_len(0, 0, 0, 2, 120);
        ext_beat = 0;
        song.g[G_CLOCK] = 0;
        midi_clock.mode = 0;
        midi_beat_samples = 0;
        check("BSYNC SYNC: the external clock's tempo (165 at BPM 120)", len + 2u * CTL >= want && len <= want + 2u * CTL,
              "%u samples, want %u", len, want);
    }

    /* 3: AMEN BRAIN: the kinds */
    {
        uint8_t t16[SLC_AUTO / 4u];
        slc_classify(&SLC_BREAK, 2, t16);
        printf("jungle: BREAK's 16ths:");
        for (i = 0; i < 16u; i++) {
            uint32_t c = slc_cls_get(t16, i);
            printf(" %s", KIND[c]);
            if (BREAK_KIND[i] >= 0) {
                judged++;
                right += c == (uint32_t)BREAK_KIND[i];
            }
        }
        printf("\n");
        check("BRAIN: BREAK's hits sorted as built (kick / snare / hat / ghost)", right * 10u >= judged * 8u,
              "%u of %u", right, judged);
        printf("jungle: BREAK's AUTO slices:");
        for (i = 0; i < SLC_BREAK.nauto; i++)
            printf(" %s", KIND[slc_cls_get(slc_cls[0][1], i)]);
        printf("\njungle: USR1's AUTO slices: ");
        for (i = 0; i < slc_usr[0].nauto; i++)
            printf(" %s", KIND[slc_cls_get(slc_cls[1][1], i)]);
        printf("\n");
        for (n = 0, i = 0; i < 4u; i++)
            for (j = 0; j < slc_usr[0].nauto; j++)
                n |= 1u << slc_cls_get(slc_cls[1][1], j);
        check("BRAIN: the loop's AUTO slices: kicks, snares and hats found", (n & 7u) == 7u, "kinds 0x%x", n);
    }
    /* 3: the moves */
    {
        uint8_t got[64], ref[64];
        uint32_t revs, jumps, moved = 0, kick_moved = 0, kicks = 0, drops = 0, kick_drops = 0, k;
        uint8_t pat[64];
        const uint8_t *tab = slc_cls[0][0];
        for (i = 0; i < 64u; i++)
            pat[i] = AMEN[i % 16u];
        brain_run(0, 2, 0, pat, 64, ref, &revs, &jumps);
        for (ok = !revs && !jumps, i = 0; i < 64u; i++)
            ok &= ref[i] == i % 16u;
        check("BRAIN 0: every slice as played", ok, 0);
        brain_run(0, 2, 127, pat, 64, got, &revs, &jumps);
        for (i = 0; i < 64u; i++) {
            moved += got[i] != ref[i];
            drops += got[i] == 0xFF;
            if (slc_cls_get(tab, (i % 16u) << 1) == SLC_KICK)
                kick_drops += got[i] == 0xFF;
        }
        check("BRAIN 127: most notes re-cut; swaps, reverses, jumps, drops all seen, no kick dropped",
              moved + revs + jumps >= 40u && moved > drops && revs && jumps && drops && !kick_drops,
              "%u moved, %u reversed, %u jumps, %u drops", moved, revs, jumps, drops);
        brain_run(0, 2, 127, pat, 64, ref, &revs, &jumps);
        check("BRAIN 127: the same seed, the same mangling", !memcmp(got, ref, 64), 0);
        brain_run(0, 2, 25, pat, 64, got, &revs, &jumps);
        for (moved = 0, i = 0; i < 64u; i++) {
            k = slc_cls_get(tab, (i % 16u) << 1);
            moved += got[i] != i % 16u;
            if (k <= SLC_SNARE) {
                kicks++;
                kick_moved += got[i] != i % 16u;
            }
        }
        check("BRAIN 25: a few re-cut, the kicks and snares hold", moved && moved < 20u && kick_moved * 8u <= kicks,
              "%u of 64 moved, kicks / snares %u of %u", moved, kick_moved, kicks);
        brain_run(1, SLC_DIV_AUTO, 127, pat, 64, got, &revs, &jumps);
        for (ok = 1, i = 0; i < 64u; i++)
            ok &= got[i] == 0xFF || got[i] < slc_usr[0].nauto;
        check("BRAIN 127 on the user loop's AUTO slices: only its slices", ok, 0);
    }

    /* 4: DRILL */
    {
        int32_t lp, fp;
        static const struct { uint32_t eng, ratch; int16_t drill; uint32_t hits; int32_t first, last; const char *what; } DR[] = {
            {SLC_ENG, 1, 0, 1, 960, 960, "DRILL OFF: x1 is one hit"},
            {SLC_ENG, 4, 0, 4, 960, 960, "DRILL OFF: RATCH x4 is 4 (as before)"},
            {SLC_ENG, 1, 1, 2, 960, 960, "DRILL x2: x1 plays 2"},
            {SLC_ENG, 2, 2, 8, 960, 960, "DRILL x4: RATCH x2 plays 8"},
            {SLC_ENG, 1, 3, 8, 960, 960, "DRILL x8: x1 plays 8"},
            {0, 1, 6, 4, 960, 960 + 192, "DRILL x4UP: 4 hits, the last an octave up"},
            {0, 1, 10, 4, 960, 960 - 192, "DRILL x4DN: 4 hits, the last an octave down"},
        };
        for (i = 0; i < NELEM(DR); i++) {
            n = drill_run(DR[i].eng, DR[i].ratch, DR[i].drill, &lp, &fp);
            check(DR[i].what, n == DR[i].hits && fp == DR[i].first && lp == DR[i].last, "%u hits, pitch %d .. %d", n,
                  fp, lp);
        }
        n = drill_run(SLC_ENG, 4, 3, &lp, &fp);
        check("DRILL x8 of RATCH x4: 32 hits in a 1/16 at 120 (a buzz roll), none lost", n == 32u, "%u hits", n);
        song.g[G_BPM] = 200;
        n = drill_run(SLC_ENG, 4, 3, &lp, &fp);
        check("DRILL x8 of RATCH x4 at 120 again (the run sets it): 32", n == 32u, "%u hits", n);
    }

    /* 5 */
    {
        int bad = 0;
        mkdir(dir, 0755);
        snprintf(path, sizeof path, "%s/break_172_sync.wav", dir);
        bad |= demo(path, 0, 2, 172, 2, 0, AMEN, 16, 4, 0);
        snprintf(path, sizeof path, "%s/break_172_brain60_drill.wav", dir);
        bad |= demo(path, 0, 2, 172, 2, 76, JUNGLE, 32, 4, 1);
        snprintf(path, sizeof path, "%s/break_172_brain100.wav", dir);
        bad |= demo(path, 0, 3, 172, 2, 127, JUNGLE, 32, 4, 1);
        snprintf(path, sizeof path, "%s/usr_loop_174_sync_auto.wav", dir);
        bad |= demo(path, 1, SLC_DIV_AUTO, 174, 2, 50, JUNGLE, 32, 4, 0);
        check("demos rendered (peak above -24 dBFS, no clipping)", !bad, "%s", dir);
    }
    printf(fails ? "jungle test FAILED (%d)\n" : "jungle test passed\n", fails);
    return fails != 0;
}
