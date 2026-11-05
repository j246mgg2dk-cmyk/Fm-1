/* SPDX-License-Identifier: GPL-3.0-only */
/* TITAN (this fork): a big two-layer polysynth voice, in the manner of the great Japanese and Soviet polysynths of the
 * late 70s (two complete layers per key, a high-pass before a resonant low-pass, a ring modulator, an overdriven
 * filter that growls). Original code; no samples, no tables of anyone else's.
 *
 * Per voice:
 *   LAYER I   osc A (saw / pulse / sine / square, WAVE picks the pair)
 *   LAYER II  osc B, INT semitones from A (and the SUB pair adds a square an octave below A)
 *   DRIFT     the two layers apart in cents (A up, B down), and every voice wanders on its own: a slow sine per voice
 *             (its rate from the voice's age, 0.06 .. 0.3 Hz) moves A's and B's pitch a third of a turn apart, the
 *             pulse widths and the cutoff a little. A chord never sits still: the analog ensemble of the old desks.
 *   RING      A x B (the ring modulator) faded in for layer II: bells, gongs, metal
 *   HPF       a one-pole high-pass before the low-pass (the desk's thinning HPF)
 *   CUT RES   a trapezoidal SVF low-pass, key-tracked at half
 *   GRIT      drive into the filter and a resonance that saturates and growls instead of ringing (the Soviet filter's
 *             bite): the band-pass state is clipped hard, the input overdriven up to 4x
 * EDIT 1 (LAYERS): WAVE INT DRFT RING; EDIT 2 (FILTER): CUT RES HPF GRIT. The track's ENV / LFO / matrix -> FLT move
 * CUT, -> SHP the pulse width. Voice state: ph[0] A, ph[1] B, ph[2] the drift sine; s[0..1] the SVF, s[2] the noise /
 * flip-flop (bit 0: the sub's half), s[3] the HPF, s[4] the drift rate. */
static const char *const N_TITAN_WAVE[] = {"SAW2", "SAWPW", "PWM2", "SUB", "SINE", "SQR2"};
enum { TW2_SAW2, TW2_SAWPW, TW2_PWM2, TW2_SUB, TW2_SINE, TW2_SQR2, TW2_N };

static void titan_note_on(track_t *t, voice_t *v)
{
    uint32_t h = v->age * 2654435761u;
    (void)t;
    v->ph[1] = v->ph[0] + 0x2A000000u;                 /* the layers start apart: no cancelling at DRFT 0 */
    v->ph[2] = h;                                      /* the drift sine starts anywhere */
    v->s[0] = v->s[1] = 0;                             /* the low-pass */
    v->s[2] = 0;                                       /* the sub's half */
    v->s[3] = 0;                                       /* the high-pass */
    v->s[4] = (int32_t)(1900u + (h >> 22) * 8u);       /* drift: 1900 .. 10084 per block (0.06 .. 0.33 Hz) */
}

/* the one-pole HPF coefficient (Q15) of HPF 0..127: 0 off, then ~15 Hz .. ~1.6 kHz */
static inline int32_t titan_hp_g(int32_t h) { return h <= 0 ? 0 : 60 + ((h * h * 7600) >> 14); }

