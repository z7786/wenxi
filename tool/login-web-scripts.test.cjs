const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const viewport = scripts.viewport ?? fs.readFileSync(path.join(__dirname, '../lib/ui/login_webview.dart'), 'utf8')
  .match(/const desktopLoginViewportScript = r'''([\s\S]*?)''';/)[1];

function scene({passport = true} = {}) {
  let now = 1000, sender, nextTimer = 0;
  const timers = new Map(), messages = [], deliveries = [];
  const names = {main: 'www.alipan.com', auth: 'auth.alipan.com', passport: 'passport.alipan.com'};
  const frames = {};
  const run = (frame, action) => {
    const previous = sender;
    sender = frame;
    try { return typeof action === 'string' ? vm.runInContext(action, frame.context) : action(); }
    finally { sender = previous; }
  };
  const flush = () => {
    let count = 0;
    while (messages.length) {
      assert.ok(++count < 100, 'messages must not loop');
      const {to, event} = messages.shift();
      run(to, () => to.listeners.forEach(fn => fn(event)));
    }
  };
  for (const [name, host] of Object.entries(names)) {
    const frame = frames[name] = {name, listeners: [], children: [], clicks: 0, visible: false};
    class Input {
      constructor() { this._value = ''; this.events = []; }
      get value() { return this._value; }
      set value(value) { this._value = value; }
      getClientRects() { return frame.visible ? [{}] : []; }
      closest() { return frame.form; }
      dispatchEvent(event) { this.events.push(event.type); }
    }
    frame.user = new Input(); frame.password = new Input();
    frame.button = {isConnected: true, disabled: false, click: () => frame.clicks++};
    frame.form = {querySelector: () => frame.button};
    frame.window = {
      location: {origin: `https://${host}`, href: `https://${host}/`, pathname: name === 'passport' ? '/mini_login.htm' : '/'},
      addEventListener: (name, listener) => { if (name === 'message') frame.listeners.push(listener); },
      postMessage: (data, targetOrigin) => {
        deliveries.push({from: sender?.name, to: name, kind: data.kind, targetOrigin});
        assert.notEqual(targetOrigin, '*', 'the relay must never broadcast credentials');
        if (targetOrigin === frame.window.location.origin) {
          messages.push({to: frame, event: {data, origin: sender.window.location.origin, source: sender.window}});
        }
      },
    };
    frame.document = {
      querySelectorAll: selector => selector === 'iframe' ? frame.children : !frame.visible ? [{textContent: '账号登录', click: () => frame.visible = true}] : [],
      getElementById: id => frame.visible ? (id === 'fm-login-id' ? frame.user : frame.password) : null,
    };
    frame.window.document = frame.document;
    frame.stored = new Map([['token', 'previous-web-session']]);
    frame.context = vm.createContext({
      window: frame.window, location: frame.window.location, document: frame.document,
      URL, HTMLInputElement: Input, Event: class {constructor(type) {this.type = type;}},
      Date: {now: () => now},
      localStorage: {removeItem: key => frame.stored.delete(key)},
      setInterval: (fn, delay) => { const id = ++nextTimer; timers.set(id, {frame, fn, repeat: true, time: now + delay, delay}); return id; },
      setTimeout: (fn, delay) => { const id = ++nextTimer; timers.set(id, {frame, fn, repeat: false, time: now + delay}); return id; },
      clearInterval: id => timers.delete(id),
    });
  }
  for (const frame of Object.values(frames)) frame.window.top = frames.main.window;
  frames.main.window.parent = frames.main.window;
  frames.auth.window.parent = frames.main.window;
  frames.passport.window.parent = frames.auth.window;
  for (const frame of Object.values(frames)) frame.context.parent = frame.window.parent;
  const authElement = {src: 'https://auth.alipan.com/v2/oauth/authorize', contentWindow: frames.auth.window, isConnected: true};
  const passportElement = {src: 'https://passport.alipan.com/mini_login.htm', contentWindow: frames.passport.window, isConnected: true};
  frames.main.children.push(authElement); frames.auth.children.push(passportElement);
  for (const name of passport ? ['main', 'auth', 'passport'] : ['main', 'auth']) run(frames[name], scripts.bootstrap);
  const tick = (elapsed = 200) => {
    now += elapsed;
    for (const [id, timer] of [...timers]) {
      if (timer.time > now) continue;
      if (timer.repeat) timer.time = now + timer.delay;
      else timers.delete(id);
      run(timer.frame, timer.fn);
    }
    flush();
  };
  tick();
  return {
    ...frames, tick, flush, authElement, passportElement, deliveries,
    status: () => run(frames.main, scripts.status),
    submit: () => { const result = run(frames.main, scripts.submission); flush(); return result; },
    inject: (frame, event) => { run(frame, () => frame.listeners.forEach(fn => fn(event))); flush(); },
  };
}

test('official nested form receives a password once, without credentials in frame scripts', () => {
  assert.ok(!scripts.bootstrap.includes('fixture-password'));
  assert.ok(!scripts.bootstrap.includes('fixture-user'));
  const s = scene();
  assert.equal(s.status(), 'ready');
  assert.equal(s.submit(), 'sent');
  assert.equal(s.main.stored.has('token'), false);
  s.tick(100);
  assert.equal(s.passport.user.value, 'fixture-user');
  assert.equal(s.passport.password.value, ' fixture-password ');
  assert.deepEqual(s.passport.password.events, ['input', 'change']);
  assert.equal(s.passport.clicks, 1);
  assert.equal(s.status(), 'submitted');
  assert.equal(s.submit(), 'unavailable');
  s.tick();
  assert.equal(s.passport.clicks, 1);
});

