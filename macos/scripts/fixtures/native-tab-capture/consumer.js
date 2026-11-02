'use strict';
// Real Chrome MediaStream decoding. No mocked capture, synthetic screenshots or
// remote source. The worker provides the exact expected owned canvas color.
(() => {
  const route = location.pathname.endsWith('/offscreen.html') ? 'offscreen' : 'document';
  async function sample(stream, expectedRGB) {
    const track = stream.getVideoTracks()[0];
    const video = document.createElement('video');
    video.muted = true; video.autoplay = true; video.playsInline = true;
    video.srcObject = stream; document.body.append(video);
    const events = [], timestamps = new Set();
    let reader, frames = 0, rgb = [], width = 0, height = 0, playError = null;
    const record = event => {
      events.push({type: event.type, at: Math.round(performance.now())});
      if (events.length > 24) events.shift();
    };
    for (const name of ['loadedmetadata', 'loadeddata', 'canplay', 'playing', 'waiting', 'stalled', 'error', 'ended']) {
      video.addEventListener(name, record);
    }
    for (const name of ['mute', 'unmute', 'ended']) track?.addEventListener(name, record);
    const diagnostics = () => {
      const settings = track?.getSettings() || {};
      return {route, visibility: document.visibilityState, processorAvailable: typeof MediaStreamTrackProcessor === 'function',
        streamActive: stream.active, track: track ? {readyState: track.readyState, enabled: track.enabled,
          muted: track.muted, width: settings.width, height: settings.height, frameRate: settings.frameRate} : null,
        video: {readyState: video.readyState, networkState: video.networkState, paused: video.paused,
          ended: video.ended, width: video.videoWidth, height: video.videoHeight,
          error: video.error ? {code: video.error.code, message: video.error.message} : null, playError},
        observedFrames: frames, distinctFrames: timestamps.size, lastTimestamps: [...timestamps].slice(-3),
        decodedWidth: width, decodedHeight: height, rgb, expectedRGB, events};
    };
    try {
      if (!track || track.readyState !== 'live') throw new Error('Native capture did not return a live video track');
      if (typeof MediaStreamTrackProcessor !== 'function') {
        throw new Error('Pinned Chromium MediaStreamTrackProcessor is unavailable');
      }
      // requestVideoFrameCallback depends on compositor/rAF presentation and
      // may never run in an offscreen extension document. Read real captured
      // VideoFrames directly from Chromium's Window-exposed track processor.
      // The video is diagnostic only; showing it or faking activation is not
      // required to consume the native stream.
      void video.play().catch(error => { playError = String(error.message || error); });
      const processor = new MediaStreamTrackProcessor({track, maxBufferSize: 2});
      reader = processor.readable.getReader();
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 1;
      const context = canvas.getContext('2d', {willReadFrequently: true});
      if (!context) throw new Error('No canvas context for actual captured pixel decoding');
      const end = performance.now() + 10000;
      while (performance.now() < end) {
        let timer, acceptsFrame = true;
        const pending = reader.read().then(result => {
          // A timeout can win just as native capture delivers its next frame.
          // Close that late frame instead of leaking its backing buffer.
          if (!acceptsFrame) result.value?.close();
          return result;
        });
        let result;
        try {
          result = await Promise.race([pending, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('No native captured VideoFrame arrived')),
              Math.max(1, end - performance.now()));
          })]);
        } finally { acceptsFrame = false; clearTimeout(timer); }
        if (result.done || !result.value) throw new Error('Native captured video stream ended before two frames');
        const frame = result.value;
        try {
          frames++;
          if (!(frame instanceof VideoFrame) || !Number.isFinite(frame.timestamp)) {
            throw new Error('Capture processor returned no timestamped native VideoFrame');
          }
          timestamps.add(frame.timestamp);
          width = frame.displayWidth; height = frame.displayHeight;
          if (!width || !height) continue;
          context.drawImage(frame, Math.floor(width / 2), Math.floor(height / 2), 1, 1, 0, 0, 1, 1);
          rgb = [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
          if (timestamps.size >= 2 && rgb.every((value, i) => Math.abs(value - expectedRGB[i]) < 24)) {
            return {frames: timestamps.size, observedFrames: frames, timestamps: [...timestamps].slice(-3),
              rgb, width, height, trackState: track.readyState, decoder: 'MediaStreamTrackProcessor',
              diagnostics: diagnostics()};
          }
        } finally { frame.close(); }
      }
      throw new Error(`Captured another document: pixel=${rgb}, expected=${expectedRGB}`);
    } catch (error) {
      throw new Error(`${error.message || error}; capture diagnostics=${JSON.stringify(diagnostics())}`);
    } finally {
      stream.getTracks().forEach(item => item.stop());
      if (reader) {
        let timer;
        try { await Promise.race([reader.cancel().catch(() => {}), new Promise(resolve => {
          timer = setTimeout(resolve, 1000);
        })]); } finally { clearTimeout(timer); }
        try { reader.releaseLock(); } catch { /* A cancelled native read still owns its release. */ }
      }
      for (const name of ['mute', 'unmute', 'ended']) track?.removeEventListener(name, record);
      video.srcObject = null; video.remove();
    }
  }

  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id || message?.channel !== 'zacro-tab-capture'
        || message.route !== route) return;
    if (message.operation === 'ping') { respond({ready: true, route}); return; }
    (async () => {
      if (!Array.isArray(message.expectedRGB) || message.expectedRGB.length !== 3
          || !message.expectedRGB.every(value => Number.isInteger(value) && value >= 0 && value <= 255)) {
        throw new Error('Invalid bounded canvas expectation');
      }
      let stream;
      if (message.operation === 'consume') {
        if (typeof message.streamID !== 'string' || !message.streamID) throw new Error('No native stream ID');
        stream = await navigator.mediaDevices.getUserMedia({audio: false, video: {mandatory: {
          chromeMediaSource: 'tab', chromeMediaSourceId: message.streamID
        }}});
      } else if (message.operation === 'legacy' && route === 'document') {
        stream = await new Promise((resolve, reject) => chrome.tabCapture.capture(
          {audio: false, video: true}, result => {
            const error = chrome.runtime.lastError;
            if (error || !result) reject(new Error(error?.message || 'Native capture returned no stream'));
            else resolve(result);
          }));
      } else throw new Error('Unexpected capture operation');
      return sample(stream, message.expectedRGB);
    })().then(value => respond({ok: true, value}), error => respond({ok: false, error: String(error.message || error)}));
    return true;
  });
})();
