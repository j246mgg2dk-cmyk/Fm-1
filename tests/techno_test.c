/* SPDX-License-Identifier: GPL-3.0-only */
/* TECHNO and the clock it follows (this fork) on the Mac, through hostsim.c (run_tests.sh):
 *   build/host/techno_test DEMO_DIR [SECONDS]
 * 1. The music: the same seed the same steps; four tracks of 64 sixteenths (DRUM DRUM DRUM ANALOG); the kick on every
 *    beat of every half (ROBOT its own; out only in a BREAK); DRIVE thins and fills the hats; EVOLVE 0 a loop; the
 *    bass in its key's notes (the keys move it); the halves rewritten off the playhead.
 * 2. The clock: the internal one plays at the style's tempo; USB clock with START: the steps on the pulses (each step
 *    within a few ms of its sixth pulse), the tempo measured; the Song Position Pointer then CONTINUE: the step of that
 *    sixteenth, TECHNO's phrases counted from it; AUTO: the internal clock until a source sends, then that one (TRS or
 *    USB), let go when it stops; the cable pulled: it stops; OCT+ while the master plays: the clock goes on.
 * 3. The hand-over: a step edited, TECHNO lets the music be.
 * 4. Demos into DEMO_DIR: each style, 16-bit stereo WAV, no clipping. */
#include <stdarg.h>
#include <sys/stat.h>
#include <stdint.h>
#define main hostsim_main
#include "hostsim.c"
#undef main

