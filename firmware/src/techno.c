/* SPDX-License-Identifier: GPL-3.0-only */
/* TECHNO (this fork): a techno partner that keeps time with whatever else is playing. Kicks, hats, percussion and a
 * bassline, written as it goes, locked to the clock that comes in (MIDI CLK AUTO: USB or TRS, whichever sends; the
 * Song Position Pointer: started from bar 9 in the DAW, it plays bar 9). Four tracks, all ordinary steps:
 *   T1 KICK    DRUM, four on the floor (ROBOT: broken), the downbeats never left out but in a BREAK
 *   T2 HATS    DRUM, closed, open (the closed one chokes it) and the ride: offbeats, sixteenths, ghosts
 *   T3 PERC    DRUM, the backbeat clap, a motif of rims / congas / toms / bells, the fills and the rolls
 *   T4 BASS    ANALOG: the rumble, offbeat bass, an acid line, dub chords or an electro bass, by STYLE
 * The tracks are 64 steps of 1/16 (four bars). As in DREAM (dream.c) the half not playing (two bars) is written
 * again while the other plays, so nothing that sounds is touched. The halves are counted from the transport's start
 * (or the song position it was started from), so a PHRASE (16 bars) starts with the master's bars: 1, 17, 33 ..
 * A SET is four phrases: GROOVE (thinner; EVOLVE 80 up: the bass out), LIFT, PEAK (everything, the ride, the clap),
 * then with EVOLVE a BREAK (the kick out for four bars, a BUILD, the DROP) or a new motif. EVOLVE at 0: a loop that
 * never changes. The fills (a roll into the next phrase) come with EVOLVE too.
 * The controls (GLO > TECHNO; the keys pick the bassline's key, C .. B, silently):
 *   STYLE   HYPNO DARK (Berlin) SOUL (Detroit) DUB ACID ROBOT (electro) HARD (hard techno) INDUS (industrial): the
 *           kits, the sounds, the bass, the tempo on the internal clock
 *   DRIVE   the energy: hats from offbeats to sixteenths, more percussion, the kick's drive, the bass brighter
 *   GROOVE  the swing, the ghost notes, the hats' dynamics
 *   EVOLVE  how much it changes: 0 a fixed loop, then fills, new motifs, the arrangement, at the top the BREAK
 * GLO again, DRUMS: the drums by hand, at once (the steps are not touched):
 *   KIT     AUTO (the style's kits) or one kit for kick, hats and percussion: CRISP HARD 8BIT RUST (drum_voice.c, made
 *           for this) STD 80 10 66 55 77 DEEP TIGHT PERC
 *   KICK    64 the kit's kick; down longer, rounder, lower; up shorter, harder, more sweep and drive
 *   HATS    64 the kit's hats; down darker and tighter; up brighter, longer, more sizzle
 *   CRUSH   0 off; up the INSERT's CRUSH on the three drum tracks, 12 bits down to 4, the rate down to 5.5 kHz
 *           (8BIT and CRUSH: the old game consoles' drums)
 * OCT+: a new groove (the controls as they are). Playing: from the next half, without stopping (the clock goes on).
 * Edit a step and TECHNO hands the music over, as DREAM does. Deterministic: the same seed, the same music. */
