// A small DOM for running compiled Gene browser components under Node.
//
// The editor component is ordinary web-profile Gene; only its host objects are
// JavaScript. This file supplies exactly the surface the component calls —
// element creation, attributes, classes, text, events, a textarea's value and
// selection, and the scroll metrics follow-mode reads — so the scenario module
// can mount, edit, reveal, save, and tail a log without a browser.
//
// It is deliberately a test double, not a DOM: no layout, no CSS cascade, no
// focus trapping. A test that needs those belongs in a real browser.

class FakeNode {
  constructor(document, nodeType, tagName) {
    this.ownerDocument = document;
    this.nodeType = nodeType;
    this.tagName = tagName;
    this.childNodes = [];
    this.parentNode = null;
    this._listeners = new Map();
    this._text = '';
  }

  get parentElement() {
    return this.parentNode && this.parentNode.nodeType === 1
      ? this.parentNode
      : null;
  }

  get firstChild() {
    return this.childNodes[0] ?? null;
  }

  get isConnected() {
    let node = this;
    while (node.parentNode) node = node.parentNode;
    return node === this.ownerDocument.body || node === this.ownerDocument;
  }

  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }

  append(...nodes) {
    for (const node of nodes) {
      this.appendChild(typeof node === 'string'
        ? this.ownerDocument.createTextNode(node)
        : node);
    }
  }

  insertBefore(child, reference) {
    if (child.parentNode) child.parentNode.removeChild(child);
    const at = reference ? this.childNodes.indexOf(reference) : -1;
    child.parentNode = this;
    if (at < 0) this.childNodes.push(child);
    else this.childNodes.splice(at, 0, child);
    return child;
  }

  removeChild(child) {
    const at = this.childNodes.indexOf(child);
    if (at >= 0) this.childNodes.splice(at, 1);
    child.parentNode = null;
    return child;
  }

  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }

  replaceChildren(...nodes) {
    for (const child of this.childNodes.slice()) this.removeChild(child);
    for (const node of nodes) this.appendChild(node);
  }

  contains(node) {
    let current = node;
    while (current) {
      if (current === this) return true;
      current = current.parentNode;
    }
    return false;
  }

  addEventListener(type, handler, capture = false) {
    const key = `${type}|${capture ? 1 : 0}`;
    const list = this._listeners.get(key) ?? [];
    if (!list.includes(handler)) list.push(handler);
    this._listeners.set(key, list);
  }

  removeEventListener(type, handler, capture = false) {
    const key = `${type}|${capture ? 1 : 0}`;
    const list = this._listeners.get(key) ?? [];
    const at = list.indexOf(handler);
    if (at >= 0) list.splice(at, 1);
    this._listeners.set(key, list);
  }

  listeners(type) {
    return [
      ...(this._listeners.get(`${type}|0`) ?? []),
      ...(this._listeners.get(`${type}|1`) ?? []),
    ];
  }

  dispatchEvent(event) {
    event.target = this;
    let node = this;
    while (node) {
      event.currentTarget = node;
      for (const handler of node.listeners(event.type)) handler(event);
      if (event.cancelBubble) break;
      node = node.parentNode;
    }
    event.currentTarget = null;
    return !event.defaultPrevented;
  }

  get textContent() {
    if (this.nodeType === 3) return this._text;
    if (this.nodeType === 8) return '';
    return this.childNodes.map(child => child.textContent).join('');
  }

  set textContent(value) {
    if (this.nodeType === 3) {
      this._text = value === null || value === undefined ? '' : String(value);
      return;
    }
    this.replaceChildren();
    const text = value === null || value === undefined ? '' : String(value);
    if (text !== '') this.appendChild(this.ownerDocument.createTextNode(text));
  }
}

class FakeText extends FakeNode {
  constructor(document, text) {
    super(document, 3, null);
    this._text = text;
  }

  get data() {
    return this._text;
  }

  set data(value) {
    this._text = String(value);
  }
}

class FakeElement extends FakeNode {
  constructor(document, tagName) {
    super(document, 1, tagName.toUpperCase());
    this._attributes = new Map();
    this._styles = new Map();
    this._classes = new Set();
    this.dataset = {};
    this.value = '';
    this.selectionStart = 0;
    this.selectionEnd = 0;
    this.scrollTop = 0;
    this._clientHeight = 400;
    this._scrollHeight = null;
    this.style = {
      setProperty: (name, value) => this._styles.set(name, String(value)),
      getPropertyValue: name => this._styles.get(name) ?? '',
      removeProperty: name => this._styles.delete(name),
    };
    this.classList = {
      toggle: (name, force) => {
        const on = force === undefined ? !this._classes.has(name) : Boolean(force);
        if (on) this._classes.add(name);
        else this._classes.delete(name);
        return on;
      },
      add: name => this._classes.add(name),
      remove: name => this._classes.delete(name),
      contains: name => this._classes.has(name),
    };
    this._scrollListener = null;
  }

  set className(value) {
    this._classes = new Set(String(value).split(/\s+/).filter(Boolean));
  }

  get className() {
    return [...this._classes].join(' ');
  }