static int fails;
static void check(const char *what, int ok, const char *fmt, ...)
{
    printf("techno: %-70s %s", what, ok ? "ok" : "FAIL");
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

/* the world's clock: samples since the test began; fm1_ms follows it (the main loop's millisecond) */
static uint64_t now_s;
static void tick_ms(void) { fm1_ms = (uint32_t)(now_s * 1000u / FS); }

typedef struct { double peak, rms; uint64_t n; uint32_t clips; } lvl_t;
/* one block: TECHNO polled (the main loop), the mix (events_block inside) */
static void block(lvl_t *L, FILE *w)
{
    int32_t o[2 * CTL];
    uint32_t i;
    tick_ms();
    techno_poll();
    mix_block(o, CTL);
    now_s += CTL;
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
static void run_s(double secs, lvl_t *L, FILE *w)
{
    uint64_t end = now_s + (uint64_t)(secs * FS);
    while (now_s < end)
        block(L, w);
}

/* a master on `source` (1 USB, 2 TRS) at bpm: its bytes go in at their time between the blocks */
static void wire(uint32_t source, uint32_t status)
{
    tick_ms();
    if (source == 2u)
        um_byte(status);
    else
        midi_enqueue(0xFu | status << 8, source);
}
static void wire_spp(uint32_t source, uint32_t pos)
{
    tick_ms();
    if (source == 2u) {
        um_byte(0xF2);
        um_byte(pos & 0x7Fu);
        um_byte(pos >> 7 & 0x7Fu);
    } else {
        midi_in_event(0x3u | 0xF2u << 8 | (pos & 0x7Fu) << 16 | (pos >> 7 & 0x7Fu) << 24);
    }
}
/* `pulses` clocks at bpm from now; on_step: seq_idx of T1 seen at each pulse that starts a sixteenth */
static uint32_t step_err_max, step_checked, step_wrong;
static uint32_t pulse_n;                          /* pulses since the master's START (or position) */
static uint32_t pulse_base16;                     /* the sixteenth the master started from */
static void master(uint32_t source, uint32_t bpm, uint32_t pulses, int check_steps)
{
    double per = (double)FS * 60.0 / (bpm * 24.0);   /* samples a pulse */
    double next = (double)now_s;
    uint32_t p;
    for (p = 0; p < pulses; p++) {
        while ((double)now_s < next)
            block(0, 0);
        wire(source, 0xF8);
        if (check_steps && pulse_n % 6u == 0u && (!song.g[G_SWING] || pulse_n % 12u == 0u)) {   /* (SWING: odd steps late) */
            /* the step this pulse starts: it must sound by the end of the next block or two (a pulse late at most) */
            uint32_t want = (pulse_base16 + pulse_n / 6u) % NSTEP, k, got = 0;
            for (k = 0; k < 4u && !got; k++) {
                block(0, 0);
                got = trk[0].seq_idx % NSTEP == want;
            }
            step_checked++;
            if (!got)
                step_wrong++;
            else if (k > step_err_max)
                step_err_max = k;
        }
        pulse_n++;
        next += per;
    }
}

static void tc_setup(uint32_t style, uint32_t drive, uint32_t groove, uint32_t evolve)
{
    uint32_t k, i;
    host_tracks_init();
    for (k = 0; k < NTRK; k++)
        for (i = 0; i < NVOICE; i++)
            trk[k].v[i].active = trk[k].v[i].gate = 0;
    memset(&midi_clock, 0, sizeof midi_clock);
    mi_r = mi_w = 0;
    midi_beat_samples = 0;
    clk_auto_src = 0;
    song.playing = 0;
    techno.on = 0;
    techno.style = (uint8_t)style;
    techno.drive = (uint8_t)drive;
    techno.groove = (uint8_t)groove;
    techno.evolve = (uint8_t)evolve;
    techno.key = 9;
    techno.dkit = 0, techno.dkick = 64, techno.dhats = 64, techno.dcrush = 0;
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

static int has_hit(uint32_t k, uint32_t i, uint32_t lane)
{
    const step_t *s = &trk[k].step[i % NSTEP];
    return s->time == ST_NOTE && ((s->hit >> lane) & 1u);
}

/* --------------------------------------------------------- the music --- */
static void music_tests(void)
{
    uint32_t h1, st, h, i, k, ok, bad;
    tc_setup(TS_DARK, 72, 40, 48);
    techno_start(1234);
    h1 = steps_hash(0, NSTEP);
    tc_setup(TS_DARK, 72, 40, 48);
    techno_start(1234);
    check("the same seed writes the same steps", steps_hash(0, NSTEP) == h1, 0);
    tc_setup(TS_DARK, 72, 40, 48);
    techno_start(77);
    check("another seed, other steps", steps_hash(0, NSTEP) != h1, 0);
    for (k = 0, ok = 1; k < NTRK; k++)
        ok &= trk[k].p[P_SLEN] == NSTEP && trk[k].p[P_SDIV] == 2;
    check("four tracks of 64 sixteenths: DRUM KICK, HATS, PERC, ANALOG BASS", ok && trk[0].eng_req == ENGI_DRUM &&
          trk[1].eng_req == ENGI_DRUM && trk[2].eng_req == ENGI_DRUM && trk[3].eng_req == 0u, 0);
    check("CLK INT became AUTO; the internal clock plays at the style's tempo", song.g[G_CLOCK] == CLK_AUTO &&
          transport_req == 1u && song.g[G_BPM] == TC_STYLE[TS_DARK].bpm, "CLK %d, BPM %d", song.g[G_CLOCK], song.g[G_BPM]);

    /* the kick on every beat of 64 halves (the four sets), each style but ROBOT; EVOLVE 48 (no BREAK) */
    for (st = 0, bad = 0; st < TC_NSTYLE; st++) {
        if (st == TS_ROBOT)
            continue;
        tc_setup(st, 72, 40, 48);
        techno_start(5 + st);
        for (h = 0; h < 64u; h++) {
            tc_write(h & 1u, h);
            for (i = 0; i < 32u; i += 4u)
                bad += !has_hit(0, (h & 1u) * 32u + i, DV_KICK);
        }
    }
    check("the kick on every beat of every half (7 styles x 64 halves, EVOLVE 48)", bad == 0, "%u missing", bad);
    /* EVOLVE 110: the BREAK takes the kick out for four bars of 64, and nothing else does (but a fill's last beat) */
    {
        uint32_t breaks = 0, gone = 0;
        tc_setup(TS_DARK, 72, 40, 110);
        techno_start(9);
        for (h = 0; h < 64u; h++) {
            uint32_t ph = tc_phase(h);
            tc_write(h & 1u, h);
            for (i = 0; i < 32u; i += 4u) {
                int fill_beat = h % 8u == 7u && i >= 28u;
                if (!has_hit(0, (h & 1u) * 32u + i, DV_KICK) && !fill_beat) {
                    gone++;
                    breaks += ph == TPH_BREAK || ph == TPH_BUILD;   /* (the BUILD's first bar: the kick in halves) */
                }
            }
        }
        check("EVOLVE 110: the kick out only in the BREAK (4 bars a set) and the BUILD's halves", gone == breaks &&
              breaks == 2u * (2u * 8u + 2u),
              "%u beats gone, %u in breaks", gone, breaks);
    }
    /* ROBOT: broken, the one always there */
    tc_setup(TS_ROBOT, 72, 40, 48);
    techno_start(3);
    for (h = 0, ok = 1; h < 32u; h++) {
        tc_write(h & 1u, h);
        ok &= has_hit(0, (h & 1u) * 32u, DV_KICK) && has_hit(0, (h & 1u) * 32u + 16u, DV_KICK);
    }
    check("ROBOT: a broken kick, every bar on its one", ok, 0);
    /* DRIVE: the hats thin (offbeats) to full (sixteenths) */
    {
        uint32_t lo = 0, hi = 0;
        tc_setup(TS_SOUL, 0, 0, 0);
        techno_start(4);
        for (i = 0; i < 32u; i++) lo += trk[1].step[i].time == ST_NOTE;
        tc_setup(TS_SOUL, 127, 0, 0);
        techno_start(4);
        for (i = 0; i < 32u; i++) hi += trk[1].step[i].time == ST_NOTE;
        check("DRIVE 0: hats on the offbeats only; DRIVE 127: sixteenths", lo == 8u && hi == 32u, "%u and %u hats", lo, hi);
    }
    /* EVOLVE 0: a loop (each half the same as two before), BERLIN and ACID */
    {
        uint32_t s2, diff = 0, a[2] = {0, 0};
        for (s2 = 0; s2 < 2u; s2++) {
            tc_setup(s2 ? TS_ACID : TS_DARK, 72, 60, 0);
            techno_start(11);
            for (h = 0; h < 40u; h++) {
                uint32_t hh;
                tc_write(h & 1u, h);
                hh = steps_hash((h & 1u) * 32u, (h & 1u) * 32u + 32u);
                if (h >= 2u && hh != a[h & 1u])
                    diff++;
                a[h & 1u] = hh;
            }
        }
        check("EVOLVE 0: the same four bars over and over (DARK, ACID)", diff == 0, "%u halves changed", diff);
    }
    /* the bass: in its key's pentatonic (dorian / phrygian colours), any style; the keys move it */
    {
        uint32_t notes = 0, out = 0;
        for (st = 0; st < TC_NSTYLE; st++) {
            uint32_t key;
            for (key = 0; key < 12u; key += 5u) {
                const uint8_t *sc = TC_SCALE[TC_STYLE[st].scale % 3u];
                tc_setup(st, 100, 40, 100);
                techno_start(21 + key);
                techno_key(key);
                for (h = 0; h < 32u; h++) {
                    tc_write(h & 1u, h);
                    for (i = 0; i < 32u; i++) {
                        const step_t *s = &trk[3].step[(h & 1u) * 32u + i];
                        uint32_t n;
                        for (n = 0; n < s->n; n++) {
                            uint32_t pc = (s->note[n] + 12u - key) % 12u, j, in = 0;
                            for (j = 0; j < 5u; j++)
                                in |= pc == sc[j];
                            in |= TC_STYLE[st].bkind == TB_DUB && (pc == 2u || pc == 3u || pc == 5u || pc == 7u ||
                                                                   pc == 10u || pc == 0u || pc == 8u);   /* i7 and iv7 */
                            notes++;
                            out += !in;
                        }
                    }
                }
            }
        }
        check("the bass in its key (8 styles x 3 keys x 32 halves)", notes > 1000u && out == 0, "%u notes, %u out", notes, out);
    }
}

/* ------------------------------------------------------ playing on --- */
static void play_tests(void)
{
    uint32_t playing_writes = 0, rewrites = 0, last_half = 99, hs[2], prev[2], f;
    tc_setup(TS_HYPNO, 72, 40, 64);
    now_s = 0;
    techno_start(1982);
    run_s(0.05, 0, 0);
    check("PLAY (internal clock, nothing coming in)", song.playing && clock_ext() == 0u, 0);
    prev[0] = steps_hash(0, TC_HALF);
    prev[1] = steps_hash(TC_HALF, NSTEP);
    for (f = 0; f < (uint32_t)(90.0 * FS) / CTL; f++) {
        uint32_t ph = (trk[0].seq_idx % NSTEP) >= TC_HALF;
        block(0, 0);
        hs[0] = steps_hash(0, TC_HALF);
        hs[1] = steps_hash(TC_HALF, NSTEP);
        if (hs[ph] != prev[ph] && ph == last_half && ph == ((trk[0].seq_idx % NSTEP) >= TC_HALF))
            playing_writes++;
        if (hs[ph ^ 1u] != prev[ph ^ 1u])
            rewrites++;
        prev[0] = hs[0];
        prev[1] = hs[1];
        last_half = ph;
    }
    {
        uint32_t want = (uint32_t)(90.0 * song.g[G_BPM] / 60.0 / 8.0) - 2u;
        check("90 s: the half playing never written, the other one each time", playing_writes == 0 && rewrites >= want,
              "%u rewrites (%u wanted), %u while playing", rewrites, want, playing_writes);
    }
    check("the halves counted (abs) as they play", techno.abs >= 20u, "%u", techno.abs);
}

/* --------------------------------------------------------- the clock --- */
static void clock_tests(void)
{
    uint32_t idx0;
    /* USB clock (CLK USB): START, the steps on the pulses */
    tc_setup(TS_DARK, 72, 40, 48);
    song.g[G_CLOCK] = 1;
    now_s = 0;
    techno_start(42);
    song.g[G_SWING] = 0;                          /* (straight: every sixteenth checked) */
    run_s(0.2, 0, 0);
    check("CLK USB: TECHNO waits for the master (not playing)", !song.playing && techno.on && transport_req == 0u, 0);
    pulse_n = 0; pulse_base16 = 0; step_err_max = step_checked = step_wrong = 0;
    wire(1, 0xFA);
    master(1, 128, 24u * 4u * 24u, 1);            /* 24 bars */
    check("USB START: playing, the tempo measured", song.playing && song.g[G_BPM] == 128, "BPM %d", song.g[G_BPM]);
    check("every sixteenth on its sixth pulse (24 bars at 128, straight)", step_wrong == 0 && step_checked == 384u && step_err_max <= 2u,
          "%u checked, %u off, within %u blocks", step_checked, step_wrong, step_err_max);
    check("TECHNO's halves counted from the START (24 bars: 12 halves)", techno.abs == 12u || techno.abs == 11u, "%u", techno.abs);
    /* OCT+ while the master plays: the clock goes on, no stop */
    idx0 = trk[0].seq_idx;
    techno_start(43);
    master(1, 128, 24, 0);
    check("OCT+ while the master plays: no stop, the steps go on", song.playing && transport_req == 0u &&
          trk[0].seq_idx == (idx0 + 4u) % NSTEP, "%u -> %u", idx0, trk[0].seq_idx);
    /* the cable pulled: stopped within 600 ms */
    run_s(0.6, 0, 0);
    check("the cable pulled: it stops", !song.playing, 0);

    /* the Song Position Pointer: stopped, position 136 (bar 9, beat 3), CONTINUE */
    pulse_n = 0; pulse_base16 = 136; step_err_max = step_checked = step_wrong = 0;
    wire_spp(1, 136);
    run_s(0.01, 0, 0);
    wire(1, 0xFB);
    master(1, 128, 24u * 4u * 8u, 1);             /* 8 bars from there */
    check("SPP 136 + CONTINUE: the step of sixteenth 136 first, all on their pulses", step_wrong == 0 && step_checked >= 64u,
          "%u checked, %u off", step_checked, step_wrong);
    check("TECHNO's halves from the position (half 4 + 4)", techno.abs == 8u || techno.abs == 7u, "%u", techno.abs);
    wire(1, 0xFC);
    run_s(0.05, 0, 0);
    check("STOP stops", !song.playing, 0);
    /* a plain CONTINUE (no position): where it stopped, as before */
    idx0 = trk[0].seq_idx;
    wire(1, 0xFB);
    master(1, 128, 7, 0);
    check("CONTINUE without a position: on from the step it stopped at", song.playing &&
          trk[0].seq_idx == (idx0 + 1u) % NSTEP, "%u -> %u", idx0, trk[0].seq_idx);
    wire(1, 0xFC);
    run_s(0.05, 0, 0);
    /* the position over TRS too */
    pulse_n = 0; pulse_base16 = 40; step_err_max = step_checked = step_wrong = 0;
    song.g[G_CLOCK] = 2;
    run_s(0.01, 0, 0);
    wire_spp(2, 40);
    run_s(0.01, 0, 0);
    wire(2, 0xFB);
    master(2, 120, 24u * 4u * 2u, 1);
    check("TRS: SPP 40 + CONTINUE, the steps on the pulses", step_wrong == 0 && step_checked >= 16u, "%u off", step_wrong);
    wire(2, 0xFC);
    run_s(0.05, 0, 0);

    /* AUTO: the internal clock playing; TRS sends START and clocks: it follows TRS (aligned to the START) */
    tc_setup(TS_ACID, 72, 40, 48);
    now_s = 0;
    techno_start(7);
    run_s(1.0, 0, 0);
    check("AUTO, nothing coming in: the internal clock plays", song.playing && clock_ext() == 0u &&
          song.g[G_CLOCK] == CLK_AUTO, 0);
    pulse_n = 0; pulse_base16 = 0; step_err_max = step_checked = step_wrong = 0;
    wire(2, 0xFA);
    master(2, 124, 24u * 4u * 4u, 1);
    check("AUTO: TRS START takes over, the steps on its pulses", clock_ext() == 2u && song.playing && step_wrong == 0 &&
          song.g[G_BPM] == 124, "src %u, %u off, BPM %d", clock_ext(), step_wrong, song.g[G_BPM]);
    /* USB clocks meanwhile do not steal it */
    wire(1, 0xF8);
    master(2, 124, 48, 0);
    check("AUTO: another source's clock does not take it while TRS plays", clock_ext() == 2u && song.playing, 0);
    /* TRS stops and falls silent: stopped, then let go (2 s): PLAY runs the internal clock again */
    wire(2, 0xFC);
    run_s(2.5, 0, 0);
    check("AUTO: TRS stopped and silent: let go, back to the internal clock", !song.playing && clock_ext() == 0u, 0);
    transport_req = 1;
    run_s(0.5, 0, 0);
    check("AUTO: then PLAY plays on the internal clock", song.playing && clock_ext() == 0u, 0);
    /* a USB master sends a position and CONTINUE: AUTO takes USB, from that position */
    pulse_n = 0; pulse_base16 = 64; step_err_max = step_checked = step_wrong = 0;
    wire_spp(1, 64);
    run_s(0.01, 0, 0);
    wire(1, 0xFB);
    master(1, 132, 24u * 4u * 2u, 1);
    check("AUTO: USB position + CONTINUE takes over from the internal clock, aligned", clock_ext() == 1u && song.playing &&
          step_wrong == 0 && step_checked >= 16u, "src %u, %u off", clock_ext(), step_wrong);
    /* clocks running with no START (the master already playing): PLAY joins on the next pulse */
    wire(1, 0xFC);
    run_s(0.1, 0, 0);
    master(1, 132, 48, 0);
    check("clocks without START: it waits", !song.playing && clock_ext() == 1u, 0);
    transport_req = 1;
    master(1, 132, 24, 0);
    check("PLAY joins the running clock", song.playing && clock_ext() == 1u, 0);
}

/* -------------------------------------------------------- the hand-over --- */
static void handover_tests(void)
{
    tc_setup(TS_DUB, 72, 40, 48);
    now_s = 0;
    techno_start(5);
    run_s(0.3, 0, 0);
    trk[1].step[3].vel ^= 0x11u;                  /* a step edited */
    run_s(0.3, 0, 0);
    check("a step edited: TECHNO lets the music be (playing on)", !techno.on && song.playing, 0);
    tc_setup(TS_DUB, 72, 40, 48);
    techno_start(5);
    dream_start(5);
    check("DREAM and TECHNO: one at a time", dream.on && !techno.on, 0);
    techno_start(6);
    check("  .. and the other way", techno.on && !dream.on, 0);
}

/* ------------------------------------------------------------- DRUMS --- */
static void drums_tests(void)
{
    uint32_t sig, k, ok;
    int16_t before[NTRK][P_COUNT];
    /* the styles' own kits (AUTO): HARD and INDUS on theirs, the four on CRISP */
    tc_setup(TS_HARD, 72, 40, 48);
    techno_start(8);
    ok = trk[0].p[P_E0] == DK_HARD && trk[1].p[P_E0] == DK_HARD && trk[2].p[P_E0] == DK_HARD;
    tc_setup(TS_INDUS, 72, 40, 48);
    techno_start(8);
    ok &= trk[0].p[P_E0] == DK_RUST && trk[1].p[P_E0] == DK_RUST && trk[2].p[P_E0] == DK_RUST;
    tc_setup(TS_DARK, 72, 40, 48);
    techno_start(8);
    ok &= trk[0].p[P_E0] == DK_CRISP && trk[1].p[P_E0] == DK_CRISP;
    check("KIT AUTO: the style's kits (HARD HARD, INDUS RUST, DARK CRISP)", ok, 0);
    /* KIT: the three drum tracks at once, playing; the steps untouched, TECHNO still on */
    now_s = 0;
    run_s(0.2, 0, 0);
    sig = dr_sig();
    techno_dset(0, 3);                            /* 8BIT */
    ok = trk[0].p[P_E0] == DK_8BIT && trk[1].p[P_E0] == DK_8BIT && trk[2].p[P_E0] == DK_8BIT && trk[3].eng_req == 0u;
    ok &= trk[0].p[P_LEVEL] == 118 && trk[1].p[P_LEVEL] == 98;   /* (the mix on the new sounds) */
    run_s(0.3, 0, 0);
    ok &= techno.on && song.playing && dr_sig() == sig;
    check("KIT 8BIT: kick, hats and perc on it at once, the mix kept, the steps untouched, playing on", ok, 0);
    /* KICK and HATS: 64 as the kit; each way moves its track only */
    techno_dset(0, 0);
    {
        int16_t d0 = trk[0].p[P_E3], v0 = trk[0].p[P_E7], h0 = trk[1].p[P_E2], h3 = trk[1].p[P_E3], p2 = trk[2].p[P_E2];
        techno_dset(1, 127);
        ok = trk[0].p[P_E3] < d0 && trk[0].p[P_E7] > v0 && trk[0].p[P_E2] > 64 && trk[1].p[P_E2] == h0;
        techno_dset(1, 0);
        ok &= trk[0].p[P_E3] > d0 && trk[0].p[P_E7] < v0 && trk[0].p[P_E2] < 64;
        techno_dset(1, 64);
        ok &= trk[0].p[P_E3] == d0 && trk[0].p[P_E7] == v0;
        techno_dset(2, 127);
        ok &= trk[1].p[P_E2] > h0 && trk[1].p[P_E3] > h3 && trk[2].p[P_E2] == p2;
        techno_dset(2, 0);
        ok &= trk[1].p[P_E2] < h0 && trk[1].p[P_E3] < h3;
        techno_dset(2, 64);
        ok &= trk[1].p[P_E2] == h0 && trk[1].p[P_E3] == h3;
        check("KICK: up shorter, harder, more sweep; down longer, softer; HATS: up brighter and longer, down darker "
              "and tighter; 64 as the kit", ok, 0);
    }
    /* CRUSH: the INSERT on T1..T3 (not the bass), the bits down as it goes up; 0 off; kept over a new kit */
    techno_dset(3, 1);
    ok = trk[0].p[P_ITYPE] == IT_CRUSH && trk[1].p[P_ITYPE] == IT_CRUSH && trk[2].p[P_ITYPE] == IT_CRUSH &&
         trk[3].p[P_ITYPE] == IT_OFF;
    k = (uint32_t)trk[1].p[P_IA];
    techno_dset(3, 127);
    ok &= (uint32_t)trk[1].p[P_IA] < k && ins_bits_sh(trk[1].p[P_IA]) == 12u && trk[0].p[P_IA] > trk[1].p[P_IA];
    techno_dset(0, 1);
    ok &= trk[0].p[P_E0] == DK_CRISP && trk[1].p[P_ITYPE] == IT_CRUSH;
    techno_dset(3, 0);
    for (k = 0; k < 3u; k++)
        ok &= trk[k].p[P_ITYPE] == IT_OFF;
    check("CRUSH: the INSERT's CRUSH on the drums (4 bits at the top, the kick 6), kept over a kit, 0 off", ok, 0);
    /* not playing TECHNO: the knobs remember, the tracks are the user's */
    tc_setup(TS_DARK, 72, 40, 48);
    host_preset(&trk[0], ENGI_DRUM, 0);
    for (k = 0; k < NTRK; k++)
        memcpy(before[k], trk[k].p, sizeof before[k]);
    techno_dset(0, 2); techno_dset(1, 100); techno_dset(2, 20); techno_dset(3, 50);
    for (k = 0, ok = 1; k < NTRK; k++)
        ok &= !memcmp(before[k], trk[k].p, sizeof before[k]);
    techno_start(4);
    ok &= trk[0].p[P_E0] == DK_HARD && trk[1].p[P_E0] == DK_HARD && trk[0].p[P_ITYPE] == IT_CRUSH && techno_dget(1) == 100;
    check("TECHNO off: DRUMS remembers and leaves the tracks alone; the start takes it", ok, 0);
}

/* -------------------------------------------------------------- demos --- */
static void demos(const char *dir, double secs)
{
    static const char *const NAME[TC_NSTYLE + 3] = {"techno_hypno.wav", "techno_dark.wav", "techno_soul.wav",
                                                    "techno_dub.wav", "techno_acid.wav", "techno_robot.wav",
                                                    "techno_hard.wav", "techno_indus.wav",
                                                    /* DRUMS: ACID on 8BIT crushed, DARK with a long low kick and dark
                                                     * hats on 80, HARD with the hardest kick and the brightest hats */
                                                    "techno_acid_8bit_crush.wav", "techno_dark_80_deep.wav",
                                                    "techno_hard_max.wav"};
    static const uint8_t DS[3][5] = {{TS_ACID, 3, 64, 64, 96}, {TS_DARK, 6, 10, 20, 0}, {TS_HARD, 0, 127, 127, 0}};
    uint32_t st;
    for (st = 0; st < TC_NSTYLE + 3u; st++) {
        lvl_t L = {0};
        FILE *w;
        char what[96];
        tc_setup(st < TC_NSTYLE ? st : DS[st - TC_NSTYLE][0], 84, 50, 72);
        if (st >= TC_NSTYLE) {
            const uint8_t *d = DS[st - TC_NSTYLE];
            techno.dkit = d[1], techno.dkick = d[2], techno.dhats = d[3], techno.dcrush = d[4];
        }
        now_s = 0;
        techno_start(2026 + st);
        run_s(0.01, 0, 0);
        w = wav_open(dir, NAME[st], secs);
        run_s(secs, &L, w);
        if (w) fclose(w);
        snprintf(what, sizeof what, "demo %s (%.0f s): sounding, no clipping", NAME[st], secs);
        check(what, L.clips == 0 && L.peak > 4000.0, "peak %.0f, rms %.0f", L.peak, sqrt(L.rms / (double)(L.n ? L.n : 1)));
    }
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : 0;
    double secs = argc > 2 ? atof(argv[2]) : 30.0;
    if (dir)
        mkdir(dir, 0755);
    music_tests();
    play_tests();
    clock_tests();
    handover_tests();
    drums_tests();
    demos(dir, secs);
    printf(fails ? "techno test FAILED (%d)\n" : "techno test passed\n", fails);
    return fails != 0;
}