#define TC_HALF 32u
#define TC_NSTYLE 8u
#define CLK_AUTO_MODE 3u                         /* G_CLOCK's AUTO (fx.c) */
static const char *const N_TC_STYLE[TC_NSTYLE] = {"HYPNO", "DARK", "SOUL", "DUB", "ACID", "ROBOT", "HARD", "INDUS"};
enum { TS_HYPNO, TS_DARK, TS_SOUL, TS_DUB, TS_ACID, TS_ROBOT, TS_HARD, TS_INDUS };
enum { TB_RUMBLE, TB_OFFBEAT, TB_ACID, TB_DUB, TB_ROBOT };      /* the bass's kinds */
enum { AP_INIT = 0, AP_SUB = 7, AP_SQR = 2, AP_ACID = 4, AP_PLUCK = 8 };   /* ANALOG's presets (engines/src/eng_analog.c) */
typedef struct {
    uint8_t bpm, swing;                          /* the internal clock's tempo; the swing at GROOVE 0 */
    uint8_t kkit, kround, ktune, kdecy, kdrv;    /* the kick: DRUM's KIT, KICK (ROUND), TUNE, DECY, DRV */
    uint8_t hkit, pkit;                          /* the hats' kit, the percussion's */
    uint8_t bpre, bkind, scale;                  /* the bass: ANALOG's preset, TB_*, its notes (TC_SCALE) */
    uint8_t open;                                /* open hats on the offbeats from this hat level (0..4; 5 never) */
    uint8_t clap;                                /* the backbeat from this energy level (0..4; 5 never) */
    uint8_t lanes;                               /* the motif's lanes (bits: DV_*) */
    uint8_t poly;                                /* the motif runs in threes across the bar (hypnotic) */
} tc_style_t;
#define TL(l) (1u << (l))
static const tc_style_t TC_STYLE[TC_NSTYLE] = {
    /* HYPNO: a snapped punch, rolling rumble, rims in threes, congas */
    {128, 6, DK_CRISP, 0, 62, 70, 20, DK_CRISP, DK_PERC, AP_SUB, TB_RUMBLE, 0, 3, 5, TL(DV_RIM) | TL(DV_TOM), 1},
    /* DARK (Berlin): the big driven kick, open hats on the offbeats, rumble, a clap at the peak */
    {133, 0, DK_CRISP, 0, 58, 80, 48, DK_CRISP, DK_CRISP, AP_SUB, TB_RUMBLE, 0, 1, 3, TL(DV_RIM) | TL(DV_TOM), 0},
    /* SOUL (Detroit): sixteenth hats, the 808 clap, an offbeat bass in dorian, a cowbell */
    {126, 12, DK_CRISP, 0, 64, 60, 12, DK_CRISP, DK_80, AP_SQR, TB_OFFBEAT, 1, 2, 1, TL(DV_RIM) | TL(DV_BELL), 0},
    /* DUB: soft and round, shuffled hats, the chord stab into the dotted delay */
    {120, 18, DK_STD, 1, 56, 60, 0, DK_STD, DK_DEEP, AP_PLUCK, TB_DUB, 0, 4, 5, TL(DV_RIM) | TL(DV_TOM), 0},
    /* ACID: a tight kick, open hats, the 303 line sliding */
    {130, 10, DK_CRISP, 0, 64, 64, 30, DK_CRISP, DK_80, AP_ACID, TB_ACID, 2, 1, 2, TL(DV_RIM), 0},
    /* ROBOT (electro): the 808, a broken kick, the snare on two and four */
    {128, 0, DK_80, 0, 64, 70, 0, DK_80, DK_80, AP_SQR, TB_ROBOT, 0, 2, 0, TL(DV_TOM) | TL(DV_RIM), 0},
    /* HARD: fast, the held, driven HARD kick, its ghosts, loud open hats, the ride, a rumble that distorts */
    {148, 0, DK_HARD, 0, 64, 64, 40, DK_HARD, DK_HARD, AP_SUB, TB_RUMBLE, 2, 1, 2, TL(DV_RIM) | TL(DV_TOM), 0},
    /* INDUS (industrial): the RUST kit, metal in threes, the long rumble in phrygian, a big clap */
    {136, 0, DK_RUST, 0, 60, 72, 40, DK_RUST, DK_RUST, AP_SUB, TB_RUMBLE, 2, 3, 2, TL(DV_TOM) | TL(DV_BELL) | TL(DV_RIM), 1},
};
static const uint8_t TC_SCALE[3][5] = {
    {0, 3, 5, 7, 10},                            /* minor pentatonic */
    {0, 3, 5, 7, 9},                             /* dorian's colour */
    {0, 1, 3, 7, 10},                            /* phrygian's */
};
/* the kick's patterns (bit i: step i of the bar); ROBOT's own */
static const uint16_t TC_KICK_EL[4] = {0x0449u, 0x2441u, 0x0849u, 0x2449u};   /* 0 3 6 10 / 0 6 10 13 / .. */

static struct {
    uint8_t on;                                  /* TECHNO is writing the music */
    uint8_t style, drive, groove, evolve;        /* the controls (STYLE 0..5, the others 0..127) */
    uint8_t key;                                 /* the bassline's key, 0..11 (C..B) */
    uint8_t moved;                               /* the controls changed: the next half takes them (the sounds too) */
    uint8_t written;                             /* the half written last (0 / 1) */
    uint8_t fresh;                               /* OCT+ while playing: new motifs from the next half */
    uint8_t named, said;                         /* main.c: the name TECHNO, the phase shown last + 1 */
    uint8_t sty_sound;                           /* the style the sounds are of */
    uint8_t prev_half;                           /* the half the playhead was in at the last look */
    uint8_t was_playing;
    uint32_t abs;                                /* the half the playhead is in, from the transport's start */
    uint32_t phrase_made;                        /* the phrase the motifs were made for + 1 */
    uint32_t rng, seed;
    uint32_t sig, sig_ms;                        /* the steps as TECHNO left them (dr_sig, dream.c) */
    uint32_t t0;                                 /* song.tick at the start (the breathing) */
    int16_t cut0;                                /* the bass sound's own cutoff */
    /* the motifs (a phrase's; kept while EVOLVE keeps them) */
    int8_t hum[16];                              /* the hats' velocity by step (-16..+16 at GROOVE 127) */
    uint16_t perc;                               /* the percussion motif (bit i: step i of the bar) */
    uint8_t plane[16];                           /* .. the lane of each */
    uint8_t ghost;                               /* the kick's ghost step (2 or 3 after a beat), 0 none */
    uint8_t kpat;                                /* ROBOT's kick pattern */
    uint8_t bmask;                               /* the bass's steps in a beat (bit q: 16th q of the beat) */
    uint8_t bline[16], bflag[16];                /* ACID / ROBOT: the notes (the scale's degree + 1, + 8 an octave up;
                                                  * 0 a rest), their flags */
    uint8_t chord;                               /* DUB: the stab's rhythm */
    uint8_t dkit, dkick, dhats, dcrush;          /* DRUMS: KIT (0 AUTO, TC_KIT), KICK, HATS (64: as the kit), CRUSH */
} techno = {.style = TS_DARK, .drive = 72, .groove = 40, .evolve = 48, .key = 9, .written = 1, .dkick = 64, .dhats = 64};
/* DRUMS > KIT: AUTO, then the kits as DRUM stores them */
#define TC_NKIT 14u
static const char *const N_TC_KIT[TC_NKIT] = {"AUTO", "CRISP", "HARD", "8BIT", "RUST", "STD", "80", "10", "66", "55",
                                              "77", "DEEP", "TIGHT", "PERC"};
static const uint8_t TC_KIT[TC_NKIT] = {0, DK_CRISP, DK_HARD, DK_8BIT, DK_RUST, DK_STD, DK_80, DK_10, DK_66, DK_55,
                                        DK_77, DK_DEEP, DK_TIGHT, DK_PERC};

