/* SPDX-License-Identifier: GPL-3.0-only
 * Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments */
/* PERFORM: the effects of the FX hold layer, on the master. A key pressed while FX is held belongs to the
 * layer (seq.c keyboard_block): it plays no note, sends no MIDI, records nothing, and holds its effect until
 * it is let go (ui_input.c opens the layer and shows the map). The 16 white keys (F3 .. G5) hold the effect the map
 * gives them (perf_map: the settings, ui_layer.c; any effect on any key, or none). The default (PF_DEF, 1.1.5's
 * keys and the two of 1.2 after them):
 *   REPEAT 1/8 1/16 1/32, REVERSE, LPF | HPF, TAPE STOP, FREEZE, OCT UP, OCT DN, FLANGER, PHASER, REV THROW, ECHO
 *   THROW (1.5.1, D5 E5);  the other 2 white keys nothing; black keys 1..4 (F#3 G#3 A#3 C#4): tracks 1..4 muted while
 *   held (not P_MUTE, never saved).
 * REV THROW / ECHO THROW (1.5.1): while held every track's reverb / delay send is full (as REV / DLY 127; perf_throw),
 * ECHO THROW also lifts the delay's feedback to 0.7 if it is lower (fx.c fx_buses); both glide in and out over 11.6 ms
 * (THR_SLOPE). Let go, the sends are the tracks' own again and what the buses hold rings out. The buses are the song's
 * (no RAM of their own); the tracks' REV / DLY / FDBK values are never touched (nothing saved, nothing recorded).
 * REPEAT and REVERSE start on the next 1/16 (at once while stopped); the others at once; all end when let go,
 * with a 2.9 ms ramp. Effects of different kinds stack; of the buffer ones (REPEAT, REVERSE, TAPE STOP,
 * FREEZE, OCT UP, OCT DN) the last pressed plays, and letting it go returns to the one held before.
 * OCT UP / OCT DN: a harmonizer, the mix an octave up / down beside itself (after the author's earlier
 * fxHarmonizer, the classic rotating-delay shifter): two read taps of a delay sweep 128 .. 2176 samples, half a sweep apart, at the
 * speed that makes the pitch 2x / 0.5x; a raised-cosine cross-fade (the sine table) hides each tap's jump
 * back; reads between samples, linear. Left and right apart, at 44.1 kHz in the loop's frames (4096 of
 * them). Out: 0.56 the live mix + 0.7 the shifted one (its 0.55, 0.7). While it plays, DEPTH (KNOB 4) is its
 * SHIMMER instead of the level: the shifted sound fed back into its own delay (0 .. 0.82, through the soft
 * clip): with OCT UP each pass climbs another octave.
 * FLANGER (1.2): left and right each through a short delay swept 0.5 .. 8 ms (a squared triangle: longer near the
 * short end, where the comb sweeps fastest), a bar a sweep in time with the transport (the 1/16 clock), the right a
 * quarter of it behind the left; feedback 0.5 (through the soft clip); out (x + delayed) / 2 * 0.85: the comb's peaks
 * and DC +2 dB, its notches -17 dB, white noise -4 dB. Its own line (fl_buf, 356 frames: 1.4 KB; the loop's buffer is the buffer
 * effects', which it stacks with); heard once the line holds 8 ms (8 ms after the press).
 * PHASER (1.2): four first-order all-pass stages a side (the classic four-stage pedal), their break swept 150 Hz ..
 * 4.8 kHz (log; a triangle of half a bar, the right a quarter of it behind; the coefficients a block at a time), the
 * last stage's output fed back (0.4) into the first; out (x + all-passed) / 2 * 0.9: two notches moving, the peaks
 * +1.6 dB, white noise -1 .. -3.5 dB. KNOB 4 DEPTH is the FLANGER's and the PHASER's level too (OCT UP /
 * DN playing: full, KNOB 4 its shimmer).
 * The buffer: the SLICER's recordings (sl_buf, 32 KB) borrowed as one stereo loop of 8192 frames at 22.05 kHz
 * (371 ms). While borrowed, STUT tracks play live; their recordings are dropped afterwards. A REPEAT 1/8 or
 * REVERSE longer than the loop at the tempo (below 81 BPM) does nothing (the map shows it dimmed).
 * KNOB 1..4 with FX: the macros FILTER (the LPF / HPF), CRUSH, THROW (the dry mix into the delay and reverb
 * sends), DEPTH (the buffer effects' level, FLANGER's and PHASER's; OCT UP / DN: the shimmer).
 * MENU > FX LATCH ON (#40, a hand that cannot hold FX, a key and a knob together): a key pressed with FX turns its
 * effect on, the next press turns it off (perf_latched; letting the key or FX go does nothing), the macros keep
 * their values when FX is let go, FX + OCT- turns everything off (ui_layer.c), so does the menu or a dialog.
 * Chain: [REPEAT / REVERSE / TAPE / FREEZE / GLITCH / ROLL] -> LPF -> HPF -> CRUSH -> BEND -> 8-BIT -> RING MOD -> CHOP
 * -> FLANGER -> PHASER, after the master level and
 * before master_out (the limiter); THROW and the mutes act before the buses (fx.c mix_block / mix_part).
 * Idle (no key, no knob, no ramp left) every stage is skipped: the output is bit-identical.
 * GLITCH (F5 by default): a buffer effect that mangles the beat on its own. It records the mix into the loop and, at
 * every 1/16 (halved until one fits in 186 ms), draws a move for the next one from the 1/16 just played: LIVE, REPEAT
 * it, ROLL it at 1/2, 1/4, 1/8 or 1/16 of its length, CHOP it (a 1/8 roll, every other pass silent), ACCEL (a roll
 * that halves as it goes), REVERSE it, play it an octave DOWN (its first half at half speed) or UP (twice at double
 * speed), TAPE it (slowing to a stop), or GATE it (silence). A repeat after a repeat may keep the same slice, so
 * stutters build over several 1/16s. While GLITCH plays KNOB 4 is its CHAOS (its level full, as OCT UP's shimmer):
 * untouched GL_CHAOS; low, mostly live and the milder moves; high, never live and mostly the short rolls, chops and
 * gates. Each pass is windowed (SL_RAMP at both ends, less on a short one), the move's share glides (SL_SLOPE): no
 * clicks. Starts on the 1/16 (as REPEAT). Its own generator: the LFOs' S&H draws are not disturbed.
 * ROLL (A#4, a black key): a drum roll building up from what was playing: the first 1/16 caught, then repeated at
 * 1/16 for a beat, 1/32 for the next, 1/64, 1/128 .. down to 64 samples (a buzz). Starts on the 1/16; KNOB 4 DEPTH.
 * BEND (G5 by default): a circuit-bent stage after CRUSH. Each sample is multiplied by a gain and wrapped as a 16-bit
 * integer overflows (silence stays silent, loud parts fold into hard digital edges), then held for 1 .. 10 samples;
 * the gain and the hold are drawn again every 1/32. Out at 0.6 (the wrap is full scale); KNOB 4 DEPTH its level.
 * The black keys past the mutes (fixed, PF_BLK): D#4 8-BIT (8 bits, held 4 samples: 11 kHz), F#4 CHOP (dropouts: every
 * 1/32 open or shut at random, 2.9 ms ramps), G#4 RING MOD (times a sine drawn from 30 Hz .. 7 kHz every 1/16), A#4
 * ROLL, C#5 MELTDOWN (GLITCH, BEND, 8-BIT, CHOP and RING MOD at once). 8-BIT, CHOP, RING MOD: one stage after BEND
 * (perf_dirt); KNOB 4 DEPTH their level (full while GLITCH or OCT UP / DN plays). Any of them on a white key too. */
/* the effects (their numbers are stored: the key map in the settings, ui_layer.c perf_map_put; append-only, before
 * PF_M1), then the mutes of the black keys */
enum { PF_R8, PF_R16, PF_R32, PF_REV, PF_LPF, PF_HPF, PF_TAPE, PF_FRZ, PF_OUP, PF_ODN, PF_FLG, PF_PHS,
       PF_RTHR, PF_ETHR,                      /* 1.5.1: REV THROW, ECHO THROW */
       PF_GLT, PF_BND,                        /* GLITCH, BEND */
       PF_8BT, PF_CHP, PF_RNG, PF_ROL, PF_MLT,   /* 8-BIT, CHOP, RING MOD, ROLL, MELTDOWN */
       PF_M1, PF_N = PF_M1 + NTRK };
