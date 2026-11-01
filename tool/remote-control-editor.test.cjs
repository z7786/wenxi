// Run with: node --test tool/remote-control-editor.test.cjs
// Exercise the actual standalone editor's protocol code, without dependencies.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const root = resolve(__dirname, '..');
const html = readFileSync(resolve(root, '远程配置编辑器.html'), 'utf8');
const context = vm.createContext({ URL, TextEncoder, TextDecoder, AbortController, setTimeout, clearTimeout });
const script = html.match(/<script id="config-core">([\s\S]*?)<\/script>/)[1];
vm.runInContext(script, context);
const C = context.WenxiConfig;
const native = value => JSON.parse(JSON.stringify(value));
const valid = value => assert.deepEqual(native(C.validate(value)), []);

test('Optional in-app update fields roundtrip and count as changed publication content', () => {
  const before = C.template();
  before.updates.android = {...before.updates.android,enabled:true,version:'1.2.0',build:120,
    downloadUrl:'https://example.test/downloads'};
  const changed = C.clone(before);
  changed.updates.android.inAppDownloadUrl = 'https://wwanc.lanzouq.com/iabc123';
  changed.updates.android.inAppPasscode = '1234';
  valid(changed);
  const restored = C.normalize(C.parse(JSON.stringify(changed)));
  assert.equal(restored.updates.android.inAppPasscode,'1234');
  assert.equal(restored.updates.android.inAppDownloadUrl,changed.updates.android.inAppDownloadUrl);
  assert.equal(C.samePublishedContent(before,changed),false);
  changed.updates.android.inAppDownloadUrl = 'http://example.test/app.apk';
  assert.ok(C.validate(changed).some(e => e.path === 'updates.android.inAppDownloadUrl'));
});
const issue = (value, path) => assert.ok(C.validate(value).some(e => e.path === path), `Expected validation error at ${path}`);

