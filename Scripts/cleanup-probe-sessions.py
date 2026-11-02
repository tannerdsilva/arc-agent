import subprocess, time, re, json, base64

D = "/Users/tannerdsilva/.hermes/profiles/browser-dev/skills/software-development/web-ui-ux-audit/scripts/cdp-drive.mjs"

def js(expr, timeout=30):
    r = subprocess.run(["node", D, "eval", expr], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()

sweeps = 0
while sweeps < 14:
    found = js("(() => JSON.stringify([...document.querySelectorAll('.sess-row')].filter(r => /probe|UXGATE|cdp-|fix-check|queued probe/i.test(r.textContent)).map(r => r.getAttribute('data-sid'))))()")
    m = re.search(r"\[.*\]", found)
    sids = json.loads(m.group(0)) if m else []
    if not sids:
        print("clean after", sweeps, "sweeps")
        break
    sid = sids[0]
    print(f"sweep {sweeps}: deleting {sid[:8]}")
    js("(() => { const row = document.querySelector('.sess-row[data-sid=\"%s\"]'); const mb = row && (row.querySelector('[id^=s-menu]') || row.querySelector('.chat-menu')); if (mb) mb.click(); return mb ? 'menu' : 'no-menu'; })()" % sid)
    time.sleep(1.0)
    key = base64.b64encode(sid.encode()).decode().rstrip("=")
    print("  del btn:", js("(() => { const b = document.getElementById('sm-del-%s'); if (b) { b.click(); return 'clicked'; } return 'no-btn'; })()" % key))
    time.sleep(1.2)
    print("  confirm:", js("(() => { const delBtn = [...document.querySelectorAll('button')].find(x => /delete/i.test(x.textContent) && !x.id.startsWith('sm-')); if (delBtn) { delBtn.click(); return 'confirmed'; } return 'no modal'; })()"))
    time.sleep(2.0)
    sweeps += 1

final = js("(() => JSON.stringify([...document.querySelectorAll('.sess-row')].filter(r => /probe|UXGATE|cdp-|fix-check|queued probe/i.test(r.textContent)).map(r => (r.textContent||'').replace(/\\s+/g,' ').trim().slice(0,30))))()")
print("FINAL:", final)