#define PF_NFX PF_M1                          /* the effects a white key can hold */
#define PF_KEYS 16u                           /* the white keys F3 .. G5 */
#define PF_BIT(e) (1u << (e))
#define PF_REPEAT 0x7u                                         /* the three REPEAT rates */
#define PF_Q (PF_REPEAT | PF_BIT(PF_REV) | PF_BIT(PF_GLT) | PF_BIT(PF_ROL))   /* start on the 1/16 */
#define PF_HARM (PF_BIT(PF_OUP) | PF_BIT(PF_ODN))
#define PF_BUF (PF_REPEAT | PF_BIT(PF_REV) | PF_BIT(PF_TAPE) | PF_BIT(PF_FRZ) | PF_HARM | PF_BIT(PF_GLT) | PF_BIT(PF_ROL))
#define PF_DIRT (PF_BIT(PF_8BT) | PF_BIT(PF_CHP) | PF_BIT(PF_RNG))   /* perf_dirt's */
#define PF_MELT (PF_BIT(PF_GLT) | PF_BIT(PF_BND) | PF_DIRT)          /* MELTDOWN holds these */
#define PF_NBLK 5u                            /* the black keys past the mutes with an effect (PF_BLK) */
#define PF_MUTE (((1u << NTRK) - 1u) << PF_M1)
#define PF_MOD (PF_BIT(PF_FLG) | PF_BIT(PF_PHS))   /* FLANGER, PHASER: their own stages after CRUSH */
#define PB_FRAMES (NTRK * SL_LEN / 2u)        /* stereo frames in sl_buf: 8192, 371 ms at 22.05 kHz */
#define PB_MAX (2u * PB_FRAMES)               /* the longest loop, 44.1 kHz samples */
#define PB_TAPE 32000u                        /* TAPE STOP takes 1 beat, at most this (it lags a quarter of it) */
#define PB_FREC 4096u                         /* FREEZE: frames it records (186 ms) */
#define PB_GRAIN 2048u                        /* .. its two overlapping grains, samples (46 ms) */
#define HB_MASK 4095u                         /* OCT UP / DN: the delay's frames (of the loop's 8192) */
#define HB_BASE 128u                          /* .. the taps' shortest delay, samples; the sweep: 2048 */
#define HB_FB 269                             /* .. KNOB 4 (0 .. 100) -> the shimmer, Q15: 0 .. 0.82 */
#define PF_TOP (63 << 8)                      /* filter cutoff index, Q8 (PF_SVF): the LPF's open end */
#define PF_LOW (14 << 8)                      /* .. the LPF sweep's end, the HPF sweep's (and K1's) top */
enum { BM_NONE, BM_LOOP, BM_TAPE, BM_FRZ, BM_HARM, BM_GLT };
#define FL_LEN 356u                           /* FLANGER: its line's frames (8.1 ms: FL_MAX + 2) */
#define FL_MIN 22u                            /* .. the delay's sweep, samples: 0.5 .. 8 ms */
#define FL_MAX 353u
#define FL_FB 16384                           /* .. the feedback, Q15: 0.5 */
#define PH_ST 4u                              /* PHASER: all-pass stages a side (two notches, the classic pedal's) */
#define PH_FB 13107                           /* .. the feedback, Q15: 0.4 */
#define THR_SLOPE 64                          /* REV / ECHO THROW: the sends' glide a sample, Q15 (11.6 ms end to end) */
#define THR_FB 22938                          /* ECHO THROW: the delay's feedback while held at least this, Q15 (0.7) */
#define GL_SEG_MAX 8192u                      /* GLITCH: its slice at most, samples (186 ms): two fit in the loop */
#define GL_CHAOS 60                           /* .. its CHAOS while KNOB 4 is untouched */
enum { GM_LIVE, GM_REP, GM_R2, GM_R4, GM_R8, GM_R16, GM_REV, GM_DOWN, GM_UP, GM_GATE, GM_CHOP, GM_ACCEL, GM_TAPE,
       GM_ROLL, GM_N };
#define GM_KEEPS ((1u << GM_REP) | (1u << GM_R2) | (1u << GM_R4) | (1u << GM_R8) | (1u << GM_R16) | (1u << GM_CHOP) | \
                  (1u << GM_ACCEL))           /* .. the repeats: may keep a slice */

/* the white keys' effects by default (1.1.5's ten, then FLANGER and PHASER, 1.5.1's REV THROW and ECHO THROW on D5
 * and E5, GLITCH and BEND on F5 and G5) */
static const uint8_t PF_DEF[PF_KEYS] = {PF_R8, PF_R16, PF_R32, PF_REV, PF_LPF, PF_HPF, PF_TAPE, PF_FRZ, PF_OUP, PF_ODN,
                                        PF_FLG, PF_PHS, PF_RTHR, PF_ETHR, PF_GLT, PF_BND};
static volatile uint8_t perf_map[PF_KEYS] = {PF_R8, PF_R16, PF_R32, PF_REV, PF_LPF, PF_HPF, PF_TAPE, PF_FRZ, PF_OUP,
                                             PF_ODN, PF_FLG, PF_PHS, PF_RTHR, PF_ETHR, PF_GLT, PF_BND};
/* the black keys past the four mutes (D#4 F#4 G#4 A#4 C#5; fixed) */
static const uint8_t PF_BLK[PF_NBLK] = {PF_8BT, PF_CHP, PF_RNG, PF_ROL, PF_MLT};
                                      /* main: white key p's effect (PF_N none), from the settings (ui_layer.c) */
static volatile uint8_t perf_remap;   /* main: perf_map changed (seq.c: a key held takes its new effect) */

static volatile uint32_t perf_mask;   /* main: the FX button's bit while its layer may own keys, 0 = none */
static volatile uint32_t kb_mask;     /* main: the button bits whose hold makes keys a layer's (ui_layer.c), 0 = none */
static volatile uint8_t kb_lock;      /* main: a layer locked open (#83, no button held): 1 keys are the layer's, 2 FX's */
static volatile uint8_t perf_solo;    /* main: tracks soloed in the GLO layer (the others muted as by a black key) */
static volatile uint8_t perf_kill;    /* main: every effect off (the menu, a dialog, UBOOT) */
static volatile int8_t perf_k[4];     /* main: the knob macros, 0 = untouched: FILTER -100..100 (- LPF, + HPF),
                                       * CRUSH 0..100, THROW 0..100, DEPTH cut 0..100 (the buffer effects' level) */
static volatile uint32_t kb_layer;    /* ISR: the keys held that are the layer's, a bit per key */
static volatile uint32_t perf_held;   /* ISR: the effects held (PF_*) */
static volatile uint8_t perf_latch_on;   /* main: MENU > FX LATCH ON (#40): a key with FX toggles its effect */
static volatile uint32_t perf_latched;   /* ISR: the effects latched (FX LATCH; main clears it: OCT-, the menu) */
static volatile uint32_t perf_act;    /* ISR: .. running (a 1/16 one from its start on) */
static uint32_t perf_ord[PF_N], perf_seq;   /* press order: the last pressed buffer effect plays */

/* the ZDF state-variable filter at cutoff index i (30 Hz * 2^(i / 7), 0..63: up to 15.4 kHz), k = 1:
 * a1 a2 a3 in Q14 (tools: g = tan(pi fc / fs), a1 = 1 / (1 + g (g + k)), a2 = g a1, a3 = g a2) */
static const int16_t PF_SVF[64][3] = {
    {16349, 35, 0}, {16345, 39, 0}, {16341, 43, 0}, {16337, 47, 0}, {16332, 52, 0}, {16327, 57, 0}, {16321, 63, 0},
    {16314, 70, 0}, {16307, 77, 0}, {16299, 85, 0}, {16290, 94, 1}, {16280, 103, 1}, {16269, 114, 1},
    {16257, 126, 1}, {16244, 139, 1}, {16229, 153, 1}, {16213, 169, 2}, {16196, 186, 2}, {16176, 205, 3},
    {16154, 227, 3}, {16130, 250, 4}, {16104, 275, 5}, {16075, 303, 6}, {16043, 334, 7}, {16007, 368, 8},
    {15968, 406, 10}, {15925, 447, 13}, {15877, 492, 15}, {15824, 541, 19}, {15766, 596, 22}, {15702, 655, 27},
    {15631, 720, 33}, {15553, 791, 40}, {15467, 869, 49}, {15372, 953, 59}, {15267, 1046, 72}, {15151, 1146, 87},
    {15024, 1255, 105}, {14883, 1374, 127}, {14729, 1502, 153}, {14559, 1640, 185}, {14372, 1790, 223},
    {14166, 1950, 268}, {13940, 2121, 323}, {13692, 2304, 388}, {13420, 2499, 465}, {13122, 2704, 557},
    {12797, 2921, 667}, {12441, 3147, 796}, {12053, 3382, 949}, {11631, 3624, 1129}, {11173, 3870, 1341},
    {10677, 4119, 1589}, {10140, 4365, 1879}, {9562, 4605, 2218}, {8940, 4832, 2612}, {8274, 5040, 3070},
    {7563, 5219, 3602}, {6807, 5359, 4219}, {6006, 5444, 4934}, {5163, 5456, 5766}, {4282, 5369, 6733},
    {3372, 5149, 7863}, {2449, 4745, 9190},
};