static uint32_t tc_rand(void)                     /* xorshift32 */
{
    uint32_t s = techno.rng;
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return techno.rng = s ? s : 0x9E3779B9u;
}
static uint32_t tc_pick(uint32_t n) { return n ? (tc_rand() >> 8) % n : 0u; }
static int tc_chance(uint32_t pct) { return tc_pick(100u) < pct; }
static const tc_style_t *tc_sty(void) { return &TC_STYLE[techno.style % TC_NSTYLE]; }
/* the kits playing: DRUMS > KIT's, or the style's (AUTO) */
static uint32_t tc_kk(void) { return techno.dkit ? TC_KIT[techno.dkit % TC_NKIT] : tc_sty()->kkit; }
static uint32_t tc_hk(void) { return techno.dkit ? TC_KIT[techno.dkit % TC_NKIT] : tc_sty()->hkit; }
static uint32_t tc_pk(void) { return techno.dkit ? TC_KIT[techno.dkit % TC_NKIT] : tc_sty()->pkit; }
static int tc_heavy(void) { return techno.style == TS_DARK || techno.style == TS_HARD || techno.style == TS_INDUS; }

/* ------------------------------------------------------------ the set --- */
/* a half's place: its phrase (8 halves, 16 bars), the set (4 phrases) */
enum { TPH_GROOVE, TPH_LIFT, TPH_PEAK, TPH_BREAK, TPH_BUILD, TPH_DROP, TPH_LOOP };
static const char *const N_TC_PHASE[7] = {"GROOVE", "LIFT", "PEAK", "BREAK", "BUILD", "DROP", "LOOP"};
static uint32_t tc_phase(uint32_t h)
{
    uint32_t ph = (h / 8u) % 4u, in = h % 8u;
    if (techno.evolve < 20u)
        return TPH_LOOP;                           /* a fixed loop */
    if (ph < 3u)
        return ph;
    if (techno.evolve >= 96u)                     /* the fourth phrase: the BREAK, the BUILD, the DROP */
        return in < 2u ? TPH_BREAK : in < 4u ? TPH_BUILD : TPH_DROP;
    return TPH_PEAK;                               /* (a new motif comes with it: tc_motifs) */
}
/* the energy of a half: DRIVE's level (0..4) and the phase's lift (the GROOVE phrase thinner, the bass out of it with
 * EVOLVE from 80: an intro) */
static int32_t tc_energy(uint32_t ph)
{
    int32_t e = (int32_t)techno.drive * 5 / 128;
    if (ph == TPH_GROOVE) e -= techno.evolve >= 40u ? 1 : 0;
    else if (ph == TPH_PEAK || ph == TPH_DROP) e += 1;
    else if (ph == TPH_BREAK) e -= 2;
    return clamp(e, 0, 4);
}

/* a euclidean rhythm of k hits in 16, turned by r (bit i: step i) */
static uint32_t tc_euclid(uint32_t k, uint32_t r)
{
    uint32_t m = 0, i;
    for (i = 0; i < 16u; i++)
        if (((i * k) % 16u) < k)
            m |= 1u << ((i + r) % 16u);
    return m;
}

/* the motifs of a phrase: all at the start (and OCT+, a STYLE); later each part again with EVOLVE's chance */
static void tc_motifs(uint32_t all)
{
    const tc_style_t *S = tc_sty();
    uint32_t i, e = techno.evolve;
    if (all || tc_chance(e / 2u)) {               /* the hats' dynamics */
        for (i = 0; i < 16u; i++)
            techno.hum[i] = (int8_t)((int32_t)tc_pick(33u) - 16);
    }
    if (all || tc_chance(e * 3u / 4u)) {          /* the percussion motif: k hits, turned, its lanes */
        static const uint8_t PREF[NLANE] = {DV_RIM, DV_TOM, DV_BELL, DV_CLAP, DV_SNARE, DV_HATC, DV_HATO, DV_KICK};
        uint32_t k = 3u + tc_pick(3u) + techno.drive / 48u, lanes[8], nl = 0, l;
        for (l = 0; l < NLANE; l++)               /* the rim first: the motif's voice, the other its answer */
            if (S->lanes & TL(PREF[l]))
                lanes[nl++] = PREF[l];
        techno.perc = (uint16_t)tc_euclid(k, 1u + tc_pick(5u));
        techno.perc &= (uint16_t)~(1u << 0 | 1u << 4 | 1u << 8 | 1u << 12);   /* off the kick's beats */
        if (!techno.perc)
            techno.perc = 0x0808u;
        for (i = 0; i < 16u; i++)
            techno.plane[i] = (uint8_t)lanes[nl > 1u && tc_chance(35) ? 1u : 0u];
    }
    if (all || tc_chance(e / 3u)) {               /* the kick's ghost, ROBOT's pattern */
        techno.ghost = (techno.drive > 90u || (techno.style == TS_HARD && techno.drive > 60u)) && S->bkind == TB_RUMBLE &&
                       tc_chance(60) ? (uint8_t)(2u + tc_pick(2u)) : 0u;   /* (HARD: from DRIVE 60) */
        techno.kpat = (uint8_t)tc_pick(NELEM(TC_KICK_EL));
    }
    if (all || tc_chance(e / 2u)) {               /* the bass */
        static const uint8_t RUMBLE[5] = {0xCu, 0xEu, 0x4u, 0xAu, 0xCu};   /* 16ths of the beat: x.xx, xxx, ..x., .x.x */
        techno.bmask = RUMBLE[tc_pick(5u)];
        techno.chord = (uint8_t)tc_pick(4u);
        if (S->bkind == TB_ACID || S->bkind == TB_ROBOT) {
            for (i = 0; i < 16u; i++) {
                uint32_t on = S->bkind == TB_ACID ? tc_chance(64u + techno.drive / 8u)
                                                  : (TC_KICK_EL[techno.kpat] >> i & 1u) || tc_chance(18);
                uint32_t deg = tc_chance(45) ? 0u : tc_pick(5u), up = tc_chance(S->bkind == TB_ACID ? 28 : 18) ? 8u : 0u;
                techno.bline[i] = on ? (uint8_t)(deg + up + 1u) : 0u;
                techno.bflag[i] = (uint8_t)((tc_chance(30) ? SF_ACCENT : 0u) |
                                            (S->bkind == TB_ACID && tc_chance(22) ? SF_SLIDE : 0u));
            }
            if (!techno.bline[0])
                techno.bline[0] = 1u;             /* the line starts on the one */
        }
    }
}