test('a claimed trusted origin from an unrelated frame cannot receive credentials', () => {
  const s = scene({passport: false});
  s.inject(s.main, {origin: 'https://auth.alipan.com', source: {}, data: {asterLogin: scripts.id, kind: 'ready'}});
  assert.equal(s.status(), 'waiting');
  assert.equal(s.submit(), 'unavailable');
  assert.equal(s.deliveries.filter(d => d.kind === 'credentials').length, 0);
});

test('navigation of either authentication frame stops password delivery', () => {
  const main = scene();
  main.authElement.src = 'https://untrusted.invalid/';
  assert.equal(main.submit(), 'unavailable');
  const nested = scene();
  nested.passportElement.src = 'https://untrusted.invalid/';
  assert.equal(nested.submit(), 'sent');
  nested.tick(100);
  assert.equal(nested.passport.password.value, '');
  assert.equal(nested.status(), 'unavailable');
});

test('top-level navigation, expiry and a disabled official form cannot submit', () => {
  const moved = scene();
  moved.main.window.location.origin = 'https://untrusted.invalid';
  assert.equal(moved.submit(), 'unavailable');
  const expired = scene();
  expired.tick(60001);
  assert.equal(expired.submit(), 'unavailable');
  const disabled = scene();
  disabled.passport.button.disabled = true;
  disabled.submit(); disabled.tick(100);
  assert.equal(disabled.passport.clicks, 0);
  assert.equal(disabled.status(), 'unavailable');
});

test('a sibling frame cannot submit to the passport even with the expected origin', () => {
  const s = scene();
  s.inject(s.passport, {origin: 'https://auth.alipan.com', source: {}, data: {asterLogin: scripts.id, kind: 'credentials', username: 'wrong', password: 'wrong'}});
  s.tick(100);
  assert.equal(s.passport.password.value, '');
  assert.equal(s.passport.clicks, 0);
  s.submit(); s.tick(100);
  assert.equal(s.passport.clicks, 1);
});

test('a previous attempt cannot announce readiness for this attempt', () => {
  const s = scene({passport: false});
  s.inject(s.main, {origin: 'https://auth.alipan.com', source: s.auth.window, data: {asterLogin: 'old-attempt', kind: 'ready'}});
  assert.equal(s.status(), 'waiting');
});

test('desktop viewport stays wide and zoomable after a provider rewrites it', () => {
  const script = viewport;
  const tags = [{name: 'viewport', content: 'width=device-width,user-scalable=no'}];
  let observe;
  const window = {addEventListener() {}}; window.top = window;
  const context = {
    window, location: {protocol: 'https:'},
    document: {head: {querySelectorAll: () => tags, appendChild: tag => tags.push(tag)}},
    MutationObserver: class {constructor(fn) { observe = fn; } observe() {}},
  };
  vm.runInNewContext(script, context);
  assert.ok(tags[0].content.includes('width=1280'));
  assert.ok(tags[0].content.includes('user-scalable=yes'));
  assert.ok(!tags[0].content.includes('initial-scale=1'));
  tags.push({name: 'viewport', content: 'width=device-width,maximum-scale=1'});
  observe();
  assert.equal(tags[0].content, tags[1].content);
  window.top = {};
  const nested = {name: 'viewport', content: 'width=device-width'};
  context.document.head.querySelectorAll = () => [nested];
  vm.runInNewContext(script, context);
  assert.equal(nested.content, 'width=device-width');
});

function viewportScene(hostname, hash = '#/oauth/login', protocol = 'https:', pathname = '/') {
  const tags = [{name: 'viewport', content: 'width=1100,user-scalable=no'}];
  const attributes = new Set(), listeners = new Map();
  const location = {protocol, hostname, hash, pathname, origin: `${protocol}//${hostname}`};
  const document = {
    head: {
      querySelectorAll: () => tags.filter(tag => tag.name === 'viewport'),
      appendChild: tag => tags.push(tag),
    },
    documentElement: {toggleAttribute: (name, enabled) => enabled ? attributes.add(name) : attributes.delete(name)},
    createElement: () => ({}),
    getElementById: id => tags.find(tag => tag.id === id),
  };
  const window = {addEventListener: (event, callback) => listeners.set(event, callback)};
  window.top = window;
  vm.runInNewContext(viewport, {
    window, location, document,
    MutationObserver: class {observe() {}},
  });
  return {tags, attributes, location, change: () => listeners.get('hashchange')()};
}

test('Guangya official login fits the phone and restores desktop width when leaving the login route', () => {
  const page = viewportScene('www.guangyapan.com');
  assert.ok(page.tags[0].content.includes('width=device-width'));
  assert.ok(page.tags[0].content.includes('user-scalable=yes'));
  assert.ok(page.attributes.has('data-aster-guangya-login'));
  assert.ok(page.tags[1].textContent.includes('min-width:0!important'));
  page.location.hash = '#/drive'; page.change();
  assert.ok(page.tags[0].content.includes('width=1280'));
  assert.equal(page.attributes.has('data-aster-guangya-login'), false);
  page.location.hash = '#/oauth/login?redirect=drive'; page.change();
  assert.equal(page.tags.length, 2, 'the layout style must not be duplicated');
  assert.ok(page.attributes.has('data-aster-guangya-login'));
});

