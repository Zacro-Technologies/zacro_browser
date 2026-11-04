/* Original local assets only. Runs inside an actual Chromium page. */
(() => {
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const until = async (test, message, timeout = 12000) => {
    const end = Date.now() + timeout;
    while (Date.now() < end) { if (await test()) return; await wait(25); }
    throw new Error(message);
  };
  let retainedVideo;
  globalThis.zacroMediaAcceptance = {
    async run(baseURL) {
      const checks = {}, errors = {};
      const base = new URL(baseURL);
      assert(base.protocol === 'http:' && base.hostname === '127.0.0.1', 'Media acceptance requires loopback');
      const asset = name => new URL(`/media/${name}`, base).href;
      const check = async (name, action) => {
        try { await action(); checks[name] = true; }
        catch (error) { checks[name] = false; errors[name] = String(error?.stack || error); }
      };
      await check('h264FrameDecoding', async () => {
        const video = document.createElement('video');
        video.muted = true; video.playsInline = true; video.loop = true;
        video.style.cssText = 'position:fixed;right:4px;bottom:4px;width:160px;height:96px;z-index:2147483647';
        video.src = asset('synthetic-h264.mp4'); document.body.append(video);
        retainedVideo = video;
        assert(video.canPlayType('video/mp4; codecs="avc1.42E01E"'), 'H.264 codec is disabled');
        await video.play();
        await until(() => video.getVideoPlaybackQuality().totalVideoFrames >= 3 && video.currentTime > 0.05,
          'The H.264 file loaded but did not decode frames');
        assert(video.videoWidth === 160 && video.videoHeight === 96, 'Decoded dimensions changed');
      });
      await check('aacSampleDecoding', async () => {
        const context = new AudioContext();
        try {
          const response = await fetch(asset('synthetic-aac.m4a'));
          assert(response.ok, 'AAC fixture request failed');
          const decoded = await context.decodeAudioData(await response.arrayBuffer());
          const samples = decoded.getChannelData(0);
          let energy = 0; for (const sample of samples) energy += sample * sample;
          assert(decoded.duration > 1.8 && decoded.duration < 2.3 && Math.sqrt(energy / samples.length) > 0.02,
            'AAC decoder did not produce the synthetic tone');
        } finally { await context.close(); }
      });
      await check('webRTCLoopbackMediaAndData', async () => {
        // A genuine local TURN relay makes this transport check independent of
        // ambient LAN/mDNS discovery and macOS Local Network permission state.
        // Browser privacy policies and native DTLS/SCTP/RTP remain unchanged.
        const response = await fetch(asset('ice-config.json'), { cache: 'no-store', credentials: 'omit' });
        assert(response.ok, 'The owned authenticated TURN fixture is unavailable');
        const configuration = await response.json();
        const server = configuration?.iceServers?.[0];
        const endpoint = typeof server?.urls === 'string' && /^turn:127\.0\.0\.1:(\d+)\?transport=udp$/.exec(server.urls);
        assert(configuration?.iceTransportPolicy === 'relay' && configuration.iceServers.length === 1
          && endpoint && Number(endpoint[1]) >= 1024 && Number(endpoint[1]) <= 65535
          && /^[0-9a-f]{48}$/.test(server.username) && /^[0-9a-f]{48}$/.test(server.credential),
        'Media acceptance requires its exact authenticated IPv4 loopback relay');
        const canvas = document.createElement('canvas'); canvas.width = 160; canvas.height = 96;
        const painting = canvas.getContext('2d'); let frame = 0;
        const animation = setInterval(() => {
          painting.fillStyle = `hsl(${frame++ * 7 % 360} 70% 50%)`; painting.fillRect(0, 0, 160, 96);
        }, 33);
        const stream = canvas.captureStream(30);
        const sender = new RTCPeerConnection(configuration);
        const receiver = new RTCPeerConnection(configuration);
        const received = [];
        const candidates = [], candidateErrors = [];
        const forward = (peer, event) => {
          if (event.candidate) candidates.push((async () => {
            await until(() => peer.remoteDescription || peer.signalingState === 'closed', 'Remote description missing');
            if (peer.signalingState !== 'closed') await peer.addIceCandidate(event.candidate);
          })().catch(error => candidateErrors.push(String(error))));
        };
        sender.onicecandidate = event => forward(receiver, event);
        receiver.onicecandidate = event => forward(sender, event);
        receiver.ondatachannel = event => { event.channel.onmessage = message => received.push(message.data); };
        const remoteVideo = document.createElement('video'); remoteVideo.muted = true; remoteVideo.playsInline = true;
        receiver.ontrack = event => { remoteVideo.srcObject = event.streams[0]; remoteVideo.play().catch(() => {}); };
        const data = sender.createDataChannel('zacro-native-loopback');
        try {
          sender.addTrack(stream.getVideoTracks()[0], stream);
          await sender.setLocalDescription(await sender.createOffer());
          await receiver.setRemoteDescription(sender.localDescription);
          await receiver.setLocalDescription(await receiver.createAnswer());
          await sender.setRemoteDescription(receiver.localDescription);
          await until(() => data.readyState === 'open', 'WebRTC data channel did not connect');
          data.send('native-chromium-media');
          await until(() => received.includes('native-chromium-media'), 'WebRTC data channel lost its payload');
          await until(async () => [...(await receiver.getStats()).values()].some(report =>
            report.type === 'inbound-rtp' && report.kind === 'video' && report.framesDecoded >= 2),
          'WebRTC did not decode loopback video frames');
          const statistics = await receiver.getStats();
          const selected = [...statistics.values()].filter(report => report.type === 'transport'
            && report.selectedCandidatePairId).map(report => statistics.get(report.selectedCandidatePairId));
          assert(selected.length > 0 && selected.every(pair => {
            const local = statistics.get(pair?.localCandidateId), remote = statistics.get(pair?.remoteCandidateId);
            return pair?.state === 'succeeded' && local?.candidateType === 'relay'
              && local.address === '127.0.0.1' && remote?.candidateType === 'relay' && remote.address === '127.0.0.1';
          }), 'The actual selected ICE pair did not use the owned loopback TURN relay');
          checks.webRTCSelectedPairUsesOwnedAuthenticatedLoopbackRelay = true;
          await Promise.all(candidates);
          assert(!candidateErrors.length, candidateErrors.join('; '));
        } finally {
          clearInterval(animation); stream.getTracks().forEach(track => track.stop());
          sender.close(); receiver.close(); remoteVideo.srcObject = null;
        }
      });
      await check('nativePDFViewerCapability', async () => {
        assert(navigator.pdfViewerEnabled === true, 'Native PDF viewer is disabled');
        const response = await fetch(asset('synthetic.pdf'));
        assert(response.ok && (await response.text()).startsWith('%PDF-'), 'Synthetic PDF was not served');
      });
      return { passed: Object.values(checks).every(Boolean), checks, errors };
    },
    // Invoke separately with real native Runtime.evaluate userGesture:true.
    async pictureInPicture() {
      assert(document.pictureInPictureEnabled && retainedVideo, 'Native Picture-in-Picture unavailable');
      const window = await retainedVideo.requestPictureInPicture();
      try {
        assert(document.pictureInPictureElement === retainedVideo && window.width > 0 && window.height > 0,
          'Picture-in-Picture did not present the decoded video');
        return true;
      } finally { if (document.pictureInPictureElement) await document.exitPictureInPicture(); }
    },
    cleanup() { retainedVideo?.pause(); retainedVideo?.remove(); retainedVideo = undefined; }
  };
})();