static struct {
    uint32_t ph, P, split;             /* samples since play; the 1/16; this block: where a 1/16 starts */
    uint32_t act, act0;                /* running after / before split */
    uint8_t busy, sync, mute;          /* sync: a 1/16 starts with the next block; mute: tracks to ramp */
    /* the buffer */
    uint8_t mode, src, next, rev;      /* BM_*, the effect it plays (PF_N none), one waiting for the fade, REVERSE */
    uint8_t state, odd, xrev;          /* LOOP: 0 recording, 1 playing; the sample of a pair; the old loop's */
    uint32_t len, wr, rp;              /* loop length (samples), frames written, read (samples into the loop) */
    uint32_t xrp, xlen, xn;            /* the loop it switched from, faded over xn samples */
    uint32_t tv, dv, tpos;             /* TAPE: speed Q16, its step, read position Q16 frames */
    uint32_t gp[2], gs[2];             /* FREEZE: grain positions (samples), starts (frames) */
    uint32_t hph, hinc;                /* OCT UP / DN: tap A's place in the sweep (Q32), its step a sample */
    int32_t hfb;                       /* .. the shimmer now, Q15 (glides to KNOB 4's a block at a time) */
    int32_t w, tw, hl, hr;             /* the buffer's share and its target, Q15; the first of a pair */
    /* the filters, CRUSH, THROW, mutes */
    int32_t lc, hc, la, ha;            /* cutoffs (Q8 index) and shares (Q15) of LPF and HPF */
    int32_t lz[4], hz[4];              /* their states: L ic1 ic2, R ic1 ic2 */
    int16_t lk[3], hk[3];              /* their coefficients this block */
    uint32_t lt, ht;                   /* samples the LPF / HPF key has been held */
    int32_t cw, cc, chl, chr;          /* CRUSH share, amount, held sample */
    uint32_t cn;
    int32_t td;                        /* THROW: the share of the dry mix sent, Q15 */
    int32_t rw, ew, rw1, ew1;          /* REV / ECHO THROW: their shares (Q15) at this block's start and end */
    uint8_t thr;                       /* .. either at work this block (mix_part: perf_throw) */
    int32_t mg[NTRK];                  /* mute gains, Q15 (32768 = open) */
    /* FLANGER, PHASER */
    int32_t fw, pw;                    /* their shares, Q15 */
    uint32_t fwp, fn;                  /* FLANGER: the frame written next; frames written since it started */
    int32_t px[2][PH_ST], py[2][PH_ST], pfb[2];   /* PHASER: each stage's last input and output, L and R; the fed back */
    /* GLITCH, BEND */
    uint32_t gt, gseg;                 /* GLITCH: samples into this slice, its length */
    uint32_t gcur, gsb, gnf;           /* .. the frame this slice's recording began at; the source's first frame, frames */
    uint8_t gmv, groll;                /* .. this slice's move (GM_*); ROLL (not GLITCH) plays */
    uint32_t gpp, gpl, gpt;            /* .. ACCEL / ROLL: place in the pass, the pass's length, samples at that length */
    uint32_t gpos, gsp, gdv;           /* .. TAPE: read place Q16, speed Q16, its step a sample */
    int32_t gw;                        /* .. the move's share, Q15 (0: live) */
    uint32_t grng;                     /* GLITCH and BEND's generator (their own: rng() stays the LFOs') */
    int32_t bw, bg, bhl, bhr;          /* BEND: its share (Q15), the gain, the held samples */
    uint32_t bt, bn, bhold;            /* .. samples into the 1/32, since the last hold, the hold */
    int32_t d8w, drw, dcw, dcg;        /* 8-BIT, RING MOD, CHOP: their shares (Q15); CHOP's gate gain */
    int32_t d8l, d8r;                  /* 8-BIT: the held samples */
    uint32_t d8n, rph, rinc, drt, dct; /* .. since its hold; RING's phase, step (0: draw), 1/16 count; CHOP's 1/32 count */
    uint8_t dco, dcs;                  /* CHOP: the gate open; drawn once since it started */
} pf = {.src = PF_N, .next = PF_N, .lc = PF_TOP, .mg = {32768, 32768, 32768, 32768}};

static int16_t fl_buf[FL_LEN][2];      /* FLANGER's line: L R, at half the level (headroom) */

/* the key map in the settings (ui_layer.c: favorites.factory[15][14..23]): white key p's code in 5 bits from bit 5p
 * of b: 0 its default (PF_DEF), 1 none, 2 + e effect e (an unknown code, a later firmware's effect: the default) */
static uint32_t perf_map_of(const uint8_t *b, uint32_t p)
{
    uint32_t i = 5u * p, c = (uint32_t)b[i >> 3] >> (i & 7u);
    if ((i & 7u) > 3u)
        c |= (uint32_t)b[(i >> 3) + 1u] << (8u - (i & 7u));
    c &= 31u;
    return c == 1u ? PF_N : c >= 2u && c - 2u < PF_NFX ? c - 2u : PF_DEF[p];
}
static void perf_map_put(uint8_t *b, uint32_t p, uint32_t e)
{
    uint32_t i = 5u * p, sh = i & 7u, c = e == PF_DEF[p] ? 0u : e >= PF_NFX ? 1u : e + 2u, two = sh > 3u, v;
    v = b[i >> 3] | (two ? (uint32_t)b[(i >> 3) + 1u] << 8 : 0u);
    v = (v & ~(31u << sh)) | c << sh;
    b[i >> 3] = (uint8_t)v;
    if (two)
        b[(i >> 3) + 1u] = (uint8_t)(v >> 8);
}

/* the loop length of a REPEAT / REVERSE (1/8) at the tempo, 44.1 kHz samples; 0 = not one */
static const uint8_t PF_DEN[PF_REV + 1] = {2, 4, 8, 2};
static uint32_t perf_len(uint32_t e) { return e <= PF_REV ? beat_samples() / PF_DEN[e] : 0u; }
/* the effects that can run at the tempo: a REPEAT / REVERSE longer than the loop cannot */
static uint32_t perf_avail(void)
{
    uint32_t e, m = ~0u, b = beat_samples();
    for (e = PF_R8; e <= PF_REV; e++)
        if (b > PB_MAX * PF_DEN[e])
            m &= ~PF_BIT(e);
    return m;
}

/* seq.c keyboard_block: a layer key down / up (e: PF_*, PF_N = no effect) */
static void perf_press(uint32_t e, int down)
{
    if (e >= PF_N)
        return;
    if (perf_latch_on) {                  /* FX LATCH: a press turns it on or off, letting go does nothing */
        if (down) {
            perf_latched ^= PF_BIT(e);
            perf_ord[e] = ++perf_seq;
        }
        return;
    }
    if (down) {
        perf_held |= PF_BIT(e);
        perf_ord[e] = ++perf_seq;
    } else {
        perf_held &= ~PF_BIT(e);
    }
}

static void perf_start(void) { pf.ph = 0; pf.sync = 1; }      /* seq_start: a 1/16 starts with the transport */

/* the SLICER's recordings dropped (when the buffer is taken and given back) */
static void perf_drop_slicer(void)
{
    uint32_t k;
    for (k = 0; k < NTRK; k++)
        sl[k].rec = sl[k].loop = sl[k].rec_on = 0;
}

/* the buffer effect to play: the last pressed of those running */
static uint32_t perf_pick(uint32_t a)
{
    uint32_t e, best = PF_N;
    a &= PF_BUF;
    for (e = 0; e < PF_M1; e++)
        if (((a >> e) & 1u) && (best == PF_N || perf_ord[e] - perf_ord[best] < 0x80000000u))
            best = e;
    return best;
}

/* GLITCH / BEND's generator (xorshift; 0 is no state: reseeded) */
static uint32_t gl_rand(void)
{
    uint32_t x = pf.grng ? pf.grng : 0x9E3779B9u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    pf.grng = x;
    return x;
}
/* GLITCH: a slice's length, the 1/16 halved until it fits (two slices in the loop: the one played, the one recorded) */
static uint32_t gl_seg(void)
{
    uint32_t s = beat_samples() >> 2;
    while (s > GL_SEG_MAX)
        s >>= 1;
    return s > 2u * SL_RAMP ? s : 2u * SL_RAMP;
}