test('Guangya layout is limited to its trusted HTTPS login route', () => {
  for (const host of ['www.guangyapan.com.invalid', 'www.weiyun.com', 'www.ilanzou.com']) {
    const page = viewportScene(host);
    assert.ok(page.tags[0].content.includes('width=1280'));
    assert.equal(page.tags.length, 1);
  }
  assert.equal(viewportScene('www.guangyapan.com', '#/oauth/login', 'http:').tags[0].content,
    'width=1100,user-scalable=no');
});

test('Tianyi portal form stays within a 400px zoomable viewport on phones', () => {
  const route = '/api/logbox/separate/web/index.html';
  const page = viewportScene('open.e.189.cn', '', 'https:', route);
  assert.ok(page.tags[0].content.includes('width=400'));
  assert.ok(page.tags[0].content.includes('user-scalable=yes'));
  assert.ok(!page.tags[0].content.includes('initial-scale=1'));
  page.location.pathname = '/other'; page.change();
  assert.ok(page.tags[0].content.includes('width=1280'));
  for (const host of ['open.e.189.cn.invalid', 'cloud.189.cn', 'www.alipan.com']) {
    assert.ok(viewportScene(host, '', 'https:', route).tags[0].content.includes('width=1280'));
  }
});

function storageScene({local = {}, session = {}, cookie = '', origin = 'https://www.ilanzou.com'} = {}) {
  const storage = entries => new Proxy({
    entries: new Map(Object.entries(entries)),
    getItem(key) { return this.entries.get(key) ?? null; },
    setItem(key, value) { this.entries.set(key, String(value)); },
    removeItem(key) { this.entries.delete(key); },
  }, {
    ownKeys(target) { return [...target.entries.keys()]; },
    getOwnPropertyDescriptor(target, key) {
      return target.entries.has(key) ? {configurable: true, enumerable: true, value: target.entries.get(key)} : undefined;
    },
  });
  const localStorage = storage(local), sessionStorage = storage(session);
  const context = {localStorage, sessionStorage, document: {cookie}, location: {origin}};
  context.window = context;
  context.top = context;
  return {localStorage, sessionStorage, run: script => vm.runInNewContext(script, context)};
}

test('PikPak captures the current client-scoped SDK storage and browser device', () => {
  const key = 'credentials_YUMx5nI8ZU8Ap8pm';
  const device = '0123456789abcdef0123456789abcdef';
  const pair = {sub: 'current-user', access_token: 'current-access-0123456789', refresh_token: 'current-refresh-0123456789', expires_at: '2099-01-01'};
  for (const stored of [pair, {credentials: pair}, {data: JSON.stringify(pair)}, JSON.stringify(pair)]) {
    const page = storageScene({origin: 'https://mypikpak.com', local: {
      [key]: JSON.stringify(stored), deviceid: 'div101.' + device + 'signature',
      captcha_YUMx5nI8ZU8Ap8pm: JSON.stringify({action: 'GET:/drive/v1/about', captcha_token: 'current-captcha-0123456789', expires_at: '2099-01-01'}),
    }});
    const result = JSON.parse(page.run(scripts.pikpak.read));
    assert.equal(result.client_id, 'YUMx5nI8ZU8Ap8pm');
    assert.equal(result.access_token, pair.access_token);
    assert.equal(result.refresh_token, pair.refresh_token);
    assert.equal(result.device_id, device);
    assert.equal(result.sub, 'current-user');
    assert.equal(result.captcha_token, 'current-captcha-0123456789');
  }
});

test('PikPak follows current_sub and rejects stale or unidentified accounts', () => {
  const key = 'credentials_YUMx5nI8ZU8Ap8pm';
  const current = {sub: 'new-user', access_token: 'new-access-0123456789', refresh_token: 'new-refresh-0123456789'};
  const stale = {sub: 'old-user', access_token: 'old-access-0123456789'};
  for (const selector of ['new-user', JSON.stringify('new-user')]) {
    const page = storageScene({local: {current_sub: selector, [key]: JSON.stringify(stale), [key + '@new-user']: JSON.stringify(current)}});
    assert.equal(JSON.parse(page.run(scripts.pikpak.read)).sub, 'new-user');
  }
  for (const value of ['null', '[]', '{broken', JSON.stringify(stale), JSON.stringify({access_token: current.access_token})]) {
    const page = storageScene({local: {current_sub: 'new-user', [key]: JSON.stringify(stale), [key + '@new-user']: value}});
    assert.equal(page.run(scripts.pikpak.read), '');
  }
  const onlyStaleScoped = storageScene({local: {[key + '@old-user']: JSON.stringify(stale)}});
  assert.equal(onlyStaleScoped.run(scripts.pikpak.read), '');
  const numericSub = '12345678901234567890';
  const numericDevice = '12345678901234567890123456789012';
  const numeric = storageScene({local: {
    current_sub: numericSub, deviceid: numericDevice,
    [key + '@' + numericSub]: JSON.stringify({sub: numericSub, access_token: 'current-access-0123456789'}),
  }});
  const captured = JSON.parse(numeric.run(scripts.pikpak.read));
  assert.equal(captured.sub, numericSub);
  assert.equal(captured.device_id, numericDevice);
});

