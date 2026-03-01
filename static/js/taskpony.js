// TaskPony JavaScript
// playTaskCompleteSound();  = Simple wooden tick sound for task completion feedback. Uses Web Audio API to generate a short sound effect.

function playTaskCompleteSound() {
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const osc = ctx.createOscillator();
  const gain = ctx.createGain();

  osc.type = "sine";
  osc.frequency.setValueAtTime(1200, ctx.currentTime);
  osc.frequency.exponentialRampToValueAtTime(900, ctx.currentTime + 0.06);

  gain.gain.setValueAtTime(0.064, ctx.currentTime);
  gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.06);

  osc.connect(gain);
  gain.connect(ctx.destination);

  osc.start();
  osc.stop(ctx.currentTime + 0.06);
  osc.frequency.setValueAtTime(1100 + Math.random()*200, ctx.currentTime);
}

