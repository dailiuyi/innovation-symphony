# -*- coding: utf-8 -*-
"""Codex transcript context pages and page-writing helpers.

Ported from build/symphony-watch.py.
"""
import hashlib
import os
import re
import tempfile
import time
from html import escape as html_escape

from .collector import public_session

_CODEX_HTML = {}

VIEWER_MINUTE = re.compile(r"Generated \d{4}-\d{2}-\d{2} \d{2}:\d{2}")
GEN_STAMP = re.compile(r"生成 \d{2}-\d{2} \d{2}:\d{2}:\d{2}")


def codex_transcript_html(path):
    """Render one rollout with masonc15/codex-transcript-viewer.

    The library stamps the current minute into the page. Reuse the HTML
    while the rollout size and mtime stay the same, so a quiet cycle does
    not rewrite every context file.
    """
    st = os.stat(path)
    token = (st.st_size, getattr(st, "st_mtime_ns", st.st_mtime))
    cached = _CODEX_HTML.get(path)
    if cached and cached[0] == token:
        return cached[1]
    try:
        from codex_transcript_viewer.html_builder import build_html
        from codex_transcript_viewer.parser import (
            extract_conversation,
            parse_jsonl,
            unrecognized_record_kinds,
        )
    except ImportError as exc:
        raise RuntimeError(
            "需要 codex-transcript-viewer：python -m pip install codex-transcript-viewer"
        ) from exc
    entries = parse_jsonl(path)
    meta, events = extract_conversation(entries)
    page = build_html(meta, events)
    unknown = unrecognized_record_kinds(entries)
    if unknown:
        summary = ", ".join(f"{kind} x{count}" for kind, count in unknown.most_common())
        print(f"codex viewer {os.path.basename(path)} skipped unrecognized records: {summary}")
    _CODEX_HTML[path] = (token, page)
    return page