  get id() {
    return this._attributes.get('id') ?? '';
  }

  set id(value) {
    this.setAttribute('id', value);
  }

  get hidden() {
    return this._attributes.has('hidden');
  }

  set hidden(value) {
    if (value) this._attributes.set('hidden', '');
    else this._attributes.delete('hidden');
  }

  setAttribute(name, value) {
    this._attributes.set(name, String(value));
    if (name === 'class') this.className = value;
  }

  getAttribute(name) {
    return this._attributes.has(name) ? this._attributes.get(name) : null;
  }

  hasAttribute(name) {
    return this._attributes.has(name);
  }

  removeAttribute(name) {
    this._attributes.delete(name);
  }

  get clientHeight() {
    return this._clientHeight;
  }

  set clientHeight(value) {
    this._clientHeight = Number(value);
  }

  get scrollHeight() {
    if (this._scrollHeight !== null) return this._scrollHeight;
    return Math.max(this._clientHeight, this.childNodes.length * 18);
  }

  set scrollHeight(value) {
    this._scrollHeight = Number(value);
  }

  get scrollLeft() {
    return 0;
  }

  get boundingClientRect() {
    const index = this.parentNode ? this.parentNode.childNodes.indexOf(this) : 0;
    return { top: index * 18, height: 18, left: 0, width: 200 };
  }

  getBoundingClientRect() {
    return this.boundingClientRect;
  }

  focus() {
    this.ownerDocument.activeElement = this;
    return undefined;
  }

  blur() {
    if (this.ownerDocument.activeElement === this) {
      this.ownerDocument.activeElement = this.ownerDocument.body;
    }
    return undefined;
  }

  setSelectionRange(start, end) {
    this.selectionStart = Number(start);
    this.selectionEnd = Number(end);
  }

  click() {
    this.dispatchEvent(new FakeEvent('click', {}));
    return undefined;
  }
}

class FakeEvent {
  constructor(type, init = {}) {
    this.type = type;
    this.bubbles = true;
    this.defaultPrevented = false;
    this.cancelBubble = false;
    this.target = null;
    this.currentTarget = null;
    this.timeStamp = Date.now();
    Object.assign(this, init);
  }

  preventDefault() {
    this.defaultPrevented = true;
  }

  stopPropagation() {
    this.cancelBubble = true;
  }
}

export function installDom() {
  const document = {
    createElement: tag => new FakeElement(document, tag),
    createTextNode: text => new FakeText(document, String(text)),
    createDocumentFragment: () => new FakeElement(document, '#fragment'),
    getElementById: id => findByAttribute(document.body, 'id', id),
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener() {},
    removeEventListener() {},
  };
  document.body = new FakeElement(document, 'body');
  document.activeElement = document.body;

  const windowListeners = new Map();
  const window = {
    addEventListener(type, handler) {
      if (!windowListeners.has(type)) windowListeners.set(type, new Set());
      windowListeners.get(type).add(handler);
    },
    removeEventListener(type, handler) {
      windowListeners.get(type)?.delete(handler);
    },
    dispatchEvent(event) {
      for (const handler of windowListeners.get(event.type) ?? []) handler(event);
      return true;
    },
    innerWidth: 1200,
    innerHeight: 800,
    setTimeout,
    clearTimeout,
    location: { href: 'http://localhost/', search: '', hash: '' },
  };

  const storage = new Map();
  const sessionStorage = {
    getItem: key => (storage.has(key) ? storage.get(key) : null),
    setItem: (key, value) => storage.set(key, String(value)),
    removeItem: key => storage.delete(key),
  };

  const copied = [];
  const navigator = {
    clipboard: {
      writeText: text => {
        copied.push(String(text));
        return Promise.resolve();
      },
    },
  };

  globalThis.document = document;
  globalThis.window = window;
  globalThis.sessionStorage = sessionStorage;
  globalThis.localStorage = sessionStorage;
  Object.defineProperty(globalThis, 'navigator', {
    value: navigator,
    configurable: true,
    writable: true,
  });
  globalThis.HTMLElement = FakeElement;
  globalThis.Element = FakeElement;

  return { document, window, sessionStorage, copied };
}

export function dispatch(target, type, init = {}) {
  const event = new FakeEvent(type, init);
  target.dispatchEvent(event);
  return event;
}

export function find(node, predicate) {
  if (predicate(node)) return node;
  for (const child of node.childNodes ?? []) {
    const found = find(child, predicate);
    if (found) return found;
  }
  return null;
}

export function findAll(node, predicate, out = []) {
  if (predicate(node)) out.push(node);
  for (const child of node.childNodes ?? []) findAll(child, predicate, out);
  return out;
}

export function findByTag(root, tagName) {
  return find(root, node => node.nodeType === 1 && node.tagName === tagName.toUpperCase());
}

export function findByClass(root, className) {
  return find(root, node => node.nodeType === 1 && node.classList?.contains(className));
}

function findByAttribute(root, name, value) {
  return find(
    root,
    node => node.nodeType === 1 && node.getAttribute && node.getAttribute(name) === value,
  );
}