/* ------------------------------------------------------------- steps --- */
/* step i of track t: hits (lanes, accents), notes (n of them), the velocity, the chance, the flags */
static void tc_put(track_t *t, uint32_t i, uint32_t hits, uint32_t acc, uint32_t n, const uint8_t *notes, uint32_t vel,
                   uint32_t chance, uint32_t flags)
{
    step_t *s = &t->step[i % NSTEP];
    uint32_t k;
    memset(s, 0, sizeof *s);
    if (!hits && !n) {
        s->time = ST_REST;
        return;
    }
    s->time = ST_NOTE;
    s->hit = (uint8_t)hits;
    s->acc = (uint8_t)(acc & hits);
    s->n = (uint8_t)(n > 4u ? 4u : n);
    for (k = 0; k < s->n; k++)
        s->note[k] = notes[k];
    s->vel = (uint8_t)clamp((int32_t)vel, 1, 126);
    s->flags = (uint8_t)flags;
    if (chance < 100u)
        step_set_chance(s, chance);
}
static uint32_t tc_vel(int32_t v, uint32_t pos)   /* v with the hats' dynamics (GROOVE) */
{
    return (uint32_t)clamp(v + techno.hum[pos & 15u] * (int32_t)techno.groove / 127, 20, 124);
}

/* the bass's root: E1 .. D#2 */
static uint32_t tc_root(void) { return 28u + (techno.key + 8u) % 12u; }

