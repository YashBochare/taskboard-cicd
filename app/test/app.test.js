const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');

let server;
let base;

before(async () => {
  server = createApp().listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

const post = (path, body) =>
  fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

test('TC-01 health endpoint reports ok', async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).status, 'ok');
});

test('TC-02 info endpoint exposes version and build metadata', async () => {
  const info = await (await fetch(`${base}/api/info`)).json();
  assert.equal(info.app, 'TaskBoard');
  assert.ok('version' in info && 'build' in info && 'commit' in info);
});

test('TC-03 lists seeded tasks', async () => {
  const tasks = await (await fetch(`${base}/api/tasks`)).json();
  assert.ok(Array.isArray(tasks));
  assert.ok(tasks.length >= 3);
});

test('TC-04 creates a task', async () => {
  const res = await post('/api/tasks', { title: 'Write report' });
  assert.equal(res.status, 201);
  const task = await res.json();
  assert.equal(task.title, 'Write report');
  assert.equal(task.done, false);
});

test('TC-05 rejects a task without a title', async () => {
  const res = await post('/api/tasks', { title: '   ' });
  assert.equal(res.status, 400);
});

test('TC-06 rejects a title longer than 100 characters', async () => {
  const res = await post('/api/tasks', { title: 'x'.repeat(101) });
  assert.equal(res.status, 400);
});

test('TC-07 marks a task as done', async () => {
  const res = await fetch(`${base}/api/tasks/3`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ done: true }),
  });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).done, true);
});

test('TC-08 returns 404 for an unknown task', async () => {
  const res = await fetch(`${base}/api/tasks/9999`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ done: true }),
  });
  assert.equal(res.status, 404);
});

test('TC-09 serves the web UI', async () => {
  const res = await fetch(`${base}/`);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /TaskBoard/);
});