static void perf_buf_start(uint32_t e)
{
    if (!sl_lent) {
        sl_lent = 1;
        perf_drop_slicer();
    }
    pf.src = (uint8_t)e;
    pf.next = PF_N;
    pf.wr = pf.rp = 0;
    pf.odd = 0;
    pf.xn = 0;
    if (e == PF_TAPE) {
        uint32_t t = beat_samples();
        pf.mode = BM_TAPE;
        if (t > PB_TAPE)
            t = PB_TAPE;
        pf.tv = 65536;
        pf.dv = 65536u / t + 1u;
        pf.tpos = 0;
    } else if (e == PF_OUP || e == PF_ODN) {    /* (wr: the frame written next, len: frames written) */
        pf.mode = BM_HARM;
        pf.len = 0;
        pf.hph = 0;
        pf.hinc = e == PF_OUP ? 0u - (1u << 21) : 1u << 20;   /* the delay: -1 / +0.5 sample a sample */
        pf.hfb = 0;
    } else if (e == PF_GLT || e == PF_ROL) {    /* (wr: frames written) */
        pf.mode = BM_GLT;
        pf.groll = e == PF_ROL;
        pf.gpl = pf.gpp = pf.gpt = 0;
        pf.gt = 0;
        pf.gseg = gl_seg();
        pf.gcur = pf.gsb = pf.gnf = 0;
        pf.gmv = GM_LIVE;
        pf.gw = 0;
    } else if (e == PF_FRZ) {
        pf.mode = BM_FRZ;
        pf.gp[0] = 0;
        pf.gp[1] = PB_GRAIN / 2u;
        pf.gs[0] = pf.gs[1] = 0;
    } else {
        pf.mode = BM_LOOP;
        pf.state = 0;
        pf.len = perf_len(e);
        pf.rev = e == PF_REV;
    }
}

/* the buffer effect to play becomes e (at a 1/16 for REPEAT / REVERSE): a shorter REPEAT of what is
 * recorded switches with a cross-fade, anything else fades the old one out first */
static void perf_buf_select(uint32_t e)
{
    if (e == pf.src && pf.next == PF_N)
        return;
    if (e != PF_N && pf.mode == BM_LOOP && pf.state && e <= PF_REV && pf.src != PF_N &&
        perf_len(e) <= 2u * pf.wr) {
        pf.xrp = pf.rp;
        pf.xlen = pf.len;
        pf.xrev = pf.rev;
        pf.xn = SL_RAMP;
        pf.src = (uint8_t)e;
        pf.next = PF_N;
        pf.len = perf_len(e);
        pf.rev = e == PF_REV;
        pf.rp = 0;
        return;
    }
    if (pf.mode == BM_NONE || !pf.w) {
        if (e == PF_N) {
            pf.src = PF_N;
            pf.next = PF_N;
        } else {
            perf_buf_start(e);
        }
        return;
    }
    pf.src = PF_N;                                  /* fade out, then the next one (perf_seg) */
    pf.next = (uint8_t)e;
}

/* each block, after the keys (seq.c) and before the parts: what runs, the 1/16, the filters, the mutes.
 * Returns 1 when a stage has something to do */
static __attribute__((noinline)) int perf_begin(uint32_t n)
{
    uint32_t held = perf_kill ? 0u : (perf_held | perf_latched | (perf_solo ? (~(uint32_t)perf_solo & 15u) << PF_M1 : 0u)) & perf_avail();
    uint32_t q, k, ph0, bnd;
    int32_t m;
    if (held & PF_BIT(PF_MLT))                      /* MELTDOWN: all of it */
        held |= PF_MELT;
    if (!held && !pf.busy && !(perf_k[0] | perf_k[1] | perf_k[2])) {   /* idle: the clock only */
        pf.ph += n;
        pf.sync = 0;
        perf_act = 0;
        return 0;
    }
    pf.P = beat_samples() >> 2;
    if (pf.sync) {
        pf.ph = 0;
        pf.sync = 0;
    }
    ph0 = pf.ph % pf.P;                             /* the 1/16 in this block (n: none) */
    bnd = ph0 ? (pf.P - ph0 < n ? pf.P - ph0 : n) : 0u;
    pf.ph += n;
    pf.act &= held;                                 /* let go: at once */
    pf.act |= held & ~PF_Q;
    pf.act0 = pf.act;
    q = held & PF_Q & ~pf.act;
    pf.split = n;
    if (q && (!song.playing || bnd < n)) {
        pf.split = song.playing ? bnd : 0u;
        pf.act |= q;
    }
    perf_act = pf.act;
    /* the filters: LPF from open down over a bar while its key is held, KNOB 1 left; HPF up, KNOB 1 right */
    m = perf_k[0];
    {
        uint32_t bar = 16u * pf.P, t;
        int32_t lt = PF_TOP, ht = 0;
        pf.lt = (pf.act & PF_BIT(PF_LPF)) ? pf.lt + n : 0u;
        pf.ht = (pf.act & PF_BIT(PF_HPF)) ? pf.ht + n : 0u;
        if (pf.lt) {
            t = pf.lt < bar ? pf.lt : bar;
            lt = PF_TOP - (int32_t)((uint32_t)(PF_TOP - PF_LOW) / 64u * (t * 64u / bar));
        }
        if (m < 0 && PF_TOP + m * (PF_TOP - PF_LOW) / 100 < lt)
            lt = PF_TOP + m * (PF_TOP - PF_LOW) / 100;
        if (pf.ht) {
            t = pf.ht < bar ? pf.ht : bar;
            ht = (int32_t)((uint32_t)(PF_TOP - PF_LOW) / 64u * (t * 64u / bar));
        }
        if (m > 0 && m * (PF_TOP - PF_LOW) / 100 > ht)
            ht = m * (PF_TOP - PF_LOW) / 100;
        pf.lc += clamp(lt - pf.lc, -192, 192);      /* ~45 ms over the range */
        pf.hc += clamp(ht - pf.hc, -192, 192);
        for (k = 0; k < 3u; k++) {                  /* the coefficients, between two table rows */
            int32_t i = pf.lc >> 8, f = pf.lc & 255, j = pf.hc >> 8, g = pf.hc & 255;
            pf.lk[k] = (int16_t)(PF_SVF[i][k] + (((PF_SVF[i < 63 ? i + 1 : 63][k] - PF_SVF[i][k]) * f) >> 8));
            pf.hk[k] = (int16_t)(PF_SVF[j][k] + (((PF_SVF[j < 63 ? j + 1 : 63][k] - PF_SVF[j][k]) * g) >> 8));
        }
    }
    {   /* REV / ECHO THROW: their shares glide (THR_SLOPE a sample) to full while held, back to 0 when let go */
        int32_t s = THR_SLOPE * (int32_t)n;
        pf.rw = pf.rw1;
        pf.ew = pf.ew1;
        pf.rw1 += clamp((pf.act & PF_BIT(PF_RTHR) ? 32768 : 0) - pf.rw1, -s, s);
        pf.ew1 += clamp((pf.act & PF_BIT(PF_ETHR) ? 32768 : 0) - pf.ew1, -s, s);
        pf.thr = (pf.rw | pf.rw1 | pf.ew | pf.ew1) != 0;
    }
    pf.mute = 0;
    for (k = 0; k < NTRK; k++)
        if (((held >> (PF_M1 + k)) & 1u) || pf.mg[k] != 32768)
            pf.mute |= (uint8_t)(1u << k);
    pf.busy = 1;
    return 1;
}

/* a track muted by its black key: its signal ramps to 0 and back (fx.c mix_part, after the SLICER) */
static __attribute__((noinline)) void perf_mute(uint32_t k, int32_t *b, uint32_t n)
{
    uint32_t i;
    int32_t g = pf.mg[k], t = (pf.act >> (PF_M1 + k)) & 1u ? 0 : 32768;
    for (i = 0; i < n; i++) {
        g += clamp(t - g, -SL_SLOPE, SL_SLOPE);
        b[i] = mulq16(b[i], (uint32_t)g << 1);
    }
    pf.mg[k] = g;
}
/* perf_mute with SPREAD's side signal sd (fx.c mix_spread): the same ramp on both */
static __attribute__((noinline)) void perf_mute_sd(uint32_t k, int32_t *b, int32_t *sd, uint32_t n)
{
    uint32_t i;
    int32_t g = pf.mg[k], t = (pf.act >> (PF_M1 + k)) & 1u ? 0 : 32768;
    for (i = 0; i < n; i++) {
        g += clamp(t - g, -SL_SLOPE, SL_SLOPE);
        b[i] = mulq16(b[i], (uint32_t)g << 1);
        sd[i] = mulq16(sd[i], (uint32_t)g << 1);
    }
    pf.mg[k] = g;
}

/* before the buses: THROW (KNOB 3) adds the dry mix to the delay and reverb sends */
static __attribute__((noinline)) void perf_pre(const int32_t *ml, const int32_t *mr, int32_t *sd, int32_t *sr,
                                               uint32_t n)
{
    uint32_t i;
    int32_t m = perf_k[2] * 327;
    for (i = 0; i < n; i++) {
        pf.td += clamp(m - pf.td, -SL_SLOPE, SL_SLOPE);
        if (pf.td) {
            int32_t x = mulq16((ml[i] + mr[i]) >> 1, (uint32_t)pf.td << 1);
            sd[i] += x;
            sr[i] += x;
        }
    }
}

