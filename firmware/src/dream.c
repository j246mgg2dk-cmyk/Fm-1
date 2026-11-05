/* SPDX-License-Identifier: GPL-3.0-only */
/* DREAM (this fork): the FM-1 plays itself, in the manner of the early-80s film scores (big brass swells over rain,
 * a growl from far below, a pulsing arpeggio, a lonely lead). Four parts, all TITAN (eng_titan.c), no samples:
 *   T1 SWELLS   slow brass / pad chords that bloom open, voice-led (each chord's notes the nearest to the last one's)
 *   T2 GROWL    2049 GROWL: the roots far below, overdriven, swelling (with MOTION, a slow heartbeat)
 *   T3 PULSE    UPSIDE ARP: the chord as a running arpeggio, eighths or sixteenths, the filter breathing over it
 *   T4 LEAD     TEARS LEAD: a slow melody, long notes, glides, a vibrato that comes in late
 * It never stops changing. The four tracks are 64 steps of 1/16 (four bars); while the playhead is in one half the
 * other half is written again, so nothing that sounds is touched and the music runs on without a seam. Every half is
 * two bars: a chord a bar (or a chord over both). An ACT is 16 halves (32 bars): it EMERGEs (the swells alone, dark),
 * BLOOMs (the pulse), RISEs (the lead, the growl), PEAKs (everything, open) and DISSOLVEs; then a new progression,
 * and with DRIFT a new key, a new mood, another arpeggio. The swells' cutoff, the layers' drift, the pulse's filter
 * and the space breathe slowly all the time (dream_poll, the main loop).
 * The controls (GLO > DREAM; nothing stored but the music itself):
 *   MOOD    NOIR RAIN PULSE NEON VOID ALIEN (aeolian, dorian, aeolian and fast, ionian, phrygian, hungarian minor)
 *   MOTION  how much happens: the pulse in sixteenths, the growl's heartbeat, the lead's phrases
 *   BLOOM   how bright and open (the cutoffs, the sevenths and ninths)
 *   DRIFT   how fast it wanders off: new progressions, keys and moods
 * The music it writes is ordinary steps and sounds: edit a step and DREAM hands it over (it stays a project like any
 * other: save it, change it). Deterministic: the same seed and the same moves play the same (the host test). */
#define DR_HALF 32u
#define DR_ACT 16u
#define DR_NMOOD 6u
static const char *const N_DR_MOOD[DR_NMOOD] = {"NOIR", "RAIN", "PULSE", "NEON", "VOID", "ALIEN"};
enum { DM_NOIR, DM_RAIN, DM_PULSE, DM_NEON, DM_VOID, DM_ALIEN };
static const uint8_t DR_SCALE[DR_NMOOD][7] = {
    {0, 2, 3, 5, 7, 8, 10},      /* NOIR: aeolian */
    {0, 2, 3, 5, 7, 9, 10},      /* RAIN: dorian */
    {0, 2, 3, 5, 7, 8, 10},      /* PULSE: aeolian, the pulse in front */
    {0, 2, 4, 5, 7, 9, 11},      /* NEON: ionian */
    {0, 1, 3, 5, 7, 8, 10},      /* VOID: phrygian */
    {0, 2, 3, 6, 7, 8, 11},      /* ALIEN: hungarian minor */
};
/* progressions: scale degrees (0 = the tonic), four chords; per mood family */
static const uint8_t DR_PROG_MIN[][4] = {{0, 5, 2, 6}, {0, 3, 5, 4}, {0, 6, 5, 6}, {0, 5, 3, 4}, {0, 2, 5, 6},
                                         {0, 3, 0, 5}, {0, 5, 6, 4}, {5, 6, 0, 0}};
static const uint8_t DR_PROG_MAJ[][4] = {{0, 4, 5, 3}, {0, 1, 0, 4}, {0, 5, 3, 4}, {3, 0, 4, 5}, {0, 3, 5, 4},
                                         {0, 2, 3, 1}, {5, 3, 0, 4}, {0, 1, 3, 0}};
static const uint8_t DR_PROG_DARK[][4] = {{0, 1, 0, 6}, {0, 1, 6, 5}, {0, 6, 1, 0}, {0, 3, 1, 0}, {0, 5, 1, 6},
                                          {0, 0, 1, 1}, {0, 6, 5, 1}, {0, 1, 3, 1}};
