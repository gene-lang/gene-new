// Browser/Node adapter for the text-only host ABI. No guest Value escapes.
export function createGeneHost(module) {
  const encode = new TextEncoder();
  const decode = new TextDecoder();
  function allocateResult(source) {
    const bytes = encode.encode(source);
    const pointer = bytes.length ? module._gene_alloc(bytes.length) : 0;
    if (bytes.length && !pointer) throw new Error('gene_alloc failed');
    try {
      if (bytes.length) module.HEAPU8.set(bytes, pointer);
      const handle = module._gene_eval(pointer, bytes.length);
      if (handle <= 0) throw new Error('gene_eval rejected input');
      return handle;
    } finally {
      if (pointer) module._gene_free(pointer);
    }
  }
  function readString(pointer, length) {
    return length ? decode.decode(module.HEAPU8.subarray(pointer, pointer + length)) : '';
  }
  function readResult(handle) {
    return {status: module._gene_result_status(handle),
      text: readString(module._gene_result_text_ptr(handle), module._gene_result_text_len(handle)),
      out: readString(module._gene_result_out_ptr(handle), module._gene_result_out_len(handle))};
  }
  function release(handle) { module._gene_result_free(handle); }
  function evaluate(source) {
    const handle = allocateResult(source);
    try { return readResult(handle); }
    finally { release(handle); }
  }
  return {allocateResult, readResult, release, evaluate};
}