static void titan_render(track_t *t, voice_t *v, int32_t *out, uint32_t n, const vmod_t *m)
{
    const int16_t *p = t->p;
    uint32_t wave = (uint32_t)p[P_E0] < TW2_N ? (uint32_t)p[P_E0] : 0u, i;
    int32_t drft = p[P_E2], ring = p[P_E3] * 258, grit = p[P_E7];
    int32_t base_fine = 0;
    uint32_t ph0 = v->ph[0], ph1 = v->ph[1], dph = v->ph[2];
    int32_t ic1 = v->s[0], ic2 = v->s[1], half = v->s[2] & 1, hp = v->s[3];
    int32_t wob, wobB, ca, cb, cut, k, hg, drive, bmax, gA = 15000, gB = 15000, gS = 0;
    uint32_t incA, incB, incS, pwA, pwB;
    tsvf_t flt;
    if (n > CTL)
        n = CTL;
    {   /* the voice's drift, once per block: a slow sine per voice; B a third of a turn behind A */
        uint32_t b0 = pitch_inc(m->pitch16);
        base_fine = (b0 >> 12) ? (int32_t)(m->inc - b0) / (int32_t)(b0 >> 12) : 0;   /* unison / TUNE / bend */
        dph += (uint32_t)v->s[4] * 4096u;
        wob = sine_i(dph);                             /* Q15 */
        wobB = sine_i(dph + 0x55555555u);
    }
    /* DRFT: the layers apart (0 .. +-16 ct) and the wander (0 .. +-7 ct), in cents */
    ca = (drft >> 3) + ((wob * drft) >> 19);
    cb = -(drft >> 3) + ((wobB * drft) >> 19);
    incA = cents_inc(m->pitch16, ca, base_fine);
    incB = cents_inc(m->pitch16 + p[P_E1] * 16, cb, base_fine);
    incS = incA >> 1;
    /* pulse widths: the shape (ENV / LFO / matrix -> SHP) and the wander */
    {
        int32_t sh = m->shape - (64 << 8) + ((wob * drft) >> 13);   /* +-1 << 15 of the wander at DRFT 127: ~+-12 % */
        int32_t w = clamp(16384 + (sh >> 1), 2000, 30767);          /* Q15 of a cycle */
        pwA = (uint32_t)w << 17;
        pwB = (uint32_t)(32767 - w) << 17;
    }
    switch (wave) {
    case TW2_SUB: gA = 12000; gB = 9000; gS = 14000; break;
    case TW2_SINE: gA = 19000; gB = 11000; break;
    case TW2_SQR2: pwA = pwB = 0x80000000u; break;
    default: break;
    }
    /* the low-pass: CUT + the modulation + half key tracking + a little of the wander */
    cut = (p[P_E4] << 8) + m->cutoff + ((v->pitch16 - 60 * 16) << 2) + ((wob * drft) >> 12);
    k = 8192 - p[P_E5] * 7700 / 127;                   /* damping 2.0 .. ~0.12 */
    tsvf_coef_k(&flt, cut, k);
    hg = titan_hp_g(p[P_E6]);
    drive = 1024 + grit * 24;                          /* Q10: 1x .. ~4x */
    bmax = 150000 - grit * 820;                        /* GRIT: the band state clipped hard (growl, no ringing) */
    for (i = 0; i < n; i++) {
        int32_t a, b, s, v1, v2, v3, y, ay;
        switch (wave) {
        case TW2_SAWPW:
            a = osc_saw(ph0, incA);
            b = osc_pulse(ph1, incB, pwB);
            break;
        case TW2_PWM2:
        case TW2_SQR2:
            a = osc_pulse(ph0, incA, pwA);
            b = osc_pulse(ph1, incB, pwB);
            break;
        case TW2_SINE:
            a = osc_sine(ph0);
            b = osc_saw(ph1, incB);
            break;
        default:                                       /* SAW2, SUB */
            a = osc_saw(ph0, incA);
            b = osc_saw(ph1, incB);
            break;
        }
        if (ring)                                      /* RING: layer II becomes A x B */
            b += ((((a * b) >> 15) - b) >> 1) * ring >> 14;
        s = ((a * gA) >> 15) + ((b * gB) >> 15);
        if (gS) {                                      /* SUB: a square an octave below A (A's phase, half speed) */
            uint32_t sp = (ph0 >> 1) | ((uint32_t)half << 31);
            s += (osc_pulse(sp, incS, 0x80000000u) * gS) >> 15;
        }
        ph1 += incB;
        {
            uint32_t o = ph0;
            ph0 += incA;
            if (ph0 < o)
                half ^= 1;
        }
        if (hg) {                                      /* the high-pass: what a one-pole low-pass leaves */
            hp += ((s - hp) * hg) >> 15;
            s -= hp;
        }
        if (grit)
            s = softclip((s * drive) >> 10);           /* overdriven into the filter */
        s >>= 1;
        v3 = s - ic2;
        v1 = (flt.a1 * ic1 + flt.a2 * v3) >> 13;
        v2 = ic2 + ((flt.a2 * ic1 + flt.a3 * v3) >> 13);
        ic1 = clamp(2 * v1 - ic1, -bmax, bmax);
        ic2 = clamp(2 * v2 - ic2, -150000, 150000);
        y = v2;
        ay = y < 0 ? -y : y;                           /* linear to half scale, then a soft knee */
        if (ay > 16000) {
            ay = 16000 + (softclip((ay - 16000) * 2) >> 1);
            y = y < 0 ? -ay : ay;
        }
        out[i] += voice_amp(y << 1, m, i) << 1;
    }
    v->ph[0] = ph0;
    v->ph[1] = ph1;
    v->ph[2] = dph;
    v->s[0] = ic1;
    v->s[1] = ic2;
    v->s[2] = half;
    v->s[3] = hp;
}