test('PikPak supports sessionStorage and old storage without mixing accounts or clients', () => {
  const key = 'credentials_YUMx5nI8ZU8Ap8pm';
  for (const legacy of ['credentials', 'credentials@new-user', 'token', key]) {
    const page = storageScene({local: {[key]: JSON.stringify({sub: 'old-user', access_token: 'old-access'})}, session: {
      current_sub: 'new-user', [legacy]: JSON.stringify({sub: 'new-user', accessToken: 'new-access-0123456789', refreshToken: 'new-refresh-0123456789'}),
      _deviceid: JSON.stringify('abcdef0123456789abcdef0123456789'),
    }});
    const result = JSON.parse(page.run(scripts.pikpak.read));
    assert.equal(result.sub, 'new-user');
    assert.equal(result.device_id, 'abcdef0123456789abcdef0123456789');
  }
  const wrongClient = storageScene({local: {[key]: JSON.stringify({client_id: 'different-client', access_token: 'other-access-0123456789'})}});
  assert.equal(wrongClient.run(scripts.pikpak.read), '');
  const otherClientKey = storageScene({local: {credentials_otherclient: JSON.stringify({access_token: 'other-access-0123456789'})}});
  assert.equal(otherClientKey.run(scripts.pikpak.read), '');
});

test('PikPak ignores expired or mismatching captcha metadata', () => {
  const key = 'credentials_YUMx5nI8ZU8Ap8pm';
  for (const captcha of [
    '{broken', 'null', JSON.stringify({captcha_token: 'expired', expires_at: '2000-01-01'}),
    JSON.stringify({sub: 'different-user', captcha_token: 'wrong', expires_at: '2099-01-01'}),
  ]) {
    const page = storageScene({local: {
      [key]: JSON.stringify({sub: 'current-user', access_token: 'current-access-0123456789'}),
      captcha_YUMx5nI8ZU8Ap8pm: captcha,
    }});
    assert.equal(JSON.parse(page.run(scripts.pikpak.read)).captcha_token, undefined);
  }
});

test('PikPak clears old credentials once per login while preserving device and preferences', () => {
  const key = 'credentials_YUMx5nI8ZU8Ap8pm';
  for (const origin of ['https://mypikpak.com', 'https://www.mypikpak.com']) {
    const page = storageScene({origin, local: {
      [key]: 'old', [key + '@old']: 'old', current_sub: 'old', credentials: 'old', 'credentials@old': 'old', token: 'old',
      captcha_YUMx5nI8ZU8Ap8pm: 'old', oauth_sign_in_YUMx5nI8ZU8Ap8pm: 'old',
      deviceid: 'preserved-device', locale: 'zh-CN', credentials_otherclient: 'preserve',
    }, session: {[key]: 'old'}});
    assert.equal(page.run(scripts.pikpak.prepare), 'cleared');
    assert.deepEqual(Object.keys(page.localStorage), ['deviceid', 'locale', 'credentials_otherclient']);
    assert.equal(page.sessionStorage.getItem(key), null);
    page.localStorage.setItem(key, JSON.stringify({access_token: 'new-access-0123456789'}));
    assert.equal(page.run(scripts.pikpak.prepare), 'ready');
    assert.equal(JSON.parse(page.run(scripts.pikpak.read)).access_token, 'new-access-0123456789');
    assert.equal(page.run(scripts.pikpak.nextSession), 'cleared');
    assert.equal(page.run(scripts.pikpak.read), '');
  }
  const untrusted = storageScene({origin: 'https://mypikpak.com.invalid', local: {[key]: 'preserve'}});
  assert.equal(untrusted.run(scripts.pikpak.prepare), 'untrusted');
  assert.equal(untrusted.localStorage.getItem(key), 'preserve');
});

test('ILanzou reads the current disk-pc-vuex key used by the official desktop client', {skip: !scripts.ilanzou}, () => {
  const page = storageScene({local: {'disk-pc-vuex': JSON.stringify({common: {
    appToken: 'fixture-token:with+/=&reserved', uuid: 'fixture-device', private: 'ignore',
  }}), unrelated: 'preserve'}});
  assert.deepEqual(JSON.parse(page.run(scripts.ilanzou.read)), {
    appToken: 'fixture-token:with+/=&reserved', uuid: 'fixture-device',
  });
  page.run(scripts.ilanzou.clear);
  assert.equal(page.run(scripts.ilanzou.read), '');
  assert.equal(page.localStorage.getItem('unrelated'), 'preserve');
});

test('Xunlei reads the current account and retains its matching browser metadata', () => {
  const key = 'credentials_Xqp0kJBXWhwaTpB6';
  const pair = {access_token: 'current-access', refresh_token: 'current-refresh', sub: 'current'};
  for (const multiple of [false, true]) {
    const local = {
      [multiple ? key + '@current' : key]: JSON.stringify(pair),
      [key + '@old']: JSON.stringify({access_token: 'old-access', sub: 'old'}),
      captcha_Xqp0kJBXWhwaTpB6: JSON.stringify({token: 'current-captcha', expires_at: new Date(Date.now() + 60000).toISOString()}),
      ...(multiple ? {current_sub: 'current', [key]: JSON.stringify({access_token: 'legacy-old'})} : {}),
    };
    const page = storageScene({local, cookie: 'deviceid=w.12345678901234567890123456789012.signature', origin: 'https://pan.xunlei.com'});
    assert.deepEqual(JSON.parse(page.run(scripts.xunlei.read)), {...pair, captcha_token: 'current-captcha', device_id: '12345678901234567890123456789012'});
  }
});

