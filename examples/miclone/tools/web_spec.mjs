// The one JS line the web profile requires, for all eleven spec shells.
//
//   node tools/web_spec.mjs web_world_spec
//
// A web-profile module exports an entry and the host calls it — there are no
// top-level statements in the profile, which is why `net.html` ends in
// `import { main } from "./dist/net_main.mjs"; main();`. This is that, made
// generic, and it replaced eleven hand-written shells of seventeen lines each.
// Everything those shells did is now `probes/web_*.gene`, in the language under
// test; what is left here is the call, which cannot be.
const name = process.argv[2];
if (!name) { console.error("usage: node tools/web_spec.mjs <web_spec_module>"); process.exit(2); }
const mod = await import(new URL(`../dist/${name}.mjs`, import.meta.url).pathname);
mod.main();