static const preset_t TITAN_PRESETS[] = {
    /* name, {WAVE, INT, DRFT, RING, CUT, RES, HPF, GRIT}, {A D S R}, fenv, mono, FX(dist, chorus, delay, reverb).
     * The ENV times: ATK 98 is 1.2 s, 104 1.9 s; REL 102 1.6 s (params.c TIME_MS_X10) */
    {"VAST BRASS", {0, 0, 70, 0, 40, 24, 12, 10}, {98, 104, 100, 102}, 40, 0, FX(0, 70, 22, 100), PAT(6)},
    {"NOIR SWELL", {2, 12, 90, 0, 48, 14, 18, 0}, {104, 108, 110, 108}, 24, 0, FX(0, 90, 30, 112), PAT(5)},
    {"GOD STRING", {1, 12, 80, 0, 60, 10, 30, 0}, {100, 104, 115, 106}, 10, 0, FX(0, 100, 25, 105), PAT(5)},
    {"UPSIDE ARP", {1, 12, 24, 0, 46, 62, 14, 18}, {0, 86, 20, 66}, 48, 0, FX(0, 20, 60, 50), PAT(13)},
    {"IRON BASS", {3, 0, 30, 0, 36, 70, 0, 90}, {0, 86, 70, 70}, 40, 1, FX(0, 0, 8, 12), PAT(2)},
    {"2049 GROWL", {3, 0, 64, 18, 26, 66, 0, 118}, {96, 106, 112, 104}, 50, 1, FX(0, 40, 10, 100), PAT(8)},
    {"TEARS LEAD", {0, 0, 50, 0, 54, 30, 16, 20}, {84, 100, 104, 100}, 30, 1, FX(0, 40, 45, 110), PAT(4)},
    {"CATHEDRAL", {2, -12, 110, 30, 70, 8, 40, 0}, {108, 112, 120, 116}, 8, 0, FX(0, 110, 30, 127), PAT(5)},
};

static const engine_t ENG_TITAN = {
    .name = "TITAN",
    .page_title = {"LAYERS", "FILTER"},
    .edit = {
        {"WAVE", F_ENUM, 0, TW2_N - 1, 0, N_TITAN_WAVE, 0},
        {"INT", F_SEMI, -24, 24, 0, 0, 0},
        {"DRFT", F_PCT, 0, 127, 60, 0, 0},
        {"RING", F_PCT, 0, 127, 0, 0, 0},
        {"CUT", F_CUTOFF, 0, 127, 60, 0, 0},
        {"RES", F_PCT, 0, 127, 20, 0, 0},
        {"HPF", F_PCT, 0, 127, 0, 0, 0},
        {"GRIT", F_PCT, 0, 127, 0, 0, 0},
    },
    .presets = TITAN_PRESETS,
    .npresets = NELEM(TITAN_PRESETS),
    .note_on = titan_note_on,
    .render = titan_render,
    .knob = {P_E4, P_E5, P_E2, P_E7},
    .keep = 0x03,                /* the low-pass (s[0], s[1]) over a retrigger */
};