/* the sounds: TITAN's presets (eng_titan.c); the swells by mood */
enum { TP_BRASS, TP_SWELL, TP_STRING, TP_ARP, TP_IRON, TP_GROWL, TP_LEAD, TP_CATH };
static const uint8_t DR_PAD[DR_NMOOD] = {TP_BRASS, TP_SWELL, TP_SWELL, TP_STRING, TP_CATH, TP_CATH};
static const uint8_t DR_BPM[DR_NMOOD] = {72, 76, 92, 84, 64, 70};
/* the pulse's figures over a chord's four notes (0 = the lowest), a step each; 4..7: the same an octave up */
#define DR_NFIG 6u
static const uint8_t DR_FIG[DR_NFIG][8] = {
    {0, 1, 2, 3, 4, 3, 2, 1},    /* up and down */
    {0, 2, 1, 3, 2, 4, 3, 5},    /* climbing thirds */
    {0, 1, 2, 3, 0, 1, 2, 3},    /* up, again */
    {0, 2, 4, 2, 1, 3, 5, 3},    /* the wide one */
    {4, 3, 2, 1, 3, 2, 1, 0},    /* falling */
    {0, 4, 1, 4, 2, 4, 3, 4},    /* the pedal: the octave between */
};
static struct {
    uint8_t on;                  /* DREAM is writing the music */
    uint8_t mood, motion, bloom, drift;   /* the controls (MOOD 0..5, the others 0..127) */
    uint8_t moved;               /* the controls changed: the next half follows at once */
    uint8_t written;             /* the half written last (0 / 1), 2 = none yet */
    uint8_t key;                 /* the tonic, 0..11 (C..B) */
    uint8_t prog[4];             /* the act's progression (scale degrees) */
    uint8_t chord[4];            /* the pad's chord sounding (MIDI notes, sorted), voice-led from it */
    uint8_t fig;                 /* the pulse's figure (DR_FIG) */
    uint8_t melo;                /* the voice's last note (MIDI), 0 none */
    uint16_t half;               /* halves written since the start */
    uint32_t rng, seed;
    uint32_t t0;                 /* song.tick at the start (the breathing's clock) */
    int16_t cut0[NTRK];          /* the sounds' own cutoffs (EDIT CUT): the breathing moves around them */
    int32_t lift_q8, lvl_q8;     /* the act's cutoff lift and the pad's level, gliding to the phase's (1/256) */
    uint32_t glide_t;            /* song.tick of the last glide step */
    uint32_t sig;                /* the steps as DREAM left them (dr_sig): another value, the user edited them */
    uint32_t sig_ms;             /* fm1_ms of the last look */
    uint8_t named;               /* 1: a new dream began (main.c names the music DREAM) */
    uint8_t said;                /* the phase shown last + 1 (main.c: the toast), 0 none */
} dream = {.motion = 56, .bloom = 70, .drift = 48, .written = 2};

static uint32_t dr_rand(void)                     /* xorshift32 */
{
    uint32_t s = dream.rng;
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return dream.rng = s ? s : 0x9E3779B9u;
}
static uint32_t dr_pick(uint32_t n) { return n ? (dr_rand() >> 8) % n : 0u; }
static int dr_chance(uint32_t pct) { return dr_pick(100u) < pct; }

static const uint8_t (*dr_progs(uint32_t *n))[4]
{
    switch (dream.mood) {
    case DM_NEON: *n = NELEM(DR_PROG_MAJ); return DR_PROG_MAJ;
    case DM_VOID: case DM_ALIEN: *n = NELEM(DR_PROG_DARK); return DR_PROG_DARK;
    default: *n = NELEM(DR_PROG_MIN); return DR_PROG_MIN;           /* NOIR RAIN PULSE */
    }
}

/* scale degree d (any, wraps by octaves) as semitones above the tonic */
static int32_t dr_deg(int32_t d)
{
    int32_t o = d >= 0 ? d / 7 : -((6 - d) / 7);
    return 12 * o + DR_SCALE[dream.mood % DR_NMOOD][d - 7 * o];
}