/* half h into the steps of half `which` (0: 0..31, 1: 32..63) */
static void tc_write(uint32_t which, uint32_t h)
{
    const tc_style_t *S = tc_sty();
    uint32_t base = which * TC_HALF, ph = tc_phase(h), i, groove = techno.groove, ev = techno.evolve;
    int32_t e = tc_energy(ph);
    track_t *kick = &trk[0], *hat = &trk[1], *per = &trk[2], *bas = &trk[3];
    uint32_t phrase = h / 8u, last_half = h % 8u == 7u, fill = ev >= 30u && last_half;
    uint32_t minifill = ev >= 70u && (h & 1u) && !last_half;
    uint32_t hk = tc_hk(), ride = (hk == DK_STD || (drum_kit_plays(hk) >= DK_80 && (DK_SWAP[drum_kit_plays(hk) - DK_80] & 4u)));
    uint32_t root = tc_root();
    if (techno.phrase_made != phrase + 1u || techno.fresh) {   /* a new phrase: the motifs (all of them on OCT+) */
        if (techno.fresh || techno.phrase_made == 0u || ev >= 20u)
            tc_motifs(techno.fresh || techno.phrase_made == 0u || (ph == TPH_PEAK && (h / 8u) % 4u == 3u && ev >= 40u));
        techno.phrase_made = phrase + 1u;
        techno.fresh = 0;
    }
    for (i = 0; i < TC_HALF; i++) {
        uint32_t pos = i % 16u, q = pos % 4u, bar2 = i >= 16u, at = base + i;
        uint32_t kh = 0, kv = 118, hh = 0, hv = 0, hch = 100, hrat = 1, nn = 0, pv = 0, ph_hits = 0, pch = 100, prat = 1;
        uint8_t hn = 0;
        /* T1 KICK: the four (ROBOT its own); out in the BREAK; before a fill's last beat nothing (the drop in) */
        if (ph != TPH_BREAK) {
            uint32_t m = S->kkit >= DK_80 && techno.style == TS_ROBOT ? TC_KICK_EL[techno.kpat] : 0x1111u;
            if (ph == TPH_BUILD && !bar2 && (h % 8u) == 2u)
                m = 0x0101u;                      /* the BUILD comes back in halves */
            if ((m >> pos) & 1u)
                kh = TL(DV_KICK);
            else if (techno.ghost && q == techno.ghost && e >= 3 && (pos == 6u || pos == 14u || pos == 7u || pos == 15u)) {
                kh = TL(DV_KICK);
                kv = 54;
            }
            if (fill && bar2 && pos >= 12u && ev >= 60u && techno.style != TS_ROBOT)
                kh = (tc_heavy() && e >= 3) ? TL(DV_KICK) : 0u;   /* DARK HARD INDUS roll the kick in, others drop */
        }
        tc_put(kick, at, kh, pos == 0u && kh && kv > 100u ? TL(DV_KICK) : 0u, 0, 0, kv, 100, 0);
        /* T2 HATS: the offbeat (open from S->open), the sixteenths and their ghosts with energy, the ride at the top */
        {
            int32_t hl = e;
            if (ph == TPH_BUILD) hl = (h % 8u) == 2u ? 1 : 3;
            if (q == 2u) {
                hh = hl >= S->open ? TL(DV_HATO) : TL(DV_HATC);
                hv = tc_vel(hh == TL(DV_HATO) ? 96 : 104, pos);
            } else if (q == 0u) {
                if (hl >= 3) { hh = TL(DV_HATC); hv = tc_vel(58, pos); }
            } else if (hl >= 2 || (q == 3u && hl >= 1 && (techno.style == TS_DUB || techno.style == TS_HYPNO))) {
                hh = TL(DV_HATC);
                hv = tc_vel(q == 1u ? 46 : 62, pos);
                hch = 100u - groove * 35u / 127u;   /* the ghosts breathe */
            }
            if (hl >= 4 && ride && (q == 0u || (q == 2u && techno.style != TS_DUB))) {
                if (hk == DK_STD) { hn = 51; nn = 1; }             /* GM ride: STD's cymbal */
                else hh |= TL(DV_BELL);                            /* a kit that plays a cymbal on BELL */
                if (!hv) hv = tc_vel(70, pos);
            }
            if (hh == TL(DV_HATC) && pos == 15u && hl >= 3 && ev >= 50u && (minifill || fill))
                hrat = 2;                                         /* a closed hat doubled into the next bar */
            tc_put(hat, at, hh, 0, nn, &hn, hv, hch, 0);
            if (hrat > 1u)
                step_set_ratchet(&hat->step[at % NSTEP], hrat);
        }
        /* T3 PERC: the backbeat, the motif (or threes), fills and the build's roll */
        {
            uint32_t clap = techno.style == TS_ROBOT ? TL(DV_SNARE) : TL(DV_CLAP);
            if ((pos == 4u || pos == 12u) && e >= S->clap && ph != TPH_BREAK) {
                ph_hits |= clap;
                pv = 108;
            }
            if (ph != TPH_BUILD) {
                uint32_t mot = S->poly ? ((i + (h % 3u) * 2u) % 3u == 0u) : ((techno.perc >> pos) & 1u);
                if (mot && e >= 1 && !(S->poly && q == 0u)) {
                    ph_hits |= TL(S->poly ? (pos & 4u ? DV_TOM : DV_RIM) : techno.plane[pos]);
                    if (!pv) {
                        pv = 64u + (uint32_t)(techno.hum[pos] + 16) / 4u + (uint32_t)e * 6u;
                        pch = e >= 3 ? 100u : 88u - groove / 8u;
                    }
                }
            }
            if (ph == TPH_BUILD) {                 /* the roll: eighths, then sixteenths, louder, the last beat ratcheted */
                uint32_t n = (h % 8u) - 2u, every = n == 0u ? (bar2 ? 2u : 4u) : (bar2 ? 1u : 2u);
                if (pos % every == 0u) {
                    ph_hits = TL(DV_SNARE);
                    pv = 60u + (n * 32u + i) * 60u / 64u;
                    pch = 100;
                    if (n == 1u && bar2 && pos >= 12u)
                        prat = pos >= 14u ? 4u : 2u;
                }
            }
            if (fill && bar2 && pos >= 12u) {     /* the fill into the next phrase */
                ph_hits = techno.style == TS_ROBOT || techno.style == TS_SOUL ? TL(DV_SNARE) | (pos == 15u ? clap : 0u)
                                                                                    : (pos & 1u ? TL(DV_SNARE) : TL(DV_TOM));
                pv = 70u + (pos - 12u) * 14u;
                pch = 100;
                prat = ev >= 80u && pos >= 14u ? (pos == 15u ? 3u : 2u) : 1u;
            } else if (minifill && bar2 && pos == 15u) {
                ph_hits |= TL(DV_TOM);
                pv = pv ? pv : 84u;
            }
            tc_put(per, at, ph_hits, 0, 0, 0, pv, pch, 0);
            if (prat > 1u)
                step_set_ratchet(&per->step[at % NSTEP], prat);
        }
    }
    /* T4 BASS: out in the GROOVE phrase (with EVOLVE) and the BREAK's first half; the kinds by STYLE */
    {
        uint32_t off = (ph == TPH_GROOVE && ev >= 80u) || (ph == TPH_BREAK && (h % 8u) == 0u) || techno.drive < 12u;
        const uint8_t *sc = TC_SCALE[S->scale % 3u];
        for (i = 0; i < TC_HALF; i++) {
            uint32_t pos = i % 16u, q = pos % 4u, bar2 = i >= 16u, at = base + i, vel = 100, fl = 0, n = 0;
            uint8_t nt[4];
            if (!off) {
                switch (S->bkind) {
                case TB_RUMBLE:                   /* the root after the kick, low, into the reverb; a turn at the bar's end */
                    if ((techno.bmask >> q) & 1u) {
                        nt[0] = (uint8_t)root;
                        if (bar2 && pos >= 12u && (h & 1u) && ev >= 30u)
                            nt[0] = (uint8_t)(root + sc[(h / 2u) % 2u ? 4u : 3u]);   /* the seventh / the fifth */
                        n = 1;
                        vel = q == 2u ? 108u : 84u;
                    }
                    break;
                case TB_OFFBEAT:                  /* the offbeat, the octave now and then, a pickup */
                    if (q == 2u || (pos == 15u && techno.chord & 1u) || (pos == 7u && techno.chord & 2u)) {
                        nt[0] = (uint8_t)(root + 12u + (q == 2u && pos == 14u && bar2 ? 12u : 0u));
                        if (bar2 && pos == 10u && (h & 1u))
                            nt[0] = (uint8_t)(root + 12u + sc[3]);
                        n = 1;
                        vel = q == 2u ? 104u : 80u;
                    }
                    break;
                case TB_ACID:
                case TB_ROBOT:                  /* the line; the second bar of every other half answers two notes up */
                    if (techno.bline[pos]) {
                        uint32_t d = ((techno.bline[pos] - 1u) & 7u) + (S->bkind == TB_ACID && bar2 && (h & 1u) && ev >= 40u ? 2u : 0u);
                        nt[0] = (uint8_t)(root + 12u + sc[d % 5u] + 12u * (d / 5u) + ((techno.bline[pos] - 1u) & 8u ? 12u : 0u));
                        n = 1;
                        fl = techno.bflag[pos];
                        vel = fl & SF_ACCENT ? 118u : 92u;
                    }
                    break;
                default: {                        /* TB_DUB: the stab, the minor seventh spread wide, now and then the iv */
                    static const uint16_t STAB[4] = {0x0404u, 0x0408u, 0x0484u, 0x4404u};   /* 2 10 / 3 10 / 2 7 10 / 2 10 14 */
                    if ((STAB[techno.chord & 3u] >> pos) & 1u) {
                        uint32_t r = 48u + techno.key % 12u + (bar2 && (h & 3u) == 3u && ev >= 30u ? 5u : 0u);
                        nt[0] = (uint8_t)r;
                        nt[1] = (uint8_t)(r + 7u);
                        nt[2] = (uint8_t)(r + 10u);
                        nt[3] = (uint8_t)(r + 15u);
                        n = 4;
                        vel = 92;
                    }
                    break;
                }
                }
            }
            tc_put(bas, at, 0, 0, n, nt, vel, 100, fl);
        }
    }
}