CONTEXT_REFRESH = r"""<script>
(function(){
  function textSig(html){
    return String(html || '').replace(/Generated \d{4}-\d{2}-\d{2} \d{2}:\d{2}/g, 'Generated');
  }
  function scrub(el){
    if(!el) return '';
    const clone = el.cloneNode(true);
    clone.querySelectorAll('.tool-output.expanded').forEach(node => node.classList.remove('expanded'));
    clone.querySelectorAll('.tree-node.active').forEach(node => node.classList.remove('active'));
    clone.querySelectorAll('[style]').forEach(node => {
      node.style.removeProperty('display');
      node.style.removeProperty('outline');
      if(!(node.getAttribute('style') || '').trim()) node.removeAttribute('style');
    });
    const wrap = new DOMParser().parseFromString('<div id="sig-root">' + clone.innerHTML + '</div>', 'text/html');
    const root = wrap.getElementById('sig-root');
    return textSig(root ? root.innerHTML : '');
  }
  let snapshotText = null;
  let refreshing = false;
  function nearEnd(el){
    if(!el || el.scrollHeight <= el.clientHeight + 1) return false;
    return (el.scrollHeight - el.scrollTop - el.clientHeight) < 48;
  }
  function bindTree(root){
    root.querySelectorAll('.tree-node').forEach(node => {
      node.addEventListener('click', function(e){
        e.preventDefault();
        const href = this.getAttribute('href') || '';
        const id = href.charAt(0) === '#' ? href.slice(1) : '';
        if(id){
          const el = document.getElementById(id);
          if(el){
            const folded = el.tagName === 'DETAILS' ? el : el.closest('details');
            if(folded) folded.open = true;
            el.scrollIntoView({behavior:'smooth', block:'center'});
            el.style.outline = '2px solid var(--accent)';
            setTimeout(() => { el.style.outline = ''; }, 2000);
          }
        }
        document.querySelectorAll('.tree-node').forEach(item => item.classList.remove('active'));
        this.classList.add('active');
      });
    });
  }
  window.applyFilters = function(search){
    const box = document.getElementById('tree-search');
    search = (search || (box ? box.value : '')).toLowerCase();
    const active = document.querySelector('.filter-btn.active');
    const activeFilter = active && active.dataset.filter ? active.dataset.filter : 'default';
    document.querySelectorAll('#tree-container .tree-node').forEach(node => {
      const classes = node.className;
      let visible = true;
      if(activeFilter === 'no-tools'){
        visible = classes.indexOf('tree-role-tool') < 0 && classes.indexOf('tree-role-system') < 0;
      }else if(activeFilter === 'user-only'){
        visible = classes.indexOf('tree-role-user') >= 0;
      }else if(activeFilter === 'answers'){
        visible = node.dataset.kind === 'user' || node.dataset.kind === 'final-answer';
      }else if(activeFilter === 'default'){
        visible = classes.indexOf('tree-role-system') < 0 && classes.indexOf('tree-role-thinking') < 0;
      }
      if(visible && search) visible = node.textContent.toLowerCase().indexOf(search) >= 0;
      node.style.display = visible ? '' : 'none';
    });
  };
  window.filterTree = function(search){ applyFilters(search); };
  window.setFilter = function(filter, btn){
    document.querySelectorAll('.filter-btn').forEach(item => item.classList.remove('active'));
    const match = btn || document.querySelector('.filter-btn[data-filter="' + filter + '"]');
    if(match) match.classList.add('active');
    applyFilters();
  };
  function captureView(){
    const content = document.getElementById('content');
    const tree = document.getElementById('tree-container');
    const page = document.scrollingElement || document.documentElement;
    const active = document.querySelector('.filter-btn.active');
    const current = document.querySelector('.tree-node.active');
    return {
      x: window.scrollX,
      y: window.scrollY,
      pageNear: nearEnd(page),
      content: content ? content.scrollTop : 0,
      contentNear: nearEnd(content),
      tree: tree ? tree.scrollTop : 0,
      treeNear: nearEnd(tree),
      search: (document.getElementById('tree-search') || {}).value || '',
      filter: active && active.dataset.filter ? active.dataset.filter : 'default',
      expanded: Array.from(document.querySelectorAll('#messages .tool-output.expanded')).map(el => {
        const host = el.closest('[id]');
        if(!host) return '';
        const items = Array.from(host.querySelectorAll('.tool-output.expandable'));
        return host.id + ':' + items.indexOf(el);
      }).filter(Boolean),
      openDetails: Array.from(document.querySelectorAll('#messages details[open]')).map(el => el.id).filter(Boolean),
      activeHref: current ? (current.getAttribute('href') || '') : '',
      sidebar: !!(document.getElementById('sidebar') && document.getElementById('sidebar').classList.contains('open'))
    };
  }
  function restoreView(view){
    const content = document.getElementById('content');
    const tree = document.getElementById('tree-container');
    const box = document.getElementById('tree-search');
    if(box) box.value = view.search;
    const btn = document.querySelector('.filter-btn[data-filter="' + view.filter + '"]');
    if(btn) setFilter(view.filter, btn);
    else applyFilters();
    view.expanded.forEach(key => {
      const parts = key.split(':');
      const host = document.getElementById(parts[0]);
      const item = host ? host.querySelectorAll('.tool-output.expandable')[Number(parts[1])] : null;
      if(item) item.classList.add('expanded');
    });
    view.openDetails.forEach(id => {
      const el = document.getElementById(id);
      if(el && el.tagName === 'DETAILS') el.open = true;
    });
    if(view.activeHref){
      document.querySelectorAll('.tree-node').forEach(node => {
        if(node.getAttribute('href') === view.activeHref) node.classList.add('active');
      });
    }
    const sidebar = document.getElementById('sidebar');
    const overlay = document.getElementById('sidebar-overlay');
    if(sidebar) sidebar.classList.toggle('open', view.sidebar);
    if(overlay) overlay.classList.toggle('open', view.sidebar);
    if(content) content.scrollTop = view.contentNear ? content.scrollHeight : view.content;
    if(content) content.scrollTop = view.contentNear ? content.scrollHeight : view.content;
    if(tree) tree.scrollTop = view.treeNear ? tree.scrollHeight : view.tree;
    const page = document.scrollingElement || document.documentElement;
    window.scrollTo(view.x, view.pageNear ? page.scrollHeight : view.y);
  }
  function replaceRegion(sel, doc, force){
    const cur = document.querySelector(sel);
    const nxt = doc.querySelector(sel);
    if(!cur || !nxt) return false;
    if(!force && scrub(cur) === scrub(nxt)) return false;
    cur.innerHTML = nxt.innerHTML;
    return true;
  }
  function applyDoc(doc, force){
    const view = captureView();
    const treeChanged = replaceRegion('#tree-container', doc, force);
    const messagesChanged = replaceRegion('#messages', doc, force);
    const metaChanged = replaceRegion('.sidebar-meta', doc, force);
    const headerChanged = replaceRegion('.header-info', doc, force);
    const footerChanged = replaceRegion('.footer', doc, force);
    if(!(treeChanged || messagesChanged || metaChanged || headerChanged || footerChanged)) return false;
    if(treeChanged){
      const tree = document.getElementById('tree-container');
      if(tree) bindTree(tree);
    }
    restoreView(view);
    return true;
  }
  async function refreshSilent(){
    if(refreshing) return false;
    refreshing = true;
    try{
      const res = await fetch(location.href, {cache:'no-store'});
      if(!res.ok) return false;
      const raw = await res.text();
      const incoming = (raw.match(/data-transcript="([0-9a-f]{20})"/) || [])[1] || '';
      const current = document.body.getAttribute('data-transcript') || '';
      if(incoming && incoming === current) return false;
      const sig = textSig(raw);
      if(!incoming && sig === snapshotText) return false;
      const doc = new DOMParser().parseFromString(raw, 'text/html');
      if(!doc.getElementById('messages') || !doc.getElementById('tree-container')) return false;
      const applied = applyDoc(doc, !!incoming);
      if(!applied) return false;
      if(incoming) document.body.setAttribute('data-transcript', incoming);
      else snapshotText = sig;
      return true;
    }catch(err){
      return false;
    }finally{
      refreshing = false;
    }
  }
  window.refreshSilent = refreshSilent;
  setInterval(refreshSilent, __INTERVAL__ * 1000);
  document.addEventListener('visibilitychange', () => { if(!document.hidden) refreshSilent(); });
})();
</script>
"""