/* the pad's next chord on degree d: root, third, fifth and, with BLOOM, the seventh or the ninth, each tone in the
 * octave nearest the chord before (voice leading), within 50..79 */
static void dr_chord(uint32_t d, uint8_t *out)
{
    int32_t tones[4], i, k, c = 0;
    tones[0] = dr_deg((int32_t)d);
    tones[1] = dr_deg((int32_t)d + 2);
    tones[2] = dr_deg((int32_t)d + 4);
    tones[3] = dr_deg((int32_t)d + (dream.bloom > 80 ? 8 : dream.bloom > 40 ? 6 : 7));   /* 9th, 7th, the octave */
    for (i = 0; i < 4; i++)
        c += dream.chord[i];
    c = dream.chord[0] ? c / 4 : 64;                  /* the last chord's middle */
    for (i = 0; i < 4; i++) {
        int32_t n = 48 + (int32_t)dream.key + tones[i], best = n, bd = 999;
        for (k = -3; k <= 3; k++) {
            int32_t m = n + 12 * k, dd = m - c - (i - 1) * 4;   /* spread the four around the middle */
            if (dd < 0)
                dd = -dd;
            if (m >= 50 && m <= 79 && dd < bd) {
                bd = dd;
                best = m;
            }
        }
        out[i] = (uint8_t)best;
    }
    for (i = 1; i < 4; i++)                           /* sorted, no two the same */
        for (k = i; k > 0 && out[k] < out[k - 1]; k--) {
            uint8_t s = out[k];
            out[k] = out[k - 1];
            out[k - 1] = s;
        }
    for (i = 1; i < 4; i++)
        if (out[i] <= out[i - 1])
            out[i] = (uint8_t)(out[i - 1] + 12 <= 84 ? out[i - 1] + 12 : out[i - 1] + 1);
}

/* the phase of the act a half is in: 0 EMERGE, 1 BLOOM, 2 RISE, 3 PEAK, 4 DISSOLVE */
enum { DA_EMERGE, DA_BLOOM, DA_RISE, DA_PEAK, DA_DISSOLVE };
static const char *const N_DR_ACT[5] = {"EMERGE", "BLOOM", "RISE", "PEAK", "DISSOLVE"};
static uint32_t dr_phase(uint32_t h)
{
    h %= DR_ACT;
    return h < 4u ? DA_EMERGE : h < 7u ? DA_BLOOM : h < 11u ? DA_RISE : h < 14u ? DA_PEAK : DA_DISSOLVE;
}

static void dr_step(track_t *t, uint32_t i, uint32_t n, const uint8_t *notes, uint32_t time, uint32_t vel,
                    uint32_t chance)
{
    step_t *s = &t->step[i % NSTEP];
    uint32_t k;
    memset(s, 0, sizeof *s);
    s->n = (uint8_t)n;
    for (k = 0; k < n && k < 4u; k++)
        s->note[k] = notes[k];
    s->time = (uint8_t)time;
    s->vel = (uint8_t)(n ? vel : 0u);
    if (n && chance < 100u)
        step_set_chance(s, chance);
}
static void dr_rest(track_t *t, uint32_t a, uint32_t b)
{
    for (; a < b; a++)
        dr_step(t, a, 0, 0, ST_REST, 0, 100);
}
static void dr_hold(track_t *t, uint32_t at, uint32_t len, uint32_t n, const uint8_t *notes, uint32_t vel)
{
    uint32_t i;
    dr_step(t, at, n, notes, ST_NOTE, vel, 100);
    for (i = 1; i < len; i++)
        dr_step(t, at + i, 0, 0, ST_TIE, 0, 100);
}

/* a new act: its progression, and with DRIFT a new key, a new mood, another figure for the pulse */
static void dr_act(void)
{
    uint32_t n;
    const uint8_t (*pr)[4];
    if (dream.half && dr_chance(dream.drift * 3u / 4u))        /* a new key: a fourth or a fifth away, or a third */
        dream.key = (uint8_t)((dream.key + (dr_chance(50) ? 5u : dr_chance(50) ? 7u : 3u)) % 12u);
    if (dream.half && dr_chance(dream.drift > 90 ? 40u : 0u))  /* far gone: another mood */
        dream.mood = (uint8_t)dr_pick(DR_NMOOD);
    pr = dr_progs(&n);
    memcpy(dream.prog, pr[dr_pick(n)], 4);
    if (!dream.half || dr_chance(dream.drift))
        dream.fig = (uint8_t)dr_pick(DR_NFIG);
}