/* REV THROW / ECHO THROW (1.5.1): track t's reverb / delay send towards full (127) while held, b its signal as its sends
 * take it (fx.c mix_part, after the mute key; t's values as the matrix has them this block). What the full send adds to
 * the track's own (REV / DLY) goes in at the share rw / ew, which glides from the block's start to its end a sample at
 * a time (THR_SLOPE: no click; every track the same glide). The track's REV / DLY are never changed: nothing is saved
 * or recorded, and when the key is let go the share glides back to 0 and the buses ring out as they are */
static __attribute__((noinline)) void perf_throw(const track_t *t, const int32_t *b, int32_t *sd, int32_t *sr, uint32_t n)
{
    uint32_t i;
    int32_t lvl = LEVEL_Q12[t->p[P_LEVEL] & 127];
    int32_t rg = 32766 - t->p[P_REV] * 258, dg = 32766 - t->p[P_DLY] * 258;   /* full (127 * 258) less its own */
    int32_t rw = pf.rw, ew = pf.ew, r1 = pf.rw1, e1 = pf.ew1;
    for (i = 0; i < n; i++) {
        int32_t x = clamp(((b[i] >> 2) * lvl) >> 10, -65536, 65536);   /* (mix_part's xs at a full send) */
        rw += clamp(r1 - rw, -THR_SLOPE, THR_SLOPE);
        ew += clamp(e1 - ew, -THR_SLOPE, THR_SLOPE);
        sr[i] += mulq15(x, mulq16(rg, (uint32_t)rw << 1));
        sd[i] += mulq15(x, mulq16(dg, (uint32_t)ew << 1));
    }
}

/* x towards y by w (Q15, 32768 = y) */
static inline int32_t pf_mix(int32_t x, int32_t y, int32_t w)
{
    return w == 32768 ? y : x + mulq16(y - x, (uint32_t)w << 1);
}

/* the loop: frame f of it, both channels (Q15) */
static inline void pb_put(uint32_t f, int32_t l, int32_t r)
{
    int16_t *p = &sl_buf[0][0] + 2u * (f & (PB_FRAMES - 1u));
    p[0] = (int16_t)clamp(l, -32768, 32767);
    p[1] = (int16_t)clamp(r, -32768, 32767);
}
/* sample s of the frames recorded from 0 (n of them): between two frames on an odd one */
static inline void pb_at(uint32_t s, uint32_t n, int32_t *l, int32_t *r)
{
    uint32_t f = s >> 1 < n ? s >> 1 : n - 1u;    /* (an odd loop's last sample: the frame before) */
    const int16_t *p = &sl_buf[0][0] + 2u * (f & (PB_FRAMES - 1u));
    const int16_t *q;                               /* a frame is the mean of samples 2f, 2f + 1: sample s */
    if (s & 1u)                                     /* lies a quarter frame from it, towards f + 1 or f - 1 */
        q = f + 1u < n ? p + 2 : p;
    else
        q = f ? p - 2 : p;
    *l = (3 * p[0] + q[0]) >> 1;
    *r = (3 * p[1] + q[1]) >> 1;
}
/* REPEAT / REVERSE at sample rp of a loop of len, windowed at both ends */
static inline void pb_loop(uint32_t rp, uint32_t len, int rev, uint32_t n, int32_t *l, int32_t *r)
{
    uint32_t e = len - 1u - rp;
    pb_at(rev ? e : rp, n, l, r);
    if (rp < e)
        e = rp;
    if (e < (uint32_t)SL_RAMP) {
        *l = (*l * (int32_t)e) >> SL_RAMP_LOG2;
        *r = (*r * (int32_t)e) >> SL_RAMP_LOG2;
    }
}

/* record the pair into frame f (the mean, >> 1: headroom) */
static inline uint32_t pb_rec(uint32_t f, int32_t l, int32_t r)
{
    if (!pf.odd) {
        pf.hl = l;
        pf.hr = r;
        pf.odd = 1;
        return f;
    }
    pf.odd = 0;
    pb_put(f, (pf.hl + l) >> 2, (pf.hr + r) >> 2);
    return f + 1u;
}

/* FREEZE: grain g's sample, by its triangle window, added to yl / yr; a new start at each pass */
static inline void perf_grain(uint32_t g, int32_t *yl, int32_t *yr)
{
    uint32_t p = pf.gp[g], tri = p < PB_GRAIN / 2u ? p : PB_GRAIN - p;
    int32_t a, b;
    if (!p)
        pf.gs[g] = ((rng() >> 16) * (pf.wr - PB_GRAIN / 2u + 1u)) >> 16;
    pb_at(2u * pf.gs[g] + p, pf.wr, &a, &b);
    *yl += a * (int32_t)tri;
    *yr += b * (int32_t)tri;
    pf.gp[g] = p + 1u < PB_GRAIN ? p + 1u : 0u;
}

/* OCT UP / DN: the tap at sweep place ph, both channels (as stored: half the level); silence before the
 * delay has that much in it */
static inline void hb_tap(uint32_t ph, int32_t *l, int32_t *r)
{
    uint32_t d = (HB_BASE << 16) + (ph >> 5), di = d >> 16;   /* the delay, Q16: 128 .. 2176 samples */
    int32_t f = (int32_t)((d >> 1) & 0x7FFFu);
    const int16_t *p, *q;
    if (di + 1u > pf.len) {
        *l = *r = 0;
        return;
    }
    p = &sl_buf[0][0] + 2u * ((pf.wr - di) & HB_MASK);
    q = &sl_buf[0][0] + 2u * ((pf.wr - di - 1u) & HB_MASK);
    *l = p[0] + (((q[0] - p[0]) * f) >> 15);
    *r = p[1] + (((q[1] - p[1]) * f) >> 15);
}
/* OCT UP / DN on one sample: yl / yr the harmonized mix (see the top). noinline: perf_block's loop keeps its
 * code layout (target_budget.py: a block placed out of line looks like a loop round the per-sample code) */
static __attribute__((noinline)) void perf_harm(int32_t l, int32_t r, int32_t *yl, int32_t *yr)
{
    int32_t wa = (32768 - osc_sine(pf.hph + 0x40000000u)) >> 1, al, ar, bl, br, sl_, sr_;   /* A's share, Q15 */
    hb_tap(pf.hph, &al, &ar);
    hb_tap(pf.hph + 0x80000000u, &bl, &br);
    sl_ = (al * wa + bl * (32768 - wa)) >> 15;
    sr_ = (ar * wa + br * (32768 - wa)) >> 15;
    l >>= 1;                                        /* (stored at half: headroom, as the loop's frames) */
    r >>= 1;
    {
        int32_t xl = l, xr = r;
        if (pf.hfb) {                               /* the shimmer: back into the delay, soft-clipped */
            xl += softclip(mulq15(sl_, pf.hfb));
            xr += softclip(mulq15(sr_, pf.hfb));
        }
        if (pf.len < (uint32_t)SL_RAMP) {           /* the recording fades in (2.9 ms): no step where it */
            xl = (xl * (int32_t)pf.len) >> SL_RAMP_LOG2;   /* begins, for a tap to read across */
            xr = (xr * (int32_t)pf.len) >> SL_RAMP_LOG2;
        }
        pb_put(pf.wr & HB_MASK, xl, xr);
    }
    pf.wr++;
    if (pf.len <= HB_MASK)
        pf.len++;
    pf.hph += pf.hinc;
    *yl = l + (l >> 3) + ((sl_ * 45875) >> 15);     /* 0.56 live + 0.7 shifted (x2: stored at half) */
    *yr = r + (r >> 3) + ((sr_ * 45875) >> 15);
}

/* GLITCH: a new slice. The one just recorded becomes the source (or a repeat keeps the one it repeats, while the
 * loop still holds it), and the next move is drawn by CHAOS c (0 .. 100): LIVE (100 - c) * 0.6 %, else a WILD move
 * c % of the time, a MILD one the rest (GATE in both: the dropouts). ROLL: the first slice, kept, rolling on */