test('Xunlei does not fall back to a different account or submit malformed storage', () => {
  const key = 'credentials_Xqp0kJBXWhwaTpB6';
  for (const value of [undefined, '{broken', 'null', '[]', JSON.stringify({sub: 'another', access_token: 'wrong'})]) {
    const page = storageScene({local: {current_sub: 'new', [key]: JSON.stringify({access_token: 'old'}), ...(value ? {[key + '@new']: value} : {})}});
    assert.equal(page.run(scripts.xunlei.read), '');
  }
});

test('Xunlei ignores expired or malformed optional captcha and device metadata', () => {
  const key = 'credentials_Xqp0kJBXWhwaTpB6';
  const pair = {access_token: 'current-access', refresh_token: 'current-refresh'};
  for (const captcha of ['{broken', 'null', JSON.stringify({token: 'expired', expires_at: '2000-01-01'})]) {
    const page = storageScene({local: {[key]: JSON.stringify(pair), captcha_Xqp0kJBXWhwaTpB6: captcha}, cookie: 'deviceid=%invalid'});
    assert.deepEqual(JSON.parse(page.run(scripts.xunlei.read)), pair);
  }
});

test('Xunlei clears all previous account tokens once per login session', () => {
  const key = 'credentials_Xqp0kJBXWhwaTpB6';
  const page = storageScene({origin: 'https://pan.xunlei.com', local: {
    [key]: 'old', [key + '@old']: 'old-account', current_sub: 'old', captcha_Xqp0kJBXWhwaTpB6: 'old-captcha', unrelated: 'preserve',
  }});
  assert.equal(page.run(scripts.xunlei.prepare), 'cleared');
  assert.deepEqual(Object.keys(page.localStorage), ['unrelated']);
  page.localStorage.setItem(key, JSON.stringify({access_token: 'new'}));
  assert.equal(page.run(scripts.xunlei.prepare), 'ready');
  assert.equal(JSON.parse(page.run(scripts.xunlei.read)).access_token, 'new');
  assert.equal(page.run(scripts.xunlei.nextSession), 'cleared');
  assert.equal(page.run(scripts.xunlei.read), '');
});

test('Xunlei resets the account center once and preserves the new provider callback', () => {
  const key = 'credentials_XW5SkOhLDjnOZP7J';
  const oauth = 'oauth_sign_in_XW5SkOhLDjnOZP7J';
  const page = storageScene({origin: 'https://i.xunlei.com', local: {
    [key]: 'old', [key + '@old']: 'old-account', current_sub: 'old',
    captcha_XW5SkOhLDjnOZP7J: 'old-captcha', [oauth]: 'old-provider-state',
    deviceid: 'preserve-device', unrelated: 'preserve',
  }, session: {[key]: 'old-session-account'}});
  assert.equal(page.run(scripts.xunlei.prepare), 'cleared');
  assert.deepEqual(Object.keys(page.localStorage), ['deviceid', 'unrelated']);
  assert.equal(page.sessionStorage.getItem(key), null);
  page.localStorage.setItem(oauth, 'new-provider-state');
  page.localStorage.setItem(key, 'new-account');
  assert.equal(page.run(scripts.xunlei.prepare), 'ready');
  assert.equal(page.localStorage.getItem(oauth), 'new-provider-state');
  assert.equal(page.localStorage.getItem(key), 'new-account');
  assert.equal(page.run(scripts.xunlei.nextSession), 'cleared');
  assert.equal(page.localStorage.getItem(oauth), null);
  assert.equal(page.localStorage.getItem(key), null);
  for (const origin of ['https://account.xiaomi.com', 'https://i.xunlei.com.attacker.invalid']) {
    const external = storageScene({origin, local: {[key]: 'preserve'}});
    assert.equal(external.run(scripts.xunlei.prepare), 'untrusted');
    assert.equal(external.localStorage.getItem(key), 'preserve');
  }
});

test('ILanzou prefers the current store and still accepts the legacy vuex key', {skip: !scripts.ilanzou}, () => {
  const current = JSON.stringify({common: {appToken: 'current-token-0123456789', uuid: 'current-device'}});
  const legacy = JSON.stringify({common: {appToken: 'legacy-token-0123456789', uuid: 'legacy-device'}});
  for (const primary of ['', '{broken', current]) {
    const page = storageScene({local: {'disk-pc-vuex': primary, vuex: legacy}});
    const data = JSON.parse(page.run(scripts.ilanzou.read));
    assert.equal(data.appToken, primary === current ? 'current-token-0123456789' : 'legacy-token-0123456789');
  }
});

test('ILanzou accepts its encoded cookie when Vuex is missing or malformed', {skip: !scripts.ilanzou}, () => {
  for (const vuex of ['', '{broken']) {
    const page = storageScene({local: {vuex}, cookie: 'unrelated=ignore; appToken=fixture%3Atoken%2B%2F%3D'});
    assert.deepEqual(JSON.parse(page.run(scripts.ilanzou.read)), {appToken: 'fixture:token+/=', uuid: ''});
  }
});