/* the voice's next note: a chord tone or a step of the scale from the last one, in 60..81 */
static uint8_t dr_melody_note(const uint8_t *chord)
{
    int32_t n;
    if (!dream.melo || dr_chance(45)) {
        n = chord[dr_pick(4)];
        while (n < 62)
            n += 12;
        while (n > 81)
            n -= 12;
    } else {
        int32_t i, best = 0, bd = 99, want = (int32_t)dream.melo + (dr_chance(50) ? 2 : -2) * (int32_t)(1u + dr_pick(2));
        for (i = 0; i < 4; i++) {                     /* the chord tone nearest where the line wants to go */
            int32_t m = chord[i], d;
            while (m < want - 6) m += 12;
            while (m > want + 6) m -= 12;
            d = m > want ? m - want : want - m;
            if (d < bd) { bd = d; best = m; }
        }
        n = best < 60 ? best + 12 : best > 81 ? best - 12 : best;
    }
    return dream.melo = (uint8_t)n;
}

/* half h of the music into the steps of half `which` (0: 0..31, 1: 32..63) */
static void dr_write(uint32_t which)
{
    uint32_t base = which * DR_HALF, h = dream.half, ph, i, bar;
    uint32_t mo = dream.motion, bl = dream.bloom;
    track_t *pad = &trk[0], *dep = &trk[1], *sta = &trk[2], *voc = &trk[3];
    uint8_t ch[2][4], root[2];
    if (h % DR_ACT == 0u && h)
        dr_act();
    ph = dr_phase(h);
    /* the chords of the two bars: degrees 2 (h % 2) and 2 (h % 2) + 1 of the progression; slow moods hold one over both */
    for (bar = 0; bar < 2u; bar++) {
        uint32_t d = dream.prog[(2u * (h % 2u) + bar) & 3u];
        if (bar == 1u && mo < 30 && dream.prog[(2u * (h % 2u)) & 3u] == d)
            d = dream.prog[(2u * (h % 2u)) & 3u];
        dr_chord(d, ch[bar]);
        memcpy(dream.chord, ch[bar], 4);
        root[bar] = (uint8_t)(36 + ((int32_t)dream.key + dr_deg((int32_t)d)) % 12);   /* C2 .. B2 */
        if (root[bar] < 40)
            root[bar] += 12;                          /* E2 .. D#3: under the pad, above the mud */
    }
    /* T1 PAD: a chord a bar (MOTION low and the same degree twice: one over both) */
    if (mo < 30 && ch[0][0] == ch[1][0] && ch[0][1] == ch[1][1])
        dr_hold(pad, base, DR_HALF, 4, ch[0], 92);
    else {
        dr_hold(pad, base, 16, 4, ch[0], 92);
        dr_hold(pad, base + 16u, 16, 4, ch[1], 88);
    }
    /* T2 GROWL: the root far below, overdriven, swelling over both bars; RISE and PEAK (VOID: from BLOOM; EMERGE too
     * with BLOOM high); MOTION high at the PEAK: a slow heartbeat (dotted eighths) */
    if (ph == DA_RISE || ph == DA_PEAK || (ph == DA_BLOOM && dream.mood == DM_VOID) || (ph == DA_EMERGE && bl > 100)) {
        if (mo > 80 && ph == DA_PEAK) {
            for (bar = 0; bar < 2u; bar++) {
                uint32_t at = base + 16u * bar;
                dr_rest(dep, at, at + 16u);
                for (i = 0; i < 16u; i += 3u)
                    dr_hold(dep, at + i, i + 3u <= 16u ? 2u : 1u, 1, &root[bar], i ? 72 : 110);
            }
        } else if (root[0] == root[1]) {
            dr_hold(dep, base, DR_HALF, 1, &root[0], 104);
        } else {
            dr_hold(dep, base, 16, 1, &root[0], 104);
            dr_hold(dep, base + 16u, 16, 1, &root[1], 96);
        }
    } else {
        dr_rest(dep, base, base + DR_HALF);
    }
    /* T3 PULSE: the chord as a running figure, an octave over the swells' middle; eighths, sixteenths with MOTION
     * (PULSE: always, and from EMERGE); accents on the beats; DISSOLVE thins it out */
    dr_rest(sta, base, base + DR_HALF);
    if (ph != DA_EMERGE || dream.mood == DM_PULSE || bl > 110) {
        uint32_t sixteenths = mo > 70 || dream.mood == DM_PULSE, every = sixteenths ? 1u : 2u, n_ = 0;
        for (i = 0; i < DR_HALF; i += every, n_++) {
            const uint8_t *c = ch[i / 16u];
            uint32_t f = DR_FIG[dream.fig % DR_NFIG][n_ % 8u], vel;
            uint8_t nt = (uint8_t)(c[f & 3u] + (f >= 4u ? 12u : 0u));
            while (nt < 57)
                nt += 12;
            while (nt > 84)
                nt -= 12;
            vel = (i % 4u) == 0u ? 112u : 84u + dr_pick(12);
            dr_step(sta, base + i, 1, &nt, ST_NOTE, vel, ph == DA_DISSOLVE ? 55u + dr_pick(25) : 100u);
        }
    }
    /* T4 LEAD: a phrase in RISE and PEAK, every other half (call and answer): 2..4 long notes, gliding */
    dr_rest(voc, base, base + DR_HALF);
    if ((ph == DA_RISE || ph == DA_PEAK) && ((h & 1u) == 0u || mo > 90)) {
        uint32_t notes = 2u + dr_pick(mo > 60 ? 3u : 2u), at = dr_pick(3) * 2u, len;
        for (i = 0; i < notes && at < DR_HALF - 2u; i++) {
            uint8_t n = dr_melody_note(ch[at / 16u]);
            len = (DR_HALF - at) / (notes - i);
            len = len > 4u ? len - dr_pick(len / 3u) : len;
            dr_hold(voc, base + at, len, 1, &n, 80 + dr_pick(30));
            at += len + (dr_chance(30) ? 2u : 0u);
        }
    } else {
        dream.melo = 0;
    }
    dream.half++;
}

