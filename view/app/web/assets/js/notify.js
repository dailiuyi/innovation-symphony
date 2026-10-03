// 状态变化提示：页内 toast + 标签页标题角标。
// demo 原型不做桌面通知（设置页的通知开关已移除），只保留页内部分。

import { $, esc } from './fmt.js';
import { state } from './data.js';

let unread = 0;

function baseTitle() {
  return (state.boot.title || 'innovation-view') + ' · 任务看板';
}

function bumpTitle() {
  document.title = unread > 0 ? `(${unread}) ${baseTitle()}` : baseTitle();
}

export function clearUnread() {
  if (unread === 0) return;
  unread = 0;
  bumpTitle();
}

function toast(event) {
  const host = $('toasts');
  if (!host) return;
  const el = document.createElement('div');
  el.className = 'toast ' + event.kind;
  el.innerHTML = `<b>${esc(event.issueLabel)} ${esc(event.title)}</b><span>${esc(event.detail)} · ${esc(event.repo)}</span>`;
  el.addEventListener('click', () => {
    location.hash = '#/story/' + encodeURIComponent(event.taskId.startsWith('story--') ? event.taskId : storyOf(event.taskId) || event.taskId);
    el.remove();
  });
  host.appendChild(el);
  while (host.children.length > 5) host.firstChild.remove();
  setTimeout(() => { el.classList.add('gone'); setTimeout(() => el.remove(), 300); }, 6000);
}

function storyOf(taskId) {
  const story = (state.stories || []).find(s => (s.beats || []).some(b => b.taskId === taskId));
  return story ? story.id : null;
}

export function handleEvents(events) {
  if (!events || !events.length) return;
  for (const event of events) {
    toast(event);
    unread += 1;
  }
  bumpTitle();
}

document.addEventListener('visibilitychange', () => { if (!document.hidden) clearUnread(); });

// 调试/集成口：控制台里 window.__boardNotify([...events]) 可直接触发通知链路。
window.__boardNotify = handleEvents;
window.__boardClearUnread = clearUnread;