test('Wopan reads its official session-storage pair and clears login keys in both stores', {skip: !scripts.wopan}, () => {
  for (const quoted of [false, true]) {
    const value = token => quoted ? JSON.stringify(token) : token;
    const page = storageScene({
      session: {token: value('fixture-access'), refreshToken: value('fixture-refresh'), unrelated: 'preserve'},
      local: {token: 'old-login', unrelated: 'preserve-local'},
    });
    assert.deepEqual(JSON.parse(page.run(scripts.wopan.read)), {
      access_token: 'fixture-access', refresh_token: 'fixture-refresh',
    });
    page.run(scripts.wopan.clear);
    assert.equal(page.run(scripts.wopan.read), '');
    assert.equal(page.sessionStorage.getItem('unrelated'), 'preserve');
    assert.equal(page.localStorage.getItem('token'), null);
    assert.equal(page.localStorage.getItem('unrelated'), 'preserve-local');
  }
});

test('Wopan supports persisted token objects and alternate official token names', {skip: !scripts.wopan}, () => {
  const pair = {access_token: 'fixture-access-0123456789', refresh_token: 'fixture-refresh-0123456789'};
  for (const local of [pair, {accessToken: pair.access_token, refreshToken: pair.refresh_token},
    {token: JSON.stringify(pair)}, {token: JSON.stringify({data: pair})}]) {
    const page = storageScene({local});
    assert.deepEqual(JSON.parse(page.run(scripts.wopan.read)), pair);
  }
});

test('Wopan never combines access and refresh tokens from different storage sessions', {skip: !scripts.wopan}, () => {
  const page = storageScene({session: {token: 'session-access'}, local: {refreshToken: 'local-refresh'}});
  assert.deepEqual(JSON.parse(page.run(scripts.wopan.read)), {access_token: '', refresh_token: 'local-refresh'});
});

test('Login storage is prepared once before page scripts and never erases a completed login on load-stop', () => {
  for (const [name, origin, key, value] of [
    ['ilanzou', 'https://www.ilanzou.com', 'disk-pc-vuex', JSON.stringify({common: {appToken: 'new-token-0123456789'}})],
    ['wopan', 'https://panservice.mail.wo.cn', 'refreshToken', 'new-refresh-0123456789'],
    ['wopan', 'https://pan.wo.cn', 'refreshToken', 'new-refresh-0123456789'],
  ]) {
    const page = storageScene({origin});
    const store = name === 'ilanzou' ? page.localStorage : page.sessionStorage;
    store.setItem(key, 'previous-session');
    assert.equal(page.run(scripts[name].prepare), 'cleared');
    assert.equal(store.getItem(key), null);
    store.setItem(key, value);
    assert.equal(page.run(scripts[name].prepare), 'ready');
    assert.equal(store.getItem(key), value);
    assert.equal(page.run(scripts[name].nextSession), 'cleared');
    assert.equal(store.getItem(key), null);
  }
});

test('Login preparation ignores unrelated origins and nested frames', () => {
  const page = storageScene({origin: 'https://www.ilanzou.com.attacker.invalid', local: {'disk-pc-vuex': 'preserve'}});
  assert.equal(page.run(scripts.ilanzou.prepare), 'untrusted');
  assert.equal(page.localStorage.getItem('disk-pc-vuex'), 'preserve');
});

test('Wopan waits for the refresh token instead of submitting a partial web login', {skip: !scripts.wopan}, () => {
  assert.equal(storageScene({session: {token: 'fixture-access'}}).run(scripts.wopan.read), '');
});

function weiyunScene({origin = 'https://www.weiyun.com', nested = false} = {}) {
  const calls = [];
  class Xhr {
    open(...args) { calls.push(['open', ...args]); return 'opened'; }
    send(body) { calls.push(['send', body]); return 'sent'; }
  }
  const window = {
    fetch(...args) { calls.push(['fetch', ...args]); return Promise.resolve('fetched'); },
  };
  window.top = nested ? {} : window;
  const document = {cookie: 'weiyun_qq_openid=qq-fixture'};
  const context = vm.createContext({
    window, document, location: {origin, href: `${origin}/disk`},
    URL, URLSearchParams, FormData, Request, XMLHttpRequest: Xhr,
  });
  const run = source => vm.runInContext(source, context);
  run(scripts.weiyun.bootstrap);
  return {window, document, Xhr, calls, run, read: () => {
    const raw = run(scripts.weiyun.read);
    return raw ? JSON.parse(raw) : null;
  }};
}

const weiAddress = 'https://www.weiyun.com/webapp/json/weiyunQdisk/DiskDirList?g_tk=observed-csrf&cmd=2208';
const weiInfo = {token_type: 3, login_key_type: 1540, qq_openid: 'qq-fixture'};
const weiHeader = {user_flag: 3, uin: '12345', qq_openid: 'qq-fixture'};
const weiPayload = {
  req_body: JSON.stringify({ReqMsg_body: {ext_req_head: {token_info: weiInfo}, '.weiyun.DiskDirListMsgReq_body': {dir_key: 'private-not-captured'}}}),
  req_header: JSON.stringify(weiHeader),
};

test('Weiyun observes official XHR authentication without changing the request', () => {
  const page = weiyunScene();
  const xhr = new page.Xhr(), body = JSON.stringify(weiPayload);
  assert.equal(xhr.open('POST', weiAddress, true), 'opened');
  assert.equal(xhr.send(body), 'sent');
  assert.deepEqual(page.calls, [['open', 'POST', weiAddress, true], ['send', body]]);
  assert.deepEqual(page.read(), {cookie: page.document.cookie, tokenInfo: weiInfo, requestHeader: weiHeader, csrf: 'observed-csrf'});
  assert.ok(!JSON.stringify(page.read()).includes('private-not-captured'));
  page.run(scripts.weiyun.bootstrap);
  xhr.send(body);
  assert.equal(page.calls.filter(c => c[0] === 'send').length, 2);
});