/* a sound: engine e, preset pi, as a sound load does (ui.c apply_preset_to): the track's other values to their
 * defaults, then the preset's (the steps are written by DREAM) */
static void dr_sound(track_t *t, uint32_t e, uint32_t pi)
{
    static const uint8_t FX_DEF[4] = {0, 24, 28, 36};
    const engine_t *en = ENGINES[e % NENGINES];
    const preset_t *pr = &en->presets[pi % (en->npresets ? en->npresets : 1u)];
    uint32_t i;
    for (i = 0; i < P_E0; i++)
        t->p[i] = TP[i].def;
    t->eng_req = (uint8_t)e;
    t->preset = (uint8_t)(pi % (en->npresets ? en->npresets : 1u));
    t->user = 0;
    for (i = 0; i < 8u; i++)
        t->p[P_E0 + i] = en->npresets ? pr->e[i] : en->edit[i].def;
    if (en->npresets) {
        t->p[P_ATK] = pr->env[0];
        t->p[P_DEC] = pr->env[1];
        t->p[P_SUS] = pr->env[2];
        t->p[P_REL] = pr->env[3];
        t->p[P_ED_FLT] = pr->fenv;
        t->p[P_VOICE] = pr->mono ? V_LEGATO : V_POLY;
        for (i = 0; i < 4u; i++)
            t->p[P_DIST + i] = (int16_t)(pr->fx[i] ? pr->fx[i] - 1 : FX_DEF[i]);
    }
    t->p[P_SLEN] = NSTEP;
    t->p[P_SDIV] = 2;                                 /* 1/16 */
    t->p[P_SGATE] = 120;
}