/* ------------------------------------------------------------ sounds --- */
static void tc_drum(track_t *t, uint32_t kit)
{
    dr_sound(t, ENGI_DRUM, 0);
    t->p[P_E0] = (int16_t)kit;                    /* KIT (the rest: DRUM KIT's) */
}
/* the three drum sounds: the kits (DRUMS > KIT, or the style's), the kick's tune and decay (DRUMS: tc_drums) */
static void tc_kits(void)
{
    tc_drum(&trk[0], tc_kk());
    trk[0].p[P_E6] = tc_sty()->kround;
    tc_drum(&trk[1], tc_hk());
    tc_drum(&trk[2], tc_pk());
}
/* DRUMS > KICK HATS CRUSH on the kits' sounds (after tc_kits, tc_mix: they set what this moves from). KICK and HATS
 * at 64 leave the sounds as the kit and the style make them */
static void tc_drums(void)
{
    const tc_style_t *S = tc_sty();
    track_t *k = &trk[0], *h = &trk[1];
    int32_t dk = (int32_t)techno.dkick - 64, dh = (int32_t)techno.dhats - 64, c = techno.dcrush, i;
    int32_t ktone = tc_kk() == DK_STD ? ENG_DRUM.presets[0].e[2] : 64, htone = tc_hk() == DK_STD ? ENG_DRUM.presets[0].e[2] : 64;
    k->p[P_E1] = (int16_t)clamp(S->ktune + (dk < 0 ? dk / 6 : 0), 0, 127);      /* TUNE: down a little, longer */
    k->p[P_E2] = (int16_t)clamp(ktone + dk / 2, 0, 127);                         /* TONE: the sweep */
    k->p[P_E3] = (int16_t)clamp(S->kdecy - dk * 3 / 4, 8, 127);                  /* DECY */
    k->p[P_E4] = (int16_t)clamp(64 + dk / 2, 0, 127);                            /* SNAP: the kit's drive */
    k->p[P_E7] = (int16_t)clamp(S->kdrv + techno.drive / 4 + (dk > 0 ? dk : dk / 2), 0, 120);   /* DRV */
    h->p[P_E2] = (int16_t)clamp(htone + dh * 3 / 4, 0, 127);                     /* TONE */
    h->p[P_E3] = (int16_t)clamp((techno.style == TS_DUB ? 72 : 60) + dh / 2, 0, 127);   /* DECY: a little short (DUB:
                                                                                  * longer) */
    h->p[P_E4] = (int16_t)clamp(64 + dh / 2, 0, 127);                            /* SNAP: the sizzle */
    for (i = 0; i < 3; i++) {                     /* CRUSH: the INSERT, bits 12 .. 4 (the kick two more), the rate */
        track_t *t = &trk[i];
        int32_t bits = 12 - c * 8 / 127 + (i == 0 ? 2 : 0), rate = 15 - c * 6 / 127;
        t->p[P_ITYPE] = c ? IT_CRUSH : IT_OFF;
        t->p[P_IA] = (int16_t)(c ? (bits - 1) * 8 + 4 : TP[P_IA].def);
        t->p[P_IB] = (int16_t)(c ? rate * 8 + 4 : TP[P_IB].def);
        t->p[P_IC] = (int16_t)(c ? 120 : TP[P_IC].def);
        t->p[P_IMIX] = 127;
    }
}
/* the four sounds by STYLE (an engine switch fades: at a half's start) */
static void tc_sounds(void)
{
    const tc_style_t *S = tc_sty();
    tc_kits();
    dr_sound(&trk[3], 0 /* ANALOG */, S->bpre);
    trk[3].p[P_VOICE] = S->bkind == TB_DUB ? V_POLY : V_LEGATO;
    trk[3].p[P_GLIDE] = S->bkind == TB_ACID ? 24 : 0;
    techno.cut0 = trk[3].p[P_E4];
    techno.sty_sound = techno.style;
}
/* the mix and the space: from STYLE, DRIVE and GROOVE (not the tempo: tc_tempo) */
static void tc_mix(void)
{
    const tc_style_t *S = tc_sty();
    track_t *k = &trk[0], *h = &trk[1], *p = &trk[2], *b = &trk[3];
    uint32_t i;
    for (i = 0; i < NTRK; i++) {
        trk[i].p[P_SLEN] = NSTEP;
        trk[i].p[P_SDIV] = 2;                     /* 1/16 */
        trk[i].p[P_CHOR] = 0;
        trk[i].p[P_DIST] = 0;
    }
    k->p[P_LEVEL] = 118;
    k->p[P_REV] = 2;
    k->p[P_DLY] = 0;
    h->p[P_LEVEL] = 98;
    h->p[P_REV] = 12;
    h->p[P_DLY] = techno.style == TS_DUB ? 26 : 0;
    h->p[P_PAN] = 6;
    p->p[P_LEVEL] = 94;
    p->p[P_REV] = 30;
    p->p[P_DLY] = techno.style == TS_DUB || techno.style == TS_HYPNO || techno.style == TS_INDUS ? 40 : 14;
    p->p[P_PAN] = -10;
    b->p[P_SGATE] = S->bkind == TB_RUMBLE ? 46 : S->bkind == TB_ACID ? 96 : S->bkind == TB_DUB ? 30 : 70;
    b->p[P_LEVEL] = S->bkind == TB_RUMBLE ? 104 : S->bkind == TB_DUB ? 102 : 94;
    b->p[P_REV] = techno.style == TS_INDUS ? 84 : S->bkind == TB_RUMBLE ? 72 : S->bkind == TB_DUB ? 56 : 8;
    b->p[P_DLY] = S->bkind == TB_DUB ? 92 : S->bkind == TB_ACID ? 24 : 0;
    b->p[P_DIST] = S->bkind == TB_ACID ? (int16_t)(20 + techno.drive / 3) : S->bkind == TB_RUMBLE ?
                   (int16_t)(techno.drive / 4 + (techno.style == TS_HARD || techno.style == TS_INDUS ? 24 : 0)) : 0;
    song.g[G_SWING] = (int16_t)clamp(S->swing + techno.groove * 28 / 127, 0, 60);
    song.g[G_RTYPE] = techno.style == TS_DUB ? 2 : 0;    /* DUB a HALL, the rest a ROOM */
    song.g[G_RSIZE] = techno.style == TS_DUB ? 110 : 84;
    song.g[G_RDAMP] = 64;
    song.g[G_DTIME] = 10;                         /* 1/8D */
    song.g[G_DFDBK] = techno.style == TS_DUB ? 92 : 64;
    song.g[G_DMIX] = 90;
    song.g[G_CDEPTH] = 0;
    tc_drums();
}
/* the tempo on the internal clock: the style's, unless it was set by hand (another than the last style's) */
static void tc_tempo(uint32_t was_style, int force)
{
    uint32_t bpm = (uint32_t)song.g[G_BPM];
    if (clock_ext())
        return;                                   /* the master's */
    if (force || bpm == TC_STYLE[was_style % TC_NSTYLE].bpm || bpm < 100u || bpm > 160u)
        song.g[G_BPM] = TC_STYLE[techno.style % TC_NSTYLE].bpm;
}