test('Weiyun accepts JSON, URL-encoded and FormData request bodies', () => {
  const formData = new FormData();
  for (const [key, value] of Object.entries(weiPayload)) formData.set(key, value);
  for (const body of [JSON.stringify(weiPayload), new URLSearchParams(weiPayload).toString(), new URLSearchParams(weiPayload), formData]) {
    const page = weiyunScene(), xhr = new page.Xhr();
    xhr.open('POST', weiAddress); xhr.send(body);
    assert.deepEqual(page.read().tokenInfo, weiInfo);
    assert.deepEqual(page.read().requestHeader, weiHeader);
  }
});

test('Weiyun observes fetch init and cloned Request bodies without consuming them', async () => {
  for (const body of [JSON.stringify(weiPayload), new URLSearchParams(weiPayload)]) {
    const page = weiyunScene();
    assert.equal(await page.window.fetch(weiAddress, {method: 'POST', body}), 'fetched');
    assert.deepEqual(page.read().tokenInfo, weiInfo);
    assert.equal(page.calls[0][2].body, body);
  }
  const page = weiyunScene(), request = new Request(weiAddress, {method: 'POST', body: JSON.stringify(weiPayload)});
  assert.equal(await page.window.fetch(request), 'fetched');
  for (let tries = 0; !page.read().tokenInfo && tries < 30; tries++) await new Promise(resolve => setTimeout(resolve, 5));
  assert.deepEqual(page.read().tokenInfo, weiInfo);
  assert.equal(request.bodyUsed, false);
  assert.equal(await request.text(), JSON.stringify(weiPayload));
});

test('Weiyun ignores unrelated domains, APIs and requests lacking authentication', () => {
  const page = weiyunScene();
  for (const url of ['https://untrusted.invalid/webapp/json/test?g_tk=x', 'https://www.weiyun.com.attacker.invalid/webapp/json/test', 'http://www.weiyun.com/webapp/json/test', 'https://www.weiyun.com:444/webapp/json/test', 'https://www.weiyun.com/other']) {
    const xhr = new page.Xhr(); xhr.open('POST', url); xhr.send(JSON.stringify(weiPayload));
  }
  const xhr = new page.Xhr(); xhr.open('POST', weiAddress); xhr.send('{invalid'); xhr.send('{}');
  assert.deepEqual(page.read(), {cookie: page.document.cookie});
});

test('Weiyun installs only in its trusted top-level page', () => {
  for (const options of [{origin: 'https://www.weiyun.com.attacker.invalid'}, {origin: 'https://graph.qq.com'}, {origin: 'http://www.weiyun.com'}, {nested: true}]) {
    const page = weiyunScene(options);
    assert.equal(page.window.__asterWeiyunLogin, undefined);
    assert.equal(page.read(), null);
    const xhr = new page.Xhr(); xhr.open('POST', weiAddress); xhr.send(JSON.stringify(weiPayload));
    assert.equal(page.window.__asterWeiyunLogin, undefined);
  }
});

function tianyiScene({origin = 'https://cloud.189.cn', nested = false, iframeSrc = ''} = {}) {
  const calls = [], frame = {src: iframeSrc};
  class Xhr {
    open(...args) { calls.push(['open', ...args]); return 'opened'; }
    setRequestHeader(...args) { calls.push(['header', ...args]); return 'header-set'; }
    send(...args) { calls.push(['send', ...args]); return 'sent'; }
  }
  const window = {fetch: (...args) => { calls.push(['fetch', ...args]); return Promise.resolve('fetched'); }};
  window.top = nested ? {} : window;
  const document = {getElementById: id => id === 'udb_login' ? frame : null};
  const context = vm.createContext({window, document, location: {origin, href: `${origin}/web/login.html`}, URL, Headers, Request, XMLHttpRequest: Xhr});
  const run = source => vm.runInContext(source, context);
  run(scripts.tianyi.bootstrap);
  return {window, frame, calls, Xhr, run, read: () => {
    const raw = run(scripts.tianyi.read);
    return raw ? JSON.parse(raw) : null;
  }};
}

const tianyiBrowser = '0123456789abcdef0123456789abcdef';
const tianyiApi = 'https://cloud.189.cn/api/open/user/getUserInfoForPortal.action';

test('Tianyi retains the exact browser binding from its official login iframe', () => {
  const page = tianyiScene({iframeSrc: `https://cloud.189.cn/api/portal/loginUrl.action?browserId=${tianyiBrowser}&ticket=not-captured`});
  assert.deepEqual(page.read(), {browserId: tianyiBrowser});
  page.frame.src = 'https://open.e.189.cn/other';
  assert.deepEqual(page.read(), {browserId: tianyiBrowser});
  assert.deepEqual(page.calls, []);
});

