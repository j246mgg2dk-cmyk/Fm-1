/* SPDX-License-Identifier: GPL-3.0-only */
/* DREAM and TITAN (this fork) on the Mac, through hostsim.c (run_tests.sh):
 *   build/host/dream_test DEMO_DIR [SECONDS]
 * 1. TITAN: every preset sounds (level, no DC, no clipping before the master), the voices end after the release.
 * 2. DREAM: the same seed writes the same music; it starts playing; the half not playing is rewritten and the one
 *    playing never is; the acts go round (the depths, the stars and the voice come and go); the controls change what
 *    it writes; the four tracks keep to 64 steps of 1/16.
 * 3. demos into DEMO_DIR: TITAN's presets, and DREAM renders by mood (stereo 16-bit WAV). */
#include <stdarg.h>
#include <sys/stat.h>
#include <stdint.h>
#define main hostsim_main
#include "hostsim.c"
#undef main

static int fails;
static void check(const char *what, int ok, const char *fmt, ...)
{
    printf("dream: %-66s %s", what, ok ? "ok" : "FAIL");
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

static uint32_t steps_hash(uint32_t a, uint32_t b)
{
    uint32_t h = 2166136261u, k, i;
    for (k = 0; k < NTRK; k++)
        for (i = a; i < b; i++) {
            const uint8_t *p = (const uint8_t *)&trk[k].step[i];
            uint32_t j;
            for (j = 0; j < sizeof(step_t); j++)
                h = (h ^ p[j]) * 16777619u;
        }
    return h;
}

typedef struct { double peak, rms; uint64_t n; uint32_t clips; } lvl_t;
/* `secs` of the mix, DREAM polled every block (as the main loop: once per ISR half or so) */
static void run(FILE *w, double secs, lvl_t *L, int poll)
{
    uint32_t f, frames = (uint32_t)(secs * FS), i;
    for (f = 0; f < frames; f += CTL) {
        int32_t o[2 * CTL];
        if (poll)
            dream_poll();
        if (getenv("SOLO")) {                         /* SOLO=k: the other tracks muted (balance checks by ear) */
            uint32_t k;
            for (k = 0; k < NTRK; k++)
                trk[k].p[P_MUTE] = k != (uint32_t)atoi(getenv("SOLO"));
        }
        mix_block(o, CTL);
        if (!(f % (44u * CTL)))
            fm1_ms += 32;                             /* (the main loop's clock, ~1 ms a 44 samples) */
        for (i = 0; i < 2u * CTL; i++) {
            double a = o[i] < 0 ? -(double)o[i] : (double)o[i];
            if (L) {
                if (a > L->peak) L->peak = a;
                L->rms += a * a;
                L->n++;
                L->clips += a >= 32767.0;
            }
            if (w) {
                int16_t s = (int16_t)(o[i] > 32767 ? 32767 : o[i] < -32768 ? -32768 : o[i]);
                fwrite(&s, 2, 1, w);
            }
        }
    }
}

static FILE *wav_open(const char *dir, const char *name, double secs)
{
    char path[512];
    FILE *w;
    if (!dir)
        return 0;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    w = fopen(path, "wb");
    if (w)
        wav_hdr(w, (uint32_t)(secs * FS) / CTL * CTL);
    return w;
}

static void titan_tests(const char *dir)
{
    uint32_t pi, k;
    for (pi = 0; pi < ENG_TITAN.npresets; pi++) {
        static const uint8_t CH[4] = {48, 55, 60, 63};
        lvl_t L = {0};
        char name[64], *c;
        double secs = 4.0;
        uint32_t left = 0;
        FILE *w;
        host_tracks_init();
        host_preset(&trk[0], ENGI_TITAN, pi);
        snprintf(name, sizeof name, "titan_%u_%s.wav", pi, ENG_TITAN.presets[pi].name);
        for (c = name; *c; c++)
            if (*c == ' ') *c = '_';
        w = wav_open(dir, name, secs + 4.0);
        if (ENG_TITAN.presets[pi].mono) {
            static const uint8_t LINE[4] = {36, 43, 48, 46};
            for (k = 0; k < 4u; k++) {
                trk_note_on(&trk[0], LINE[k], 110);
                run(w, 1.0, &L, 0);
                trk_note_off(&trk[0], LINE[k]);
            }
        } else {
            for (k = 0; k < 4u; k++)
                trk_note_on(&trk[0], CH[k], 100);
            run(w, secs, &L, 0);
            for (k = 0; k < 4u; k++)
                trk_note_off(&trk[0], CH[k]);
        }
        run(w, 4.0, 0, 0);
        run(0, 8.0, 0, 0);                            /* (the long releases: CATHEDRAL's 115) */
        if (w)
            fclose(w);
        for (k = 0; k < NVOICE; k++)
            left += trk[0].v[k].active;
        snprintf(name, sizeof name, "TITAN %s: sounds, no clipping, voices end", ENG_TITAN.presets[pi].name);
        check(name, L.peak > 3000 && L.clips == 0 && !left, "peak %.0f, rms %.0f, %u voices left", L.peak,
              sqrt(L.rms / (double)L.n), left);
    }
}

static void dream_setup(uint32_t mood, uint32_t motion, uint32_t bloom, uint32_t drift)
{
    host_tracks_init();
    {
        uint32_t k, i;
        for (k = 0; k < NTRK; k++)
            for (i = 0; i < NVOICE; i++)
                trk[k].v[i].active = trk[k].v[i].gate = 0;
    }
    dream.mood = (uint8_t)mood;
    dream.motion = (uint8_t)motion;
    dream.bloom = (uint8_t)bloom;
    dream.drift = (uint8_t)drift;
}

static void dream_tests(const char *dir, double demo_secs)
{
    uint32_t h1, h2, k, i, ok;
    /* the same seed: the same music */
    dream_setup(0, 56, 70, 48);
    dream_start(1234);
    h1 = steps_hash(0, NSTEP);
    dream_setup(0, 56, 70, 48);
    dream_start(1234);
    h2 = steps_hash(0, NSTEP);
    check("the same seed writes the same music", h1 == h2, 0);
    dream_setup(0, 56, 70, 48);
    dream_start(99);
    check("another seed, other music", steps_hash(0, NSTEP) != h1, 0);
    for (k = 0, ok = 1; k < NTRK; k++)
        ok &= trk[k].p[P_SLEN] == NSTEP && trk[k].p[P_SDIV] == 2;
    check("four tracks of 64 steps of 1/16, all TITAN (swells, growl, pulse, lead)",
          ok && trk[0].eng_req == ENGI_TITAN && trk[1].eng_req == ENGI_TITAN && trk[2].eng_req == ENGI_TITAN &&
          trk[3].eng_req == ENGI_TITAN && trk[1].preset == TP_GROWL && trk[2].preset == TP_ARP &&
          trk[3].preset == TP_LEAD, 0);
    /* it plays; the half playing is never written; the other one is */
    {
        uint32_t f, playing_writes = 0, rewrites = 0, last_half = 99, hs[2], prev[2];
        lvl_t L = {0};
        run(0, 0.05, 0, 1);
        check("PLAY", song.playing, 0);
        prev[0] = steps_hash(0, DR_HALF);
        prev[1] = steps_hash(DR_HALF, NSTEP);
        for (f = 0; f < 120u * FS; f += CTL) {
            uint32_t ph = (trk[0].seq_idx % NSTEP) >= DR_HALF;
            int32_t o[2 * CTL];
            dream_poll();
            hs[0] = steps_hash(0, DR_HALF);
            hs[1] = steps_hash(DR_HALF, NSTEP);
            if (hs[ph] != prev[ph] && ph == last_half)
                playing_writes++;
            if (hs[ph ^ 1u] != prev[ph ^ 1u])
                rewrites++;
            prev[0] = hs[0];
            prev[1] = hs[1];
            last_half = ph;
            mix_block(o, CTL);
            for (i = 0; i < 2u * CTL; i++) {
                double a = o[i] < 0 ? -(double)o[i] : (double)o[i];
                if (a > L.peak) L.peak = a;
                L.clips += a >= 32767.0;
            }
        }
        {
            uint32_t want = (uint32_t)(120.0 * song.g[G_BPM] / 60.0 / 8.0) - 2u;   /* a half: 8 beats */
            check("2 minutes: the half playing never written, the other rewritten each time", playing_writes == 0 &&
                  rewrites >= want, "%u rewrites (%u wanted), %u while playing", rewrites, want, playing_writes);
        }
        check("2 minutes: no clipping at the master", L.clips == 0 && L.peak > 8000, "peak %.0f", L.peak);
        check("the halves go on (counted)", dream.half >= 16, "%u halves", dream.half);
    }
    /* the acts: the depths and the voice only in RISE / PEAK; the stars from BLOOM */
    {
        uint32_t ph, seen[5] = {0}, dep[5] = {0}, voc[5] = {0}, sta[5] = {0};
        dream_setup(0, 56, 70, 0);
        dream_start(7);
        for (i = 0; i < 2u * DR_ACT; i++) {
            uint32_t which = i & 1u, n0 = 0, n1 = 0, n2 = 0, j;
            ph = dr_phase(dream.half);
            dr_write(which);
            for (j = which * DR_HALF; j < (which + 1u) * DR_HALF; j++) {
                n0 += trk[1].step[j].time == ST_NOTE && trk[1].step[j].n;
                n1 += trk[3].step[j].time == ST_NOTE && trk[3].step[j].n;
                n2 += trk[2].step[j].time == ST_NOTE && trk[2].step[j].n;
            }
            seen[ph]++;
            dep[ph] += n0;
            voc[ph] += n1;
            sta[ph] += n2;
        }
        check("EMERGE: the swells alone (no growl, lead or pulse; NOIR, BLOOM 70)", !dep[DA_EMERGE] && !voc[DA_EMERGE] &&
              !sta[DA_EMERGE], 0);
        check("RISE / PEAK: the growl and the lead", dep[DA_RISE] && dep[DA_PEAK] && voc[DA_RISE] + voc[DA_PEAK], 0);
        check("BLOOM .. DISSOLVE: the pulse", sta[DA_BLOOM] && sta[DA_PEAK] && sta[DA_DISSOLVE], 0);
        check("DISSOLVE: the growl and the lead gone", !dep[DA_DISSOLVE] && !voc[DA_DISSOLVE], 0);
    }
    /* the pad: four notes a chord, in range, voice-led (no chord jumps more than 7 semitones on average) */
    {
        uint32_t bad = 0, chords = 0, jump = 0;
        uint8_t last[4] = {0};
        dream_setup(1, 56, 100, 60);
        dream_start(42);
        for (i = 0; i < 64u; i++) {
            uint32_t j, b;
            dr_write(i & 1u);
            for (b = 0; b < 2u; b++) {
                const step_t *s = &trk[0].step[(i & 1u) * DR_HALF + 16u * b];
                if (s->time != ST_NOTE)
                    continue;
                chords++;
                if (s->n != 4)
                    bad++;
                for (j = 0; j < s->n; j++) {
                    if (s->note[j] < 48 || s->note[j] > 86)
                        bad++;
                    if (last[0])
                        jump += (uint32_t)abs((int)s->note[j] - (int)last[j]);
                }
                memcpy(last, s->note, 4);
            }
        }
        check("the pad: four-note chords in range, voice-led", !bad && chords > 60 && jump / chords < 7 * 4,
              "%u chords, %u bad notes, %.1f st moved a chord", chords, bad, (double)jump / chords);
    }
    /* the controls: MOTION more stars; MOOD another scale */
    {
        uint32_t lo = 0, hi = 0, j;
        dream_setup(0, 0, 100, 0);
        dream_start(5);
        for (i = 0; i < DR_ACT; i++) {
            dr_write(i & 1u);
            for (j = (i & 1u) * DR_HALF; j < ((i & 1u) + 1u) * DR_HALF; j++)
                lo += trk[2].step[j].time == ST_NOTE && trk[2].step[j].n;
        }
        dream_setup(0, 127, 100, 0);
        dream_start(5);
        for (i = 0; i < DR_ACT; i++) {
            dr_write(i & 1u);
            for (j = (i & 1u) * DR_HALF; j < ((i & 1u) + 1u) * DR_HALF; j++)
                hi += trk[2].step[j].time == ST_NOTE && trk[2].step[j].n;
        }
        check("MOTION 127: the pulse in sixteenths (more notes than MOTION 0)", hi > lo * 3 / 2, "%u against %u", hi, lo);
    }
    /* demos */
    if (dir) {
        static const struct { const char *name; uint8_t mood, motion, bloom, drift; uint32_t seed; } D[] = {
            {"dream_noir.wav", DM_NOIR, 56, 70, 48, 1982},
            {"dream_rain.wav", DM_RAIN, 50, 80, 40, 2019},
            {"dream_pulse.wav", DM_PULSE, 80, 70, 50, 1983},
            {"dream_neon.wav", DM_NEON, 70, 100, 50, 1985},
            {"dream_void.wav", DM_VOID, 60, 50, 60, 2049},
            {"dream_alien.wav", DM_ALIEN, 90, 80, 100, 1979},
        };
        for (i = 0; i < NELEM(D); i++) {
            lvl_t L = {0};
            FILE *w = wav_open(dir, D[i].name, demo_secs);
            dream_setup(D[i].mood, D[i].motion, D[i].bloom, D[i].drift);
            dream_start(D[i].seed);
            run(w, demo_secs, &L, 1);
            if (w)
                fclose(w);
            {
                char what[96];
                snprintf(what, sizeof what, "demo %s (%.0f s): no clipping", D[i].name, demo_secs);
                check(what, L.clips == 0 && L.peak > 8000, "peak %.0f, rms %.0f", L.peak, sqrt(L.rms / (double)L.n));
            }
        }
    }
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : 0;
    double secs = argc > 2 ? atof(argv[2]) : 60.0;
    if (dir)
        mkdir(dir, 0755);
    titan_tests(dir);
    dream_tests(dir, secs);
    printf(fails ? "dream test FAILED (%d)\n" : "dream test passed\n", fails);
    return fails != 0;
}