/* ---------------------------------------------------------- transport --- */
/* start (or a new groove): the sounds, the first two halves. Stopped: PLAY on the internal clock, ready for the
 * master's START on an external one. Playing: in place, the clock goes on (a new groove from the halves as they
 * come; the sounds at once). INT turns into AUTO (an external clock, when one comes, leads). Call from the main loop */
static uint8_t tc_noplay;                         /* (main.c techno_boot: ready, not playing) */
static void techno_start(uint32_t seed)
{
    uint32_t k, f, playing = song.playing, was_on = techno.on, ext, inplace;
    if (chain.running || chain.armed)
        chain_stop();
    dream_stop();                                 /* (one plays itself at a time) */
    if (!song.g[G_CLOCK])
        song.g[G_CLOCK] = CLK_AUTO_MODE;
    ext = clock_ext();
    techno.seed = seed ? seed : 0x7EC40u;
    techno.rng = techno.seed * 2654435761u + 1u;
    if (playing && was_on) {                      /* OCT+ while it plays: new motifs, from the next half */
        techno.fresh = 1;
        techno.moved = 1;
        return;
    }
    inplace = playing && ext;                     /* the master plays: in place, its clock goes on */
    if (!inplace) {
        transport_req = 2;
        panic_req = (1u << NTRK) - 1u;
    }
    for (k = 0; k < NTRK; k++)
        motion_clear(&trk[k]);
    f = motion_guard();                           /* the audio ISR must not see half a groove */
    if (!inplace) {
        seq_stop();
        transport_req = 0;
    }
    tc_sounds();
    for (k = 0; k < NTRK; k++)
        trk[k].seq_active = 1;
    tc_mix();
    tc_tempo(techno.style, !was_on);
    techno.phrase_made = 0;
    techno.fresh = 0;
    techno.prev_half = (uint8_t)(inplace && (trk[0].seq_idx % NSTEP) >= TC_HALF);
    techno.abs = techno.prev_half;
    tc_write(0, 0);
    tc_write(1, 1);
    techno.written = (uint8_t)(techno.prev_half ^ 1u);   /* the next write: when the playhead goes into the other half */
    techno.on = 1;
    techno.moved = 0;
    techno.named = 1;
    techno.said = 0;
    techno.was_playing = (uint8_t)inplace;
    techno.t0 = song.tick;
    motion_unguard(f);
    techno.sig = dr_sig();
    if (!ext && !tc_noplay)
        transport_req = 1;                        /* the internal clock: go (an external one: its START) */
    tc_noplay = 0;
}

static void techno_stop(void) { techno.on = 0; }

