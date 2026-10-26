// Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
// Sonidos cortos sintetizados al momento (sin archivos). Suaves y solo en momentos con significado.
const Sound = (() => {
  let ctx = null, enabled = true;
  const cache = {};
  const tone = (t, f0, f1, sweep) => {
    const k = (f1 - f0) / Math.max(sweep, 0.0001);
    const ph = t < sweep ? f0 * t + 0.5 * k * t * t : f0 * sweep + 0.5 * k * sweep * sweep + f1 * (t - sweep);
    return Math.sin(2 * Math.PI * ph);
  };
  const env = (t, a, d) => Math.min(1, t / a) * Math.exp(-Math.max(0, t - a) / d);
  const defs = {
    tick: [0.035, t => tone(t, 1900, 1500, 0.035) * env(t, 0.001, 0.007) * 0.22],
    copy: [0.16, t => (tone(t, 2637, 2637, 0.16) + 0.35 * tone(t, 3951, 3951, 0.16)) * env(t, 0.002, 0.04) * 0.18],
    pop: [0.14, t => tone(t, 420, 980, 0.07) * env(t, 0.003, 0.035) * 0.34],
    start: [0.32, t => (tone(t, 280, 620, 0.3) * 0.5 + (Math.random() * 2 - 1) * 0.25 * env(t, 0.12, 0.08)) * env(t, 0.06, 0.12) * 0.3],
    success: [0.75, t => [[0, 1046.5], [0.08, 1318.5], [0.16, 1568]].reduce((acc, [d, f]) => {
      const u = t - d;
      return u < 0 ? acc : acc + (tone(u, f, f, 1) + 0.2 * tone(u, f * 2, f * 2, 1)) * env(u, 0.004, 0.22) * 0.16;
    }, 0)],
    error: [0.34, t => { const u = t < 0.14 ? t : t - 0.14, f = t < 0.14 ? 392 : 293.7; return tone(u, f, f, 1) * env(u, 0.004, 0.07) * 0.28; }],
  };
  function buffer(kind) {
    if (cache[kind]) return cache[kind];
    const [secs, fn] = defs[kind];
    const n = Math.floor(secs * ctx.sampleRate), b = ctx.createBuffer(1, n, ctx.sampleRate), ch = b.getChannelData(0);
    for (let i = 0; i < n; i++) ch[i] = fn(i / ctx.sampleRate) * 0.55;
    return (cache[kind] = b);
  }
  return {
    set enabled(v) { enabled = v; },
    get enabled() { return enabled; },
    play(kind) {
      if (!enabled || !defs[kind]) return;
      try {
        ctx = ctx || new AudioContext();
        if (ctx.state === 'suspended') ctx.resume();
        const s = ctx.createBufferSource();
        s.buffer = buffer(kind); s.connect(ctx.destination); s.start();
      } catch (e) { /* sin audio: no pasa nada */ }
    },
  };
})();