/* the mix and the space, from the mood and BLOOM */
static void dr_mix(void)
{
    track_t *pad = &trk[0], *dep = &trk[1], *sta = &trk[2], *voc = &trk[3];
    pad->p[P_LEVEL] = 100;
    pad->p[P_SPRD] = 90;
    dep->p[P_LEVEL] = 84;
    sta->p[P_LEVEL] = 110;
    sta->p[P_SPRD] = 70;
    sta->p[P_SGATE] = 64;                             /* the pulse: short */
    voc->p[P_LEVEL] = 92;
    voc->p[P_GLIDE] = 50;
    song.g[G_BPM] = DR_BPM[dream.mood % DR_NMOOD];
    song.g[G_RTYPE] = 2;                              /* HALL */
    song.g[G_RSIZE] = 118;
    song.g[G_RDAMP] = 50;
    song.g[G_DTIME] = 1;                              /* 1/8 */
    song.g[G_DFDBK] = 62;
    song.g[G_DMIX] = 90;
    song.g[G_CDEPTH] = 90;
    song.g[G_CRATE] = 20;
    song.g[G_SWING] = 0;
}

/* the four tracks' steps, hashed (FNV-1a): DREAM's own writes keep it, anyone else's (REC, STEP, a pattern, a load)
 * changes it, and DREAM hands the music over (dream_poll) */
static uint32_t dr_sig(void)
{
    uint32_t h = 2166136261u, k, i;
    for (k = 0; k < NTRK; k++) {
        const uint8_t *b = (const uint8_t *)trk[k].step;
        for (i = 0; i < sizeof trk[k].step; i++)
            h = (h ^ b[i]) * 16777619u;
    }
    return h;
}

/* start dreaming: the four sounds, the space, the first two halves, PLAY. Nothing of the project before stays (its
 * steps, automation and song chain); call from the main loop */
static void dream_start(uint32_t seed)
{
    uint32_t k, f;
    if (chain.running || chain.armed)
        chain_stop();
    transport_req = 2;
    panic_req = (1u << NTRK) - 1u;
    for (k = 0; k < NTRK; k++)
        motion_clear(&trk[k]);
    f = motion_guard();                               /* the audio ISR must not see half a dream */
    seq_stop();
    transport_req = 0;
    dream.seed = seed ? seed : 0x5EED1234u;
    dream.rng = dream.seed * 2654435761u + 1u;
    dream.key = (uint8_t)dr_pick(12);
    memset(dream.chord, 0, sizeof dream.chord);
    dream.melo = 0;
    dream.half = 0;
    dream.fig = 0;
    dr_act();                                         /* the first act's progression; it starts halfway into EMERGE */
    dream.half = 2;
    dream.lift_q8 = -30 << 8;
    dream.lvl_q8 = 80 << 8;
    dr_sound(&trk[0], ENGI_TITAN, DR_PAD[dream.mood % DR_NMOOD]);
    dr_sound(&trk[1], ENGI_TITAN, TP_GROWL);
    dr_sound(&trk[2], ENGI_TITAN, TP_ARP);
    dr_sound(&trk[3], ENGI_TITAN, TP_LEAD);
    trk[3].p[P_LRATE] = 86;                           /* the lead's vibrato: 4.6 Hz, +-0.4 semitone, coming in late */
    trk[3].p[P_LD_PIT] = 2;
    trk[3].p[P_LFADE] = 100;
    for (k = 0; k < NTRK; k++) {
        trk[k].seq_active = 1;
        dream.cut0[k] = trk[k].p[P_E4];
    }
    dr_mix();
    dr_write(0);
    dr_write(1);
    dream.written = 1;
    dream.on = 1;
    dream.moved = 0;
    dream.named = 1;
    dream.said = 0;
    motion_unguard(f);
    dream.sig = dr_sig();
    dream.t0 = dream.glide_t = 0;                   /* (song.tick starts at 0 with PLAY) */
    transport_req = 1;
}

static void dream_stop(void) { dream.on = 0; }


/* the controls (GLO > DREAM): MOOD changes the key's colour from the next half; the pad and the voice follow it at the
 * next act */