test('Tianyi observes XHR Browser-Id without changing headers, bodies or return values', () => {
  const page = tianyiScene(), xhr = new page.Xhr();
  assert.equal(xhr.open('GET', tianyiApi, true), 'opened');
  assert.equal(xhr.setRequestHeader('browser-id', tianyiBrowser), 'header-set');
  xhr.setRequestHeader('Other', 'not-captured');
  assert.equal(xhr.send('not-captured'), 'sent');
  assert.deepEqual(page.read(), {browserId: tianyiBrowser});
  assert.deepEqual(page.calls, [['open', 'GET', tianyiApi, true], ['header', 'browser-id', tianyiBrowser], ['header', 'Other', 'not-captured'], ['send', 'not-captured']]);
  page.run(scripts.tianyi.bootstrap);
  xhr.send();
  assert.equal(page.calls.filter(c => c[0] === 'send').length, 2);
});

test('Tianyi observes fetch headers and Request headers without consuming request bodies', async () => {
  for (const headers of [{'Browser-Id': tianyiBrowser}, new Headers({'Browser-Id': tianyiBrowser}), [['browser-id', tianyiBrowser]]]) {
    const page = tianyiScene();
    assert.equal(await page.window.fetch(tianyiApi, {headers}), 'fetched');
    assert.deepEqual(page.read(), {browserId: tianyiBrowser});
    assert.equal(page.calls[0][2].headers, headers);
  }
  const page = tianyiScene(), request = new Request(tianyiApi, {method: 'POST', headers: {'Browser-Id': tianyiBrowser}, body: 'not-captured'});
  await page.window.fetch(request);
  assert.deepEqual(page.read(), {browserId: tianyiBrowser});
  assert.equal(request.bodyUsed, false);
});

test('Tianyi ignores unrelated requests, frames and unsafe browser identifiers', () => {
  for (const address of ['https://cloud.189.cn.attacker.invalid/api/test', 'http://cloud.189.cn/api/test', 'https://cloud.189.cn:444/api/test', 'https://user@cloud.189.cn/api/test', 'https://cloud.189.cn/other']) {
    const page = tianyiScene(), xhr = new page.Xhr();
    xhr.open('GET', address); xhr.setRequestHeader('Browser-Id', tianyiBrowser); xhr.send();
    assert.deepEqual(page.read(), {browserId: ''});
  }
  for (const options of [{origin: 'https://cloud.189.cn.attacker.invalid'}, {origin: 'https://open.e.189.cn'}, {origin: 'http://cloud.189.cn'}, {nested: true}]) {
    const page = tianyiScene(options);
    assert.equal(page.window.__asterTianyiLogin, undefined);
    assert.equal(page.read(), null);
  }
  const page = tianyiScene(), xhr = new page.Xhr();
  xhr.open('GET', tianyiApi); xhr.setRequestHeader('Browser-Id', 'value\r\nInjected: true'); xhr.send();
  assert.deepEqual(page.read(), {browserId: ''});
});

function tianyiPortalForm({origin = 'https://open.e.189.cn', pathname = '/api/logbox/separate/web/index.html', appId = 'cloud', nested = false} = {}) {
  const window = {};
  window.top = nested ? {} : window;
  const nodes = new Map(), timers = [], observers = [];
  class Observer {
    constructor(fn) { this.fn = fn; this.closed = false; observers.push(this); }
    observe() {}
    disconnect() { this.closed = true; }
  }
  const context = vm.createContext({window, location: {origin, pathname, href: `${origin}${pathname}?appId=${appId}`}, URL, document: {getElementById: id => nodes.get(id)}, MutationObserver: Observer, setTimeout: (fn, delay) => timers.push({fn, delay})});
  const run = () => vm.runInContext(scripts.tianyi.form, context);
  return {nodes, timers, observers, run};
}

test('Tianyi portal entry opens the SMS form once without submitting login or requesting codes', () => {
  const page = tianyiPortalForm();
  let accountClicks = 0, smsClicks = 0, submissions = 0;
  page.nodes.set('j-login', {getClientRects: () => [1], click: () => submissions++});
  page.nodes.set('j-msg-verifyCode', {getClientRects: () => [1], click: () => submissions++});
  page.nodes.set('j-agreement-box', {getClientRects: () => [1], click: () => submissions++});
  page.nodes.set('tab-pw', {getClientRects: () => [1], click: () => accountClicks++});
  page.nodes.set('j-jump-sms', {getClientRects: () => accountClicks ? [1] : [], click: () => smsClicks++});
  page.run();
  assert.equal(accountClicks, 1);
  assert.equal(smsClicks, 0);
  assert.equal(submissions, 0);
  page.observers[0].fn();
  assert.equal(smsClicks, 1);
  assert.equal(page.observers[0].closed, true);
  page.run();
  assert.equal(accountClicks, 1);
  assert.equal(smsClicks, 1);
  assert.equal(submissions, 0);
  assert.equal(page.timers[0].delay, 15000);
  page.timers[0].fn();
});

test('Tianyi SMS form selection stays within the official cloud portal login page', () => {
  for (const options of [{origin: 'https://open.e.189.cn.attacker.invalid'}, {origin: 'http://open.e.189.cn'}, {pathname: '/api/logbox/separate/wap/index.html'}, {appId: 'another-app'}, {nested: true}]) {
    const page = tianyiPortalForm(options);
    page.run();
    assert.equal(page.observers.length, 0);
  }
  const page = tianyiPortalForm();
  let clicks = 0;
  page.nodes.set('tab-pw', {getClientRects: () => [], click: () => clicks++});
  page.nodes.set('j-jump-sms', {getClientRects: () => [1], disabled: true, click: () => clicks++});
  page.run();
  assert.equal(clicks, 0);
});
