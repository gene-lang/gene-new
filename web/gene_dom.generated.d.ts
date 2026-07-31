// The DOM ABI shapes the web profile's generated renderer uses, as TypeScript
// declarations for `transpile_typecheck` to compile against.
//
// This file is hand-maintained. It is NOT the source of truth for what Gene can
// call — src/gene/web.nim is, and tools/check_host_bindings.mjs verifies that
// surface against the pinned lib.dom.d.ts. An earlier generator wrote this file
// and a JSON allowlist that nothing read, and the allowlist drifted until three
// of its nine advertised methods were not callable from Gene at all.
export interface GeneDomBindings {
  create_element(document: Document, tag_name: string): Element;
  create_text_node(document: Document, text: string): Text;
  create_document_fragment(document: Document): DocumentFragment;
  append_child(parent: Node, child: Node): Node;
  remove_child(parent: Node, child: Node): Node;
  set_attribute(element: Element, name: string, value: string): void;
  remove_attribute(element: Element, name: string): void;
  add_event_listener(target: EventTarget, type: string, listener: (event: Event) => void): void;
  remove_event_listener(target: EventTarget, type: string, listener: (event: Event) => void): void;
}