static void dream_set(uint32_t c, int32_t v)
{
    switch (c) {
    case 0: dream.mood = (uint8_t)clamp(v, 0, DR_NMOOD - 1); break;
    case 1: dream.motion = (uint8_t)clamp(v, 0, 127); break;
    case 2: dream.bloom = (uint8_t)clamp(v, 0, 127); break;
    default: dream.drift = (uint8_t)clamp(v, 0, 127); break;
    }
    dream.moved = 1;
}
static const param_desc_t DR_DESC[4] = {          /* GLO > DREAM's four knobs (ui_draw.c: their cards) */
    {"MOOD", F_ENUM, 0, DR_NMOOD - 1, 0, N_DR_MOOD, 0},
    {"MOTION", F_PCT, 0, 127, 56, 0, 0},
    {"BLOOM", F_PCT, 0, 127, 70, 0, 0},
    {"DRIFT", F_PCT, 0, 127, 48, 0, 0},
};
static int32_t dream_get(uint32_t c)
{
    return c == 0 ? dream.mood : c == 1 ? dream.motion : c == 2 ? dream.bloom : dream.drift;
}

/* the breathing: a slow sine of `period` blocks at phase `ph` (Q15) */
static int32_t dr_breath(uint32_t now, uint32_t period, uint32_t ph)
{
    return sine_i((uint32_t)((uint64_t)(now % period) * 0xFFFFFFFFu / period) + ph);
}

/* main loop, every pass: the half not playing written again; the sounds breathe */
static void dream_poll(void)
{
    uint32_t idx, playing_half, now, f;
    if (!dream.on)
        return;
    if (fm1_ms - dream.sig_ms >= 100u) {              /* ten times a second: steps DREAM did not write */
        dream.sig_ms = fm1_ms;
        if (dr_sig() != dream.sig) {
            dream.on = 0;                             /* the user took the music over: it stays as it is */
            return;
        }
    }
    if (!song.playing)
        return;
    idx = trk[0].seq_idx % NSTEP;
    playing_half = idx >= DR_HALF ? 1u : 0u;
    if (playing_half == dream.written) {              /* it plays the half written last: write the other one */
        f = motion_guard();
        dr_write(playing_half ^ 1u);
        dream.written = (uint8_t)(playing_half ^ 1u);
        motion_unguard(f);
        dream.sig = dr_sig();
        dream.moved = 0;
    }
    /* the breathing (sub-blocks since PLAY): the pad's cutoff around its own with BLOOM and the act, the drift, the
     * pulse's filter. Main-loop writes of one value each: as a knob turn */
    now = song.tick - dream.t0;
    {
        static const int8_t LIFT[5] = {-30, -12, 0, 18, -18};   /* EMERGE BLOOM RISE PEAK DISSOLVE */
        static const uint8_t LVL[5] = {80, 92, 100, 108, 86};
        uint32_t ph = dr_phase(dream.half ? dream.half - 1u : 0u);
        int32_t want_lift = (LIFT[ph] + (int32_t)dream.bloom / 3 - 20) << 8, want_lvl = LVL[ph] << 8;
        int32_t b1 = dr_breath(now, 41u * 1378u, 0), b2 = dr_breath(now, 29u * 1378u, 0x40000000u), lift;
        if (song.tick - dream.glide_t >= 69u) {      /* every 50 ms: the act's colour glides (about 12 s end to end) */
            dream.glide_t = song.tick;
            dream.lift_q8 += clamp(want_lift - dream.lift_q8, -128, 128);
            dream.lvl_q8 += clamp(want_lvl - dream.lvl_q8, -100, 100);
        }
        lift = dream.lift_q8 >> 8;
        trk[0].p[P_E4] = (int16_t)clamp(dream.cut0[0] + lift + (b1 * 22 >> 15), 8, 122);
        trk[0].p[P_E2] = (int16_t)clamp(70 + (b2 * 40 >> 15), 0, 127);
        trk[0].p[P_LEVEL] = (int16_t)clamp(dream.lvl_q8 >> 8, 0, 127);
        trk[3].p[P_E4] = (int16_t)clamp(dream.cut0[3] + lift / 2 + (b2 * 12 >> 15), 8, 122);
        trk[2].p[P_E4] = (int16_t)clamp(dream.cut0[2] + lift / 2 + (dr_breath(now, 17u * 1378u, 0) * 18 >> 15), 8, 120);
        trk[1].p[P_E4] = (int16_t)clamp(dream.cut0[1] + lift / 3 + (b2 * 8 >> 15), 8, 100);
    }
}