static const uint8_t GL_MILD[8] = {GM_REP, GM_R2, GM_R4, GM_REV, GM_DOWN, GM_TAPE, GM_R8, GM_GATE};
static const uint8_t GL_WILD[8] = {GM_R8, GM_R16, GM_GATE, GM_CHOP, GM_ACCEL, GM_UP, GM_GATE, GM_R16};
static __attribute__((noinline)) void gl_next(void)
{
    uint32_t r = gl_rand(), r2 = gl_rand(), c = perf_k[3] ? (uint32_t)perf_k[3] : GL_CHAOS, mv;
    uint32_t prev = pf.gcur, nf = pf.wr - pf.gcur, keep;
    if (pf.groll)
        mv = GM_ROLL;
    else if (((r & 0xFFFFu) * 100u) >> 16 < (100u - c) * 3u / 5u)
        mv = GM_LIVE;
    else
        mv = (((r >> 16) * 100u) >> 16) < c ? GL_WILD[r2 & 7u] : GL_MILD[(r2 >> 3) & 7u];
    keep = pf.gnf && (pf.groll || (((GM_KEEPS >> pf.gmv) & 1u) && ((GM_KEEPS >> mv) & 1u) && ((r2 >> 6) & 1u) &&
                                   pf.wr + (GL_SEG_MAX >> 1) + 1u - pf.gsb <= PB_FRAMES));   /* (the next slice cannot overwrite it) */
    pf.gcur = pf.wr;
    pf.gseg = gl_seg();
    pf.gt = 0;
    if (!keep) {
        pf.gsb = prev;
        pf.gnf = nf;
    }
    pf.gmv = (uint8_t)(pf.gnf ? mv : GM_LIVE);      /* (nothing recorded yet: live) */
    if (pf.gmv == GM_ACCEL || (pf.gmv == GM_ROLL && !pf.gpl)) {   /* a roll from a 1/2 (ACCEL) / the 1/16 (ROLL) */
        pf.gpl = pf.gmv == GM_ROLL ? pf.gseg : pf.gseg >> 1;
        pf.gpp = pf.gpt = 0;
    } else if (pf.gmv == GM_TAPE) {
        pf.gpos = 0;
        pf.gsp = 65536u;
        pf.gdv = 65536u / pf.gseg;
    }
}
/* a pass of len samples at place p windowed at both ends: SL_RAMP, less on a short pass (a quarter of it at most) */
static inline void gl_win(int32_t *l, int32_t *r, uint32_t p, uint32_t len)
{
    uint32_t e = len - 1u - p, sh = SL_RAMP_LOG2;
    if (p < e)
        e = p;
    while (sh > 2u && (4u << sh) > len)
        sh--;
    if (e < (1u << sh)) {
        *l = (*l * (int32_t)e) >> sh;
        *r = (*r * (int32_t)e) >> sh;
    }
}
/* GLITCH / ROLL on one sample: records l / r (ROLL: until its slice is caught), plays this slice's move (see the
 * top) into yl / yr */
static __attribute__((noinline)) void perf_glitch(int32_t l, int32_t r, int32_t *yl, int32_t *yr)
{
    uint32_t t, len = pf.gseg, s, p, mute = 0;
    int32_t gl = 0, gr = 0;
    if (pf.gt >= pf.gseg)
        gl_next();
    t = pf.gt++;
    if (!pf.groll || !pf.gnf)
        pf.wr = pb_rec(pf.wr, l, r);
    switch (pf.gmv) {
    case GM_R2: case GM_R4: case GM_R8: case GM_R16:
        len >>= pf.gmv - GM_REP;
        s = p = t % len;
        break;
    case GM_CHOP: {                                 /* a 1/8 roll, every other pass silent */
        uint32_t q;
        len >>= 3;
        q = t / len;
        s = p = t - q * len;
        mute = q & 1u;
        break;
    }
    case GM_ACCEL: case GM_ROLL:                    /* passes of gpl, halving: ACCEL each pass (to 128), ROLL each beat (to 64) */
        len = pf.gpl;
        s = p = pf.gpp;
        pf.gpt++;
        if (++pf.gpp >= pf.gpl) {
            pf.gpp = 0;
            if (pf.gmv == GM_ACCEL ? pf.gpl > 256u : pf.gpt >= 4u * pf.gseg && pf.gpl > 127u) {
                pf.gpl >>= 1;
                pf.gpt = 0;
            }
        }
        break;
    case GM_REV:
        p = t;
        s = len - 1u - t;
        break;
    case GM_DOWN:
        p = t;
        s = t >> 1;
        break;
    case GM_UP:
        len >>= 1;
        p = t % len;
        s = 2u * p;
        break;
    case GM_TAPE:                                   /* slowing down to a stop over the slice */
        p = t;
        s = pf.gpos >> 16;
        pf.gpos += pf.gsp;
        pf.gsp = pf.gsp > pf.gdv ? pf.gsp - pf.gdv : 0u;
        break;
    default:                                        /* REPEAT (LIVE, GATE: nothing read) */
        s = p = t;
        break;
    }
    if (pf.gmv != GM_LIVE && pf.gmv != GM_GATE && !mute && p < len) {
        uint32_t f = s >> 1 < pf.gnf ? s >> 1 : pf.gnf - 1u;
        pb_at(2u * (pf.gsb + f) + (s & 1u), pf.gsb + pf.gnf, &gl, &gr);
        gl_win(&gl, &gr, p, len);
    }
    pf.gw += clamp((pf.gmv == GM_LIVE ? 0 : 32768) - pf.gw, -SL_SLOPE, SL_SLOPE);
    *yl = pf_mix(l, gl, pf.gw);
    *yr = pf_mix(r, gr, pf.gw);
}

/* the buffer effect faded out: the next one, or the buffer back. Once per effect, out of the per-sample loop
 * (noinline: its calls stay out of perf_block's loop code) */
static __attribute__((noinline)) void perf_buf_done(void)
{
    if (pf.next != PF_N) {
        perf_buf_start(pf.next);
    } else {
        pf.mode = BM_NONE;
        if (sl_lent) {
            sl_lent = 0;
            perf_drop_slicer();
        }
    }
}

/* the buffer effect on one sample: the share pf.w of what it plays, the rest live */
static inline void perf_buf(int32_t *pl, int32_t *pr)
{
    int32_t l = *pl, r = *pr, yl = 0, yr = 0, on = 0;
    if (pf.mode == BM_LOOP) {
        if (!pf.state) {
            pf.wr = pb_rec(pf.wr, l, r);
            if (++pf.rp >= pf.len) {                /* (rp: samples recorded) */
                pf.state = 1;
                pf.rp = 0;
            }
        } else {
            pb_loop(pf.rp, pf.len, pf.rev, pf.wr, &yl, &yr);
            if (pf.xn) {                            /* the loop it switched from, fading out */
                int32_t ol, orr, g = (int32_t)pf.xn;
                pb_loop(pf.xrp, pf.xlen, pf.xrev, pf.wr, &ol, &orr);
                yl += (ol * g) >> SL_RAMP_LOG2;
                yr += (orr * g) >> SL_RAMP_LOG2;
                pf.xn--;
                if (++pf.xrp >= pf.xlen)
                    pf.xrp = 0;
            }
            if (++pf.rp >= pf.len)
                pf.rp = 0;
            on = 1;
        }
    } else if (pf.mode == BM_TAPE) {
        pf.wr = pb_rec(pf.wr, l, r);
        if (pf.wr >= 2u) {                          /* read behind the writing, slower and slower */
            uint32_t f = pf.tpos >> 16;
            int32_t fr = (int32_t)((pf.tpos >> 1) & 0x7FFFu), a, b, env;
            const int16_t *p = &sl_buf[0][0] + 2u * (f & (PB_FRAMES - 1u));
            const int16_t *s = &sl_buf[0][0] + 2u * ((f + 1u) & (PB_FRAMES - 1u));
            a = p[0];
            b = s[0];
            yl = (a + (((b - a) * fr) >> 15)) << 1;
            a = p[1];
            b = s[1];
            yr = (a + (((b - a) * fr) >> 15)) << 1;
            env = pf.tv >= 8192u ? 32768 : (int32_t)(pf.tv << 2);   /* the last eighth fades to silence */
            yl = mulq16(yl, (uint32_t)env << 1);
            yr = mulq16(yr, (uint32_t)env << 1);
            pf.tpos += pf.tv >> 1;
            pf.tv = pf.tv > pf.dv ? pf.tv - pf.dv : 0u;
            on = 1;
        }
    } else if (pf.mode == BM_FRZ) {
        if (pf.wr < PB_FREC)
            pf.wr = pb_rec(pf.wr, l, r);
        if (pf.wr >= PB_GRAIN / 2u) {               /* two grains of what it caught, triangle windows */
            perf_grain(0, &yl, &yr);
            perf_grain(1, &yl, &yr);
            yl >>= 10;                              /* (the windows sum to PB_GRAIN / 2) */
            yr >>= 10;
            on = 1;
        }
    } else if (pf.mode == BM_HARM) {
        perf_harm(l, r, &yl, &yr);
        on = 2;                                     /* (KNOB 4 is the shimmer: the level stays full) */
    } else if (pf.mode == BM_GLT) {
        perf_glitch(l, r, &yl, &yr);
        on = pf.groll ? 1 : 2;                      /* (GLITCH: KNOB 4 is its chaos, the level stays full) */
    }
    pf.tw = on && pf.src != PF_N ? on == 2 ? 32768 : 32768 - perf_k[3] * 327 : 0;
    pf.w += clamp(pf.tw - pf.w, -SL_SLOPE, SL_SLOPE);
    if (pf.w) {
        *pl = pf_mix(l, yl, pf.w);
        *pr = pf_mix(r, yr, pf.w);
    } else if (pf.src == PF_N) {                    /* faded out: the next one, or the buffer back */
        perf_buf_done();
    }
}