def context_refresh_script(interval):
    """Poll this transcript in place. Ignore the viewer minute when nothing else changed."""
    return CONTEXT_REFRESH.replace("__INTERVAL__", str(interval))


def stamp_codex_page(page, heading, note, source, interval, back_url="workbench.html"):
    """Keep the Codex transcript and add the link back to the board."""
    heading = heading or "会话"
    safe_heading = html_escape(heading)
    css = (
        "a.symphony-back{color:var(--accent);text-decoration:none;font-size:12px}"
        ".sidebar-header a.symphony-back{display:inline-block;margin:0 0 8px}"
        ".header-info .info-value{white-space:normal;word-break:break-all}"
        "@media (max-width:900px){.header{padding-top:36px}}"
    )
    page = page.replace("</head>", f"<style>{css}</style></head>", 1)
    page = page.replace("<title>Codex CLI Session — ", f"<title>{safe_heading} · ", 1)
    page = page.replace(
        '<div class="sidebar-header">\n        <h2>CODEX CLI SESSION</h2>',
        '<div class="sidebar-header">\n'
        f'        <a class="symphony-back" href="{back_url}">← 返回工作台</a>\n'
        f"        <h2>{safe_heading}</h2>",
        1,
    )
    page = page.replace(
        '<h1><span class="codex-logo">CODEX</span> Session Transcript</h1>',
        f'<h1><a class="symphony-back" href="{back_url}">← 返回工作台</a>'
        f'<span class="codex-logo">CODEX</span> {safe_heading}</h1>',
        1,
    )
    facts = []
    if note:
        facts.append(
            '<div class="info-item"><span class="info-label">说明</span>'
            f'<span class="info-value">{html_escape(note)}</span></div>'
        )
    if source:
        facts.append(
            '<div class="info-item"><span class="info-label">来源</span>'
            f'<span class="info-value">{html_escape(source)}</span></div>'
        )
    if facts:
        page = page.replace('<div class="header-info">', '<div class="header-info">' + "".join(facts), 1)
    if page.count(f'href="{back_url}"') < 2:
        raise RuntimeError("codex transcript page is missing the workbench link")
    if "</body>" not in page:
        raise RuntimeError("codex transcript page is missing a body")
    page = page.replace("</body>", context_refresh_script(interval) + "</body>", 1)
    if "refreshSilent" not in page or 'http-equiv="refresh"' in page:
        raise RuntimeError("codex transcript page is missing silent refresh")
    token = transcript_token(page)
    if "<body>" not in page:
        raise RuntimeError("codex transcript page is missing a body tag")
    page = page.replace("<body>", f'<body data-transcript="{token}">', 1)
    return page


def transcript_token(page):
    """Hash the transcript. The viewer minute is not part of the token."""
    normalized = VIEWER_MINUTE.sub("Generated", page or "")
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:20]


def page_body(text):
    return GEN_STAMP.sub("生成", text or "")


def write_if_changed(path, content):
    try:
        with open(path, encoding="utf-8") as handle:
            current = handle.read()
    except FileNotFoundError:
        current = None
    if current is not None and page_body(current) == page_body(content):
        return False
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".page-", suffix=".tmp", dir=directory)
    replaced = False
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        for _ in range(8):
            try:
                os.replace(tmp, path)
                replaced = True
                break
            except PermissionError:
                time.sleep(0.05)
        if not replaced:
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(content)
    finally:
        if not replaced and os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
    return True


def viewer_pages(sessions, interval, back_url="workbench.html"):
    pages = []
    notes = {
        "预检": "这是启动前的预检会话，不写 Issue 回执。",
        "编码": "编码代理。角色由任务指令开头「Implement only this repository's issue」推断，回执没有按角色保存 session id。",
        "Review": "Review 代理，只读。角色由任务指令开头「Independently review」推断，回执没有按角色保存 session id。",
        "诊断": "检查失败后的只读诊断。它不改仓库里的代码，结论是 repair_code、retry_stage 或 stop。",
        "未识别": "任务指令对不上预检、编码、Review 或诊断的开头，所以单独标出来。",
    }
    for session in sessions:
        meta_session = public_session(session)
        local = session.get("local")
        if not local or not os.path.exists(local):
            continue
        role = meta_session["role"]
        gid = session.get("issue") or "预检"
        heading = f"{gid} {role}会话"
        page = stamp_codex_page(
            codex_transcript_html(local),
            heading,
            notes.get(role, ""),
            session.get("remote") or "",
            interval,
            back_url,
        )
        pages.append((meta_session["href"], page))
        cwd = (session.get("cwd") or "").rstrip("/")
        if meta_session["runtime"] == "v0" and cwd.endswith("/workspaces/GH-1") and role == "编码":
            pages.append(("context-GH-1.html", page))
    return pages