/* the controls: STYLE from the next half (its sounds there too), the others the same */
static void techno_set(uint32_t c, int32_t v)
{
    switch (c) {
    case 0: {
        uint32_t was = techno.style;
        techno.style = (uint8_t)clamp(v, 0, TC_NSTYLE - 1);
        if (techno.style != was) {
            tc_tempo(was, 0);
            techno.fresh = 1;
        }
        break;
    }
    case 1: techno.drive = (uint8_t)clamp(v, 0, 127); break;
    case 2: techno.groove = (uint8_t)clamp(v, 0, 127); break;
    default: techno.evolve = (uint8_t)clamp(v, 0, 127); break;
    }
    techno.moved = 1;
}
static void techno_key(uint32_t pc) { techno.key = (uint8_t)(pc % 12u); techno.moved = 1; }
static const param_desc_t TC_DESC[4] = {          /* GLO > TECHNO's four knobs (ui_draw.c: their cards) */
    {"STYLE", F_ENUM, 0, TC_NSTYLE - 1, TS_DARK, N_TC_STYLE, 0},
    {"DRIVE", F_PCT, 0, 127, 72, 0, 0},
    {"GROOVE", F_PCT, 0, 127, 40, 0, 0},
    {"EVOLVE", F_PCT, 0, 127, 48, 0, 0},
};
static int32_t techno_get(uint32_t c)
{
    return c == 0 ? techno.style : c == 1 ? techno.drive : c == 2 ? techno.groove : techno.evolve;
}
/* GLO > DRUMS: KIT KICK HATS CRUSH, heard at once (playing or not; the tracks only while TECHNO has them) */
static const param_desc_t TD_DESC[4] = {
    {"KIT", F_ENUM, 0, TC_NKIT - 1, 0, N_TC_KIT, 0},
    {"KICK", F_PCT, 0, 127, 64, 0, 0},
    {"HATS", F_PCT, 0, 127, 64, 0, 0},
    {"CRUSH", F_PCT, 0, 127, 0, 0, 0},
};
static int32_t techno_dget(uint32_t c)
{
    return c == 0 ? techno.dkit : c == 1 ? techno.dkick : c == 2 ? techno.dhats : techno.dcrush;
}
static void techno_dset(uint32_t c, int32_t v)
{
    uint32_t was = techno.dkit, f;
    switch (c) {
    case 0: techno.dkit = (uint8_t)clamp(v, 0, TC_NKIT - 1); break;
    case 1: techno.dkick = (uint8_t)clamp(v, 0, 127); break;
    case 2: techno.dhats = (uint8_t)clamp(v, 0, 127); break;
    default: techno.dcrush = (uint8_t)clamp(v, 0, 127); break;
    }
    if (!techno.on)
        return;                                   /* (the next start takes them) */
    f = motion_guard();
    if (techno.dkit != was) {
        tc_kits();                                /* a kit: the three drum sounds again, the mix (and the rest) on them */
        tc_mix();
    } else {
        tc_drums();
    }
    motion_unguard(f);
}

/* main loop, every pass: the playhead's half counted (from the transport's start, or the song position it was
 * started from: seq_top16), the half not playing written again, the knobs' changes there; the bass breathes */
static void techno_poll(void)
{
    uint32_t idx, half, f;
    if (!techno.on)
        return;
    if (fm1_ms - techno.sig_ms >= 100u) {         /* ten times a second: steps TECHNO did not write */
        techno.sig_ms = fm1_ms;
        if (dr_sig() != techno.sig) {
            techno.on = 0;                        /* the user took the music over: it stays as it is */
            return;
        }
    }
    if (!song.playing) {
        techno.was_playing = 0;
        return;
    }
    idx = trk[0].seq_idx % NSTEP;
    half = idx >= TC_HALF ? 1u : 0u;
    if (!techno.was_playing || song.tick < techno.t0) {   /* the transport (re)started: from its song position */
        techno.was_playing = 1;
        techno.abs = seq_top16 / TC_HALF;
        if ((techno.abs & 1u) != half)            /* (the song position's half is the half playing) */
            techno.abs = (techno.abs & ~1u) | half;
        techno.prev_half = (uint8_t)half;
    }
    techno.t0 = song.tick;
    if (half != techno.prev_half) {               /* the playhead went into the other half */
        techno.prev_half = (uint8_t)half;
        techno.abs++;
    }
    if (half == techno.written) {                 /* it plays the half written last: write the other one */
        f = motion_guard();
        if (techno.moved || techno.sty_sound != techno.style) {
            if (techno.sty_sound != techno.style)
                tc_sounds();
            tc_mix();
        }
        tc_write(half ^ 1u, techno.abs + 1u);
        techno.written = (uint8_t)(half ^ 1u);
        motion_unguard(f);
        techno.sig = dr_sig();
        techno.moved = 0;
    }
    /* the breathing: ACID's cutoff and resonance, the others' cutoff a little, with DRIVE (one value each: a knob turn) */
    {
        const tc_style_t *S = tc_sty();
        uint32_t now = song.tick;
        int32_t b = dr_breath(now, 23u * 1378u, 0), lift = ((int32_t)techno.drive - 64) / 3;
        if (techno.sty_sound == techno.style) {
            if (S->bkind == TB_ACID) {
                trk[3].p[P_E4] = (int16_t)clamp(techno.cut0 - 18 + lift + (b * 30 >> 15), 8, 118);
                trk[3].p[P_E5] = (int16_t)clamp(96 + (dr_breath(now, 37u * 1378u, 0x40000000u) * 22 >> 15), 0, 124);
            } else {
                trk[3].p[P_E4] = (int16_t)clamp(techno.cut0 + lift + (b * 8 >> 15), 8, 120);
            }
        }
    }
}