/* one channel of a state-variable filter (k = 1): x in Q15 >> 2 */
static inline int32_t pf_svf(int32_t x, int32_t *z, const int16_t *c, int hp)
{
    int32_t v3 = x - z[1], v1 = (c[0] * z[0] + c[1] * v3) >> 14, v2 = z[1] + ((c[1] * z[0] + c[2] * v3) >> 14);
    z[0] = 2 * v1 - z[0];
    z[1] = 2 * v2 - z[1];
    return hp ? x - v1 - v2 : v2;
}

static __attribute__((noinline)) void perf_switch(uint32_t a) { perf_buf_select(perf_pick(a)); }

/* the UI: OCT UP / DN is the buffer effect playing (KNOB 4 is its shimmer, the card says so) */
static int perf_harm_on(void) { return (PF_HARM >> perf_pick(perf_act)) & 1u; }
/* the UI: GLITCH is the buffer effect playing (KNOB 4 is its CHAOS) */
static int perf_chaos_on(void) { return perf_pick(perf_act) == PF_GLT; }

/* FLANGER / PHASER: the sweep's place at this block's first sample, a cycle every `s` 1/16s of the transport's clock
 * (pf.ph: in time with the bars while playing), and its step a sample (*inc) */
static uint32_t perf_lfo(uint32_t s, uint32_t n, uint32_t *inc)
{
    uint32_t per = s * pf.P;
    *inc = 0xFFFFFFFFu / per;
    return ((pf.ph - n) % per) * *inc;
}
/* a triangle of the sweep's place q, 0 .. 65534 (Q16) */
static inline uint32_t pf_tri(uint32_t q)
{
    uint32_t t = q >> 16;
    return t < 32768u ? t << 1 : (65535u - t) << 1;
}
/* the share a FLANGER / PHASER / BEND / 8-BIT / CHOP / RING MOD fades to: KNOB 4 DEPTH (its shimmer while OCT UP / DN
 * plays, GLITCH's chaos: full) */
static int32_t perf_mod_depth(void)
{
    uint32_t b = perf_pick(perf_act);
    return ((PF_HARM >> b) & 1u) || b == PF_GLT ? 32768 : 32768 - perf_k[3] * 327;
}

/* FLANGER on one side c: x in, the line read at the sweep's place q (see the top) */
static inline int32_t fl_side(uint32_t c, int32_t x, uint32_t q)
{
    uint32_t t = pf_tri(q), d = (FL_MIN << 16) + (FL_MAX - FL_MIN) * ((t * t) >> 16);   /* the delay, Q16 samples */
    int32_t r0 = (int32_t)pf.fwp - (int32_t)(d >> 16), r1, a, v, fr = (int32_t)((d >> 1) & 0x7FFFu);
    if (r0 < 0)
        r0 += (int32_t)FL_LEN;
    r1 = r0 ? r0 - 1 : (int32_t)FL_LEN - 1;
    a = fl_buf[r0][c];
    v = a + (((fl_buf[r1][c] - a) * fr) >> 15);
    fl_buf[pf.fwp][c] = (int16_t)clamp((x >> 1) + softclip(mulq15(v, FL_FB)), -32767, 32767);
    return pf_mix(x, mulq16((x >> 1) + v, 55706u), pf.fw);   /* (x + delayed) / 2 * 0.85 (v: stored at half) */
}
/* after CRUSH, while held or fading: FLANGER (noinline, its own loop: the audio ISR's code stays as it was) */
static __attribute__((noinline)) void perf_flanger(int32_t *bl, int32_t *br, uint32_t n)
{
    uint32_t i, c, inc, q = perf_lfo(16u, n, &inc);
    int32_t tw = pf.act & PF_BIT(PF_FLG) ? perf_mod_depth() : 0, *const b[2] = {bl, br};
    if (!pf.fw && !(pf.act & PF_BIT(PF_FLG))) {         /* let go and faded: off, the line empty next time */
        pf.fn = 0;
        return;
    }
    if (!pf.fn)                                         /* (starting: the line empty) */
        memset(fl_buf, 0, sizeof fl_buf);
    for (i = 0; i < n; i++, q += inc) {
        pf.fw += clamp((pf.fn > FL_MAX + 1u ? tw : 0) - pf.fw, -SL_SLOPE, SL_SLOPE);   /* (heard once it holds 8 ms) */
        for (c = 0; c < 2u; c++)                        /* (one call: inlined; the right a quarter of the sweep behind) */
            b[c][i] = fl_side(c, b[c][i], q - (c << 30));
        if (++pf.fwp >= FL_LEN)
            pf.fwp = 0;
        if (pf.fn <= FL_MAX + 1u)
            pf.fn++;
    }
}

/* PHASER: the stages' coefficient a (Q14) for a break of 150 Hz * 2^(5 i / 32): a = (g - 1) / (g + 1), g = tan(pi f / fs) */
static const int16_t PH_A[33] = {
    -16038, -15998, -15955, -15906, -15853, -15793, -15727, -15653, -15572, -15481, -15381, -15270, -15147, -15012,
    -14862, -14696, -14514, -14313, -14092, -13849, -13582, -13290, -12970, -12621, -12240, -11825, -11375, -10886,
    -10356, -9784, -9166, -8500, -7783,
};
/* PHASER: the stages' coefficient at the sweep's place q (Q14) */
static int32_t ph_coef(uint32_t q)
{
    uint32_t t = pf_tri(q), i = t >> 11;
    return PH_A[i] + (((PH_A[i + 1u] - PH_A[i]) * (int32_t)(t & 2047u)) >> 11);
}
/* PHASER on one side c: x in, the stages' coefficient a (rounded: no DC creeping in through the low breaks) */
static inline int32_t ph_side(uint32_t c, int32_t x, int32_t a)
{
    int32_t xs = clamp((x + 2) >> 2, -16383, 16383), u = xs + ((pf.pfb[c] * PH_FB + 16384) >> 15), y = u;
    uint32_t s;
    for (s = 0; s < PH_ST; s++) {                       /* y = a (u - y1) + u1 */
        y = clamp(pf.px[c][s] + ((a * (u - pf.py[c][s]) + 8192) >> 14), -65535, 65535);
        pf.px[c][s] = u;
        pf.py[c][s] = y;
        u = y;
    }
    pf.pfb[c] = clamp(y, -32767, 32767);
    u = xs + y;                                         /* (x + y) / 2 * 0.9, x 4 (>> 2 above): (x + y) * 1.8 */
    return pf_mix(x, u + mulq16(u, 52429u), pf.pw);
}
/* after FLANGER, while held or fading: PHASER (noinline, as FLANGER). The coefficients a block at a time (at its
 * middle: 2.9 ms at most, the sweep moves 1 % in frequency meanwhile) */
static __attribute__((noinline)) void perf_phaser(int32_t *bl, int32_t *br, uint32_t n)
{
    uint32_t i, c, inc, q = perf_lfo(8u, n, &inc) + (n >> 1) * inc;
    int32_t tw = pf.act & PF_BIT(PF_PHS) ? perf_mod_depth() : 0, *const b[2] = {bl, br};
    int32_t a[2] = {ph_coef(q), ph_coef(q - 0x40000000u)};   /* (the right a quarter of the sweep behind) */
    if (!pf.pw) {                                       /* starting: the stages from rest */
        memset(pf.px, 0, sizeof pf.px);
        memset(pf.py, 0, sizeof pf.py);
        pf.pfb[0] = pf.pfb[1] = 0;
    }
    for (i = 0; i < n; i++) {
        pf.pw += clamp(tw - pf.pw, -SL_SLOPE, SL_SLOPE);
        for (c = 0; c < 2u; c++)
            b[c][i] = ph_side(c, b[c][i], a[c]);
    }
}

