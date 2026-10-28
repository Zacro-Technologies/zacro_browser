'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

// A local, deterministic browsing surface for hands-on desktop acceptance.
// No third-party assets, accounts, tracking, permissions, or network API calls.
function createInteractiveSite() {
  const icon = fs.readFileSync(path.resolve(__dirname, '../../assets/icon-256.png'));
  return http.createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname === '/favicon.ico') {
      response.writeHead(200, { 'Content-Type': 'image/png' });
      response.end(icon);
      return;
    }
    if (url.pathname === '/download') {
      response.writeHead(200, {
        'Content-Type': 'text/plain',
        'Content-Disposition': 'attachment; filename="zacro-acceptance.txt"',
      });
      response.end('Zacro local browser acceptance fixture.\nThis file contains no user information.\n');
      return;
    }
    if (url.pathname === '/popup-check' || url.pathname === '/popup-result') {
      const child = url.pathname === '/popup-result';
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      response.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Local popup ${child ? 'result' : 'check'}</title><style>
        body{font:16px/1.6 system-ui,sans-serif;margin:0;padding:48px;background:#f4f2eb;color:#263b32}main{max-width:600px;margin:auto}h1{font:40px Georgia,serif}button{font:inherit;border:0;border-radius:9px;padding:12px 18px;background:#2b5a46;color:white;cursor:pointer}button:focus-visible{outline:3px solid #bd773e;outline-offset:3px}output{display:block;margin-top:24px}small{display:block;margin-top:32px;color:#52685b}
        </style></head><body><main><h1>Local popup ${child ? 'result' : 'check'}</h1><p>${child ? 'Return a fixed test message to the original page, then close this popup.' : 'Open this page in Peek. Opening its popup should keep this exact page alive as a tab.'}</p><button id="popup-action">${child ? 'Return test result' : 'Open test popup'}</button><output id="popup-status" aria-live="polite">${child ? 'No account or credentials involved.' : 'Waiting for the local test.'}</output><small>This is a local browser-mechanics fixture. It does not sign in to any service.</small></main><script>
        const status=document.getElementById('popup-status');
        ${child ? '' : `const link=document.createElement('a');link.href='/popup-check';link.textContent='Open this check in Peek from the link menu';link.style.display='block';link.style.marginTop='24px';document.querySelector('main').append(link);`}
        ${
          child
            ? `document.getElementById('popup-action').onclick=()=>{if(!window.opener){status.textContent='Failed: original page was closed.';return}window.opener.postMessage({fixture:'zacro-popup',result:'returned'},location.origin);window.close()};`
            : `let popup;window.addEventListener('message',event=>{if(event.origin===location.origin&&event.source===popup&&event.data?.fixture==='zacro-popup'&&event.data.result==='returned')status.textContent='Passed: the original page received its popup result.'});document.getElementById('popup-action').onclick=()=>{popup=window.open('/popup-result','local-popup-check');status.textContent=popup?'Waiting for the popup result…':'Popup was blocked.'};`
        }
        </script></body></html>`);
      return;
    }
    const notes = url.pathname === '/notes';
    const title = notes ? 'The quiet web — Fieldnotes' : 'Fieldnotes — A local browsing test';
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="/favicon.ico"><title>${title}</title><style>
      *{box-sizing:border-box}body{margin:0;background:#f4f2eb;color:#263b32;font:16px/1.6 system-ui,sans-serif}header{display:flex;align-items:center;gap:32px;padding:24px 6%;border-bottom:1px solid #263b3220}header strong{font:italic 28px Georgia,serif;letter-spacing:-1px;margin-right:auto}header a{color:inherit;text-decoration:none;font-size:13px}main{max-width:1040px;margin:auto;padding:56px 6% 100px}.eyebrow{font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#576b60}h1{font:normal clamp(38px,5vw,68px)/1.06 Georgia,serif;letter-spacing:-2px;max-width:630px;margin:20px 0}p{max-width:620px;color:#52685b}a{color:#235c46;text-underline-offset:4px}.landscape{height:240px;position:relative;border-radius:16px;overflow:hidden;background:linear-gradient(130deg,#b3c7b4,#dce3d6 45%,#f2c99b);margin:36px 0}.sun{width:86px;height:86px;border-radius:50%;background:#ffeac3;position:absolute;top:25px;right:20%}.hill{position:absolute;border-radius:50% 50% 0 0;width:80%;height:230px;bottom:-140px;background:#315c4d;transform:rotate(-9deg);left:-20%}.hill.two{left:36%;bottom:-100px;background:#72937a;transform:rotate(10deg)}.hill.three{left:4%;bottom:-180px;background:#193d32;width:110%}.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}.card{border:1px solid #263b3225;border-radius:14px;padding:24px;background:#fff9}.card h2{font:26px Georgia,serif;margin:0 0 12px}.card p{font-size:14px}button{font:inherit;border-radius:9px;border:0;background:#2b5a46;color:#fff;padding:10px 18px;cursor:pointer}button:focus-visible,a:focus-visible,input:focus-visible,textarea:focus-visible{outline:3px solid #bd773e;outline-offset:3px}label{display:block;font-size:13px;margin:20px 0 6px}textarea,input{font:inherit;display:block;width:100%;border:1px solid #91a396;border-radius:9px;background:#fffdf9;padding:12px;color:#263b32}output{font-size:13px;display:block;margin-top:12px;overflow-wrap:anywhere}.status{color:#3c6952;font-size:12px}footer{font-size:12px;margin-top:40px;color:#617167}.article p{margin:25px 0}.article h2{font:32px Georgia,serif;margin:40px 0 20px}@media(max-width:620px){header{gap:16px}.grid{grid-template-columns:1fr}main{padding-top:30px}}
      </style></head><body><header><strong>fieldnotes</strong><a href="/">Journal</a><a href="/notes">The quiet web</a><span class="status">Local test page</span></header><main><div class="eyebrow">Issue 001 · A little room to think</div><h1>${notes ? 'A quieter corner of the internet.' : 'Good things happen when you make a little space.'}</h1><p>${notes ? 'Keep this page open in Peek. Your notes, scroll position, and counter should stay with you when you promote it to a tab.' : 'A small, local journal for testing the everyday details: reading, writing, navigating, and picking up where you left off.'}</p><div class="landscape" role="img" aria-label="Illustrated green hills under a warm sky"><div class="sun"></div><div class="hill two"></div><div class="hill"></div><div class="hill three"></div></div>
      <div class="grid"><section class="card"><h2>${notes ? 'Leave yourself a note' : 'Follow a thought'}</h2><p>${notes ? 'This draft stays in the page. Switching tabs or promoting Peek must preserve it.' : 'Open the article, try Peek from its context menu, or put the two pages side by side.'}</p><a href="${notes ? '/' : '/notes'}">${notes ? 'Back to the journal' : 'Read The quiet web'}</a><label for="draft">Test note · no data is sent</label><textarea id="draft" rows="3" placeholder="Write a test note…"></textarea></section><section class="card"><h2>Small details matter.</h2><p>Try the counter, keyboard focus, browser find, history, and zoom. There are no external requests on this page.</p><button id="counter">Count: 0</button><output id="keys" aria-live="polite">Keyboard: waiting for input</output><p><a href="/notes" target="_blank">Open article in a new tab</a></p><p><a href="/download">Download a small test file</a></p></section></div>
      <section class="article"><h2>A place to pause.</h2><p>The best tools leave room for what matters. Their details become familiar: the weight of a button, a page that stays where you left it, a shortcut that does exactly what you expect.</p><p>Use this paragraph to test Find on page. The phrase <strong>quiet confidence</strong> appears here, and nowhere else in this article.</p><h2>Keep your place.</h2><p>Scroll to this section, switch to another tab, and return. The browser should preserve your reading position. Open this article in Peek, write a note, then promote it to a full tab. Your work should still be here.</p><p>Split view should keep both pages steady while focus moves between them. The address bar, zoom, find, and navigation controls should follow the pane you are using.</p></section><footer>Served only on 127.0.0.1. This fixture is for browser acceptance, not a production service.</footer></main><script>
      let count=0;document.getElementById('counter').addEventListener('click',event=>{event.target.textContent='Count: '+(++count)});document.addEventListener('keydown',event=>{document.getElementById('keys').textContent='Keyboard: '+event.code+' | Ctrl '+event.ctrlKey+' | Alt '+event.altKey+' | Shift '+event.shiftKey+' | Meta '+event.metaKey});
      </script></body></html>`);
  });
}

module.exports = { createInteractiveSite };