test('both embedded scripts parse and the single HTML has no remote dependencies', () => {
  for (const [, id, source] of html.matchAll(/<script id="([^"]+)">([\s\S]*?)<\/script>/g)) {
    new vm.Script(source, { filename: id });
  }
  assert.doesNotMatch(html, /<(?:script|img|iframe)[^>]+src=["']https?:/i);
  assert.doesNotMatch(html, /<link[^>]+href=["']https?:/i);
});

test('new template leaves prompts inactive and all fourteen clouds enabled', () => {
  const config = C.template();
  valid(config);
  assert.equal(config.schema, 1);
  assert.equal(config.revision, 1);
  assert.equal(config.announcement.enabled, false);
  assert.equal(config.announcement.buttonUrl, '');
  assert.equal(config.help.enabled, false);
  assert.equal(Object.keys(config.clouds).length, 14);
  assert.equal(C.CLOUDS.length, 14);
  assert.ok(Object.values(config.clouds).every(c => c.enabled));
  for (const update of Object.values(config.updates)) {
    assert.equal(update.enabled, false);
    assert.equal(update.force, false);
    assert.equal(update.downloadUrl, '');
    assert.equal(update.build, 53);
  }
});

test('Aliyun and Guangya can be enabled independently and are added to older configs', () => {
  const config = C.normalize({schema: 1, revision: 1, clouds: {
    aliyun: {enabled: false, message: '维护中'},
  }});
  valid(config);
  assert.equal(config.clouds.aliyun.enabled, false);
  assert.equal(config.clouds.aliyun.message, '维护中');
  assert.equal(config.clouds.guangya.enabled, true);
  config.clouds.guangya = {...config.clouds.guangya, enabled: false, message: '升级中'};
  const restored = C.normalize(C.parse(JSON.stringify(config)));
  valid(restored);
  assert.deepEqual(native(restored.clouds), native(config.clouds));
});

test('OpenList clouds are added to older configs and retain independent switches on export', () => {
  const config = C.normalize({schema: 1, revision: 7, clouds: {uc: {enabled: false, message: '维护'}}});
  for (const key of ['ilanzou', 'weiyun', 'wopan', 'pan115']) {
    assert.equal(config.clouds[key].enabled, true);
    config.clouds[key] = {...config.clouds[key], enabled: false, message: `维护 ${key}`};
  }
  valid(config);
  const restored = C.normalize(C.parse(JSON.stringify(config)));
  valid(restored);
  assert.deepEqual(native(restored.clouds), native(config.clouds));
  assert.equal(restored.revision, 7);
  assert.equal(restored.clouds.uc.enabled, false);
});

test('minimal config gets the app defaults without enabling prompts', () => {
  const config = C.normalize(C.parse('{"schema":1,"revision":8}'));
  valid(config);
  assert.equal(config.revision, 8);
  assert.equal(config.announcement.enabled, false);
  assert.equal(config.announcement.id, '');
  assert.equal(config.updates.android.build, 0);
  assert.equal(config.updates.windows.enabled, false);
  assert.equal(config.help.url, '');
  assert.equal(config.about.description, '');
  assert.ok(Object.values(config.clouds).every(c => c.enabled));
});

test('public configuration examples can be imported without losing their content', () => {
  for (const name of ['config/control.example.json']) {
    const original = C.parse(readFileSync(resolve(root, name), 'utf8'));
    const config = C.normalize(original);
    valid(config);
    assert.equal(config.revision, original.revision);
    assert.equal(config.announcement.content, original.announcement.content);
    assert.equal(config.updates.android.version, original.updates.android.version);
    assert.equal(config.updates.windows.build, original.updates.windows.build);
  }
});

test('all controls coexist, with independent normal and forced platform updates', () => {
  const config = C.template();
  config.revision = 9;
  Object.assign(config.announcement, {
    enabled: true, id: 'notice-new', title: '活动公告', content: '第一行\n第二行',
    buttonText: '查看详情', buttonUrl: 'https://github.com/z7786/wenxi#readme',
  });
  config.clouds.uc = { enabled: false, message: '维护中，请稍后重试。' };
  Object.assign(config.updates.android, { enabled: true, build: 52, version: '0.3.47', force: true, downloadUrl: 'https://github.com/z7786/wenxi/releases' });
  Object.assign(config.updates.windows, { enabled: true, build: 51, force: false, downloadUrl: 'https://github.com/z7786/wenxi/releases' });
  config.help = { enabled: true, url: 'https://github.com/z7786/wenxi' };
  valid(config);
  const roundTrip = C.parse(JSON.stringify(config, null, 2));
  assert.deepEqual(native(roundTrip), native(config));
  assert.equal(roundTrip.updates.android.force, true);
  assert.equal(roundTrip.updates.windows.force, false);
});

test('unknown optional metadata and future platform fields survive editing', () => {
  const original = C.parse('{"schema":1,"revision":2,"metadata":{"nested":[1,{"note":"保留"}]},"__proto__":{"polluted":true},"announcement":{"extra":"保留"},"updates":{"ios":{"enabled":true}}}');
  const config = C.normalize(original);
  config.about.description = '新的介绍';
  const roundTrip = JSON.parse(JSON.stringify(config));
  assert.deepEqual(roundTrip.metadata, { nested: [1, { note: '保留' }] });
  assert.equal(roundTrip.__proto__.polluted, true);
  assert.equal({}.polluted, undefined);
  assert.equal(config.announcement.extra, '保留');
  assert.equal(config.updates.ios.enabled, true);
  assert.ok(C.extras(config).includes('updates.ios'));
  valid(config);
});

test('duplicate fields are rejected, including escaped equivalent keys and nested arrays', () => {
  const invalid = [
    ['{"schema":1,"revision":1,"revision":2}', /revision/],
    ['{"schema":1,"revision":1,"announcement":{"content":"a","content":"b"}}', /announcement.content/],
    ['{"schema":1,"revision":1,"\\u0072evision":3}', /revision/],
    ['{"schema":1,"revision":1,"extra":[{"x":1,"x":2}]}', /extra\[0\].x/],
  ];
  for (const [raw, path] of invalid) assert.throws(() => C.parse(raw), path);
});

test('invalid syntax is rejected and a UTF-8 BOM is accepted', () => {
  for (const raw of ['', '{"schema":1,}', '{/*comment*/"schema":1}', '{"schema":1', '[]']) {
    assert.throws(() => C.parse(raw));
  }
  assert.equal(C.parse('\ufeff{"schema":1,"revision":1}').revision, 1);
});

test('publication metadata is optional while update builds remain integers', () => {
  for (const raw of [
    '{"schema":1,"revision":1,"updates":{"android":{"enabled":true,"build":2.0}}}',
    '{"schema":1,"revision":1,"updates":{"windows":{"enabled":true,"build":5e1}}}',
  ]) assert.throws(() => C.parse(raw), /整数/);
  for (const revision of [0, -1, 0.5, 2147483648, null, '2', true]) {
    valid({ schema: 1, revision });
  }
  valid({ schema: 1, revision: 2147483647 });
  valid({ schema: 2, revision: 1 });
  valid({ revision: 1 });
  valid({});
  assert.doesNotThrow(() => C.parse('{"schema":1.0,"revision":1e2}'));
});

test('active switches must be booleans and inactive update policies are ignored', () => {
  for (const invalid of ['false', 0, 1, null]) {
    const config = C.template();
    config.clouds.uc.enabled = invalid;
    config.updates.windows.force = invalid;
    config.help.enabled = invalid;
    issue(config, 'clouds.uc.enabled');
    assert.ok(!C.validate(config).some(e => e.path === 'updates.windows.force'));
    config.updates.windows.enabled = true;
    issue(config, 'updates.windows.force');
    issue(config, 'help.enabled');
  }
});

test('only known cloud names and object sections are accepted', () => {
  issue({ schema: 1, revision: 1, clouds: { tiany: { enabled: true } } }, 'clouds.tiany');
  for (const name of ['announcement', 'clouds', 'updates', 'help', 'about']) {
    for (const value of [null, [], false, '']) issue({ schema: 1, revision: 1, [name]: value }, name);
  }
});

test('HTTPS validation rejects repaired URLs, credentials, controls and invalid ports', () => {
  for (const url of [
    'http://example.com/a', 'javascript:alert(1)', 'file:///C:/test',
    'https://u:p@example.com/', 'https:///a', 'https:example.com',
    'https://example.com/a\nb', 'https://example.com:99999/',
    'https://example.com:0/', 'https://example.com\\@other.test/',
    'https://exa mple.com/', 'https://example.com/\u0000',
  ]) {
    assert.equal(C.https(url), false, url);
    const config = C.template();
    config.announcement.enabled = config.updates.android.enabled = config.help.enabled = true;
    config.announcement.buttonText = '打开';
    config.announcement.buttonUrl = url;
    config.updates.android.downloadUrl = url;
    config.help.url = url;
    issue(config, 'announcement.buttonUrl');
    issue(config, 'updates.android.downloadUrl');
    issue(config, 'help.url');
  }
  for (const url of ['https://example.com/a?b=1#c', 'https://example.com:443/', 'https://example.com:65535/', 'https://[::1]/', ' https://example.com/ ']) {
    assert.equal(C.https(url), true, url);
  }
});

test('notice links are paired only while the notice is enabled', () => {
  for (const enabled of [true, false]) {
    const config = C.template();
    Object.assign(config.announcement, { enabled, content: '测试公告', buttonText: '查看详情' });
    if (enabled) issue(config, 'announcement.buttonUrl'); else valid(config);
    config.announcement.buttonText = '';
    config.announcement.buttonUrl = 'https://example.com/a';
    if (enabled) issue(config, 'announcement.buttonText'); else valid(config);
    config.announcement.buttonText = '打开';
    valid(config);
    config.announcement.buttonText = config.announcement.buttonUrl = '';
    valid(config);
  }
});

test('enabled sections require their essential fields', () => {
  const config = C.normalize({ schema: 1, revision: 1 });
  config.announcement.enabled = true;
  config.updates.windows.enabled = true;
  config.help.enabled = true;
  for (const path of ['announcement.title', 'announcement.content', 'updates.windows.version', 'updates.windows.build', 'updates.windows.downloadUrl', 'help.url']) issue(config, path);
});

test('notice ID is no longer an editable or required field; today preview stays local', () => {
  assert.doesNotMatch(html, /data-path="announcement\.id"|id="new-notice-id"/);
  assert.match(html, /id="preview-hide-today"/);
  assert.match(html, /今天不再显示/);
  const config = C.template();
  delete config.announcement.id;
  config.announcement.enabled = true;
  config.announcement.content = '不需要手动维护公告标识';
  valid(config);
  assert.equal(C.normalize(C.parse(JSON.stringify(config))).announcement.id, '');
  assert.equal(Object.hasOwn(config.announcement, 'hideForToday'), false);
});

test('legacy wire ID is automatic, stable on repeated exports and unchanged notices', () => {
  const original = C.template();
  original.revision = 8;
  original.announcement.id = 'legacy-publisher-id';
  original.announcement.content = '原公告';
  const config = C.clone(original);
  config.about.description = '只改介绍';
  config.revision = C.nextRevision(config, original);
  C.syncAnnouncementId(config, original);
  assert.equal(config.announcement.id, 'legacy-publisher-id');
  config.announcement.content = '新公告';
  C.syncAnnouncementId(config, original);
  assert.equal(config.announcement.id, 'notice-auto-9');
  const exported = C.clone(config);
  C.syncAnnouncementId(config, exported);
  assert.equal(config.announcement.id, 'notice-auto-9');
  assert.equal(C.nextRevision(config, exported), 9);
  config.announcement.title = '再次修改公告';
  config.revision = C.nextRevision(config, exported);
  C.syncAnnouncementId(config, exported);
  assert.equal(config.announcement.id, 'notice-auto-10');
  valid(config);
});

test('text limits use UTF-16 code units consistently with Dart, preserving line breaks', () => {
  const config = C.template();
  config.announcement.enabled = true;
  config.clouds.uc.enabled = false;
  Object.assign(config.updates.android, {enabled:true,downloadUrl:'https://example.com/update'});
  config.announcement.title = '文'.repeat(80);
  config.announcement.content = 'A'.repeat(8192);
  config.clouds.uc.message = '文'.repeat(200);
  valid(config);
  config.announcement.title = '文'.repeat(81);
  config.clouds.uc.message = '文'.repeat(201);
  config.updates.android.notes = '😀'.repeat(4097);
  config.about.description = 'A'.repeat(8193);
  for (const path of ['announcement.title', 'clouds.uc.message', 'updates.android.notes', 'about.description']) issue(config, path);
});

test('UTF-8 file size is bounded for both the import and the formatted export', () => {
  assert.throws(() => C.parse(JSON.stringify({ schema: 1, revision: 1, extra: '文'.repeat(90000) })), /256 KiB/);
  const config = C.template();
  config.extra = 'a'.repeat(256 * 1024);
  issue(config, '');
  assert.throws(() => C.parse('{"schema":1,"revision":1,"extra":9007199254740993}'), /安全编辑/);
});

test('text containing JSON escapes and HTML-like payloads survives as plain text', () => {
  const config = C.template();
  config.announcement.content = '多行\n"引号" \\路径 😀 <script>globalThis.injected=true</script>';
  const imported = C.normalize(C.parse(JSON.stringify(config)));
  assert.equal(imported.announcement.content, config.announcement.content);
  assert.equal(context.injected, undefined);
});

test('revision advances once per changed import/export, and repeated exports stay stable', () => {
  const baseline = C.template();
  baseline.revision = 7;
  const config = C.clone(baseline);
  assert.equal(C.nextRevision(config, baseline), 7);
  config.about.description = '第一处修改';
  config.revision = C.nextRevision(config, baseline);
  assert.equal(config.revision, 8);
  config.help.url = 'https://example.com/help';
  assert.equal(C.nextRevision(config, baseline), 8);
  assert.deepEqual(native(C.publicationErrors(config, baseline)), []);
  const exported = C.clone(config);
  assert.equal(C.nextRevision(config, exported), 8);
  config.about.description = '导出后再次修改';
  assert.equal(C.nextRevision(config, exported), 9);
  config.revision = 20;
  assert.equal(C.nextRevision(config, exported), 20);
});

test('manual revisions never block exporting changed or older content', () => {
  const baseline = C.template();
  baseline.revision = 12;
  const config = C.clone(baseline);
  config.announcement.content = '修改';
  assert.equal(C.publicationErrors(config, baseline).length, 0);
  config.revision = 11;
  assert.equal(C.publicationErrors(config, baseline).length, 0);
  baseline.revision = config.revision = C.MAX_INT;
  assert.equal(C.nextRevision(config, baseline), C.MAX_INT);
  assert.equal(C.publicationErrors(config, baseline).length, 0);
  assert.equal(C.nextRevision(config, null), C.MAX_INT);
});

test('disabled modules ignore inactive garbage and validate it when re-enabled', () => {
  const config = {
    schema:1, revision:8,
    announcement:{enabled:false,buttonUrl:123,title:[]},
    clouds:{uc:{enabled:true,message:123,expiresAt:false}},
    updates:{android:{enabled:false,build:-1,force:'true',downloadUrl:false}},
    help:{enabled:false,url:'http://invalid'}
  };
  valid(config);
  assert.doesNotThrow(() => C.parse('{"schema":1,"revision":1,"updates":{"windows":{"build":5e1}}}'));
  config.announcement.enabled = true;
  config.clouds.uc.enabled = false;
  config.updates.android.enabled = true;
  config.help.enabled = true;
  for (const path of ['announcement.title','clouds.uc.message','updates.android.build','help.url']) issue(config,path);
});

test('expiry uses strict UTC dates, local inputs round-trip milliseconds, and defaults remain optional', () => {
  for (const date of ['2026-10-01T00:00:00Z','2028-02-29T23:59:59.12Z','2026-09-30T14:23:12.999Z']) {
    assert.equal(C.validExpiry(date),true);
    assert.equal(C.localToUtc(C.utcToLocal(date)),new Date(date).toISOString());
  }
  for (const invalid of ['2026-02-30T00:00:00Z','2026-10-01T24:00:00Z','2026-10-01T00:00:00+08:00','2026-10-01','bad',123,null]) {
    assert.equal(C.validExpiry(invalid),false,String(invalid));
    const config = C.template();
    Object.assign(config.clouds.uc,{enabled:false,expiresAt:invalid});
    Object.assign(config.updates.android,{enabled:true,force:true,downloadUrl:'https://example.com/update',expiresAt:invalid});
    issue(config,'clouds.uc.expiresAt');
    issue(config,'updates.android.expiresAt');
    config.clouds.uc.enabled = true;
    config.updates.android.force = false;
    valid(config);
  }
  assert.equal(C.localToUtc(''),'');
  assert.equal(C.utcToLocal(''),'');
  assert.equal(C.validExpiry(''),true);
  assert.equal(C.validExpiry(C.localToUtc('2026-02-30T12:00')),false);
  assert.deepEqual(native(C.extras(C.template())),[]);
});

test('live comparison understands omitted defaults, inactive values and key order', () => {
  const published = C.parse('{"revision":7,"schema":1}');
  const local = C.normalize({schema:1,revision:7});
  local.announcement.buttonUrl = 'inactive leftover';
  local.updates.windows.build = -10;
  assert.equal(C.samePublishedContent(local,published),true);
  assert.deepEqual(native(C.publishedErrors(local,published)),[]);
  assert.equal(C.nextPublishedRevision(local,published),7);
  assert.equal(C.sameContent({a:{x:1,y:2},revision:1},{revision:9,a:{y:2,x:1}}),true);
});

test('live comparisons allow older drafts and same-revision content changes', () => {
  const published = C.template(); published.revision = 30;
  const local = C.clone(published);
  local.revision = 29;
  assert.equal(C.publishedErrors(local,published).length,0);
  assert.equal(C.nextPublishedRevision(local,published),30);
  local.revision = 30; local.about.description = 'new content';
  assert.equal(C.publishedErrors(local,published).length,0);
  assert.equal(C.nextPublishedRevision(local,published),31);
  local.revision = 31;
  assert.deepEqual(native(C.publishedErrors(local,published)),[]);
  published.revision = local.revision = C.MAX_INT;
  assert.equal(C.nextPublishedRevision(local,published),C.MAX_INT);
  assert.equal(C.publishedErrors(local,published).length,0);
});

test('broken live sections can be repaired without changing metadata', () => {
  const published = C.parse('{"schema":1,"revision":12,"updates":{"windows":{"enabled":true,"version":"1.0","build":5e1,"downloadUrl":"https://example.com/update"}}}',{strict:false});
  const local = C.normalize(published);
  local.updates.windows.build = 50;
  valid(local);
  issue(published,'updates.windows.build');
  assert.equal(C.nextPublishedRevision(local,published),13);
  assert.equal(C.publishedErrors(local,published).length,0);
  assert.doesNotThrow(() => C.parse('{"schema":2,"revision":12}',{strict:false}));
});

test('changing a restriction deadline does not require a new published revision', () => {
  const published = C.template(); published.revision = 14;
  Object.assign(published.clouds.uc,{enabled:false,expiresAt:'2026-10-01T00:00:00Z'});
  const local = C.clone(published);
  local.clouds.uc.expiresAt = '2026-10-02T00:00:00Z';
  assert.equal(C.nextPublishedRevision(local,published),15);
  assert.equal(C.publishedErrors(local,published).length,0);
});

test('the latest fetched publication replaces the reference regardless of revision', () => {
  const first = C.template(); first.revision = 20;
  const second = C.clone(first); second.about.description = 'changed without a bump';
  let reference = C.mergePublishedReference(first,second);
  assert.equal(reference.minimumRevision,0);
  const draft = C.clone(second);
  assert.equal(C.nextPublishedRevision(draft,reference.published,reference.minimumRevision),20);
  assert.equal(C.publishedErrors(draft,reference.published,reference.minimumRevision).length,0);
  reference = C.mergePublishedReference(reference.published,second,reference.minimumRevision);
  assert.equal(reference.minimumRevision,0);
  const old = C.clone(first); old.revision = 19;
  assert.equal(C.mergePublishedReference(second,old,reference.minimumRevision).published.revision,19);
  second.revision = 21;
  reference = C.mergePublishedReference(reference.published,second,reference.minimumRevision);
  assert.equal(reference.minimumRevision,0);
  assert.deepEqual(native(C.publishedErrors(second,reference.published,reference.minimumRevision)),[]);
});

const reply = (body,status=200,url='https://example.test/config.json',headers={}) => {
  const response = new Response(body,{status,headers});
  return {status,url,headers:response.headers,body:response.body};
};

test('live checks read HTTPS without credentials, preserve UTF-8 and may inspect invalid sections', async () => {
  let options;
  const config = {schema:1,revision:33,about:{description:'中文介绍'},help:{enabled:true,url:'http://invalid'}};
  const result = await C.fetchPublished('https://example.test/config.json',{fetcher:async (url,opts) => { options = opts; return reply(JSON.stringify(config)); }});
  assert.equal(result.revision,33);
  assert.equal(result.about.description,'中文介绍');
  issue(result,'help.url');
  assert.equal(options.credentials,'omit');
  assert.equal(options.cache,'no-store');
  assert.equal(options.referrerPolicy,'no-referrer');
});

test('live checks fail explicitly on unsafe endpoints, status errors, timeouts and malformed files', async () => {
  let calls = 0;
  for (const url of ['http://example.test/config','https://user:pass@example.test/config','https://example.test/config#fragment']) {
    await assert.rejects(C.fetchPublished(url,{fetcher:async () => { calls++; return reply('{}'); }}));
  }
  assert.equal(calls,0);
  await assert.rejects(C.fetchPublished(C.DEFAULT_URL,{fetcher:async () => reply('{}',500)}),/完整/);
  await assert.rejects(C.fetchPublished(C.DEFAULT_URL,{fetcher:async () => reply('{}',200,'http://example.test/config')}),/HTTPS/);
  await assert.rejects(C.fetchPublished('https://example.test/config.json',{fetcher:async () => reply('<html>failed</html>')}),/JSON/);
  let aborted = false;
  await assert.rejects(C.fetchPublished(C.DEFAULT_URL,{timeoutMs:15,fetcher:(_,opts) => { opts.signal.addEventListener('abort',() => { aborted = true; }); return new Promise(() => {}); }}),/超时/);
  assert.equal(aborted,true);
  await assert.rejects(C.fetchPublished(C.DEFAULT_URL,{fetcher:async () => { throw new TypeError('CORS'); }}),/CORS/);
});

test('live checks bound declared and streamed body sizes and cancel incomplete streams', async () => {
  await assert.rejects(C.fetchPublished(C.DEFAULT_URL,{fetcher:async () => reply('{}',200,undefined,{'content-length':String(C.MAX_BYTES+1)})}),/256 KiB/);
  let cancelled = false;
  const body = new ReadableStream({start(controller) { controller.enqueue(new Uint8Array(C.MAX_BYTES+1)); },cancel() { cancelled = true; }});
  await assert.rejects(C.fetchPublished('https://example.test/config.json',{fetcher:async () => reply(body)}),/256 KiB/);
  assert.equal(cancelled,true);
});