/* BEND: x times g, wrapped as a 16-bit integer overflows, at 0.6 */
static inline int32_t bd_wrap(int32_t x, int32_t g)
{
    int32_t v = (int32_t)((((uint32_t)(x * g)) & 0xFFFFu) ^ 0x8000u) - 32768;
    return (v * 19661) >> 15;
}
/* BEND's gains and holds, drawn every 1/32 */
static const uint8_t BD_GAIN[8] = {2, 3, 4, 5, 6, 8, 11, 16};
static const uint8_t BD_HOLD[8] = {1, 1, 2, 2, 3, 4, 6, 10};
/* after CRUSH, while held or fading: BEND (noinline, its own loop, as FLANGER) */
static __attribute__((noinline)) void perf_bend(int32_t *bl, int32_t *br, uint32_t n)
{
    uint32_t i, step = pf.P >> 1;
    int32_t tw = pf.act & PF_BIT(PF_BND) ? perf_mod_depth() : 0;
    if (!pf.bw && !(pf.act & PF_BIT(PF_BND))) {     /* let go and faded: a fresh draw next time */
        pf.bg = 0;
        return;
    }
    for (i = 0; i < n; i++) {
        pf.bw += clamp(tw - pf.bw, -SL_SLOPE, SL_SLOPE);
        if (!pf.bg || ++pf.bt >= step) {
            uint32_t r = gl_rand();
            pf.bt = 0;
            pf.bg = BD_GAIN[r & 7u];
            pf.bhold = BD_HOLD[(r >> 3) & 7u];
        }
        if (++pf.bn >= pf.bhold) {
            pf.bn = 0;
            pf.bhl = bd_wrap(bl[i], pf.bg);
            pf.bhr = bd_wrap(br[i], pf.bg);
        }
        bl[i] = pf_mix(bl[i], pf.bhl, pf.bw);
        br[i] = pf_mix(br[i], pf.bhr, pf.bw);
    }
}

/* RING MOD's frequencies: 30 55 80 110 165 220 330 440 660 880 1320 1760 2640 3520 5000 7040 Hz, as phase steps */
static const uint32_t RG_INC[16] = {2921746u, 5356535u, 7791324u, 10713070u, 16069606u, 21426141u, 32139211u, 42852281u,
                                    64278422u, 85704563u, 128556844u, 171409126u, 257113688u, 342818251u, 486957743u,
                                    685636503u};
/* after BEND, while held or fading: 8-BIT, RING MOD, CHOP (noinline, its own loop, as FLANGER) */
static __attribute__((noinline)) void perf_dirt(int32_t *bl, int32_t *br, uint32_t n)
{
    uint32_t i, a = pf.act, step = pf.P >> 1;
    int32_t dp = perf_mod_depth(), t8 = a & PF_BIT(PF_8BT) ? dp : 0, tr = a & PF_BIT(PF_RNG) ? dp : 0;
    int32_t tc = a & PF_BIT(PF_CHP) ? dp : 0;
    for (i = 0; i < n; i++) {
        int32_t l = bl[i], r = br[i];
        pf.d8w += clamp(t8 - pf.d8w, -SL_SLOPE, SL_SLOPE);
        if (pf.d8w) {                               /* 8 bits, a sample held 4 (11 kHz) */
            if (++pf.d8n >= 4u) {
                pf.d8n = 0;
                pf.d8l = (int32_t)((uint32_t)clamp(l, -32768, 32767) & ~255u);
                pf.d8r = (int32_t)((uint32_t)clamp(r, -32768, 32767) & ~255u);
            }
            l = pf_mix(l, pf.d8l, pf.d8w);
            r = pf_mix(r, pf.d8r, pf.d8w);
        }
        pf.drw += clamp(tr - pf.drw, -SL_SLOPE, SL_SLOPE);
        if (pf.drw) {                               /* times a sine, a new frequency every 1/16 */
            int32_t sn;
            if (!pf.rinc || ++pf.drt >= pf.P) {
                pf.drt = 0;
                pf.rinc = RG_INC[gl_rand() & 15u];
            }
            sn = osc_sine(pf.rph);
            pf.rph += pf.rinc;
            l = pf_mix(l, mulq15(l, sn), pf.drw);
            r = pf_mix(r, mulq15(r, sn), pf.drw);
        }
        pf.dcw += clamp(tc - pf.dcw, -SL_SLOPE, SL_SLOPE);
        if (pf.dcw) {                               /* each 1/32 open (45 %) or shut */
            if (!pf.dcs || ++pf.dct >= step) {
                pf.dcs = 1;
                pf.dct = 0;
                pf.dco = (gl_rand() & 255u) < 115u;
            }
            pf.dcg += clamp((pf.dco ? 32768 : 0) - pf.dcg, -SL_SLOPE, SL_SLOPE);
            l = pf_mix(l, mulq16(l, (uint32_t)pf.dcg << 1), pf.dcw);
            r = pf_mix(r, mulq16(r, (uint32_t)pf.dcg << 1), pf.dcw);
        }
        bl[i] = l;
        br[i] = r;
    }
    if (!pf.drw && !(a & PF_BIT(PF_RNG)))           /* let go and faded: a fresh draw next time */
        pf.rinc = 0;
    if (!pf.dcw && !(a & PF_BIT(PF_CHP)))
        pf.dcs = 0;
}

/* after the master level: the buffer effect, LPF, HPF, CRUSH on l / r (stereo, Q15) */
static __attribute__((noinline)) void perf_block(int32_t *bl, int32_t *br, uint32_t n)
{
    uint32_t i, a = pf.act0, sh, hold;
    int32_t c = perf_k[1], lt, ht, ct;
    if (c)
        pf.cc = c;
    ct = c ? 32768 : 0;
    sh = 4u + (uint32_t)pf.cc * 7u / 100u;
    hold = sh - 3u;
    if (pf.split)
        perf_switch(a);
    pf.hfb += clamp(perf_k[3] * HB_FB - pf.hfb, -512, 512);   /* OCT UP / DN's shimmer glides (~40 ms) */
    for (i = 0; i < n; i++) {
        int32_t l = bl[i], r = br[i];
        if (i == pf.split) {
            a = pf.act;
            perf_switch(a);
        }
        if (pf.mode != BM_NONE)
            perf_buf(&l, &r);
        lt = (a & PF_BIT(PF_LPF)) || perf_k[0] < 0 || pf.lc < PF_TOP ? 32768 : 0;
        pf.la += clamp(lt - pf.la, -SL_SLOPE, SL_SLOPE);
        if (pf.la) {
            int32_t fl = pf_svf(clamp(l >> 2, -32767, 32767), &pf.lz[0], pf.lk, 0) << 2;
            int32_t fr = pf_svf(clamp(r >> 2, -32767, 32767), &pf.lz[2], pf.lk, 0) << 2;
            l = pf_mix(l, fl, pf.la);
            r = pf_mix(r, fr, pf.la);
        } else {
            pf.lz[0] = pf.lz[1] = pf.lz[2] = pf.lz[3] = 0;
        }
        ht = (a & PF_BIT(PF_HPF)) || perf_k[0] > 0 || pf.hc > 0 ? 32768 : 0;
        pf.ha += clamp(ht - pf.ha, -SL_SLOPE, SL_SLOPE);
        if (pf.ha) {
            int32_t fl = pf_svf(clamp(l >> 2, -32767, 32767), &pf.hz[0], pf.hk, 1) << 2;
            int32_t fr = pf_svf(clamp(r >> 2, -32767, 32767), &pf.hz[2], pf.hk, 1) << 2;
            l = pf_mix(l, fl, pf.ha);
            r = pf_mix(r, fr, pf.ha);
        } else {
            pf.hz[0] = pf.hz[1] = pf.hz[2] = pf.hz[3] = 0;
        }
        {   /* CRUSH: fewer bits, a held sample (KNOB 2) */
            pf.cw += clamp(ct - pf.cw, -SL_SLOPE, SL_SLOPE);
            if (pf.cw) {
                if (++pf.cn >= hold) {
                    pf.cn = 0;
                    pf.chl = ((l >> sh) << sh) + (1 << (sh - 1u));
                    pf.chr = ((r >> sh) << sh) + (1 << (sh - 1u));
                }
                l = pf_mix(l, pf.chl, pf.cw);
                r = pf_mix(r, pf.chr, pf.cw);
            }
        }
        bl[i] = l;
        br[i] = r;
    }
    if ((pf.act & PF_BIT(PF_BND)) || pf.bw || pf.bg)
        perf_bend(bl, br, n);
    if ((pf.act & PF_DIRT) || pf.d8w || pf.drw || pf.dcw)
        perf_dirt(bl, br, n);
    if ((pf.act & PF_BIT(PF_FLG)) || pf.fw || pf.fn)
        perf_flanger(bl, br, n);
    if ((pf.act & PF_BIT(PF_PHS)) || pf.pw)
        perf_phaser(bl, br, n);
    pf.busy = pf.act || pf.mode != BM_NONE || pf.w || pf.la || pf.ha || pf.cw || pf.td || pf.mute || pf.fw || pf.pw || pf.thr ||
              pf.fn || pf.bw || pf.bg || pf.d8w || pf.drw || pf.dcw || perf_k[0] || perf_k[1] || perf_k[2];
}
